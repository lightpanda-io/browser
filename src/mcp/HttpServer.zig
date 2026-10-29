// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! HTTP (MCP "Streamable HTTP") transport for the browser-tools MCP server.
//!
//! Lets many clients drive one process, each on its own browsing session.
//! Threading rule: V8 isolates are thread-affine, so each session gets a
//! worker thread that owns its `Server` and does all of its browser work;
//! sessions run in parallel. Connection threads never touch a browser: they
//! queue a `Job` on the session's worker and wait for it. Routing follows
//! `Mcp-Session-Id`: an `initialize` without one mints a fresh session, an
//! unknown id creates it, a known one joins it, a reaped one gets 404.

const std = @import("std");
const lp = @import("lightpanda");
const builtin = @import("builtin");

const App = @import("../App.zig");
const sys_net = @import("../sys/net.zig");

const Server = @import("Server.zig");
const Transport = @import("Transport.zig");
const router = @import("router.zig");

const log = lp.log;
const posix = std.posix;

const HttpServer = @This();

const ns_per_ms = std.time.ns_per_ms;

/// Cap on a single JSON-RPC request body. Generous: agent tool payloads
/// (e.g. a `save` script) can be large, but this bounds a hostile client.
const max_request_bytes = 16 * 1024 * 1024;

/// One unit of work handed from a connection thread to a session's worker.
/// Allocated on the connection thread's stack — safe because that thread
/// blocks on `done` for the whole time the worker reads `body` and writes
/// `out`.
const Job = struct {
    body: []const u8,
    /// Where the worker writes the response. The connection thread owns the
    /// backing buffer and reads it back once `done` fires.
    out: *std.Io.Writer,

    done: std.Io.Event = .unset,
    next: ?*Job = null,
};

const Queue = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    head: ?*Job = null,
    tail: ?*Job = null,
    closed: bool = false,

    /// Callers push only to a listed worker, whose queue is still open.
    fn push(self: *Queue, job: *Job) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        std.debug.assert(!self.closed);
        job.next = null;
        if (self.tail) |t| t.next = job else self.head = job;
        self.tail = job;
        self.cond.signal(lp.io);
    }

    const Pop = union(enum) { job: *Job, timeout, closed };

    /// The next job, waiting at most `timeout_ms` (`.timeout` on timeout or
    /// spurious wakeup, so the worker can pump its session and retry).
    /// `.closed` only once the queue is closed AND drained, so no pushed job
    /// is ever left behind.
    fn pop(self: *Queue, timeout_ms: u64) Pop {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self.head == null) {
            if (self.closed) return .closed;
            if (timeout_ms == 0) return .timeout;
            lp.timedWait(&self.cond, &self.mutex, timeout_ms * ns_per_ms) catch {};
        }
        const job = self.head orelse return if (self.closed) .closed else .timeout;
        self.head = job.next;
        if (self.head == null) self.tail = null;
        return .{ .job = job };
    }

    fn isEmpty(self: *Queue) bool {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        return self.head == null;
    }

    fn close(self: *Queue) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.closed = true;
        self.cond.signal(lp.io);
    }
};

/// One session: its thread, its queue and, on that thread, its `Server`.
/// Listed in `workers` until closed; its thread then drains the queue, tears
/// the session down and frees it.
const Worker = struct {
    http: *HttpServer,
    id: []const u8,
    queue: Queue = .{},
    /// Guarded by `workers_mutex`, for `session_list`.
    url: ?[]const u8 = null,
};

/// How the default session reports whether it came up.
const Start = struct {
    done: std.Io.Event = .unset,
    ok: bool = false,
};

pub const SessionInfo = struct {
    id: []const u8,
    url: ?[]const u8,
};

allocator: std.mem.Allocator,
app: *App,

// Blocking listener owned by run(); -1 until bound. stop() unblocks the
// accept from another thread.
listener: std.atomic.Value(posix.socket_t) = .init(-1),
shutting_down: std.atomic.Value(bool) = .init(false),

