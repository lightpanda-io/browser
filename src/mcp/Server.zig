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
const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const testing = @import("../testing.zig");

const tools = @import("tools.zig");
const router = @import("router.zig");
const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const Transport = @import("Transport.zig");
const HttpServer = @import("HttpServer.zig");

const Self = @This();

/// The session an un-scoped request lands on: the only one over stdio, and
/// the one the HTTP transport routes to when a client sends no
/// `Mcp-Session-Id`.
pub const default_session_id = "default";

/// How many caller-cancelled ids the server remembers (see `cancelled_ids`).
const cancelled_capacity = 8;

/// A JSON-RPC request id, narrowed to what callers actually send
/// (`notifications/cancelled` must match the in-flight call's id). A string
/// is owned when it sits in the cancelled set (dupe'd out of the
/// notification's arena) and borrowed when it's `in_flight_id` (points into
/// the request arena, which outlives the dispatch).
const RequestId = union(enum) {
    integer: i64,
    string: []const u8,

    /// Copies string ids into `allocator`; null for ids a match could never
    /// name (null, bool, fractional numbers or oversized integers, which
    /// only ever arrive as `number_string` and so can't fit an i64).
    fn owned(allocator: std.mem.Allocator, value: std.json.Value) ?RequestId {
        return switch (value) {
            .integer => |i| .{ .integer = i },
            .float => |f| if (integral(f)) |i| .{ .integer = i } else null,
            .string => |s| blk: {
                const copy = allocator.dupe(u8, s) catch break :blk null;
                break :blk .{ .string = copy };
            },
            else => null,
        };
    }

    /// The in-flight id borrows the request arena — no copy needed.
    fn borrowed(value: std.json.Value) ?RequestId {
        return switch (value) {
            .integer => |i| .{ .integer = i },
            .float => |f| if (integral(f)) |i| .{ .integer = i } else null,
            .string => |s| .{ .string = s },
            else => null,
        };
    }

    /// i64 as an exact f64 only holds integers up to 2^53; beyond that an
    /// id could match a number the sender never meant.
    fn integral(f: f64) ?i64 {
        if (f != @trunc(f)) return null;
        if (f < -9007199254740992.0 or f > 9007199254740992.0) return null;
        return @trunc(f);
    }

    fn eql(self: RequestId, other: RequestId) bool {
        return switch (self) {
            .integer => |i| other == .integer and other.integer == i,
            .string => |s| other == .string and std.mem.eql(u8, other.string, s),
        };
    }
};

allocator: std.mem.Allocator,
app: *App,

/// The one session this server drives; the HTTP transport runs one server
/// per session.
active_session: *lp.ToolSession,
/// `default`, or the name the HTTP transport gave this session.
session_id: []const u8,
/// The HTTP transport, for the session tools. Null over stdio, where a
/// request can't name a session, so those tools are refused.
directory: ?*HttpServer = null,
transport: Transport,

/// Cancellation plumbing for `notifications/cancelled`. The stdio reader
/// thread (see router) records the id of the request the caller abandoned;
/// tool calls register the id they're dispatching, and the session's
/// `cancel_hook` matches the two — so the wait loops polling
/// `Session.isCancelled` abort a caller-abandoned request instead of
/// holding the session for its full timeout.
cancel_mutex: std.Io.Mutex = .init,
/// Ids the caller cancelled. A capped ring, not a single slot: calls queued
/// behind a long wait time out together, so several cancellations can land
/// before the dispatcher consumes any. When full, the oldest entry is
/// dropped — ids aren't reused within a session, so losing a very old
/// cancellation is benign. Owned; replaced or consumed under
/// `cancel_mutex`.
cancelled_ids: [cancelled_capacity]?RequestId = @splat(null),
/// Next `cancelled_ids` slot to overwrite.
cancelled_next: usize = 0,
/// The request currently dispatched. Only the dispatch thread touches it.
in_flight_id: ?RequestId = null,

pub fn init(allocator: std.mem.Allocator, app: *App, writer: *std.Io.Writer) !*Self {
    return initSession(allocator, app, writer, default_session_id);
}

