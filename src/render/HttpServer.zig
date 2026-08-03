// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

//! Bounded HTTP transport for one-shot and live client-side rendering.

const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const LiveSession = @import("LiveSession.zig");
const ResponseBuffer = @import("ResponseBuffer.zig");
const sys_net = @import("../sys/net.zig");

const HttpServer = @This();
const posix = std.posix;

const worker_stack_size = 4 * 1024 * 1024;
const connection_stack_size = 512 * 1024;
const worker_retained_arena_bytes = 64 * 1024;
const job_poll_interval_ms = 100;
const ns_per_ms = 1_000_000;

const client_js = @embedFile("client.js");
const client_etag = blk: {
    @setEvalBranchQuota(100_000);
    break :blk std.fmt.comptimePrint("W/\"{x}\"", .{std.hash.Wyhash.hash(0, client_js)});
};

const Result = enum {
    ok,
    bad_request,
    timeout,
    navigation_failed,
    response_too_large,
    not_found,
    conflict,
    live_active,
    unsupported,
    shutting_down,
    internal_error,

    fn status(self: Result) std.http.Status {
        return switch (self) {
            .ok => .ok,
            .bad_request => .bad_request,
            .timeout => .gateway_timeout,
            .navigation_failed => .bad_gateway,
            .response_too_large => .payload_too_large,
            .not_found => .not_found,
            .conflict => .conflict,
            .live_active => .conflict,
            .unsupported => .unprocessable_entity,
            .shutting_down => .service_unavailable,
            .internal_error => .internal_server_error,
        };
    }

    fn body(self: Result) []const u8 {
        return switch (self) {
            .ok => "",
            .bad_request => "{\"error\":\"invalid render request\"}\n",
            .timeout => "{\"error\":\"render deadline exceeded\"}\n",
            .navigation_failed => "{\"error\":\"page navigation failed\"}\n",
            .response_too_large => "{\"error\":\"render snapshot too large\"}\n",
            .not_found => "{\"error\":\"live session not found\"}\n",
            .conflict => "{\"error\":\"live snapshot is stale\"}\n",
            .live_active => "{\"error\":\"live session is active\"}\n",
            .unsupported => "{\"error\":\"live target is not supported\"}\n",
            .shutting_down => "{\"error\":\"render server shutting down\"}\n",
            .internal_error => "{\"error\":\"render failed\"}\n",
        };
    }
};

const Job = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    kind: Kind,
    body: []const u8,
    out: ResponseBuffer,
    max_wait_ms: u32,
    result: Result = .ok,
    done: std.atomic.Value(bool) = .init(false),
    done_mutex: std.Io.Mutex = .init,
    done_cond: std.Io.Condition = .init,
    cancel_reason: std.atomic.Value(u8) = .init(@intFromEnum(CancelReason.none)),
    termination_requested: std.atomic.Value(bool) = .init(false),
    live_snapshot: bool = false,
    live_token: [32]u8 = undefined,
    live_version: u64 = 0,
    next: ?*Job = null,

    const Kind = enum { render, live, abandon_live };

    const CancelReason = enum(u8) {
        none,
        timeout,
        disconnected,
        shutdown,
    };

    fn create(
        allocator: std.mem.Allocator,
        kind: Kind,
        body: []const u8,
        max_wait_ms: u32,
        max_response_size: usize,
    ) !*Job {
        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        const owned_body = try allocator.dupe(u8, body);
        errdefer allocator.free(owned_body);
        job.* = .{
            .allocator = allocator,
            .kind = kind,
            .body = owned_body,
            .out = .init(allocator, max_response_size),
            .max_wait_ms = max_wait_ms,
        };
        return job;
    }

    fn retain(self: *Job) void {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0);
    }

    fn release(self: *Job) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        const allocator = self.allocator;
        self.out.deinit();
        allocator.free(self.body);
        allocator.destroy(self);
    }

    fn cancel(self: *Job, reason: CancelReason) bool {
        self.done_mutex.lockUncancelable(lp.io);
        defer self.done_mutex.unlock(lp.io);
        if (self.done.load(.acquire)) return false;
        return self.cancel_reason.cmpxchgStrong(
            @intFromEnum(CancelReason.none),
            @intFromEnum(reason),
            .acq_rel,
            .acquire,
        ) == null;
    }

    fn cancellation(self: *const Job) CancelReason {
        return @enumFromInt(self.cancel_reason.load(.acquire));
    }

    fn wait(self: *Job, timeout_ms: u32) bool {
        self.done_mutex.lockUncancelable(lp.io);
        defer self.done_mutex.unlock(lp.io);
        if (self.done.load(.acquire)) return true;
        lp.timedWait(
            &self.done_cond,
            &self.done_mutex,
            @as(u64, timeout_ms) * ns_per_ms,
        ) catch {};
        return self.done.load(.acquire);
    }
};