// Registration happens in onAccept — the same (accept) thread deinit runs
// on — so a connection is always counted and its socket registered before
// deinit can observe either.
active_conns: std.atomic.Value(u32) = .init(0),
conn_mutex: std.Io.Mutex = .init,
conns: std.ArrayList(posix.socket_t) = .empty,

workers_mutex: std.Io.Mutex = .init,
workers: std.StringHashMapUnmanaged(*Worker) = .empty,
/// Answered with 404. Never pruned: an entry is just the id, against the
/// isolate the reaper freed. Guarded by `workers_mutex`.
reaped: std.StringHashMapUnmanaged(void) = .empty,
session_timeout_ms: ?u64,
/// Backs minted session ids (`s1`, `s2`, …).
session_seq: u32 = 0,
worker_wg: lp.WaitGroup = .{},

/// Create the server and start the default session. Returns once that
/// session is up (or errors if it failed to initialize).
pub fn init(allocator: std.mem.Allocator, app: *App) !*HttpServer {
    const self = try allocator.create(HttpServer);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .app = app,
        .session_timeout_ms = app.config.httpSessionTimeout(),
    };
    errdefer self.workers.deinit(allocator);

    var start: Start = .{};
    {
        self.workers_mutex.lockUncancelable(lp.io);
        defer self.workers_mutex.unlock(lp.io);
        _ = try self.spawnLocked(Server.default_session_id, &start);
    }
    start.done.waitUncancelable(lp.io);
    if (!start.ok) {
        self.worker_wg.wait();
        return error.WorkerInitFailed;
    }
    return self;
}

/// Runs after the accept loop has stopped, so no new connection can arrive.
/// Shutting the sockets down unblocks the connection threads' pending reads;
/// the workers must outlive their drain because a connection thread may
/// still be blocked on `job.done`.
pub fn deinit(self: *HttpServer) void {
    {
        self.conn_mutex.lockUncancelable(lp.io);
        defer self.conn_mutex.unlock(lp.io);
        for (self.conns.items) |socket| {
            sys_net.shutdown(socket, .both) catch {};
        }
    }
    while (self.active_conns.load(.acquire) > 0) {
        lp.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }

    {
        self.workers_mutex.lockUncancelable(lp.io);
        defer self.workers_mutex.unlock(lp.io);
        var it = self.workers.valueIterator();
        while (it.next()) |worker| worker.*.queue.close();
        self.workers.clearRetainingCapacity();
    }
    self.worker_wg.wait();

    self.workers.deinit(self.allocator);
    var reaped = self.reaped.keyIterator();
    while (reaped.next()) |id| self.allocator.free(id.*);
    self.reaped.deinit(self.allocator);
    self.conns.deinit(self.allocator);
    self.allocator.destroy(self);
}

/// Queue `job` on session `id` (null mints a new one), starting the session
/// on first use. Returns the id it went to, in `arena`.
fn submit(self: *HttpServer, arena: std.mem.Allocator, id: ?[]const u8, job: *Job) ![]const u8 {
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    const worker = try self.findOrSpawnLocked(id);
    worker.queue.push(job);
    return arena.dupe(u8, worker.id);
}

/// For `session_new`: the session named `name` (null mints one), started if
/// new, even if a session by that name was reaped. Returns its id, in `arena`.
pub fn createSession(self: *HttpServer, arena: std.mem.Allocator, name: ?[]const u8) ![]const u8 {
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    if (name) |n| _ = self.forgetReapedLocked(n);
    const worker = try self.findOrSpawnLocked(name);
    return arena.dupe(u8, worker.id);
}

pub fn listSessions(self: *HttpServer, arena: std.mem.Allocator) ![]SessionInfo {
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    const list = try arena.alloc(SessionInfo, self.workers.count());
    var it = self.workers.valueIterator();
    for (list) |*entry| {
        const worker = it.next().?.*;
        entry.* = .{
            .id = try arena.dupe(u8, worker.id),
            .url = if (worker.url) |url| try arena.dupe(u8, url) else null,
        };
    }
    return list;
}

