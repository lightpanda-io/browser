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

test "MCP Integration: smoke test" {
    const harness = try McpHarness.init(testing.allocator, testing.test_app);
    defer harness.deinit();

    harness.thread = try std.Thread.spawn(.{}, testIntegrationSmokeInternal, .{harness});
    try harness.runServer();
}

fn testIntegrationSmokeInternal(harness: *McpHarness) void {
    const aa = harness.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const allocator = arena.allocator();

    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}}}
    ) catch |err| {
        harness.test_error = err;
        return;
    };

    const response1 = harness.readResponse(allocator) catch |err| {
        harness.test_error = err;
        return;
    };
    testing.expect(std.mem.indexOf(u8, response1, "\"id\":1") != null) catch |err| {
        harness.test_error = err;
        return;
    };
    testing.expect(std.mem.indexOf(u8, response1, "\"tools\":{}") != null) catch |err| {
        harness.test_error = err;
        return;
    };
    testing.expect(std.mem.indexOf(u8, response1, "\"resources\":{}") != null) catch |err| {
        harness.test_error = err;
        return;
    };

    harness.sendRequest(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    ) catch |err| {
        harness.test_error = err;
        return;
    };

    const response2 = harness.readResponse(allocator) catch |err| {
        harness.test_error = err;
        return;
    };
    testing.expect(std.mem.indexOf(u8, response2, "\"id\":2") != null) catch |err| {
        harness.test_error = err;
        return;
    };
    testing.expect(std.mem.indexOf(u8, response2, "\"name\":\"goto\"") != null) catch |err| {
        harness.test_error = err;
        return;
    };

    harness.server.is_running.store(false, .release);
    _ = harness.client_out.writeAll("\n") catch {};
}