const Queue = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    head: ?*Job = null,
    tail: ?*Job = null,
    closed: std.atomic.Value(bool) = .init(false),

    fn push(self: *Queue, job: *Job) bool {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self.closed.load(.acquire)) return false;
        job.next = null;
        if (self.tail) |tail| tail.next = job else self.head = job;
        self.tail = job;
        job.retain();
        self.cond.signal(lp.io);
        return true;
    }

    fn pop(self: *Queue, timeout_ms: ?u64) ?*Job {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        while (self.head == null and !self.closed.load(.acquire)) {
            if (timeout_ms) |ms| {
                if (ms == 0) return null;
                lp.timedWait(&self.cond, &self.mutex, ms * ns_per_ms) catch return null;
            } else {
                self.cond.waitUncancelable(lp.io, &self.mutex);
            }
        }
        const job = self.head orelse return null;
        self.head = job.next;
        if (self.head == null) self.tail = null;
        return job;
    }

    fn remove(self: *Queue, job: *Job) bool {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);

        var previous: ?*Job = null;
        var current = self.head;
        while (current) |queued| {
            if (queued == job) {
                if (previous) |before| before.next = queued.next else self.head = queued.next;
                if (self.tail == queued) self.tail = previous;
                queued.next = null;
                return true;
            }
            previous = queued;
            current = queued.next;
        }
        return false;
    }

    fn close(self: *Queue) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.closed.store(true, .release);
        self.cond.broadcast(lp.io);
    }
};

allocator: std.mem.Allocator,
app: *App,
max_connections: u32,
max_request_size: usize,
max_response_size: usize,
max_wait_ms: u32,
client_timeout_ms: u32,
cors_origin: ?[]const u8,
auth_token: ?[]const u8,

queue: Queue = .{},
active_conns: std.atomic.Value(u32) = .init(0),
conn_mutex: std.Io.Mutex = .init,
conns: std.ArrayList(posix.socket_t) = .empty,

worker_thread: std.Thread = undefined,
worker_ready: std.Io.Event = .unset,
worker_ok: bool = false,
browser_mutex: std.Io.Mutex = .init,
active_browser: ?*lp.Browser = null,
active_job: ?*Job = null,

pub fn init(allocator: std.mem.Allocator, app: *App) !*HttpServer {
    const self = try allocator.create(HttpServer);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .app = app,
        .max_connections = app.config.maxConnections(),
        .max_request_size = app.config.renderMaxRequestSize(),
        .max_response_size = app.config.renderMaxResponseSize(),
        .max_wait_ms = app.config.renderMaxWaitMs(),
        .client_timeout_ms = app.config.renderClientTimeoutMs(),
        .cors_origin = app.config.renderCorsOrigin(),
        .auth_token = app.config.renderAuthToken(),
    };
    if (self.auth_token) |token| {
        if (token.len < 16) return error.WeakAuthToken;
    }
    if (self.cors_origin) |origin| {
        if (self.auth_token == null) return error.AuthenticationRequired;
        if (!validHeaderValue(origin)) return error.InvalidCorsOrigin;
    }
    errdefer self.conns.deinit(allocator);
    try self.conns.ensureTotalCapacity(allocator, self.max_connections);

    self.worker_thread = try std.Thread.spawn(.{ .stack_size = worker_stack_size }, worker, .{self});
    self.worker_ready.waitUncancelable(lp.io);
    if (!self.worker_ok) {
        self.worker_thread.join();
        return error.WorkerInitFailed;
    }
    return self;
}

pub fn deinit(self: *HttpServer) void {
    self.queue.close();
    self.cancelActiveJob(.shutdown);
    {
        self.conn_mutex.lockUncancelable(lp.io);
        defer self.conn_mutex.unlock(lp.io);
        for (self.conns.items) |socket| sys_net.shutdown(socket, .both) catch {};
    }
    while (self.active_conns.load(.acquire) > 0) {
        lp.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    self.worker_thread.join();

    self.conns.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn run(self: *HttpServer, address: sys_net.IpAddress) !void {
    if (!isLoopback(address)) return error.LoopbackRequired;
    var bound = address;
    try self.app.network.bind(&bound, self, onAccept);
    lp.log.note(.app, "client render server running", .{ .address = bound });
    self.app.network.run();
}

fn cancelActiveJob(self: *HttpServer, reason: Job.CancelReason) void {
    self.browser_mutex.lockUncancelable(lp.io);
    defer self.browser_mutex.unlock(lp.io);
    const job = self.active_job orelse return;
    _ = job.cancel(reason);
    const browser = self.active_browser orelse return;
    if (!job.termination_requested.swap(true, .acq_rel)) {
        browser.env.terminate();
    }
}

fn cancelJob(self: *HttpServer, job: *Job, reason: Job.CancelReason) bool {
    const cancelled = job.cancel(reason);
    if (self.queue.remove(job)) job.release();
    self.browser_mutex.lockUncancelable(lp.io);
    defer self.browser_mutex.unlock(lp.io);
    if (self.active_job != job) return cancelled;
    const browser = self.active_browser orelse return cancelled;
    if (!job.termination_requested.swap(true, .acq_rel)) {
        browser.env.terminate();
    }
    return cancelled;
}

fn onAccept(ctx: *anyopaque, socket: posix.socket_t) void {
    const self: *HttpServer = @ptrCast(@alignCast(ctx));
    const flags = sys_net.fcntl(socket, posix.F.GETFL, 0) catch {
        _ = std.c.close(socket);
        return;
    };
    _ = sys_net.fcntl(socket, posix.F.SETFL, flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true }))) catch {
        _ = std.c.close(socket);
        return;
    };
    setSocketTimeout(socket, self.client_timeout_ms) catch {
        _ = std.c.close(socket);
        return;
    };
    if (!acquireConnectionSlot(&self.active_conns, self.max_connections)) {
        _ = std.c.close(socket);
        return;
    }
    {
        self.conn_mutex.lockUncancelable(lp.io);
        defer self.conn_mutex.unlock(lp.io);
        self.conns.appendAssumeCapacity(socket);
    }

    const thread = std.Thread.spawn(.{ .stack_size = connection_stack_size }, handleConn, .{ self, socket }) catch {
        _ = self.active_conns.fetchSub(1, .release);
        self.unregister(socket);
        _ = std.c.close(socket);
        return;
    };
    thread.detach();
}