/// Close session `id`: calls already queued still run, then its thread tears
/// it down. Closing a reaped id frees it for reuse. False if there is no such
/// session. The default lives as long as the process.
pub fn closeSession(self: *HttpServer, id: []const u8) bool {
    if (Server.isDefault(id)) return false;
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    if (self.forgetReapedLocked(id)) return true;
    const worker = self.workers.get(id) orelse return false;
    self.removeLocked(worker);
    return true;
}

fn findOrSpawnLocked(self: *HttpServer, id: ?[]const u8) !*Worker {
    if (id) |name| {
        if (self.workers.get(name)) |worker| return worker;
        if (self.reaped.contains(name)) return error.SessionExpired;
        return self.spawnLocked(name, null);
    }
    var buf: [16]u8 = undefined;
    while (true) {
        self.session_seq += 1;
        const candidate = std.fmt.bufPrint(&buf, "s{d}", .{self.session_seq}) catch unreachable;
        if (!self.workers.contains(candidate) and !self.reaped.contains(candidate)) {
            return self.spawnLocked(candidate, null);
        }
    }
}

fn spawnLocked(self: *HttpServer, id: []const u8, start: ?*Start) !*Worker {
    const worker = try self.allocator.create(Worker);
    errdefer self.allocator.destroy(worker);
    const owned_id = try self.allocator.dupe(u8, id);
    errdefer self.allocator.free(owned_id);
    worker.* = .{ .http = self, .id = owned_id };

    try self.workers.put(self.allocator, owned_id, worker);
    errdefer _ = self.workers.remove(owned_id);

    self.worker_wg.start();
    errdefer self.worker_wg.finish();
    const thread = try std.Thread.spawn(.{}, runWorker, .{ worker, start });
    thread.detach();
    return worker;
}

fn removeLocked(self: *HttpServer, worker: *Worker) void {
    // Not a newer session that took the same id after this one closed.
    if (self.workers.get(worker.id) == worker) _ = self.workers.remove(worker.id);
    worker.queue.close();
}

fn forgetReapedLocked(self: *HttpServer, id: []const u8) bool {
    const kv = self.reaped.fetchRemove(id) orelse return false;
    self.allocator.free(kv.key);
    return true;
}

/// False if a call was queued meanwhile, or the id couldn't be remembered.
fn reap(self: *HttpServer, worker: *Worker) bool {
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    // Pushes happen under workers_mutex, so none can land after this check.
    if (!worker.queue.isEmpty()) return false;
    if (self.workers.get(worker.id) != worker) return true;

    const id = self.allocator.dupe(u8, worker.id) catch return false;
    self.reaped.putNoClobber(self.allocator, id, {}) catch {
        self.allocator.free(id);
        return false;
    };
    log.info(.mcp, "mcp session reaped", .{ .session = worker.id });
    self.removeLocked(worker);
    return true;
}

fn publishUrl(self: *HttpServer, worker: *Worker, url: ?[]const u8) void {
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    const old = worker.url;
    if (old != null and url != null and std.mem.eql(u8, old.?, url.?)) return;
    worker.url = if (url) |u| self.allocator.dupe(u8, u) catch null else null;
    if (old) |o| self.allocator.free(o);
}

