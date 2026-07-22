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
//! Threading rule: V8 isolates are thread-affine, so ALL browser work — every
//! session's Browser/Session — lives on a single worker thread that owns the
//! `Server`. Connection threads never touch a browser; they parse HTTP,
//! marshal a `Job` to the worker over a queue, block on its completion, then
//! write the response. Session routing follows the `Mcp-Session-Id` header:
//! an `initialize` without one mints a fresh session (isolation by default);
//! reusing an id joins that session (sharing on purpose).

const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const sys_net = @import("../sys/net.zig");

const Server = @import("Server.zig");
const router = @import("router.zig");

const log = lp.log;
const posix = std.posix;

const HttpServer = @This();

const ns_per_ms = std.time.ns_per_ms;

/// Cap on a single JSON-RPC request body. Generous: agent tool payloads
/// (e.g. a `save` script) can be large, but this bounds a hostile client.
const max_request_bytes = 16 * 1024 * 1024;

/// One unit of work handed from a connection thread to the browser worker.
/// Allocated on the connection thread's stack — safe because that thread
/// blocks on `done` for the whole time the worker reads `body`/`session_id`
/// and writes `out`.
const Job = struct {
    kind: Kind,
    body: []const u8,
    session_id: ?[]const u8,
    /// Where the worker writes the response. The connection thread owns the
    /// backing buffer and reads it back once `done` fires.
    out: *std.Io.Writer,

    /// Session id the worker actually routed to; echoed back as
    /// `Mcp-Session-Id`. Stored in a fixed buffer (not a worker arena) so it
    /// outlives the worker moving on to the next job.
    assigned_buf: [128]u8 = undefined,
    assigned_len: usize = 0,

    done: std.Io.Event = .unset,
    next: ?*Job = null,

    const Kind = enum { rpc, close };

    fn assigned(self: *const Job) []const u8 {
        return self.assigned_buf[0..self.assigned_len];
    }

    fn setAssigned(self: *Job, id: []const u8) void {
        const n = @min(id.len, self.assigned_buf.len);
        @memcpy(self.assigned_buf[0..n], id[0..n]);
        self.assigned_len = n;
    }
};

const Queue = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    head: ?*Job = null,
    tail: ?*Job = null,
    closed: std.atomic.Value(bool) = .init(false),

    fn push(self: *Queue, job: *Job) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        job.next = null;
        if (self.tail) |t| t.next = job else self.head = job;
        self.tail = job;
        self.cond.signal(lp.io);
    }

    /// Pop the next job, waiting at most `timeout_ms`. Returns null on timeout
    /// (or spurious wakeup) so the worker can pump idle sessions and retry;
    /// check `closed` to tell shutdown from timeout.
    fn pop(self: *Queue, timeout_ms: u64) ?*Job {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self.head == null) {
            if (timeout_ms == 0 or self.closed.load(.acquire)) return null;
            lp.timedWait(&self.cond, &self.mutex, timeout_ms * ns_per_ms) catch {};
        }
        const job = self.head orelse return null;
        self.head = job.next;
        if (self.head == null) self.tail = null;
        return job;
    }

    fn close(self: *Queue) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.closed.store(true, .release);
        self.cond.signal(lp.io);
    }
};

allocator: std.mem.Allocator,
app: *App,

queue: Queue = .{},

// Registration happens in onAccept — the same (network) thread deinit runs
// on — so a connection is always counted and its socket registered before
// deinit can observe either.
active_conns: std.atomic.Value(u32) = .init(0),
conn_mutex: std.Io.Mutex = .init,
conns: std.ArrayList(posix.socket_t) = .empty,

// The worker owns `server`; other threads must not touch it.
worker_thread: std.Thread = undefined,
worker_ready: std.Io.Event = .unset,
worker_ok: bool = false,

/// Create the server and start its browser worker thread. Returns once the
/// worker's default session is up (or errors if it failed to initialize).
pub fn init(allocator: std.mem.Allocator, app: *App) !*HttpServer {
    const self = try allocator.create(HttpServer);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .app = app,
    };

    self.worker_thread = try std.Thread.spawn(.{}, worker, .{self});
    self.worker_ready.waitUncancelable(lp.io);
    if (!self.worker_ok) {
        self.worker_thread.join();
        return error.WorkerInitFailed;
    }
    return self;
}

/// Runs after the accept loop has stopped, so no new connection can arrive.
/// Shutting the sockets down unblocks the connection threads' pending reads;
/// the worker must outlive their drain because a connection thread may still
/// be blocked on `job.done`.
pub fn deinit(self: *HttpServer) void {
    {
        self.conn_mutex.lockUncancelable(lp.io);
        defer self.conn_mutex.unlock(lp.io);
        for (self.conns.items) |socket| {
            sys_net.shutdown(socket, .both) catch {};
        }
    }
    while (self.active_conns.load(.monotonic) > 0) {
        lp.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }

    self.queue.close();
    self.worker_thread.join();

    self.conns.deinit(self.allocator);
    self.allocator.destroy(self);
}