fn setSocketTimeout(socket: posix.socket_t, timeout_ms: u32) !void {
    const timeout = std.mem.toBytes(posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    });
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
}

fn isLoopback(address: sys_net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| ip6.isLoopBack(),
    };
}

fn validHeaderValue(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte < ' ' or byte == 0x7f) return false;
    }
    return true;
}

fn acquireConnectionSlot(active: *std.atomic.Value(u32), max: u32) bool {
    var current = active.load(.monotonic);
    while (current < max) {
        current = active.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) orelse return true;
    }
    return false;
}

fn unregister(self: *HttpServer, socket: posix.socket_t) void {
    self.conn_mutex.lockUncancelable(lp.io);
    defer self.conn_mutex.unlock(lp.io);
    for (self.conns.items, 0..) |tracked, i| {
        if (tracked == socket) {
            _ = self.conns.swapRemove(i);
            return;
        }
    }
}

fn worker(self: *HttpServer) void {
    var browser: lp.Browser = undefined;
    browser.init(self.app, .{}, null) catch |err| {
        lp.log.err(.app, "client render browser init", .{ .err = err });
        self.worker_ready.set(lp.io);
        return;
    };
    defer browser.deinit();
    {
        self.browser_mutex.lockUncancelable(lp.io);
        self.active_browser = &browser;
        self.browser_mutex.unlock(lp.io);
    }
    defer {
        self.browser_mutex.lockUncancelable(lp.io);
        self.active_browser = null;
        self.browser_mutex.unlock(lp.io);
    }

    self.worker_ok = true;
    self.worker_ready.set(lp.io);

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    var live = LiveSession.init(self.allocator, &browser);
    defer live.deinit();
    while (true) {
        const now_ms = lp.datetime.milliTimestamp(.boot);
        closeExpiredLiveSession(&live, now_ms);
        const timeout_ms: ?u64 = if (live.isActive()) live.idleWaitMsAt(now_ms) else null;
        const job = self.queue.pop(timeout_ms) orelse {
            if (self.queue.closed.load(.acquire)) break;
            live.close();
            continue;
        };
        closeExpiredLiveSession(&live, lp.datetime.milliTimestamp(.boot));
        if (self.queue.closed.load(.acquire)) _ = job.cancel(.shutdown);

        if (job.cancellation() == .none) {
            self.browser_mutex.lockUncancelable(lp.io);
            self.active_job = job;
            self.browser_mutex.unlock(lp.io);

            if (job.cancellation() == .none) {
                switch (job.kind) {
                    .render => {
                        if (live.isActive()) {
                            job.result = .live_active;
                        } else {
                            processRender(self, &browser, arena.allocator(), job);
                        }
                    },
                    .live => processLive(&live, arena.allocator(), job),
                    .abandon_live => live.closeForToken(job.live_token[0..]) catch {},
                }
            }

            self.browser_mutex.lockUncancelable(lp.io);
            self.active_job = null;
            self.browser_mutex.unlock(lp.io);
            if (job.termination_requested.load(.acquire)) {
                browser.env.cancelTerminate();
            }
        }

        // Freeze cancellation while finalizing. A disconnect that wins this
        // lock is observed and closes live state; a later cancel sees done.
        job.done_mutex.lockUncancelable(lp.io);
        const cancellation = job.cancellation();
        closeCancelledLiveJob(&live, job, cancellation);
        job.result = switch (cancellation) {
            .none => job.result,
            .timeout => .timeout,
            .disconnected, .shutdown => .shutting_down,
        };
        _ = arena.reset(.{ .retain_with_limit = worker_retained_arena_bytes });
        job.done.store(true, .release);
        job.done_cond.broadcast(lp.io);
        job.done_mutex.unlock(lp.io);
        job.release();
    }
}

fn closeCancelledLiveJob(live: *LiveSession, job: *const Job, cancellation: Job.CancelReason) void {
    if (job.live_snapshot and cancellation != .none) live.close();
}

fn closeExpiredLiveSession(live: *LiveSession, now_ms: u64) void {
    if (live.isActive() and live.idleWaitMsAt(now_ms) == 0) live.close();
}