/// Accept MCP-over-HTTP connections until stop() (e.g. from the signal
/// handler). Blocks the calling thread; each accepted connection is served
/// by its own thread doing blocking IO.
pub fn run(self: *HttpServer, address: sys_net.IpAddress) !void {
    const listener = try sys_net.socket(sys_net.family(&address), posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer _ = std.c.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(posix.TCP, "NODELAY")) {
        try posix.setsockopt(listener, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
    }

    const sa = sys_net.sockaddrFromAddress(&address);
    try sys_net.bind(listener, sa.ptr(), sa.len);
    try sys_net.listen(listener, self.app.config.maxPendingConnections());

    // --port 0 asks the OS for an ephemeral port; log the one we actually got.
    log.note(.mcp, "mcp http server running", .{ .address = try sys_net.boundAddress(listener) });

    self.listener.store(listener, .release);
    // On non-Linux stop() closes the listener itself to unblock accept.
    defer if (builtin.target.os.tag == .linux) {
        _ = std.c.close(listener);
    };

    while (!self.shutting_down.load(.acquire)) {
        const socket = sys_net.accept(listener, null, null, 0) catch |err| {
            if (self.shutting_down.load(.acquire)) {
                return;
            }
            switch (err) {
                error.ConnectionAborted => log.debug(.mcp, "accept connection aborted", .{}),
                else => log.err(.mcp, "accept error", .{ .err = err }),
            }
            continue;
        };
        self.onAccept(socket);
    }
}

/// Make run() return. Linux wakes a blocked accept() on shutdown(); BSD/macOS
/// only on close(), in which case run() must not close it again.
pub fn stop(self: *HttpServer) void {
    self.shutting_down.store(true, .release);
    switch (builtin.target.os.tag) {
        .linux => sys_net.shutdown(self.listener.load(.acquire), .recv) catch {},
        else => _ = std.c.close(self.listener.load(.acquire)),
    }
}

fn onAccept(self: *HttpServer, socket: posix.socket_t) void {
    {
        self.conn_mutex.lockUncancelable(lp.io);
        defer self.conn_mutex.unlock(lp.io);
        self.conns.append(self.allocator, socket) catch {
            _ = std.c.close(socket);
            return;
        };
    }
    _ = self.active_conns.fetchAdd(1, .monotonic);

    const thread = std.Thread.spawn(.{}, handleConn, .{ self, socket }) catch |err| {
        log.warn(.mcp, "mcp spawn", .{ .err = err });
        _ = self.active_conns.fetchSub(1, .monotonic);
        self.unregister(socket);
        _ = std.c.close(socket);
        return;
    };
    thread.detach();
}

fn unregister(self: *HttpServer, socket: posix.socket_t) void {
    self.conn_mutex.lockUncancelable(lp.io);
    defer self.conn_mutex.unlock(lp.io);
    for (self.conns.items, 0..) |s, i| {
        if (s == socket) {
            _ = self.conns.swapRemove(i);
            break;
        }
    }
}

fn runWorker(worker: *Worker, start: ?*Start) void {
    const self = worker.http;
    defer self.worker_wg.finish();
    defer {
        if (worker.url) |url| self.allocator.free(url);
        self.allocator.free(worker.id);
        self.allocator.destroy(worker);
    }

    var placeholder: std.Io.Writer.Allocating = .init(self.allocator);
    defer placeholder.deinit();

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();

    const server: ?*Server = Server.initSession(self.allocator, self.app, &placeholder.writer, worker.id) catch |err| blk: {
        log.err(.mcp, "mcp session init", .{ .err = err, .session = worker.id });
        // Calls already queued get an error reply; no new ones arrive.
        self.workers_mutex.lockUncancelable(lp.io);
        defer self.workers_mutex.unlock(lp.io);
        self.removeLocked(worker);
        break :blk null;
    };
    defer if (server) |s| s.deinit();
    if (server) |s| s.directory = self;
    if (start) |st| {
        st.ok = server != null;
        st.done.set(lp.io);
    }

    const timeout_ms: ?u64 = if (Server.isDefault(worker.id)) null else self.session_timeout_ms;
    var idle_since = lp.datetime.milliTimestamp(.boot);

    // Drain queued jobs before pumping idle work: idle() ticks the session
    // (blocking up to 25ms), so pumping between every two jobs would cap
    // throughput.
    var wait_ms: u64 = 0;
    while (true) {
        const job = switch (worker.queue.pop(wait_ms)) {
            .job => |job| job,
            .timeout => {
                wait_ms = if (server) |s| s.idle() else 0;
                const timeout = timeout_ms orelse continue;
                const now = lp.datetime.milliTimestamp(.boot);
                const idle_for = now -| idle_since;
                if (idle_for < timeout) {
                    wait_ms = @min(wait_ms, timeout - idle_for);
                } else if (self.reap(worker)) {
                    wait_ms = 0;
                } else {
                    idle_since = now;
                }
                continue;
            },
            .closed => break,
        };
        defer job.done.set(lp.io);
        _ = arena.reset(.retain_capacity);
        const s = server orelse {
            reject(arena.allocator(), job, "session failed to start");
            continue;
        };
        s.transport.retarget(job.out);
        router.handleMessage(s, arena.allocator(), job.body) catch |err| {
            log.err(.mcp, "mcp handle", .{ .err = err });
        };
        self.publishUrl(worker, if (s.active_session.session.currentFrame()) |frame| frame.url else null);
        idle_since = lp.datetime.milliTimestamp(.boot);
        wait_ms = 0;
    }
}

/// Answer a call the session can't run with a JSON-RPC error.
fn reject(arena: std.mem.Allocator, job: *Job, message: []const u8) void {
    const Peek = struct { id: ?std.json.Value = null };
    const peek = std.json.parseFromSliceLeaky(Peek, arena, job.body, .{ .ignore_unknown_fields = true }) catch Peek{};
    // A notification (no id) gets no reply.
    const id = peek.id orelse return;
    var transport: Transport = .init(arena, job.out);
    defer transport.deinit();
    transport.sendError(id, .InternalError, message) catch {};
}

/// The session a request targets: an explicit `Mcp-Session-Id` wins;
/// otherwise `initialize` mints a new one (null) and everything else goes to
/// the default.
fn target(arena: std.mem.Allocator, session_id: ?[]const u8, body: []const u8) ?[]const u8 {
    if (session_id) |sid| {
        if (sid.len > 0) return sid;
    }
    if (isInitialize(arena, body)) return null;
    return Server.default_session_id;
}

fn isInitialize(arena: std.mem.Allocator, body: []const u8) bool {
    const Peek = struct { method: ?[]const u8 = null };
    const peek = std.json.parseFromSliceLeaky(Peek, arena, body, .{ .ignore_unknown_fields = true }) catch return false;
    const method = peek.method orelse return false;
    return std.mem.eql(u8, method, "initialize");
}

fn handleConn(self: *HttpServer, socket: posix.socket_t) void {
    defer _ = self.active_conns.fetchSub(1, .release);
    const stream: std.Io.net.Stream = .{ .socket = .{ .handle = socket, .address = .{ .ip4 = .unspecified(0) } } };
    defer stream.close(lp.io);
    // Runs before close (defers are LIFO): deinit's shutdown sweep must
    // never see an fd that has been closed and possibly reused.
    defer self.unregister(socket);

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(lp.io, &recv_buf);
    var stream_writer = stream.writer(lp.io, &send_buf);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    // Reused across requests (served serially), not reallocated per request.
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    while (true) {
        var request = http_server.receiveHead() catch return; // peer closed, bad head, or shutdown
        _ = arena.reset(.retain_capacity);
        out.clearRetainingCapacity();
        self.serve(&out.writer, arena.allocator(), &request) catch return;
        if (out.writer.buffer.len > Transport.large_response) {
            out.deinit();
            out = .init(self.allocator);
        }
        if (!request.head.keep_alive or http_server.reader.state == .closing) return;
    }
}

/// Handle one request: marshal it to the browser worker and write the reply.
/// MCP Streamable HTTP — POST carries a JSON-RPC message; DELETE closes the
/// session named by `Mcp-Session-Id`. std.http.Server owns the framing.
fn serve(self: *HttpServer, out: *std.Io.Writer, arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const method = request.head.method;
    if (method != .POST and method != .DELETE) {
        return request.respond("", .{ .status = .method_not_allowed, .keep_alive = false });
    }
    if (request.head.expect != null) {
        return request.respond("", .{ .status = .expectation_failed, .keep_alive = false });
    }

    if (method == .POST and !isJsonContentType(request.head.content_type)) {
        return request.respond("", .{ .status = .unsupported_media_type, .keep_alive = false });
    }

    // Read the headers and keep_alive before the body reader invalidates
    // the head's string memory.
    const session_id = checkHeaders(arena, request) catch |err| switch (err) {
        error.ForbiddenOrigin => return request.respond("Origin not allowed\n", .{ .status = .forbidden, .keep_alive = false }),
        error.ForbiddenHost => return request.respond("Host not allowed, connect to the MCP endpoint by IP address or localhost\n", .{ .status = .forbidden, .keep_alive = false }),
        else => return err,
    };
    const keep_alive = request.head.keep_alive;

    var body_buf: [8 * 1024]u8 = undefined;
    const body = request.readerExpectNone(&body_buf).allocRemaining(arena, .limited(max_request_bytes)) catch {
        return request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
    };

    if (method == .DELETE) {
        if (session_id) |sid| _ = self.closeSession(sid);
        return request.respond("", .{ .status = .accepted, .keep_alive = keep_alive });
    }

    var job: Job = .{ .body = body, .out = out };
    const routed = self.submit(arena, target(arena, session_id, body), &job) catch |err| switch (err) {
        error.SessionExpired => return request.respond("Session expired, start a new one\n", .{ .status = .not_found, .keep_alive = keep_alive }),
        else => {
            log.err(.mcp, "mcp session routing", .{ .err = err });
            return request.respond("", .{ .status = .internal_server_error, .keep_alive = false });
        },
    };
    job.done.waitUncancelable(lp.io);

    const resp = out.buffered();
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "mcp-session-id", .value = routed },
    };
    return request.respond(resp, .{
        // An empty body means a notification: 202, no content.
        .status = if (resp.len == 0) .accepted else .ok,
        .keep_alive = keep_alive,
        .extra_headers = &headers,
    });
}

