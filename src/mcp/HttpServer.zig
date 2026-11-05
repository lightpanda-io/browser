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
//! unknown id creates it, a known one joins it, a reaped or deleted one gets
//! 404 until `session_new` or `session_close` names it.

const std = @import("std");
const lp = @import("lightpanda");
const builtin = @import("builtin");

const App = @import("../App.zig");
const sys_net = @import("../sys/net.zig");

const Server = @import("Server.zig");
const Transport = @import("Transport.zig");
const router = @import("router.zig");
const Queue = @import("Queue.zig").Queue;

const log = lp.log;
const posix = std.posix;

const HttpServer = @This();

const ns_per_ms = std.time.ns_per_ms;

/// Cap on a single JSON-RPC request body. Generous: agent tool payloads
/// (e.g. a `save` script) can be large, but this bounds a hostile client.
const max_request_bytes = 16 * 1024 * 1024;

/// One unit of work handed from a connection thread to a session's worker.
/// Allocated on the connection thread's stack — safe because that thread
/// waits for `finished` for the whole time the worker reads `body` and
/// writes `out`.
const Job = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    /// Where the worker writes the response. The connection thread owns the
    /// backing buffer and reads it back once `finished` is set.
    out: *std.Io.Writer,
    /// The client accepts `text/event-stream`.
    streams: bool,
    next: ?*Job = null,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    /// Notifications not yet sent, one per line. Guarded by `mutex`.
    pending: std.ArrayList(u8) = .empty,
    /// Guarded by `mutex`.
    finished: bool = false,
    /// Guarded by `mutex`.
    hung_up: bool = false,

    fn deinit(self: *Job) void {
        self.pending.deinit(self.allocator);
    }

    fn sink(self: *Job) Transport.Notify {
        if (!self.streams) return .drop;
        return .{ .sink = .{ .context = self, .push = push } };
    }

    fn push(context: *anyopaque, message: []const u8) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self.hung_up) return;
        self.pending.ensureUnusedCapacity(self.allocator, message.len + 1) catch return;
        self.pending.appendSliceAssumeCapacity(message);
        self.pending.appendAssumeCapacity('\n');
        self.cond.signal(lp.io);
    }

    /// The worker's last touch: the connection thread may free the job after.
    fn finish(self: *Job) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.finished = true;
        self.cond.signal(lp.io);
    }

    fn hangUp(self: *Job) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.hung_up = true;
    }

    /// Move pending notifications into the empty `into`, waiting up to
    /// `timeout_ms` for one. True once finished, with every one moved.
    fn wait(self: *Job, into: *std.ArrayList(u8), timeout_ms: u64) bool {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self.pending.items.len == 0 and !self.finished) {
            self.cond.waitTimeout(lp.io, &self.mutex, .{ .duration = .{
                .raw = .fromNanoseconds(timeout_ms * ns_per_ms),
                .clock = .awake,
            } }) catch {};
        }
        std.mem.swap(std.ArrayList(u8), &self.pending, into);
        return self.finished;
    }
};

const JobQueue = Queue(Job);

