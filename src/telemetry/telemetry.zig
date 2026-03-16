const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const log = @import("../log.zig");
const App = @import("../App.zig");
const Config = @import("../Config.zig");

const uuidv4 = @import("../id.zig").uuidv4;
const IID_FILE = "iid";

pub fn isDisabled() bool {
    if (builtin.mode == .Debug or builtin.is_test) {
        return true;
    }

    return std.process.hasEnvVarConstant("LIGHTPANDA_DISABLE_TELEMETRY");
}

pub const Telemetry = TelemetryT(@import("lightpanda.zig"));

fn TelemetryT(comptime P: type) type {
    return struct {
        provider: *P,

        disabled: bool,

        const Self = @This();

        pub fn init(app: *App, run_mode: Config.RunMode) !Self {
            const disabled = isDisabled();
            if (builtin.mode != .Debug and builtin.is_test == false) {
                log.info(.telemetry, "telemetry status", .{ .disabled = disabled });
            }

            const iid: ?[36]u8 = if (disabled) null else getOrCreateId(app.app_dir_path);

            const provider = try app.allocator.create(P);
            errdefer app.allocator.destroy(provider);

            try P.init(provider, app, iid, run_mode);

            return .{
                .disabled = disabled,
                .provider = provider,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.provider.deinit();
            allocator.destroy(self.provider);
        }

        pub fn record(self: *Self, event: Event) void {
            if (self.disabled) {
                return;
            }
            self.provider.send(event) catch |err| {
                log.warn(.telemetry, "record error", .{ .err = err, .type = @tagName(std.meta.activeTag(event)) });
            };
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
    buffer_overflow: BufferOverflow,
    flag: []const u8, // used for testing

    const Navigate = struct {
        tls: bool,
        proxy: bool,
        driver: []const u8 = "cdp",
    };

    const BufferOverflow = struct {
        dropped: usize,
    };
};

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;

const testing = @import("../testing.zig");
test "telemetry: always disabled in debug builds" {
    // Must be disabled regardless of environment variable.
    _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"));
    try testing.expectEqual(true, isDisabled());

    _ = setenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"), @constCast(""), 0);
    defer _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"));
    try testing.expectEqual(true, isDisabled());

    const FailingProvider = struct {
        fn init(_: *@This(), _: *App, _: ?[36]u8, _: Config.RunMode) !void {}
        fn deinit(_: *@This()) void {}
        pub fn send(_: *@This(), _: Event) !void {
            unreachable;
        }
    };

    var telemetry = try TelemetryT(FailingProvider).init(testing.test_app, .serve);
    defer telemetry.deinit(testing.test_app.allocator);
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
    defer telemetry.deinit(testing.test_app.allocator);
    telemetry.disabled = false;
    const mock = telemetry.provider;

    telemetry.record(.{ .flag = "1" });
    telemetry.record(.{ .flag = "2" });
    telemetry.record(.{ .flag = "3" });
    try testing.expectEqual(3, mock.events.items.len);

    for (mock.events.items, 0..) |event, i| {
        try testing.expectEqual(i + 1, std.fmt.parseInt(usize, event.flag, 10));
    }
}

const MockProvider = struct {
    allocator: Allocator,
    events: std.ArrayList(Event),

    fn init(self: *MockProvider, app: *App, _: ?[36]u8, _: Config.RunMode) !void {
        self.* = .{
            .events = .{},
            .allocator = app.allocator,
        };
    }
    fn deinit(self: *MockProvider) void {
        self.events.deinit(self.allocator);
    }
    pub fn send(self: *MockProvider, event: Event) !void {
        try self.events.append(self.allocator, event);
    }
};