/// A server for the session named `id`, which must outlive it.
pub fn initSession(allocator: std.mem.Allocator, app: *App, writer: *std.Io.Writer, id: []const u8) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    // Heap-allocated and never moved: `Browser` registers self-pointers.
    const entry = try allocator.create(lp.ToolSession);
    errdefer allocator.destroy(entry);

    try entry.init(app);
    errdefer entry.deinit();

    // Only the default session is backed by the on-disk cookie file; named
    // sessions start clean so agents stay isolated by default.
    if (isDefault(id)) {
        if (app.config.cookieFile()) |cookie_path| {
            lp.cookies.loadFromFile(entry.session, cookie_path);
        }
    }
    entry.exitIsolate();

    self.* = .{
        .allocator = allocator,
        .app = app,
        .active_session = entry,
        .session_id = id,
        .transport = .init(allocator, writer),
    };

    // Tool calls poll `Session.isCancelled`; wire that up to this server's
    // cancellation state. (The interactive agent installs its own hook for
    // Ctrl-C; an MCP server drives its session exclusively.)
    entry.session.cancel_hook = .{ .context = self, .check = cancelledCheck };
    return self;
}

pub fn deinit(self: *Self) void {
    // The hook is about to dangle, and nothing can be polling: the caller
    // joins the reader/worker threads before tearing the server down.
    self.active_session.session.cancel_hook = null;
    {
        self.cancel_mutex.lockUncancelable(lp.io);
        defer self.cancel_mutex.unlock(lp.io);
        for (self.cancelled_ids) |request_id| {
            if (request_id) |id| self.freeRequestId(id);
        }
        self.cancelled_ids = @splat(null);
        self.in_flight_id = null;
    }

    const entry = self.active_session;
    if (isDefault(self.session_id)) {
        if (self.app.config.cookieJarFile()) |cookie_jar_path| {
            lp.cookies.saveToFile(&entry.session.cookie_jar, cookie_jar_path);
        }
    }
    entry.enterIsolate();
    entry.deinit();
    self.allocator.destroy(entry);

    self.transport.deinit();
    self.allocator.destroy(self);
}

pub fn isDefault(id: []const u8) bool {
    return std.mem.eql(u8, id, default_session_id);
}

/// Pump the session's pending transfers and return how long the
/// caller may block before pumping again. See `Session.idleSlice`.
pub fn idle(self: *Self) u31 {
    // Pumping may resume JS (e.g. a completed script fetch), so it needs
    // the session's isolate current.
    const entry = self.active_session;
    entry.enterIsolate();
    defer entry.exitIsolate();
    return entry.session.idleSlice();
}

pub fn sendError(self: *Self, id: std.json.Value, code: protocol.ErrorCode, message: []const u8) !void {
    return self.transport.sendError(id, code, message);
}

pub fn sendResult(self: *Self, id: std.json.Value, result: anytype) !void {
    return self.transport.sendResult(id, result);
}

pub fn handleInitialize(self: *Self, req: protocol.Request) !void {
    const id = req.id orelse return;
    if (protocol.clientName(req.params)) |name| {
        self.app.telemetry.record(.{ .mcp_client = .fromName(name) });
    }
    try self.sendResult(id, protocol.InitializeResult{
        .protocolVersion = @tagName(protocol.Version.negotiate(req.params)),
        .capabilities = .{
            .resources = .{},
            .tools = .{},
        },
        .serverInfo = .{ .name = "lightpanda", .version = "0.1.0" },
        .instructions = lp.tools.driver_guidance,
    });
}

pub fn handleToolList(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    return tools.handleList(self, arena, req);
}

pub fn handleToolCall(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    // A notification gets no id and can't be cancelled; `tools.handleCall`
    // ignores it anyway.
    const id = req.id orelse return tools.handleCall(self, arena, req);

    // The caller cancelled this id before it was dispatched: skip the call
    // entirely — the spec says a cancelled request gets no response, and
    // the caller has stopped waiting for one anyway.
    if (self.takeCancelled(id)) return;

    // Mark the call in flight for its whole dispatch, so a cancellation
    // naming it can abort it (see `cancelledCheck`).
    self.beginRequest(id);
    defer self.endRequest();
    // Dispatch runs page JS, so enter the target isolate around it.
    const entry = self.active_session;
    entry.enterIsolate();
    defer entry.exitIsolate();
    return tools.handleCall(self, arena, req);
}

