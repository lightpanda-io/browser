const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const Loop = @import("jsruntime").Loop;
const uuidv4 = @import("../id.zig").uuidv4;
const RunMode = @import("../app.zig").RunMode;

const log = std.log.scoped(.telemetry);
const IID_FILE = "iid";

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

        run_mode: RunMode,

        const Self = @This();

        pub fn init(allocator: Allocator, run_mode: RunMode, app_dir_path: ?[]const u8) Self {
            const disabled = std.process.hasEnvVarConstant("LIGHTPANDA_DISABLE_TELEMETRY");
            if (builtin.mode != .Debug and builtin.is_test == false) {
                log.info("telemetry {s}", .{if (disabled) "disabled" else "enabled"});
            }

            return .{
                .disabled = disabled,
                .run_mode = run_mode,
                .provider = try P.init(allocator),
                .iid = if (disabled) null else getOrCreateId(app_dir_path),
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
                log.warn("failed to record event: {}", .{err});
            };
        }
    };
}

fn getOrCreateId(app_dir_path_: ?[]const u8) ?[36]u8 {
    const app_dir_path = app_dir_path_ orelse return null;

    var buf: [37]u8 = undefined;
    var dir = std.fs.openDirAbsolute(app_dir_path, .{}) catch |err| {
        log.warn("failed to open data directory '{s}': {}", .{ app_dir_path, err });
        return null;
    };
    defer dir.close();

    const data = dir.readFile(IID_FILE, &buf) catch |err| switch (err) {
        error.FileNotFound => &.{},
        else => {
            log.warn("failed to open id file: {}", .{err});
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
        log.warn("failed to write to id file: {}", .{err});
        return null;
    };
    return id;
}

pub const Event = union(enum) {
    run: void,
    navigate: void,
    flag: []const u8, // used for testing
};

const NoopProvider = struct {
    fn init(_: Allocator) !NoopProvider {
        return .{};
    }
    fn deinit(_: NoopProvider) void {}
    pub fn send(_: NoopProvider, _: ?[]const u8, _: RunMode, _: Event) !void {}
};

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;

const testing = std.testing;
test "telemetry: disabled by environment" {
    _ = setenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"), @constCast(""), 0);
    defer _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"));

    const FailingProvider = struct {
        fn init(_: Allocator) !@This() {
            return .{};
        }
        fn deinit(_: @This()) void {}
        pub fn send(_: @This(), _: ?[]const u8, _: RunMode, _: Event) !void {
            unreachable;
        }
    };

    var telemetry = TelemetryT(FailingProvider).init(testing.allocator, .serve, null);
    defer telemetry.deinit();
    telemetry.record(.{ .run = {} });
}

test "telemetry: getOrCreateId" {
    defer std.fs.cwd().deleteFile("/tmp/" ++ IID_FILE) catch {};

    std.fs.cwd().deleteFile("/tmp/" ++ IID_FILE) catch {};

    const id1 = getOrCreateId("/tmp/").?;
    const id2 = getOrCreateId("/tmp/").?;
    try testing.expectEqualStrings(&id1, &id2);

    std.fs.cwd().deleteFile("/tmp/" ++ IID_FILE) catch {};
    const id3 = getOrCreateId("/tmp/").?;
    try testing.expectEqual(false, std.mem.eql(u8, &id1, &id3));
}

test "telemetry: sends event to provider" {
    var telemetry = TelemetryT(MockProvider).init(testing.allocator, .serve, "/tmp/");
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
    run_mode: ?RunMode,
    allocator: Allocator,
    events: std.ArrayListUnmanaged(Event),

    fn init(allocator: Allocator) !@This() {
        return .{
            .iid = null,
            .run_mode = null,
            .events = .{},
            .allocator = allocator,
        };
    }
    fn deinit(self: *MockProvider) void {
        self.events.deinit(self.allocator);
    }
    pub fn send(self: *MockProvider, iid: ?[]const u8, run_mode: RunMode, events: Event) !void {
        if (self.iid == null) {
            try testing.expectEqual(null, self.run_mode);
            self.iid = iid.?;
            self.run_mode = run_mode;
        } else {
            try testing.expectEqualStrings(self.iid.?, iid.?);
            try testing.expectEqual(self.run_mode.?, run_mode);
        }
        try self.events.append(self.allocator, events);
    }
};