const RenderRequest = struct {
    url: []const u8,
    wait_ms: u32 = 5_000,
    wait_until: ?lp.Config.WaitUntil = null,
    wait_selector: ?[]const u8 = null,
    width: u32 = 1280,
    height: u32 = 720,
};

const LiveRequest = struct {
    op: enum { open, activate, close },
    url: ?[]const u8 = null,
    session: ?[]const u8 = null,
    version: ?u64 = null,
    target: ?u64 = null,
    wait_ms: u32 = 5_000,
    width: u32 = 1280,
    height: u32 = 720,
};

fn processRender(self: *HttpServer, browser: *lp.Browser, arena: std.mem.Allocator, job: *Job) void {
    const request = std.json.parseFromSliceLeaky(RenderRequest, arena, job.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        job.result = .bad_request;
        return;
    };
    if (request.url.len == 0 or request.url.len > 8 * 1024 or
        request.width == 0 or request.width > 8192 or request.height == 0 or request.height > 8192)
    {
        job.result = .bad_request;
        return;
    }
    if (request.wait_selector) |selector| {
        if (selector.len == 0 or selector.len > 1024) {
            job.result = .bad_request;
            return;
        }
    }

    const canonical = validTargetUrl(arena, request.url) catch {
        job.result = .bad_request;
        return;
    };

    const selector: ?[:0]const u8 = if (request.wait_selector) |value|
        arena.dupeZ(u8, value) catch {
            job.result = .internal_error;
            return;
        }
    else
        null;
    browser.viewport_override = .{ .width = request.width, .height = request.height };

    var urls = [_][:0]const u8{canonical};
    lp.fetch(self.app, browser, &urls, .{
        .wait_ms = @min(request.wait_ms, job.max_wait_ms),
        .wait_until = request.wait_until,
        .wait_selector = selector,
        .dump = .{
            .with_base = true,
            .with_frames = false,
            .strip = .{ .js = true },
        },
        .dump_mode = .html,
        .writer = &job.out.writer,
    }) catch |err| {
        job.result = if (err == error.Timeout)
            .timeout
        else if (err == error.WriteFailed)
            .response_too_large
        else switch (err) {
            error.TypeError, error.InvalidURL => .bad_request,
            error.OutOfMemory => .internal_error,
            else => .navigation_failed,
        };
        return;
    };
}

fn processLive(live: *LiveSession, arena: std.mem.Allocator, job: *Job) void {
    const request = std.json.parseFromSliceLeaky(LiveRequest, arena, job.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        job.result = .bad_request;
        return;
    };

    switch (request.op) {
        .open => {
            const url = request.url orelse {
                job.result = .bad_request;
                return;
            };
            if (url.len == 0 or url.len > 8 * 1024 or !validViewport(request.width, request.height)) {
                job.result = .bad_request;
                return;
            }
            const canonical = validTargetUrl(arena, url) catch {
                job.result = .bad_request;
                return;
            };
            live.open(.{
                .url = canonical,
                .width = request.width,
                .height = request.height,
                .wait_ms = @min(request.wait_ms, job.max_wait_ms),
            }, &job.out.writer) catch |err| {
                job.result = mapLiveError(err);
                return;
            };
            setLiveSnapshotHeaders(job, live);
        },
        .activate => {
            const session = request.session orelse {
                job.result = .bad_request;
                return;
            };
            const version = request.version orelse {
                job.result = .bad_request;
                return;
            };
            const target64 = request.target orelse {
                job.result = .bad_request;
                return;
            };
            const target = std.math.cast(usize, target64) orelse {
                job.result = .unsupported;
                return;
            };
            live.activate(session, version, target, @min(request.wait_ms, job.max_wait_ms), &job.out.writer) catch |err| {
                job.result = mapLiveError(err);
                return;
            };
            setLiveSnapshotHeaders(job, live);
        },
        .close => {
            const session = request.session orelse {
                job.result = .bad_request;
                return;
            };
            live.closeForToken(session) catch |err| {
                job.result = mapLiveError(err);
                return;
            };
        },
    }
}

fn validViewport(width: u32, height: u32) bool {
    return width != 0 and width <= 8192 and height != 0 and height <= 8192;
}

fn validTargetUrl(arena: std.mem.Allocator, raw: []const u8) ![:0]const u8 {
    const canonical = try lp.URL.resolveNavigation(arena, raw, .{});
    const protocol = lp.URL.getProtocol(canonical);
    if ((!std.mem.eql(u8, protocol, "http:") and !std.mem.eql(u8, protocol, "https:")) or
        lp.URL.getUsername(canonical).len != 0 or lp.URL.getPassword(canonical).len != 0)
    {
        return error.InvalidURL;
    }
    return canonical;
}

fn mapLiveError(err: anyerror) Result {
    return switch (err) {
        error.LiveSessionActive => .live_active,
        error.StaleSnapshot => .conflict,
        error.InvalidSession => .not_found,
        error.UnsupportedTarget => .unsupported,
        error.Timeout => .timeout,
        error.WriteFailed, error.TargetLimit => .response_too_large,
        error.TypeError, error.InvalidURL => .bad_request,
        error.OutOfMemory => .internal_error,
        else => .navigation_failed,
    };
}

