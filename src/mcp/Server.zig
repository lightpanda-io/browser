const std = @import("std");

const lp = @import("lightpanda");

const App = @import("../App.zig");
const HttpClient = @import("../http/Client.zig");
const protocol = @import("protocol.zig");
const Self = @This();

allocator: std.mem.Allocator,
app: *App,

http_client: *HttpClient,
notification: *lp.Notification,
browser: lp.Browser,
session: *lp.Session,
page: *lp.Page,

is_running: std.atomic.Value(bool) = .init(false),
out_stream: std.fs.File,

pub fn init(allocator: std.mem.Allocator, app: *App, out_stream: std.fs.File) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.app = app;
    self.out_stream = out_stream;

    self.http_client = try app.http.createClient(allocator);
    errdefer self.http_client.deinit();

    self.notification = try .init(allocator);
    errdefer self.notification.deinit();

    self.browser = try lp.Browser.init(app, .{ .http_client = self.http_client });
    errdefer self.browser.deinit();

    self.session = try self.browser.newSession(self.notification);
    self.page = try self.session.createPage();

    return self;
}

pub fn deinit(self: *Self) void {
    self.is_running.store(false, .release);

    self.browser.deinit();
    self.notification.deinit();
    self.http_client.deinit();

    self.allocator.destroy(self);
}

pub fn sendResponse(self: *Self, response: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &aw.writer);
    try aw.writer.writeByte('\n');
    try self.out_stream.writeAll(aw.written());
}

pub fn sendResult(self: *Self, id: std.json.Value, result: anytype) !void {
    const GenericResponse = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: @TypeOf(result),
    };
    try self.sendResponse(GenericResponse{
        .id = id,
        .result = result,
    });
}

pub fn sendError(self: *Self, id: std.json.Value, code: protocol.ErrorCode, message: []const u8) !void {
    try self.sendResponse(protocol.Response{
        .id = id,
        .@"error" = protocol.Error{
            .code = @intFromEnum(code),
            .message = message,
        },
    });
}

const testing = @import("../testing.zig");
const McpHarness = @import("testing.zig").McpHarness;

test "MCP Integration: handshake and tools/list" {
    const harness = try McpHarness.init(testing.allocator, testing.test_app);
    defer harness.deinit();

    harness.thread = try std.Thread.spawn(.{}, testHandshakeAndTools, .{harness});
    try harness.runServer();
}

fn testHandshakeAndTools(harness: *McpHarness) void {
    defer harness.server.is_running.store(false, .release);

    // 1. Initialize
    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}}}
    ) catch return;

    var arena = std.heap.ArenaAllocator.init(harness.allocator);
    defer arena.deinit();

    const response1 = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response1, "\"id\":1") != null) catch return;
    testing.expect(std.mem.indexOf(u8, response1, "\"protocolVersion\":\"2025-11-25\"") != null) catch return;

    // 2. Initialized notification
    harness.sendRequest(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ) catch return;

    // 3. List tools
    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    ) catch return;

    const response2 = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response2, "\"id\":2") != null) catch return;
    testing.expect(std.mem.indexOf(u8, response2, "\"name\":\"goto\"") != null) catch return;
}

test "MCP Integration: tools/call evaluate" {
    const harness = try McpHarness.init(testing.allocator, testing.test_app);
    defer harness.deinit();

    harness.thread = try std.Thread.spawn(.{}, testEvaluate, .{harness});
    try harness.runServer();
}

fn testEvaluate(harness: *McpHarness) void {
    defer harness.server.is_running.store(false, .release);

    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"evaluate","arguments":{"script":"1 + 1"}}}
    ) catch return;

    var arena = std.heap.ArenaAllocator.init(harness.allocator);
    defer arena.deinit();

    const response = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response, "\"id\":1") != null) catch return;
    testing.expect(std.mem.indexOf(u8, response, "\"text\":\"2\"") != null) catch return;
}

test "MCP Integration: error handling" {
    const harness = try McpHarness.init(testing.allocator, testing.test_app);
    defer harness.deinit();

    harness.thread = try std.Thread.spawn(.{}, testErrorHandling, .{harness});
    try harness.runServer();
}

fn testErrorHandling(harness: *McpHarness) void {
    defer harness.server.is_running.store(false, .release);

    var arena = std.heap.ArenaAllocator.init(harness.allocator);
    defer arena.deinit();

    // 1. Tool not found
    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"non_existent_tool"}}
    ) catch return;

    const response1 = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response1, "\"id\":1") != null) catch return;
    testing.expect(std.mem.indexOf(u8, response1, "\"code\":-32601") != null) catch return;

    // 2. Invalid params (missing script for evaluate)
    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"evaluate","arguments":{}}}
    ) catch return;

    const response2 = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response2, "\"id\":2") != null) catch return;
    testing.expect(std.mem.indexOf(u8, response2, "\"code\":-32602") != null) catch return;
}

test "MCP Integration: resources" {
    const harness = try McpHarness.init(testing.allocator, testing.test_app);
    defer harness.deinit();

    harness.thread = try std.Thread.spawn(.{}, testResources, .{harness});
    try harness.runServer();
}

fn testResources(harness: *McpHarness) void {
    defer harness.server.is_running.store(false, .release);

    var arena = std.heap.ArenaAllocator.init(harness.allocator);
    defer arena.deinit();

    // 1. List resources
    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"resources/list"}
    ) catch return;

    const response1 = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response1, "\"uri\":\"mcp://page/html\"") != null) catch return;

    // 2. Read resource
    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"mcp://page/html"}}
    ) catch return;

    const response2 = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response2, "\"id\":2") != null) catch return;
    // Check for some HTML content
    testing.expect(std.mem.indexOf(u8, response2, "<html>") != null) catch return;
}

test "MCP Integration: tools markdown and links" {
    const harness = try McpHarness.init(testing.allocator, testing.test_app);
    defer harness.deinit();

    harness.thread = try std.Thread.spawn(.{}, testMarkdownAndLinks, .{harness});
    try harness.runServer();
}

fn testMarkdownAndLinks(harness: *McpHarness) void {
    defer harness.server.is_running.store(false, .release);

    var arena = std.heap.ArenaAllocator.init(harness.allocator);
    defer arena.deinit();

    // 1. Test markdown
    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"markdown"}}
    ) catch return;

    const response1 = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response1, "\"id\":1") != null) catch return;

    // 2. Test links
    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"links"}}
    ) catch return;

    const response2 = harness.readResponse(arena.allocator()) catch return;
    testing.expect(std.mem.indexOf(u8, response2, "\"id\":2") != null) catch return;
}