/// One session: its thread, its queue and, on that thread, its `Server`.
/// Listed in `workers` until closed; its thread then drains the queue, tears
/// the session down and frees it.
const Worker = struct {
    http: *HttpServer,
    id: []const u8,
    queue: JobQueue = .{},
    /// Guarded by `workers_mutex`, for `session_list`.
    url: ?[]const u8 = null,
    /// Guarded by `workers_mutex`, for `cancel`.
    server: ?*Server = null,
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
/// Ids the reaper or an HTTP DELETE ended, answered with 404 so a stale client
/// doesn't silently get a fresh browser. Kept until `session_new` or
/// `session_close` names the id: an entry is just the id, against the isolate
/// it freed. Guarded by `workers_mutex`.
tombstones: std.StringHashMapUnmanaged(void) = .empty,
session_timeout_ms: ?u64,
/// How long an event stream may go silent before a keep-alive comment, so
/// proxies don't time out a long call. A call that outlives it switches to
/// a stream even if it sends nothing else.
heartbeat_ms: u64 = 15_000,
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
/// still be waiting on its job.
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
    var tombstones = self.tombstones.keyIterator();
    while (tombstones.next()) |id| self.allocator.free(id.*);
    self.tombstones.deinit(self.allocator);
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
/// new, even if a session by that name was reaped or deleted. Returns its id,
/// in `arena`.
pub fn createSession(self: *HttpServer, arena: std.mem.Allocator, name: ?[]const u8) ![]const u8 {
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    if (name) |n| _ = self.forgetTombstoneLocked(n);
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
/// it down. Closing a tombstoned id frees it for reuse. False if there is no
/// such session. The default lives as long as the process.
pub fn closeSession(self: *HttpServer, id: []const u8) bool {
    if (Server.isDefault(id)) return false;
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    if (self.forgetTombstoneLocked(id)) return true;
    const worker = self.workers.get(id) orelse return false;
    self.removeLocked(worker);
    return true;
}

/// HTTP DELETE: close session `id` and tombstone it, so later requests get 404
/// instead of a fresh session. Deleting a tombstoned id again, or the default
/// (which lives as long as the process), succeeds and does nothing. False if
/// there is no such session.
fn deleteSession(self: *HttpServer, id: []const u8) bool {
    if (Server.isDefault(id)) return true;
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    if (self.tombstones.contains(id)) return true;
    const worker = self.workers.get(id) orelse return false;
    self.removeLocked(worker);
    // Close first: an id we fail to remember only lets a later request start
    // a fresh session, as it did before tombstones.
    self.tombstoneLocked(id) catch |err| {
        log.warn(.mcp, "mcp session tombstone", .{ .session = id, .err = err });
    };
    return true;
}

fn tombstoneLocked(self: *HttpServer, id: []const u8) !void {
    const owned_id = try self.allocator.dupe(u8, id);
    errdefer self.allocator.free(owned_id);
    try self.tombstones.putNoClobber(self.allocator, owned_id, {});
}

fn findOrSpawnLocked(self: *HttpServer, id: ?[]const u8) !*Worker {
    if (id) |name| {
        if (self.workers.get(name)) |worker| return worker;
        if (self.tombstones.contains(name)) return error.SessionEnded;
        return self.spawnLocked(name, null);
    }
    var buf: [16]u8 = undefined;
    while (true) {
        self.session_seq += 1;
        const candidate = std.fmt.bufPrint(&buf, "s{d}", .{self.session_seq}) catch unreachable;
        if (!self.workers.contains(candidate) and !self.tombstones.contains(candidate)) {
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

fn forgetTombstoneLocked(self: *HttpServer, id: []const u8) bool {
    const kv = self.tombstones.fetchRemove(id) orelse return false;
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

    self.tombstoneLocked(worker.id) catch return false;
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

fn publishServer(self: *HttpServer, worker: *Worker, server: ?*Server) void {
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    worker.server = server;
}

/// Bypasses the queue, where a cancellation would wait behind the call it
/// cancels.
fn cancel(self: *HttpServer, id: []const u8, request_id: std.json.Value) void {
    self.workers_mutex.lockUncancelable(lp.io);
    defer self.workers_mutex.unlock(lp.io);
    const worker = self.workers.get(id) orelse return;
    const server = worker.server orelse return;
    server.handleCancelledRequest(request_id);
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
    self.publishServer(worker, server);
    defer self.publishServer(worker, null);
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
            .item => |job| job,
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
        defer job.finish();
        _ = arena.reset(.retain_capacity);
        const s = server orelse {
            reject(arena.allocator(), job, "session failed to start");
            continue;
        };
        s.transport.bind(job.out, job.sink());
        router.handleMessage(s, arena.allocator(), job.body) catch |err| {
            log.err(.mcp, "mcp handle", .{ .err = err });
        };
        s.transport.notify = .drop;
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
/// MCP Streamable HTTP — POST carries a JSON-RPC message, answered with JSON
/// or, once the call sends a notification or outlives `heartbeat_ms`, an
/// event stream; DELETE closes the session named by `Mcp-Session-Id`.
/// std.http.Server owns the framing.
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
    const head = checkHeaders(arena, request) catch |err| switch (err) {
        error.ForbiddenOrigin => return request.respond("Origin not allowed\n", .{ .status = .forbidden, .keep_alive = false }),
        error.ForbiddenHost => return request.respond("Host not allowed, connect to the MCP endpoint by IP address or localhost\n", .{ .status = .forbidden, .keep_alive = false }),
        else => return err,
    };
    const session_id = head.session_id;
    const keep_alive = request.head.keep_alive;

    var body_buf: [8 * 1024]u8 = undefined;
    const body = request.readerExpectNone(&body_buf).allocRemaining(arena, .limited(max_request_bytes)) catch {
        return request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
    };

    if (method == .DELETE) {
        if (session_id) |sid| {
            if (!self.deleteSession(sid)) {
                return request.respond("Unknown session\n", .{ .status = .not_found, .keep_alive = keep_alive });
            }
        }
        return request.respond("", .{ .status = .accepted, .keep_alive = keep_alive });
    }

    const target_id = target(arena, session_id, body);
    if (router.cancelledRequestId(arena, body)) |request_id| {
        self.cancel(target_id orelse Server.default_session_id, request_id);
        return request.respond("", .{ .status = .accepted, .keep_alive = keep_alive });
    }

    var job: Job = .{ .allocator = self.allocator, .body = body, .out = out, .streams = head.event_stream };
    defer job.deinit();
    const routed = self.submit(arena, target_id, &job) catch |err| switch (err) {
        error.SessionEnded => return request.respond("Session ended, start a new one\n", .{ .status = .not_found, .keep_alive = keep_alive }),
        else => {
            log.err(.mcp, "mcp session routing", .{ .err = err });
            return request.respond("", .{ .status = .internal_server_error, .keep_alive = false });
        },
    };

    var stream: EventStream = .{ .request = request, .session_id = routed, .keep_alive = keep_alive };
    var events: std.ArrayList(u8) = .empty;
    defer events.deinit(self.allocator);
    var hung_up = false;
    while (true) {
        events.clearRetainingCapacity();
        const finished = job.wait(&events, self.heartbeat_ms);
        // A call that ends with nothing to stream still gets a plain reply.
        if (job.streams and !hung_up and (events.items.len > 0 or !finished)) {
            stream.send(events.items) catch {
                hung_up = true;
                job.hangUp();
            };
        }
        if (finished) break;
    }
    if (hung_up) return error.WriteFailed;

    const resp = out.buffered();
    if (stream.body != null) return stream.end(resp);
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

/// The `text/event-stream` reply to one POST, opened on its first event.
const EventStream = struct {
    request: *std.http.Server.Request,
    session_id: []const u8,
    keep_alive: bool,
    buf: [4096]u8 = undefined,
    body: ?std.http.BodyWriter = null,

    /// Send `messages`, one JSON-RPC message per line; none sends a
    /// keep-alive comment.
    fn send(self: *EventStream, messages: []const u8) !void {
        const body = try self.open();
        if (messages.len == 0) {
            try body.writer.writeAll(": keep-alive\n\n");
        } else {
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, messages, "\n"), '\n');
            while (it.next()) |message| try writeEvent(&body.writer, message);
        }
        try body.writer.flush();
        try body.flush();
    }

    /// Send the response, if the call has one, and close the stream.
    fn end(self: *EventStream, response: []const u8) !void {
        const body = &self.body.?;
        const message = std.mem.trimEnd(u8, response, "\n");
        if (message.len > 0) try writeEvent(&body.writer, message);
        try body.end();
    }

    fn open(self: *EventStream) !*std.http.BodyWriter {
        if (self.body) |*body| return body;
        self.body = try self.request.respondStreaming(&self.buf, .{ .respond_options = .{
            .keep_alive = self.keep_alive,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "mcp-session-id", .value = self.session_id },
            },
        } });
        return &self.body.?;
    }

    fn writeEvent(writer: *std.Io.Writer, message: []const u8) !void {
        try writer.print("event: message\ndata: {s}\n\n", .{message});
    }
};

const Head = struct {
    session_id: ?[]const u8 = null,
    event_stream: bool = false,
};

/// One pass over the request headers: duplicate `Mcp-Session-Id` into
/// `arena` (or null), note whether `Accept` takes an event stream, and
/// enforce the same browser-vector policy as the CDP handshake (see
/// `cdp.Connection.upgrade`).
fn checkHeaders(arena: std.mem.Allocator, request: *std.http.Server.Request) !Head {
    var head: Head = .{};
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        const key = header.name;
        const value = header.value;
        if (std.ascii.eqlIgnoreCase(key, "mcp-session-id")) {
            head.session_id = try arena.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(key, "accept")) {
            head.event_stream = head.event_stream or acceptsEventStream(value);
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
    return head;
}

fn acceptsEventStream(accept: []const u8) bool {
    var it = std.mem.splitScalar(u8, accept, ',');
    while (it.next()) |range| {
        if (isMediaType(range, "text/event-stream")) return true;
    }
    return false;
}

fn isJsonContentType(content_type: ?[]const u8) bool {
    return isMediaType(content_type orelse return false, "application/json");
}

/// Case-insensitive, ignoring parameters (`; charset=`).
fn isMediaType(value: []const u8, media_type: []const u8) bool {
    const end = std.mem.findScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..end], " \t"), media_type);
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
    return testPostAccept(allocator, port, sid, body, "application/json");
}

fn testStatus(allocator: std.mem.Allocator, port: u16, method: std.http.Method, sid: []const u8, body: ?[]const u8, out: ?*std.Io.Writer) !std.http.Status {
    return testRequest(allocator, port, method, sid, body, "application/json", out);
}

const accept_both = "application/json, text/event-stream";

/// POSTs `body` as a client that takes `accept`, and returns the response body.
fn testPostAccept(allocator: std.mem.Allocator, port: u16, sid: []const u8, body: []const u8, accept: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    _ = try testRequest(allocator, port, .POST, sid, body, accept, &out.writer);
    return out.toOwnedSlice();
}

fn testRequest(allocator: std.mem.Allocator, port: u16, method: std.http.Method, sid: []const u8, body: ?[]const u8, accept: []const u8, out: ?*std.Io.Writer) !std.http.Status {
    var client: std.http.Client = .{ .allocator = allocator, .io = lp.io };
    defer client.deinit();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(url);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &.{
            .{ .name = "mcp-session-id", .value = sid },
            .{ .name = "accept", .value = accept },
        },
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
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"goto","arguments":{"url":"http://localhost:9582/src/browser/tests/mcp_actions.html?held=1"}}}
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

    // A page held mid-load in one session...
    testing.hold_loads.store(true, .release);
    defer testing.hold_loads.store(false, .release);
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

    testing.hold_loads.store(false, .release);
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
    try testing.expect(std.mem.find(u8, list, "held=1") != null);
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

