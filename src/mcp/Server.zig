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
browser: *lp.Browser,
session: *lp.Session,
page: *lp.Page,

is_running: std.atomic.Value(bool) = .init(false),

pub fn init(allocator: std.mem.Allocator, app: *App) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.app = app;

    self.http_client = try app.http.createClient(allocator);
    errdefer self.http_client.deinit();

    self.notification = try .init(allocator);
    errdefer self.notification.deinit();

    self.browser = try allocator.create(lp.Browser);
    errdefer allocator.destroy(self.browser);
    self.browser.* = try .init(app, .{ .http_client = self.http_client });
    errdefer self.browser.deinit();

    self.session = try self.browser.newSession(self.notification);
    self.page = try self.session.createPage();

    return self;
}

pub fn deinit(self: *Self) void {
    self.is_running.store(false, .release);

    self.browser.deinit();
    self.allocator.destroy(self.browser);
    self.notification.deinit();
    self.http_client.deinit();

    self.allocator.destroy(self);
}

pub fn sendResponse(_: *Self, response: anytype) !void {
    var buffer: [8192]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
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