fn setLiveSnapshotHeaders(job: *Job, live: *const LiveSession) void {
    job.live_token = live.tokenText();
    job.live_version = live.version;
    job.live_snapshot = true;
}

fn handleConn(self: *HttpServer, socket: posix.socket_t) void {
    defer _ = self.active_conns.fetchSub(1, .release);
    const stream: std.Io.net.Stream = .{ .socket = .{ .handle = socket, .address = .{ .ip4 = .unspecified(0) } } };
    defer stream.close(lp.io);
    defer self.unregister(socket);

    var recv_buf: [8 * 1024]u8 = undefined;
    var send_buf: [8 * 1024]u8 = undefined;
    var stream_reader = stream.reader(lp.io, &recv_buf);
    var stream_writer = stream.writer(lp.io, &send_buf);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var request = http_server.receiveHead() catch return;
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    self.serve(arena.allocator(), &request, socket) catch {};
}

fn serve(
    self: *HttpServer,
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    socket: posix.socket_t,
) !void {
    if (request.head.expect != null) {
        return request.respond("", .{ .status = .expectation_failed, .keep_alive = false });
    }
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const origin = headerValue(request, "origin");
    const cors_value: ?[]const u8 = if (origin != null)
        self.allowedCorsValue(origin) orelse
            return respondJson(request, .forbidden, "{\"error\":\"origin not allowed\"}\n", null)
    else
        null;

    if (request.head.method == .OPTIONS) return respondPreflight(request, cors_value);
    if ((request.head.method == .GET or request.head.method == .HEAD) and
        std.mem.eql(u8, path, "/lightpanda-renderer.js"))
    {
        if (headerEquals(request, "if-none-match", client_etag)) return respondNotModified(request, cors_value);
        return respondBody(request, client_js, .ok, "text/javascript; charset=utf-8", "public,max-age=0,must-revalidate", client_etag, cors_value, &.{});
    }
    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/healthz")) {
        return respondBody(request, "ok\n", .ok, "text/plain; charset=utf-8", "no-store", null, cors_value, &.{});
    }
    const kind: Job.Kind = if (std.mem.eql(u8, path, "/v1/render"))
        .render
    else if (std.mem.eql(u8, path, "/v1/live"))
        .live
    else
        return respondJson(request, .not_found, "{\"error\":\"not found\"}\n", cors_value);
    if (request.head.method != .POST) {
        return respondJson(request, .not_found, "{\"error\":\"not found\"}\n", cors_value);
    }
    if (!authorized(request, self.auth_token)) {
        return respondJson(request, .unauthorized, "{\"error\":\"authentication required\"}\n", cors_value);
    }
    const content_type = headerValue(request, "content-type") orelse "";
    if (!isJsonContentType(content_type)) {
        return respondJson(request, .unsupported_media_type, "{\"error\":\"application/json required\"}\n", cors_value);
    }

    const content_length = if (request.head.transfer_encoding == .none)
        request.head.content_length
    else
        null;
    var body_buf: [8 * 1024]u8 = undefined;
    const body = readRequestBody(arena, request.readerExpectNone(&body_buf), content_length, self.max_request_size) catch {
        return respondJson(request, .payload_too_large, "{\"error\":\"request too large\"}\n", cors_value);
    };
    const job = try Job.create(self.allocator, kind, body, self.max_wait_ms, self.max_response_size);
    defer job.release();
    if (!self.queue.push(job)) {
        return respondJson(request, .service_unavailable, Result.shutting_down.body(), cors_value);
    }
    switch (self.waitForJob(job, socket)) {
        .complete => {},
        .disconnected => return error.ClientDisconnected,
        .disconnected_complete => {
            if (job.live_snapshot) self.abandonLive(job.live_token);
            return error.ClientDisconnected;
        },
        .timeout => return respondJson(request, Result.timeout.status(), Result.timeout.body(), cors_value),
    }

    if (job.out.failed and job.result == .ok) job.result = .response_too_large;
    if (job.result != .ok) return respondJson(request, job.result.status(), job.result.body(), cors_value);
    if (job.live_snapshot) {
        var version_buf: [20]u8 = undefined;
        const version = std.fmt.bufPrint(&version_buf, "{d}", .{job.live_version}) catch unreachable;
        const headers = [_]std.http.Header{
            .{ .name = "x-lightpanda-live-session", .value = job.live_token[0..] },
            .{ .name = "x-lightpanda-live-version", .value = version },
            .{ .name = "access-control-expose-headers", .value = "x-lightpanda-live-session, x-lightpanda-live-version" },
        };
        respondBody(request, job.out.buffered(), .ok, "text/html; charset=utf-8", "no-store", null, cors_value, &headers) catch |err| {
            self.abandonLive(job.live_token);
            return err;
        };
        return;
    }
    if (job.kind == .live) {
        return respondBody(request, "", .no_content, "text/plain; charset=utf-8", "no-store", null, cors_value, &.{});
    }
    return respondBody(request, job.out.buffered(), .ok, "text/html; charset=utf-8", "no-store", null, cors_value, &.{});
}

const JobWaitResult = enum { complete, disconnected, disconnected_complete, timeout };