/// Record the request the caller abandoned (`notifications/cancelled`).
/// Called from the stdio reader thread, on the caller's behalf, so it must
/// not touch the browser — just the state the session's cancel hook reads.
pub fn handleCancelledRequest(self: *Self, request_id: std.json.Value) void {
    const cancelled = RequestId.owned(self.allocator, request_id) orelse return;
    self.cancel_mutex.lockUncancelable(lp.io);
    defer self.cancel_mutex.unlock(lp.io);
    if (self.cancelled_ids[self.cancelled_next]) |oldest| self.freeRequestId(oldest);
    self.cancelled_ids[self.cancelled_next] = cancelled;
    self.cancelled_next = (self.cancelled_next + 1) % self.cancelled_ids.len;
}

/// If the caller cancelled `id` before it was dispatched, consume that
/// cancellation and return true — the request must not run at all.
fn takeCancelled(self: *Self, id: std.json.Value) bool {
    const request_id = RequestId.borrowed(id) orelse return false;
    self.cancel_mutex.lockUncancelable(lp.io);
    defer self.cancel_mutex.unlock(lp.io);
    return self.cancelledRemove(request_id);
}

/// Mark `id` as the request being dispatched, so a cancellation naming it
/// aborts the call. `id` borrows the request arena, which outlives the
/// dispatch (the router resets the arena only after `handleMessage`
/// returns).
fn beginRequest(self: *Self, id: std.json.Value) void {
    const request_id = RequestId.borrowed(id) orelse return;
    self.cancel_mutex.lockUncancelable(lp.io);
    defer self.cancel_mutex.unlock(lp.io);
    self.in_flight_id = request_id;
}

/// The dispatched request is done. Drop its cancellation if one is still
/// recorded — the call is over either way, and a leftover match could abort
/// a later request that reuses the id.
fn endRequest(self: *Self) void {
    self.cancel_mutex.lockUncancelable(lp.io);
    defer self.cancel_mutex.unlock(lp.io);
    defer self.in_flight_id = null;
    const request_id = self.in_flight_id orelse return;
    _ = self.cancelledRemove(request_id);
}

/// Remove `request_id` from the cancelled set if recorded. Assumes the
/// caller holds `cancel_mutex`.
fn cancelledRemove(self: *Self, request_id: RequestId) bool {
    for (&self.cancelled_ids) |*slot| {
        const entry = slot.* orelse continue;
        if (!entry.eql(request_id)) continue;
        self.freeRequestId(entry);
        slot.* = null;
        return true;
    }
    return false;
}

fn freeRequestId(self: *Self, request_id: RequestId) void {
    switch (request_id) {
        .string => |s| self.allocator.free(s),
        .integer => {},
    }
}

/// True while the request being dispatched is the one the caller cancelled:
/// the wait loops abort it (via `cancelledCheck`) and its reply is
/// suppressed (see tools), per the spec's "no response for a cancelled
/// request".
pub fn inFlightCancelled(self: *Self) bool {
    self.cancel_mutex.lockUncancelable(lp.io);
    defer self.cancel_mutex.unlock(lp.io);
    const request_id = self.in_flight_id orelse return false;
    for (self.cancelled_ids) |entry| {
        if (entry) |cancelled| if (cancelled.eql(request_id)) return true;
    }
    return false;
}

/// The session's `cancel_hook`: true cancels the in-flight request. Runs on
/// the dispatch thread, from the wait loops polling between ticks.
fn cancelledCheck(context: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.inFlightCancelled();
}

pub fn handleResourceList(self: *Self, req: protocol.Request) !void {
    return resources.handleList(self, req);
}

pub fn handleResourceRead(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    const entry = self.active_session;
    entry.enterIsolate();
    defer entry.exitIsolate();
    return resources.handleRead(self, arena, req);
}

test "MCP.Server - Integration: synchronous smoke test" {
    const allocator = testing.allocator;
    const app = testing.test_app;

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}}}
    ;

    var in_reader: std.Io.Reader = .fixed(input);
    var out_alloc: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Self.init(allocator, app, &out_alloc.writer);
    defer server.deinit();

    try router.processRequests(server, &in_reader, null);

    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 1, .result = .{ .protocolVersion = "2024-11-05" } }, out_alloc.writer.buffered());
}

