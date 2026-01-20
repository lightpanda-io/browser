const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const log = @import("../log.zig");
const App = @import("../App.zig");
const Notification = @import("../Notification.zig");

const uuidv4 = @import("../id.zig").uuidv4;
const IID_FILE = "iid";

pub fn isDisabled() bool {
    return std.process.hasEnvVarConstant("LIGHTPANDA_DISABLE_TELEMETRY");
}

pub const Telemetry = TelemetryT(blk: {
    if (builtin.mode == .Debug or builtin.is_test) break :blk NoopProvider;
    break :blk @import("lightpanda.zig").LightPanda;
});

fn TelemetryT(comptime P: type) type {
    return struct {
        // an "install" id that we [try to] persist and re-use between runs
        // null on IO error
        iid: ?[36]u8,

        provider: P,

        disabled: bool,

        run_mode: App.RunMode,

        const Self = @This();

        pub fn init(app: *App, run_mode: App.RunMode) !Self {
            const disabled = isDisabled();
            if (builtin.mode != .Debug and builtin.is_test == false) {
                log.info(.telemetry, "telemetry status", .{ .disabled = disabled });
            }

            const provider = try P.init(app);
            errdefer provider.deinit();

            return .{
                .disabled = disabled,
                .run_mode = run_mode,
                .provider = provider,
                .iid = if (disabled) null else getOrCreateId(app.app_dir_path),
            };
        }

        pub fn deinit(self: *Self) void {
            self.provider.deinit();
        }

        pub fn record(self: *Self, event: Event) void {
            if (self.disabled) {
                return;
            }
            const iid: ?[]const u8 = if (self.iid) |*iid| iid else null;
            self.provider.send(iid, self.run_mode, event) catch |err| {
                log.warn(.telemetry, "record error", .{ .err = err, .type = @tagName(std.meta.activeTag(event)) });
            };
        }

        // Called outside of `init` because we need a stable pointer for self.
        // We care page_navigate events, but those happen on a Browser's
        // notification. This doesn't exist yet, and there isn't only going to
        // be 1, browsers come and go.
        // What we can do is register for the `notification_created` event.
        // In the callback for that, `onNotificationCreated`, we can then register
        // for the browser-events that we care about.
        pub fn register(self: *Self, notification: *Notification) !void {
            if (self.disabled) {
                return;
            }
            try notification.register(.notification_created, self, onNotificationCreated);
        }

        fn onNotificationCreated(ctx: *anyopaque, new: *Notification) !void {
            return new.register(.page_navigate, ctx, onPageNavigate);
        }

        fn onPageNavigate(ctx: *anyopaque, data: *const Notification.PageNavigate) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.record(.{ .navigate = .{
                .proxy = false,
                .tls = std.ascii.startsWithIgnoreCase(data.url, "https://"),
            } });
        }
    };
}

fn getOrCreateId(app_dir_path_: ?[]const u8) ?[36]u8 {
    const app_dir_path = app_dir_path_ orelse {
        var id: [36]u8 = undefined;
        uuidv4(&id);
        return id;
    };

    var buf: [37]u8 = undefined;
    var dir = std.fs.openDirAbsolute(app_dir_path, .{}) catch |err| {
        log.warn(.telemetry, "data directory open error", .{ .path = app_dir_path, .err = err });
        return null;
    };
    defer dir.close();

    const data = dir.readFile(IID_FILE, &buf) catch |err| switch (err) {
        error.FileNotFound => &.{},
        else => {
            log.warn(.telemetry, "ID read error", .{ .path = app_dir_path, .err = err });
            return null;
        },
    };

    var id: [36]u8 = undefined;
    if (data.len == 36) {
        @memcpy(id[0..36], data);
        return id;
    }

    uuidv4(&id);
    dir.writeFile(.{ .sub_path = IID_FILE, .data = &id }) catch |err| {
        log.warn(.telemetry, "ID write error", .{ .path = app_dir_path, .err = err });
        return null;
    };
    return id;
}

pub const Event = union(enum) {
    run: void,
    navigate: Navigate,
    flag: []const u8, // used for testing

    const Navigate = struct {
        tls: bool,
        proxy: bool,
        driver: []const u8 = "cdp",
    };
};

const NoopProvider = struct {
    fn init(_: *App) !NoopProvider {
        return .{};
    }
    fn deinit(_: NoopProvider) void {}
    pub fn send(_: NoopProvider, _: ?[]const u8, _: App.RunMode, _: Event) !void {}
};

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;

const testing = @import("../testing.zig");
test "telemetry: disabled by environment" {
    _ = setenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"), @constCast(""), 0);
    defer _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"));

    const FailingProvider = struct {
        fn init(_: *App) !@This() {
            return .{};
        }
        fn deinit(_: @This()) void {}
        pub fn send(_: @This(), _: ?[]const u8, _: App.RunMode, _: Event) !void {
            unreachable;
        }
    };

    var telemetry = try TelemetryT(FailingProvider).init(undefined, .serve);
    defer telemetry.deinit();
    telemetry.record(.{ .run = {} });
}

test "telemetry: getOrCreateId" {
    defer std.fs.cwd().deleteFile("/tmp/" ++ IID_FILE) catch {};

    std.fs.cwd().deleteFile("/tmp/" ++ IID_FILE) catch {};

    const id1 = getOrCreateId("/tmp/").?;
    const id2 = getOrCreateId("/tmp/").?;
    try testing.expectEqual(&id1, &id2);

    std.fs.cwd().deleteFile("/tmp/" ++ IID_FILE) catch {};
    const id3 = getOrCreateId("/tmp/").?;
    try testing.expectEqual(false, std.mem.eql(u8, &id1, &id3));

    const id4 = getOrCreateId(null).?;
    try testing.expectEqual(false, std.mem.eql(u8, &id1, &id4));
    try testing.expectEqual(false, std.mem.eql(u8, &id3, &id4));
}

test "telemetry: sends event to provider" {
    var telemetry = try TelemetryT(MockProvider).init(testing.test_app, .serve);
    defer telemetry.deinit();
    const mock = &telemetry.provider;

    telemetry.record(.{ .flag = "1" });
    telemetry.record(.{ .flag = "2" });
    telemetry.record(.{ .flag = "3" });
    try testing.expectEqual(3, mock.events.items.len);

    for (mock.events.items, 0..) |event, i| {
        try testing.expectEqual(i + 1, std.fmt.parseInt(usize, event.flag, 10));
    }
}

const MockProvider = struct {
    iid: ?[]const u8,
    run_mode: ?App.RunMode,
    allocator: Allocator,
    events: std.ArrayListUnmanaged(Event),

    fn init(app: *App) !@This() {
        return .{
            .iid = null,
            .run_mode = null,
            .events = .{},
            .allocator = app.allocator,
        };
    }
    fn deinit(self: *MockProvider) void {
        self.events.deinit(self.allocator);
    }
    pub fn send(self: *MockProvider, iid: ?[]const u8, run_mode: App.RunMode, events: Event) !void {
        if (self.iid == null) {
            try testing.expectEqual(null, self.run_mode);
            self.iid = iid.?;
            self.run_mode = run_mode;
        } else {
            try testing.expectEqual(self.iid.?, iid.?);
            try testing.expectEqual(self.run_mode.?, run_mode);
        }
        try self.events.append(self.allocator, events);
    }
};