fn waitForJob(self: *HttpServer, job: *Job, socket: posix.socket_t) JobWaitResult {
    var timer: std.Io.Timestamp = .now(lp.io, .boot);
    while (true) {
        if (job.done.load(.acquire)) {
            return if (job.cancellation() == .disconnected) .disconnected else .complete;
        }
        if (peerDisconnected(socket)) {
            if (self.cancelJob(job, .disconnected)) return .disconnected;
            return if (job.done.load(.acquire)) .disconnected_complete else .disconnected;
        }

        const elapsed: u64 = @intCast(@min(
            timer.untilNow(lp.io, .boot).toMilliseconds(),
            std.math.maxInt(u64),
        ));
        if (deadlineExpired(elapsed, job.max_wait_ms)) {
            if (self.cancelJob(job, .timeout)) return .timeout;
            if (job.done.load(.acquire)) {
                return if (job.cancellation() == .disconnected) .disconnected else .complete;
            }
            return .timeout;
        }

        const remaining = job.max_wait_ms -| elapsed;
        const wait_ms: u32 = @intCast(@min(remaining, job_poll_interval_ms));
        _ = job.wait(wait_ms);
    }
}

fn deadlineExpired(elapsed_ms: u64, max_wait_ms: u32) bool {
    return elapsed_ms >= max_wait_ms;
}

fn abandonLive(self: *HttpServer, token: [32]u8) void {
    const job = Job.create(self.allocator, .abandon_live, "", self.max_wait_ms, 0) catch return;
    defer job.release();
    job.live_token = token;
    if (!self.queue.push(job)) return;
    while (!job.done.load(.acquire)) {
        _ = job.wait(@max(self.max_wait_ms, 1));
    }
}

fn peerDisconnected(socket: posix.socket_t) bool {
    var fds = [_]posix.pollfd{.{
        .fd = socket,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    _ = posix.poll(&fds, 0) catch return true;
    const fatal_events: i16 = comptime @intCast(posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL);
    if (fds[0].revents & fatal_events != 0) return true;
    if (fds[0].revents & posix.POLL.IN == 0) return false;

    var byte: [1]u8 = undefined;
    const rc = std.c.recv(socket, &byte, byte.len, posix.MSG.PEEK | posix.MSG.DONTWAIT);
    if (rc == 0) return true;
    if (rc > 0) return false;
    return switch (std.c.errno(rc)) {
        .AGAIN => false,
        else => true,
    };
}

fn respondBody(
    request: *std.http.Server.Request,
    body: []const u8,
    status: std.http.Status,
    content_type: []const u8,
    cache_control: []const u8,
    etag: ?[]const u8,
    cors_value: ?[]const u8,
    extra_headers: []const std.http.Header,
) !void {
    var headers: [10]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "content-type", .value = content_type };
    count += 1;
    headers[count] = .{ .name = "cache-control", .value = cache_control };
    count += 1;
    headers[count] = .{ .name = "x-content-type-options", .value = "nosniff" };
    count += 1;
    headers[count] = .{ .name = "vary", .value = "origin" };
    count += 1;
    if (etag) |value| {
        headers[count] = .{ .name = "etag", .value = value };
        count += 1;
    }
    if (cors_value) |value| {
        headers[count] = .{ .name = "access-control-allow-origin", .value = value };
        count += 1;
        headers[count] = .{ .name = "cross-origin-resource-policy", .value = "cross-origin" };
        count += 1;
    }
    std.debug.assert(extra_headers.len <= headers.len - count);
    for (extra_headers) |header| {
        headers[count] = header;
        count += 1;
    }
    return request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    });
}

fn respondNotModified(request: *std.http.Server.Request, cors_value: ?[]const u8) !void {
    var headers: [6]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "etag", .value = client_etag };
    count += 1;
    headers[count] = .{ .name = "cache-control", .value = "public,max-age=0,must-revalidate" };
    count += 1;
    headers[count] = .{ .name = "vary", .value = "origin" };
    count += 1;
    headers[count] = .{ .name = "x-content-type-options", .value = "nosniff" };
    count += 1;
    if (cors_value) |value| {
        headers[count] = .{ .name = "access-control-allow-origin", .value = value };
        count += 1;
        headers[count] = .{ .name = "cross-origin-resource-policy", .value = "cross-origin" };
        count += 1;
    }
    return request.respond("", .{
        .status = .not_modified,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    });
}

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8, cors_value: ?[]const u8) !void {
    var headers: [3]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "content-type", .value = "application/json; charset=utf-8" };
    count += 1;
    headers[count] = .{ .name = "cache-control", .value = "no-store" };
    count += 1;
    if (cors_value) |value| {
        headers[count] = .{ .name = "access-control-allow-origin", .value = value };
        count += 1;
    }
    return request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    });
}

fn respondPreflight(request: *std.http.Server.Request, cors_value: ?[]const u8) !void {
    const value = cors_value orelse return respondJson(
        request,
        .forbidden,
        "{\"error\":\"origin not allowed\"}\n",
        null,
    );
    const headers = [_]std.http.Header{
        .{ .name = "access-control-allow-origin", .value = value },
        .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
        .{ .name = "access-control-allow-headers", .value = "content-type, authorization" },
        .{ .name = "access-control-max-age", .value = "86400" },
        .{ .name = "vary", .value = "origin" },
    };
    return request.respond("", .{
        .status = .no_content,
        .keep_alive = false,
        .extra_headers = &headers,
    });
}