/// One pass over the request headers: duplicate `Mcp-Session-Id` into
/// `arena` (or null) and enforce the same browser-vector policy as the CDP
/// handshake (see `cdp.Connection.upgrade`).
fn checkHeaders(arena: std.mem.Allocator, request: *std.http.Server.Request) !?[]const u8 {
    var session_id: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        const key = header.name;
        const value = header.value;
        if (std.ascii.eqlIgnoreCase(key, "mcp-session-id")) {
            session_id = try arena.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "origin")) {
            log.warn(.mcp, "rejected request origin", .{
                .origin = value[0..@min(value.len, 64)],
            });
            return error.ForbiddenOrigin;
        } else if (std.ascii.eqlIgnoreCase(key, "host")) {
            const is_allowed = blk: {
                // allow literal localhost
                if (std.mem.startsWith(u8, value, "localhost:")) {
                    break :blk true;
                }

                _ = std.Io.net.IpAddress.parseLiteral(value) catch break :blk false;
                break :blk true;
            };

            if (!is_allowed) {
                log.warn(.mcp, "rejected request host", .{
                    .host = value[0..@min(value.len, 64)],
                    .hint = "connect to the MCP endpoint by IP address or localhost",
                });
                return error.ForbiddenHost;
            }
        }
    }
    return session_id;
}

