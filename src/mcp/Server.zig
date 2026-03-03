const std = @import("std");

const lp = @import("lightpanda");

const App = @import("../App.zig");
const HttpClient = @import("../http/Client.zig");
const testing = @import("../testing.zig");
const protocol = @import("protocol.zig");
const router = @import("router.zig");

const Self = @This();

allocator: std.mem.Allocator,
app: *App,

http_client: *HttpClient,
notification: *lp.Notification,
browser: lp.Browser,
session: *lp.Session,
page: *lp.Page,

writer: *std.io.Writer,
mutex: std.Thread.Mutex = .{},
aw: std.io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator, app: *App, writer: *std.io.Writer) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.app = app;
    self.writer = writer;
    self.aw = .init(allocator);

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
    self.aw.deinit();
    self.browser.deinit();
    self.notification.deinit();
    self.http_client.deinit();

    self.allocator.destroy(self);
}

pub fn sendResponse(self: *Self, response: anytype) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.aw.clearRetainingCapacity();
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &self.aw.writer);
    try self.aw.writer.writeByte('\n');
    try self.writer.writeAll(self.aw.writer.buffered());
    try self.writer.flush();
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

    try testing.expectJson(.{ .id = 1 }, out_alloc.writer.buffered());
}
