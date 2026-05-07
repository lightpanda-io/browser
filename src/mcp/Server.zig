const std = @import("std");

const lp = @import("lightpanda");

const App = @import("../App.zig");
const testing = @import("../testing.zig");
const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const router = @import("router.zig");
const tools = @import("tools.zig");
const Transport = @import("Transport.zig");
const CDPNode = @import("../cdp/Node.zig");
const Recorder = @import("../agent/Recorder.zig");
const Verifier = @import("../agent/Verifier.zig");

const Self = @This();

allocator: std.mem.Allocator,
app: *App,

notification: *lp.Notification,
browser: lp.Browser,
session: *lp.Session,
node_registry: CDPNode.Registry,
verifier: Verifier,

transport: Transport,

/// Optional PandaScript recorder. Activated by the `record_start` tool;
/// cleared by `record_stop`. State-mutating browser tool calls are
/// serialized into the active recorder via `Command.fromToolCall`.
recorder: ?Recorder = null,
/// Caller-supplied path of the active recording, owned by the server so
/// `record_stop` can return it to the MCP client.
record_path: ?[]const u8 = null,
/// Count of `record_*` calls during the current session, returned by
/// `record_stop` so callers can confirm something was captured.
record_lines: u32 = 0,

pub fn init(allocator: std.mem.Allocator, app: *App, writer: *std.io.Writer) !*Self {
    const notification = try lp.Notification.init(allocator);
    errdefer notification.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .app = app,
        .browser = undefined,
        .transport = .init(allocator, writer),
        .notification = notification,
        .session = undefined,
        .node_registry = CDPNode.Registry.init(allocator),
        .verifier = undefined,
    };

    try self.browser.init(app, .{}, null);
    errdefer self.browser.deinit();

    self.session = try self.browser.newSession(self.notification);
    self.verifier = .{ .session = self.session, .node_registry = &self.node_registry };

    if (app.config.cookieFile()) |cookie_path| {
        lp.cookies.loadFromFile(self.session, cookie_path);
    }

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.app.config.cookieJarFile()) |cookie_jar_path| {
        lp.cookies.saveToFile(&self.session.cookie_jar, cookie_jar_path);
    }

    if (self.recorder) |*r| r.deinit();
    if (self.record_path) |p| self.allocator.free(p);

    self.node_registry.deinit();
    self.transport.deinit();
    self.browser.deinit();
    self.notification.deinit();

    self.allocator.destroy(self);
}

pub fn handleInitialize(self: *Self, req: protocol.Request) !void {
    const id = req.id orelse return;
    try self.transport.sendResult(id, protocol.InitializeResult{
        .protocolVersion = @tagName(protocol.Version.default),
        .capabilities = .{
            .resources = .{},
            .tools = .{},
        },
        .serverInfo = .{ .name = "lightpanda", .version = "0.1.0" },
        .instructions = lp.script.mcp_driver_guidance,
    });
}

pub fn handleToolList(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    return tools.handleList(self, arena, req);
}

pub fn handleToolCall(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    return tools.handleCall(self, arena, req);
}

pub fn handleResourceList(self: *Self, req: protocol.Request) !void {
    return resources.handleList(self, req);
}

pub fn handleResourceRead(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    return resources.handleRead(self, arena, req);
}

test "MCP.Server - Integration: synchronous smoke test" {
    defer testing.reset();
    const allocator = testing.allocator;
    const app = testing.test_app;

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}}}
    ;

    var in_reader: std.io.Reader = .fixed(input);
    var out_alloc: std.io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Self.init(allocator, app, &out_alloc.writer);
    defer server.deinit();

    try router.processRequests(server, &in_reader);

    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 1, .result = .{ .protocolVersion = "2024-11-05" } }, out_alloc.writer.buffered());
}

test "MCP.Server - Integration: ping request returns an empty result" {
    defer testing.reset();
    const allocator = testing.allocator;
    const app = testing.test_app;

    const input =
        \\{"jsonrpc":"2.0","id":"ping-1","method":"ping"}
    ;

    var in_reader: std.io.Reader = .fixed(input);
    var out_alloc: std.io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Self.init(allocator, app, &out_alloc.writer);
    defer server.deinit();

    try router.processRequests(server, &in_reader);

    try testing.expectJson(.{ .jsonrpc = "2.0", .id = "ping-1", .result = .{} }, out_alloc.writer.buffered());
}