/// `application/json`, case-insensitive, ignoring parameters (`; charset=`).
fn isJsonContentType(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    const end = std.mem.findScalar(u8, ct, ';') orelse ct.len;
    const media_type = std.mem.trim(u8, ct[0..end], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json");
}

test "HttpServer - content type must be application/json" {
    try std.testing.expect(isJsonContentType("application/json"));
    try std.testing.expect(isJsonContentType("Application/JSON; charset=utf-8"));
    try std.testing.expect(isJsonContentType("application/json ;charset=utf-8"));
    try std.testing.expect(!isJsonContentType("text/plain"));
    try std.testing.expect(!isJsonContentType("application/x-www-form-urlencoded"));
    try std.testing.expect(!isJsonContentType(null));
}

test "HttpServer - initialize is detected for session minting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expect(isInitialize(aa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"));
    try std.testing.expect(!isInitialize(aa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}"));
    try std.testing.expect(!isInitialize(aa, "not json"));
}

const testing = @import("../testing.zig");

/// POSTs `body` to `port`, as session `sid`, and returns the response body.
fn testPost(allocator: std.mem.Allocator, port: u16, sid: []const u8, body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    _ = try testStatus(allocator, port, .POST, sid, body, &out.writer);
    return out.toOwnedSlice();
}