test "MCP.Server - initialize negotiates the protocol version" {
    var out_alloc: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Self.init(testing.allocator, testing.test_app, &out_alloc.writer);
    defer server.deinit();

    const aa = testing.arena_allocator;

    // A supported version is echoed back.
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 1, .result = .{ .protocolVersion = "2025-06-18" } }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // An unknown one gets the latest supported.
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 2, .result = .{ .protocolVersion = "2025-11-25" } }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // So does a request with no version at all.
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 3, .result = .{ .protocolVersion = "2025-11-25" } }, out_alloc.writer.buffered());
}

test "MCP.Server - RequestId matches the shapes JSON-RPC ids take" {
    const allocator = testing.allocator;

    const owned_int = RequestId.owned(allocator, .{ .integer = 7 }) orelse return error.TestUnexpectedResult;
    try testing.expect(owned_int.eql(.{ .integer = 7 }));
    try testing.expect(!owned_int.eql(.{ .integer = 8 }));

    // A string id copies; it never matches an integer one.
    const owned_str = RequestId.owned(allocator, .{ .string = "req-42" }) orelse return error.TestUnexpectedResult;
    defer allocator.free(owned_str.string);
    try testing.expect(owned_str.eql(.{ .string = "req-42" }));
    try testing.expect(!owned_str.eql(.{ .integer = 42 }));

    // A float id is matchable only while it stays integral and exact.
    try testing.expectEqual(RequestId{ .integer = 3 }, RequestId.owned(allocator, .{ .float = 3.0 }).?);
    try testing.expect(RequestId.owned(allocator, .{ .float = 3.5 }) == null);
    // 1e17 survives the round-trip as an exact integer, but past 2^53 the
    // value the sender meant isn't recoverable — refuse to match it.
    try testing.expect(RequestId.owned(allocator, .{ .float = 1e17 }) == null);

    // Ids that could never be matched come back null.
    try testing.expect(RequestId.owned(allocator, .null) == null);
    try testing.expect(RequestId.owned(allocator, .{ .bool = true }) == null);
    // An oversized integer only ever arrives as `number_string`, and it
    // can't fit the i64 the in-flight call recorded — refuse to match it.
    try testing.expect(RequestId.owned(allocator, .{ .number_string = "12345678901234567890123" }) == null);

    // The in-flight id borrows instead of copying.
    const borrowed = RequestId.borrowed(.{ .string = "no-copy" }) orelse return error.TestUnexpectedResult;
    try testing.expect(borrowed.eql(owned_str) == false);
    try testing.expect(borrowed.eql(.{ .string = "no-copy" }));
}

