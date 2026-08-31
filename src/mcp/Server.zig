const std = @import("std");

const lp = @import("lightpanda");

const App = @import("../App.zig");
const testing = @import("../testing.zig");
const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const router = @import("router.zig");
const tools = @import("tools.zig");
const Transport = @import("Transport.zig");

const Self = @This();

/// Session every un-scoped request lands on. Over stdio there is only ever
/// this one; the HTTP transport routes to it when a client sends no
/// `Mcp-Session-Id`.
pub const default_session_id = "default";

allocator: std.mem.Allocator,
app: *App,

sessions: std.StringHashMapUnmanaged(*lp.ToolSession) = .empty,
/// Monotonic counter backing auto-generated session ids (`s1`, `s2`, …).
session_seq: u32 = 0,
/// Whether the transport can route a request to a named session. HTTP does
/// (`Mcp-Session-Id`); over stdio the session tools are refused, since a
/// session created there could never be addressed.
multi_session: bool = false,
/// The session the request currently being handled targets. Safe as a single
/// field because every request is dispatched on one thread, one at a time;
/// the transport sets it (via `useSession`) before each dispatch. Tools and
/// resources read it rather than threading a session through every call.
active_session: *lp.ToolSession = undefined,
transport: Transport,

pub fn init(allocator: std.mem.Allocator, app: *App, writer: *std.Io.Writer) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .app = app,
        .transport = .init(allocator, writer),
    };
    errdefer self.transport.deinit();

    self.active_session = try self.createSession(default_session_id);
    return self;
}

pub fn deinit(self: *Self) void {
    var it = self.sessions.iterator();
    while (it.next()) |kv| self.destroySession(kv.key_ptr.*, kv.value_ptr.*);
    self.sessions.deinit(self.allocator);

    self.transport.deinit();
    self.allocator.destroy(self);
}

/// Create the session named `id`, or return the existing one. The `id` is
/// duped, so the caller keeps ownership of its slice. Sessions are
/// heap-allocated and never moved: `Browser` registers self-pointers.
pub fn createSession(self: *Self, id: []const u8) !*lp.ToolSession {
    if (self.sessions.get(id)) |existing| return existing;

    const owned_id = try self.allocator.dupe(u8, id);
    errdefer self.allocator.free(owned_id);

    const entry = try self.allocator.create(lp.ToolSession);
    errdefer self.allocator.destroy(entry);

    try entry.init(self.app);
    errdefer entry.deinit();

    // Only the default session is backed by the on-disk cookie file; named
    // sessions start clean so agents stay isolated by default.
    if (isDefault(id)) {
        if (self.app.config.cookieFile()) |cookie_path| {
            lp.cookies.loadFromFile(entry.session, cookie_path);
        }
    }

    try self.sessions.put(self.allocator, owned_id, entry);
    entry.exitIsolate();
    return entry;
}

fn isDefault(id: []const u8) bool {
    return std.mem.eql(u8, id, default_session_id);
}

/// Tear down the session named `id`. Returns false if no such session, or if
/// it is the default (which lives for the whole process).
pub fn closeSession(self: *Self, id: []const u8) bool {
    if (isDefault(id)) return false;
    const kv = self.sessions.fetchRemove(id) orelse return false;
    if (self.active_session == kv.value) self.active_session = self.defaultSession();
    self.destroySession(kv.key, kv.value);
    return true;
}

fn destroySession(self: *Self, id: []const u8, entry: *lp.ToolSession) void {
    if (isDefault(id)) {
        if (self.app.config.cookieJarFile()) |cookie_jar_path| {
            lp.cookies.saveToFile(&entry.session.cookie_jar, cookie_jar_path);
        }
    }

    entry.enterIsolate();
    entry.deinit();
    self.allocator.free(id);
    self.allocator.destroy(entry);
}

/// The session an un-scoped (stdio, or header-less HTTP) request targets.
pub fn defaultSession(self: *Self) *lp.ToolSession {
    return self.sessions.get(default_session_id).?;
}

/// Point subsequent tool/resource dispatch at the session named `id`, creating
/// it on first use. A null or empty `id` selects the default.
pub fn useSession(self: *Self, id: ?[]const u8) !*lp.ToolSession {
    const wanted = id orelse "";
    self.active_session = if (wanted.len == 0) self.defaultSession() else try self.createSession(wanted);
    return self.active_session;
}

/// A session id that is not currently in use, formatted into `arena`.
pub fn nextSessionId(self: *Self, arena: std.mem.Allocator) ![]const u8 {
    while (true) {
        self.session_seq += 1;
        const candidate = try std.fmt.allocPrint(arena, "s{d}", .{self.session_seq});
        if (!self.sessions.contains(candidate)) return candidate;
    }
}

/// Pump every live session's pending transfers and return the shortest time
/// the caller may block before pumping again. See `Session.idleSlice`.
pub fn idle(self: *Self) u31 {
    var wait: u31 = std.math.maxInt(u31);
    var it = self.sessions.valueIterator();
    while (it.next()) |entry| {
        // Pumping may resume JS (e.g. a completed script fetch), so it needs
        // the session's isolate current.
        entry.*.enterIsolate();
        wait = @min(wait, entry.*.session.idleSlice());
        entry.*.exitIsolate();
    }
    return wait;
}

pub fn sendError(self: *Self, id: std.json.Value, code: protocol.ErrorCode, message: []const u8) !void {
    return self.transport.sendError(id, code, message);
}

pub fn sendResult(self: *Self, id: std.json.Value, result: anytype) !void {
    return self.transport.sendResult(id, result);
}

pub fn handleInitialize(self: *Self, req: protocol.Request) !void {
    const id = req.id orelse return;
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
    // Dispatch runs page JS, so enter the target isolate around it.
    const entry = self.active_session;
    entry.enterIsolate();
    defer entry.exitIsolate();
    return tools.handleCall(self, arena, req);
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