fn testStatus(allocator: std.mem.Allocator, port: u16, method: std.http.Method, sid: []const u8, body: ?[]const u8, out: ?*std.Io.Writer) !std.http.Status {
    var client: std.http.Client = .{ .allocator = allocator, .io = lp.io };
    defer client.deinit();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(url);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &.{.{ .name = "mcp-session-id", .value = sid }},
        .response_writer = out,
    });
    return result.status;
}

const SlowCall = struct {
    port: u16,
    done: std.atomic.Value(bool) = .init(false),
    response: ?[]u8 = null,

    fn run(self: *SlowCall) void {
        self.response = testPost(testing.allocator, self.port, "slow",
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"goto","arguments":{"url":"http://localhost:9582/src/browser/tests/mcp_actions.html?delay_ms=1500"}}}
        ) catch null;
        self.done.store(true, .release);
    }
};

const TestServer = struct {
    http: *HttpServer,
    accept_thread: std.Thread,
    port: u16,

    /// `session_timeout_ms` overrides the config's before any session but
    /// the default (which is never reaped) reads it.
    fn start(session_timeout_ms: ?u64) !TestServer {
        const http = try HttpServer.init(testing.allocator, testing.test_app);
        errdefer http.deinit();
        http.session_timeout_ms = session_timeout_ms;
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const accept_thread = try std.Thread.spawn(.{}, run, .{ http, address });
        var port: u16 = 0;
        while (port == 0) {
            lp.io.sleep(.fromMilliseconds(5), .awake) catch {};
            const listener = http.listener.load(.acquire);
            if (listener != -1) port = (sys_net.boundAddress(listener) catch continue).getPort();
        }
        return .{ .http = http, .accept_thread = accept_thread, .port = port };
    }

    fn stop(self: *TestServer) void {
        self.http.stop();
        self.accept_thread.join();
        self.http.deinit();
    }
};