test "MCP.Server - notifications/cancelled aborts the in-flight tool call" {
    const allocator = testing.allocator;
    const app = testing.test_app;

    var out_alloc: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Self.init(allocator, app, &out_alloc.writer);
    defer server.deinit();

    // A pipe stands in for stdin: a feed thread writes the conversation
    // while processRequests runs its concurrent loop on this thread.
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.TestUnexpectedResult;
    const input: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer input.close(lp.io);

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin = input.readerStreaming(lp.io, &stdin_buf);

    const Feed = struct {
        fn run(fd: std.posix.fd_t) void {
            const write_end: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            var buf: [4096]u8 = undefined;
            var writer = write_end.writerStreaming(lp.io, &buf);
            const w = &writer.interface;

            const goto_call =
                \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"goto","arguments":{"url":"about:blank"}}}
            ;
            const wait_call =
                \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"waitForScript","arguments":{"script":"false","timeout":30000}}}
            ;
            const cancel_call =
                \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}
            ;
            const unrelated_cancel =
                \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}
            ;
            const evaluate_call =
                \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"evaluate","arguments":{"script":"1+1"}}}
            ;
            const promise_call =
                \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"evaluate","arguments":{"script":"new Promise(() => {})"}}}
            ;
            const cancel_promise =
                \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":4}}
            ;
            const evaluate_2_call =
                \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"evaluate","arguments":{"script":"2+2"}}}
            ;

            // Load a page, then park in a wait that would run its full
            // 30s timeout unless the cancellation aborts it. Flush per
            // message, like a real client, so the sleeps mean something.
            w.writeAll(goto_call ++ "\n") catch {};
            w.flush() catch {};
            lp.io.sleep(.fromMilliseconds(500), .awake) catch {};
            w.writeAll(wait_call ++ "\n") catch {};
            w.flush() catch {};

            // Abandon the wait (what an MCP client does on timeout) and
            // queue the next call behind it: it must run right away. A
            // second, unrelated cancellation lands before the dispatcher
            // consumes the first — both must be recorded, so the abort
            // isn't lost (a single cancellation slot strands the wait).
            lp.io.sleep(.fromMilliseconds(300), .awake) catch {};
            w.writeAll(cancel_call ++ "\n") catch {};
            w.writeAll(unrelated_cancel ++ "\n") catch {};
            w.writeAll(evaluate_call ++ "\n") catch {};
            w.flush() catch {};

            // A second abandoned call: an evaluate parked on a
            // never-resolving promise surfaces its cancellation in-band (an
            // is_error result reading "promise: cancelled") instead of
            // propagating error.Cancelled. Per the spec it still gets no
            // reply.
            lp.io.sleep(.fromMilliseconds(300), .awake) catch {};
            w.writeAll(promise_call ++ "\n") catch {};
            w.flush() catch {};
            lp.io.sleep(.fromMilliseconds(300), .awake) catch {};
            w.writeAll(cancel_promise ++ "\n") catch {};
            w.writeAll(evaluate_2_call ++ "\n") catch {};
            w.flush() catch {};
            write_end.close(lp.io);
        }
    };

    const feed = try std.Thread.spawn(.{}, Feed.run, .{fds[1]});
    defer feed.join();

    const started = lp.datetime.milliTimestamp(.boot);
    try router.processRequests(server, &stdin.interface, input);
    const elapsed_ms = lp.datetime.milliTimestamp(.boot) - started;

    // The wait call was abandoned after ~800ms; a server that ignores the
    // cancellation holds the session for the wait's full 30s timeout.
    try testing.expect(elapsed_ms < 20000);

    const output = out_alloc.writer.buffered();
    // The cancelled wait got no reply at all: the spec says a cancelled
    // request is not responded to (no -32001 Cancelled error either).
    try testing.expect(std.mem.find(u8, output, "\"id\":2") == null);
    try testing.expect(std.mem.find(u8, output, "-32001") == null);
    // ...and the evaluate queued behind it still ran.
    try testing.expect(std.mem.find(u8, output, "\"text\":\"2\"") != null);

    // The cancelled promise-waiting evaluate got no reply either, even
    // though it reports its cancellation in-band rather than as
    // error.Cancelled — no is_error result, no "promise: cancelled" text.
    try testing.expect(std.mem.find(u8, output, "\"id\":4") == null);
    try testing.expect(std.mem.find(u8, output, "promise: cancelled") == null);
    // ...and the evaluate queued behind it still ran.
    try testing.expect(std.mem.find(u8, output, "\"text\":\"4\"") != null);
}

test "MCP.Server - a tool call cancelled while queued is skipped without a reply" {
    var out_alloc: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Self.init(testing.allocator, testing.test_app, &out_alloc.writer);
    defer server.deinit();

    // The cancellation names the id before the call is dispatched (the
    // call was queued behind a long one when the client gave up): the call
    // must not run, and per the spec it gets no response.
    server.handleCancelledRequest(.{ .integer = 9 });
    try router.handleMessage(server, testing.arena_allocator,
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"evaluate","arguments":{"script":"1+1"}}}
    );
    try testing.expectEqual(@as(usize, 0), out_alloc.writer.buffered().len);

    // An unrelated id is unaffected by a leftover cancellation.
    server.handleCancelledRequest(.{ .string = "stale" });
    try router.handleMessage(server, testing.arena_allocator,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"evaluate","arguments":{"script":"1+1"}}}
    );
    try testing.expect(std.mem.find(u8, out_alloc.writer.buffered(), "\"id\":10") != null);
}
