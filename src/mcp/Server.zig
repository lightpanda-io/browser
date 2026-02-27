const std = @import("std");

const lp = @import("lightpanda");

const App = @import("../App.zig");
const HttpClient = @import("../http/Client.zig");

pub const McpServer = struct {
    allocator: std.mem.Allocator,
    app: *App,

    http_client: *HttpClient,
    notification: *lp.Notification,
    browser: *lp.Browser,
    session: *lp.Session,
    page: *lp.Page,

    io_thread: ?std.Thread = null,
    queue_mutex: std.Thread.Mutex = .{},
    queue_condition: std.Thread.Condition = .{},
    message_queue: std.ArrayListUnmanaged([]const u8) = .empty,

    is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    stdout_mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, app: *App) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.app = app;
        self.message_queue = .empty;

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
        self.stop();
        if (self.io_thread) |*thread| {
            thread.join();
        }
        for (self.message_queue.items) |msg| {
            self.allocator.free(msg);
        }
        self.message_queue.deinit(self.allocator);

        self.browser.deinit();
        self.allocator.destroy(self.browser);
        self.notification.deinit();
        self.http_client.deinit();

        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        self.is_running.store(true, .seq_cst);
        self.io_thread = try std.Thread.spawn(.{}, ioWorker, .{self});
    }

    pub fn stop(self: *Self) void {
        self.is_running.store(false, .seq_cst);
        self.queue_mutex.lock();
        self.queue_condition.signal();
        self.queue_mutex.unlock();
    }

    fn ioWorker(self: *Self) void {
        var stdin_file = std.fs.File.stdin();
        var stdin_buf: [8192]u8 = undefined;
        var stdin = stdin_file.reader(&stdin_buf);

        while (self.is_running.load(.seq_cst)) {
            const msg_or_err = stdin.interface.adaptToOldInterface().readUntilDelimiterAlloc(self.allocator, '\n', 1024 * 1024 * 10);
            if (msg_or_err) |msg| {
                if (msg.len == 0) {
                    self.allocator.free(msg);
                    continue;
                }

                self.queue_mutex.lock();
                self.message_queue.append(self.allocator, msg) catch |err| {
                    lp.log.err(.app, "MCP Queue failed", .{ .err = err });
                    self.allocator.free(msg);
                };
                self.queue_mutex.unlock();
                self.queue_condition.signal();
            } else |err| {
                if (err == error.EndOfStream) {
                    self.stop();
                    break;
                }
                lp.log.err(.app, "MCP IO Error", .{ .err = err });
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
    }

    pub fn getNextMessage(self: *Self) ?[]const u8 {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        while (self.message_queue.items.len == 0 and self.is_running.load(.seq_cst)) {
            self.queue_condition.wait(&self.queue_mutex);
        }

        if (self.message_queue.items.len > 0) {
            return self.message_queue.orderedRemove(0);
        }
        return null;
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
};