test "HttpServer - DELETE tombstones a session id" {
    var server: TestServer = try .start(null);
    defer server.stop();
    const port = server.port;
    const call =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"session_list"}}
    ;

    try testing.expectEqual(.not_found, try testStatus(testing.allocator, port, .DELETE, "unknown", null, null));
    try testing.expectEqual(.ok, try testStatus(testing.allocator, port, .POST, "deleted", call, null));
    try testing.expectEqual(.accepted, try testStatus(testing.allocator, port, .DELETE, "deleted", null, null));

    const listed = try testPost(testing.allocator, port, "default", call);
    defer testing.allocator.free(listed);
    try testing.expect(std.mem.find(u8, listed, "\\\"deleted\\\"") == null);

    try testing.expectEqual(.not_found, try testStatus(testing.allocator, port, .POST, "deleted", call, null));
    try testing.expectEqual(.accepted, try testStatus(testing.allocator, port, .DELETE, "deleted", null, null));
    try testing.expectEqual(.not_found, try testStatus(testing.allocator, port, .POST, "deleted", call, null));

    const revived = try testPost(testing.allocator, port, "default",
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_new","arguments":{"name":"deleted"}}}
    );
    defer testing.allocator.free(revived);
    try testing.expect(std.mem.find(u8, revived, "session deleted") != null);
    try testing.expectEqual(.ok, try testStatus(testing.allocator, port, .POST, "deleted", call, null));

    try testing.expectEqual(.accepted, try testStatus(testing.allocator, port, .DELETE, "deleted", null, null));
    const closed = try testPost(testing.allocator, port, "default",
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"session_close","arguments":{"id":"deleted"}}}
    );
    defer testing.allocator.free(closed);
    try testing.expect(std.mem.find(u8, closed, "closed session deleted") != null);
    try testing.expectEqual(.ok, try testStatus(testing.allocator, port, .POST, "deleted", call, null));
}