/// Accept MCP-over-HTTP connections until the network loop is stopped
/// (e.g. by the signal handler). Reuses the shared accept infrastructure;
/// blocks the calling thread in `Network.run`.
pub fn run(self: *HttpServer, address: sys_net.IpAddress) !void {
    var bound = address;
    try self.app.network.bind(&bound, self, onAccept);
    log.note(.mcp, "mcp http server running", .{ .address = bound });
    self.app.network.run();
}

/// Network hands us a nonblocking accepted socket; each connection is served
/// by its own thread doing blocking IO, so we clear O_NONBLOCK first.
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

fn worker(self: *HttpServer) void {
    var placeholder: std.Io.Writer.Allocating = .init(self.allocator);
    defer placeholder.deinit();

    const server = Server.init(self.allocator, self.app, &placeholder.writer) catch |err| {
        log.err(.mcp, "mcp http server init", .{ .err = err });
        self.worker_ready.set(lp.io);
        return;
    };
    defer server.deinit();

    server.enableIsolateParking();

    self.worker_ok = true;
    self.worker_ready.set(lp.io);

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();

    // Drain queued jobs before pumping idle work: idle() enters and ticks
    // every live session (blocking up to 25ms each), so pumping between
    // every two jobs would cap throughput at one job per full pass.
    var wait_ms: u64 = 0;
    while (true) {
        const job = self.queue.pop(wait_ms) orelse {
            if (self.queue.closed.load(.acquire)) break;
            wait_ms = server.idle();
            continue;
        };
        _ = arena.reset(.retain_capacity);
        process(server, arena.allocator(), job);
        job.done.set(lp.io);
        wait_ms = 0;
    }
}

fn process(server: *Server, arena: std.mem.Allocator, job: *Job) void {
    server.transport.retarget(job.out);

    if (job.kind == .close) {
        if (job.session_id) |sid| _ = server.closeSession(sid);
        return;
    }

    const chosen = resolveSession(server, arena, job) catch |err| {
        log.err(.mcp, "mcp session routing", .{ .err = err });
        return;
    };
    job.setAssigned(chosen);

    router.handleMessage(server, arena, job.body) catch |err| {
        log.err(.mcp, "mcp handle", .{ .err = err });
    };
}

/// Decide which session a request targets and make it active. An explicit
/// `Mcp-Session-Id` wins; otherwise `initialize` mints a new session and
/// everything else falls back to the default.
fn resolveSession(server: *Server, arena: std.mem.Allocator, job: *Job) ![]const u8 {
    if (job.session_id) |sid| {
        if (sid.len > 0) {
            _ = try server.useSession(sid);
            return sid;
        }
    }

    if (isInitialize(arena, job.body)) {
        const sid = try server.nextSessionId(arena);
        _ = try server.useSession(sid);
        return sid;
    }

    _ = try server.useSession(null);
    return Server.default_session_id;
}

fn isInitialize(arena: std.mem.Allocator, body: []const u8) bool {
    const Peek = struct { method: ?[]const u8 = null };
    const peek = std.json.parseFromSliceLeaky(Peek, arena, body, .{ .ignore_unknown_fields = true }) catch return false;
    const method = peek.method orelse return false;
    return std.mem.eql(u8, method, "initialize");
}

fn handleConn(self: *HttpServer, socket: posix.socket_t) void {
    defer _ = self.active_conns.fetchSub(1, .monotonic);
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
        if (!request.head.keep_alive) return;
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

    // Read the session header and keep_alive before the body reader
    // invalidates the head's string memory.
    const session_id = try sessionHeader(arena, request);
    const keep_alive = request.head.keep_alive;

    var body_buf: [8 * 1024]u8 = undefined;
    const body = request.readerExpectNone(&body_buf).allocRemaining(arena, .limited(max_request_bytes)) catch {
        return request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
    };

    var job: Job = .{
        .kind = if (method == .DELETE) .close else .rpc,
        .body = body,
        .session_id = session_id,
        .out = out,
    };
    self.queue.push(&job);
    job.done.waitUncancelable(lp.io);

    const resp = out.buffered();
    var headers: [2]std.http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "content-type", .value = "application/json" };
    n += 1;
    if (job.assigned_len > 0) {
        headers[n] = .{ .name = "mcp-session-id", .value = job.assigned() };
        n += 1;
    }
    return request.respond(resp, .{
        // An empty body means a notification (or a close): 202, no content.
        .status = if (resp.len == 0) .accepted else .ok,
        .keep_alive = keep_alive,
        .extra_headers = headers[0..n],
    });
}

/// Duplicate the `Mcp-Session-Id` request header into `arena`, or null.
fn sessionHeader(arena: std.mem.Allocator, request: *std.http.Server.Request) !?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
            return try arena.dupe(u8, header.value);
        }
    }
    return null;
}

test "HttpServer - initialize is detected for session minting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expect(isInitialize(aa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"));
    try std.testing.expect(!isInitialize(aa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}"));
    try std.testing.expect(!isInitialize(aa, "not json"));
}
