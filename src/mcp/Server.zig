const std = @import("std");

const lp = @import("lightpanda");

const App = @import("../App.zig");
const HttpClient = @import("../http/Client.zig");
const Self = @This();

allocator: std.mem.Allocator,
app: *App,

http_client: *HttpClient,
notification: *lp.Notification,
browser: *lp.Browser,
session: *lp.Session,
page: *lp.Page,

is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

stdout_mutex: std.Thread.Mutex = .{},

pub fn init(allocator: std.mem.Allocator, app: *App) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.app = app;

    self.http_client = try app.http.createClient(allocator);
    errdefer self.http_client.deinit();

    self.notification = try lp.Notification.init(allocator);
    errdefer self.notification.deinit();

    self.browser = try allocator.create(lp.Browser);
    errdefer allocator.destroy(self.browser);
    self.browser.* = try lp.Browser.init(app, .{ .http_client = self.http_client });
    errdefer self.browser.deinit();

    self.session = try self.browser.newSession(self.notification);
    self.page = try self.session.createPage();

    return self;
}

pub fn deinit(self: *Self) void {
    self.is_running.store(false, .seq_cst);

    self.browser.deinit();
    self.allocator.destroy(self.browser);
    self.notification.deinit();
    self.http_client.deinit();

    self.allocator.destroy(self);
}

pub fn sendResponse(self: *Self, response: anytype) !void {
    self.stdout_mutex.lock();
    defer self.stdout_mutex.unlock();

    var stdout_file = std.fs.File.stdout();
    var stdout_buf: [8192]u8 = undefined;
    var stdout = stdout_file.writer(&stdout_buf);
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}