test "HttpServer - idle sessions are reaped" {
    var server: TestServer = try .start(150);
    defer server.stop();
    const port = server.port;

    // Time spent in a call isn't idle time: this load outlives the timeout.
    const busy = try testPost(testing.allocator, port, "busy",
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"goto","arguments":{"url":"http://localhost:9582/src/browser/tests/mcp_actions.html?delay_ms=300"}}}
    );
    defer testing.allocator.free(busy);
    try testing.expect(std.mem.find(u8, busy, "Navigated") != null);
    const listed = try testPost(testing.allocator, port, "default",
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_list"}}
    );
    defer testing.allocator.free(listed);
    try testing.expect(std.mem.find(u8, listed, "\\\"busy\\\"") != null);

    var reaped = false;
    for (0..500) |_| {
        lp.io.sleep(.fromMilliseconds(10), .awake) catch {};
        server.http.workers_mutex.lockUncancelable(lp.io);
        defer server.http.workers_mutex.unlock(lp.io);
        reaped = server.http.tombstones.contains("busy");
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

const WaitCall = struct {
    port: u16,
    response: ?[]u8 = null,

    fn run(self: *WaitCall) void {
        self.response = testPost(testing.allocator, self.port, "cancel",
            \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"waitForScript","arguments":{"script":"false","timeout":30000}}}
        ) catch null;
    }
};