test "HttpServer - sessions run on their own threads" {
    var server: TestServer = try .start(null);
    defer server.stop();
    const port = server.port;

    // A page that takes 1.5s to load in one session...
    var slow: SlowCall = .{ .port = port };
    const slow_thread = try std.Thread.spawn(.{}, SlowCall.run, .{&slow});
    var slow_joined = false;
    defer if (!slow_joined) slow_thread.join();
    lp.io.sleep(.fromMilliseconds(100), .awake) catch {};

    // ...doesn't hold up another session's load.
    const fast = try testPost(testing.allocator, port, "fast",
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"goto","arguments":{"url":"http://localhost:9582/src/browser/tests/mcp_actions.html"}}}
    );
    defer testing.allocator.free(fast);
    try testing.expect(std.mem.find(u8, fast, "Navigated") != null);
    try testing.expect(!slow.done.load(.acquire));

    slow_thread.join();
    slow_joined = true;
    defer if (slow.response) |r| testing.allocator.free(r);
    try testing.expect(std.mem.find(u8, slow.response orelse "", "Navigated") != null);

    // The session tools see across threads.
    const list = try testPost(testing.allocator, port, "fast",
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"session_list"}}
    );
    defer testing.allocator.free(list);
    // JSON nested in the tool-result text, so its quotes are escaped.
    try testing.expect(std.mem.find(u8, list, "\\\"default\\\"") != null);
    try testing.expect(std.mem.find(u8, list, "\\\"slow\\\"") != null);
    try testing.expect(std.mem.find(u8, list, "delay_ms=1500") != null);
    // Neither load reached the default session.
    try testing.expect(std.mem.find(u8, list, "{\\\"id\\\":\\\"default\\\"}") != null);

    const close_default = try testPost(testing.allocator, port, "fast",
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"session_close","arguments":{"id":"default"}}}
    );
    defer testing.allocator.free(close_default);
    try testing.expect(std.mem.find(u8, close_default, "cannot be closed") != null);

    const close_self = try testPost(testing.allocator, port, "fast",
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"session_close","arguments":{"id":"fast"}}}
    );
    defer testing.allocator.free(close_self);
    try testing.expect(std.mem.find(u8, close_self, "attached to") != null);

    const closed = try testPost(testing.allocator, port, "fast",
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"session_close","arguments":{"id":"slow"}}}
    );
    defer testing.allocator.free(closed);
    try testing.expect(std.mem.find(u8, closed, "closed session slow") != null);

    const after = try testPost(testing.allocator, port, "fast",
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"session_list"}}
    );
    defer testing.allocator.free(after);
    try testing.expect(std.mem.find(u8, after, "\\\"slow\\\"") == null);

    // A call on a closed id starts a fresh session there, without the old page.
    const reopened = try testPost(testing.allocator, port, "slow",
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"session_list"}}
    );
    defer testing.allocator.free(reopened);
    try testing.expect(std.mem.find(u8, reopened, "{\\\"id\\\":\\\"slow\\\"}") != null);

    try testing.expectEqual(.accepted, try testStatus(testing.allocator, port, .DELETE, "slow", null, null));
    const deleted = try testPost(testing.allocator, port, "fast",
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"session_list"}}
    );
    defer testing.allocator.free(deleted);
    try testing.expect(std.mem.find(u8, deleted, "\\\"slow\\\"") == null);
}

test "HttpServer - idle sessions are reaped" {
    var server: TestServer = try .start(500);
    defer server.stop();
    const port = server.port;

    // Time spent in a call isn't idle time: this load outlives the timeout.
    const busy = try testPost(testing.allocator, port, "busy",
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"goto","arguments":{"url":"http://localhost:9582/src/browser/tests/mcp_actions.html?delay_ms=800"}}}
    );
    defer testing.allocator.free(busy);
    try testing.expect(std.mem.find(u8, busy, "Navigated") != null);
    const listed = try testPost(testing.allocator, port, "default",
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_list"}}
    );
    defer testing.allocator.free(listed);
    try testing.expect(std.mem.find(u8, listed, "\\\"busy\\\"") != null);

    var reaped = false;
    for (0..100) |_| {
        lp.io.sleep(.fromMilliseconds(50), .awake) catch {};
        server.http.workers_mutex.lockUncancelable(lp.io);
        defer server.http.workers_mutex.unlock(lp.io);
        reaped = server.http.reaped.contains("busy");
        if (reaped) break;
    }
    try testing.expect(reaped);

    const call =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"session_list"}}
    ;
    try testing.expectEqual(.not_found, try testStatus(testing.allocator, port, .POST, "busy", call, null));
    try testing.expectEqual(.ok, try testStatus(testing.allocator, port, .POST, "default", call, null));

    const revived = try testPost(testing.allocator, port, "default",
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"session_new","arguments":{"name":"busy"}}}
    );
    defer testing.allocator.free(revived);
    try testing.expect(std.mem.find(u8, revived, "session busy") != null);
    try testing.expectEqual(.ok, try testStatus(testing.allocator, port, .POST, "busy", call, null));
}