fn authorized(request: *std.http.Server.Request, expected: ?[]const u8) bool {
    const token = expected orelse return true;
    const value = headerValue(request, "authorization") orelse return false;
    const prefix = "Bearer ";
    if (!std.ascii.startsWithIgnoreCase(value, prefix)) return false;
    const actual = value[prefix.len..];
    if (actual.len != token.len) return false;
    var difference: u8 = 0;
    for (actual, token) |a, b| difference |= a ^ b;
    return difference == 0;
}

fn allowedCorsValue(self: *const HttpServer, origin: ?[]const u8) ?[]const u8 {
    const requested = origin orelse return null;
    const allowed = self.cors_origin orelse return null;
    if (std.mem.eql(u8, allowed, "*") or std.mem.eql(u8, allowed, requested)) return allowed;
    return null;
}

fn headerValue(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn headerEquals(request: *std.http.Server.Request, name: []const u8, expected: []const u8) bool {
    const value = headerValue(request, name) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn isJsonContentType(raw: []const u8) bool {
    const value = std.mem.trimStart(u8, raw, &std.ascii.whitespace);
    const mime = "application/json";
    if (value.len < mime.len or !std.ascii.eqlIgnoreCase(value[0..mime.len], mime)) return false;
    return value.len == mime.len or value[mime.len] == ';' or std.ascii.isWhitespace(value[mime.len]);
}

fn readRequestBody(
    arena: std.mem.Allocator,
    reader: *std.Io.Reader,
    content_length: ?u64,
    max_request_size: usize,
) ![]const u8 {
    if (content_length) |len64| {
        const len = std.math.cast(usize, len64) orelse return error.StreamTooLong;
        if (len > max_request_size) return error.StreamTooLong;
        if (len <= reader.buffer.len) return try reader.take(len);
        const body = try arena.alloc(u8, len);
        try reader.readSliceAll(body);
        return body;
    }
    return reader.allocRemaining(arena, .limited(max_request_size));
}

test "render server: connection slots are bounded" {
    var active: std.atomic.Value(u32) = .init(0);
    try std.testing.expect(acquireConnectionSlot(&active, 2));
    try std.testing.expect(acquireConnectionSlot(&active, 2));
    try std.testing.expect(!acquireConnectionSlot(&active, 2));
}

test "render server: connected peer stays live" {
    var pair: [2]posix.socket_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.LOCAL, posix.SOCK.STREAM, 0, &pair));
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);

    try std.testing.expect(!peerDisconnected(pair[0]));
}

test "render server: peer close and shutdown are detected" {
    {
        var pair: [2]posix.socket_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.LOCAL, posix.SOCK.STREAM, 0, &pair));
        defer _ = std.c.close(pair[0]);

        _ = std.c.close(pair[1]);
        try std.testing.expect(peerDisconnected(pair[0]));
    }

    {
        var pair: [2]posix.socket_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.LOCAL, posix.SOCK.STREAM, 0, &pair));
        defer _ = std.c.close(pair[0]);
        defer _ = std.c.close(pair[1]);

        try sys_net.shutdown(pair[1], .send);
        try std.testing.expect(peerDisconnected(pair[0]));
    }
}

test "render server: pending peer byte stays live and is not consumed" {
    var pair: [2]posix.socket_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(posix.AF.LOCAL, posix.SOCK.STREAM, 0, &pair));
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);

    try sys_net.writeAll(pair[1], "x");
    try std.testing.expect(!peerDisconnected(pair[0]));

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.recv(pair[0], &byte, byte.len, 0));
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);
}

test "render server: URL schemes and credentials are rejected" {
    const Request = struct { url: []const u8 };
    const cases = [_][]const u8{
        "file:///etc/passwd",
        "data:text/html,hello",
        "javascript:alert(1)",
        "https://user:pass@example.com/",
    };
    for (cases) |url| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const request: Request = .{ .url = url };
        const canonical = lp.URL.resolveNavigation(arena.allocator(), request.url, .{}) catch continue;
        const protocol = lp.URL.getProtocol(canonical);
        const valid = (std.mem.eql(u8, protocol, "http:") or std.mem.eql(u8, protocol, "https:")) and
            lp.URL.getUsername(canonical).len == 0 and lp.URL.getPassword(canonical).len == 0;
        try std.testing.expect(!valid);
    }
}

test "render server: CORS values cannot inject headers" {
    try std.testing.expect(validHeaderValue("*"));
    try std.testing.expect(validHeaderValue("https://preview.example"));
    try std.testing.expect(!validHeaderValue(""));
    try std.testing.expect(!validHeaderValue("https://example.test\r\nx-injected: true"));
}