test "HttpServer - notifications/cancelled reaches the call in flight" {
    var server: TestServer = try .start(null);
    defer server.stop();
    const port = server.port;

    const loaded = try testPost(testing.allocator, port, "cancel",
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"goto","arguments":{"url":"about:blank"}}}
    );
    defer testing.allocator.free(loaded);

    var wait: WaitCall = .{ .port = port };
    const started = lp.datetime.milliTimestamp(.boot);
    const wait_thread = try std.Thread.spawn(.{}, WaitCall.run, .{&wait});
    lp.io.sleep(.fromMilliseconds(300), .awake) catch {};

    const cancel_call =
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}
    ;
    try testing.expectEqual(.accepted, try testStatus(testing.allocator, port, .POST, "cancel", cancel_call, null));
    // Doesn't start a session.
    try testing.expectEqual(.accepted, try testStatus(testing.allocator, port, .POST, "never-started", cancel_call, null));

    wait_thread.join();
    defer if (wait.response) |r| testing.allocator.free(r);
    try testing.expect(lp.datetime.milliTimestamp(.boot) - started < 10_000);
    // A cancelled call gets no response.
    try testing.expectEqual(0, (wait.response orelse return error.TestUnexpectedResult).len);

    const after = try testPost(testing.allocator, port, "cancel",
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"session_list"}}
    );
    defer testing.allocator.free(after);
    try testing.expect(std.mem.find(u8, after, "\\\"never-started\\\"") == null);
}

test "HttpServer - Accept lists text/event-stream" {
    try testing.expect(acceptsEventStream("application/json, text/event-stream"));
    try testing.expect(acceptsEventStream("Text/Event-Stream;q=0.9"));
    try testing.expect(!acceptsEventStream("application/json"));
    try testing.expect(!acceptsEventStream("text/event-streams"));
}

test "HttpServer - a call's notifications stream over SSE" {
    var server: TestServer = try .start(null);
    defer server.stop();
    const port = server.port;
    const run_call =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run","arguments":{"script":"console.log('one');\nconsole.warn('two');\nreturn 'done';"}}}
    ;

    const streamed = try testPostAccept(testing.allocator, port, "sse", run_call, accept_both);
    defer testing.allocator.free(streamed);
    const one = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"logger\":\"console\",\"data\":\"one\"}}\n\n";
    const two = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"warning\",\"logger\":\"console\",\"data\":\"two\"}}\n\n";
    try testing.expect(std.mem.startsWith(u8, streamed, one ++ two ++ "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":"));
    try testing.expect(std.mem.find(u8, streamed, "one\\ntwo\\ndone\\n") != null);
    try testing.expect(std.mem.endsWith(u8, streamed, "}\n\n"));

    const plain = try testPostAccept(testing.allocator, port, "sse", run_call, "application/json");
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.startsWith(u8, plain, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":"));
    try testing.expect(std.mem.find(u8, plain, "notifications/message") == null);

    const quiet = try testPostAccept(testing.allocator, port, "sse",
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_list"}}
    , accept_both);
    defer testing.allocator.free(quiet);
    try testing.expect(std.mem.startsWith(u8, quiet, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":"));

    const progress = try testPostAccept(testing.allocator, port, "sse",
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"_meta":{"progressToken":"t"},"name":"run","arguments":{"script":"console.log('one');\nconsole.log('two');"}}}
    , accept_both);
    defer testing.allocator.free(progress);
    try testing.expect(std.mem.find(u8, progress, "\"params\":{\"progressToken\":\"t\",\"progress\":1,\"message\":\"one\"}") != null);
    try testing.expect(std.mem.find(u8, progress, "\"params\":{\"progressToken\":\"t\",\"progress\":2,\"message\":\"two\"}") != null);
    try testing.expect(std.mem.find(u8, progress, "notifications/message") == null);
}

test "HttpServer - a silent call outliving the heartbeat streams keep-alives" {
    var server: TestServer = try .start(null);
    defer server.stop();
    server.http.heartbeat_ms = 50;

    const slow = try testPostAccept(testing.allocator, server.port, "beat",
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"goto","arguments":{"url":"http://localhost:9582/src/browser/tests/mcp_actions.html?delay_ms=300"}}}
    , accept_both);
    defer testing.allocator.free(slow);
    try testing.expect(std.mem.startsWith(u8, slow, ": keep-alive\n\n"));
    try testing.expect(std.mem.find(u8, slow, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":") != null);
    try testing.expect(std.mem.find(u8, slow, "Navigated") != null);
}

test "HttpServer - a client hanging up mid-stream leaves the session usable" {
    var server: TestServer = try .start(null);
    defer server.stop();
    server.http.heartbeat_ms = 20;

    {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", server.port);
        const conn = try address.connect(lp.io, .{ .mode = .stream });
        defer conn.close(lp.io);
        const body =
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run","arguments":{"script":"const page = new Page();\nfor (let i = 0; i < 200; i++) { console.log('line ' + i); await page.goto('about:blank'); }\nreturn 'done';"}}}
        ;
        var send_buf: [1024]u8 = undefined;
        var writer = conn.writer(lp.io, &send_buf);
        try writer.interface.print("POST / HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: application/json\r\naccept: " ++ accept_both ++ "\r\nmcp-session-id: gone\r\ncontent-length: {d}\r\n\r\n{s}", .{ body.len, body });
        try writer.interface.flush();

        var recv_buf: [1024]u8 = undefined;
        var reader = conn.reader(lp.io, &recv_buf);
        const status = try reader.interface.takeDelimiterInclusive('\n');
        try testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 200"));
    }

    const after = try testPostAccept(testing.allocator, server.port, "gone",
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_list"}}
    , accept_both);
    defer testing.allocator.free(after);
    try testing.expect(std.mem.find(u8, after, "\\\"gone\\\"") != null);
}