test "render server: live operations carry a versioned activation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const open = try std.json.parseFromSliceLeaky(
        LiveRequest,
        arena.allocator(),
        "{\"op\":\"open\",\"url\":\"https://example.test/\"}",
        .{},
    );
    try std.testing.expect(open.op == .open);
    try std.testing.expectEqualStrings("https://example.test/", open.url.?);

    const activate = try std.json.parseFromSliceLeaky(
        LiveRequest,
        arena.allocator(),
        "{\"op\":\"activate\",\"session\":\"0123456789abcdef0123456789abcdef\",\"version\":7,\"target\":3}",
        .{},
    );
    try std.testing.expect(activate.op == .activate);
    try std.testing.expectEqual(@as(u64, 7), activate.version.?);
    try std.testing.expectEqual(@as(u64, 3), activate.target.?);

    const close = try std.json.parseFromSliceLeaky(
        LiveRequest,
        arena.allocator(),
        "{\"op\":\"close\",\"session\":\"0123456789abcdef0123456789abcdef\"}",
        .{},
    );
    try std.testing.expect(close.op == .close);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", close.session.?);
}

test "render server: live errors and one-shot conflicts are explicit" {
    try std.testing.expectEqual(Result.conflict, mapLiveError(error.StaleSnapshot));
    try std.testing.expectEqual(Result.live_active, mapLiveError(error.LiveSessionActive));
    try std.testing.expectEqual(std.http.Status.conflict, Result.live_active.status());
    try std.testing.expect(!std.mem.eql(u8, Result.conflict.body(), Result.live_active.body()));
    try std.testing.expectEqual(Result.not_found, mapLiveError(error.InvalidSession));
    try std.testing.expectEqual(Result.unsupported, mapLiveError(error.UnsupportedTarget));
    try std.testing.expectEqual(Result.response_too_large, mapLiveError(error.TargetLimit));
}

test "render server: cancelled live work releases the worker session" {
    inline for (.{ Job.CancelReason.timeout, Job.CancelReason.disconnected }) |reason| {
        var live: LiveSession = .{
            .allocator = std.testing.allocator,
            .browser = undefined,
            .page = .{ .frame_id = 0, .session = undefined },
        };
        defer live.deinit();

        const job = try Job.create(std.testing.allocator, .live, "", 1, 1);
        defer job.release();
        job.live_snapshot = true;
        _ = job.cancel(reason);
        closeCancelledLiveJob(&live, job, job.cancellation());
        try std.testing.expect(!live.isActive());
    }
}

test "render server: cancelled live work without a snapshot preserves the worker session" {
    var live: LiveSession = .{
        .allocator = std.testing.allocator,
        .browser = undefined,
        .page = .{ .frame_id = 0, .session = undefined },
    };
    defer live.deinit();

    const job = try Job.create(std.testing.allocator, .live, "", 1, 1);
    defer job.release();
    _ = job.cancel(.timeout);
    closeCancelledLiveJob(&live, job, job.cancellation());
    try std.testing.expect(live.isActive());
}

test "render server: queue retains job storage until worker release" {
    var queue: Queue = .{};
    const job = try Job.create(std.testing.allocator, .render, "owned body", 1, 1);
    try std.testing.expect(queue.push(job));
    job.release();

    const popped = queue.pop(null).?;
    try std.testing.expectEqualStrings("owned body", popped.body);
    popped.release();
}

test "render server: closed queue does not retain rejected job" {
    var queue: Queue = .{};
    queue.close();

    const job = try Job.create(std.testing.allocator, .render, "", 1, 1);
    defer job.release();
    try std.testing.expect(!queue.push(job));
    try std.testing.expectEqual(@as(u32, 1), job.refs.load(.acquire));
}

test "render server: cancelled queued job releases queue ownership" {
    var queue: Queue = .{};
    const job = try Job.create(std.testing.allocator, .render, "owned body", 1, 1);
    defer job.release();
    try std.testing.expect(queue.push(job));
    try std.testing.expectEqual(@as(u32, 2), job.refs.load(.acquire));

    try std.testing.expect(queue.remove(job));
    job.release();
    try std.testing.expectEqual(@as(u32, 1), job.refs.load(.acquire));
    try std.testing.expect(queue.head == null);
    try std.testing.expect(queue.tail == null);
}

test "render server: completed job rejects late timeout cancellation" {
    const job = try Job.create(std.testing.allocator, .render, "", 1, 1);
    defer job.release();

    job.done_mutex.lockUncancelable(lp.io);
    job.done.store(true, .release);
    job.done_mutex.unlock(lp.io);

    try std.testing.expect(!job.cancel(.timeout));
    try std.testing.expectEqual(Job.CancelReason.none, job.cancellation());
}

test "render server: deadline expires at the wall limit" {
    try std.testing.expect(!deadlineExpired(9, 10));
    try std.testing.expect(deadlineExpired(10, 10));
    try std.testing.expect(deadlineExpired(11, 10));
}

test "render server: expired live state closes before queued work" {
    var live: LiveSession = .{
        .allocator = std.testing.allocator,
        .browser = undefined,
        .page = .{ .frame_id = 0, .session = undefined },
        .last_activity_ms = 1,
    };
    defer live.deinit();

    closeExpiredLiveSession(&live, LiveSession.idle_timeout_ms + 1);
    try std.testing.expect(!live.isActive());
}
