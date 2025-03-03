const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const Loop = @import("jsruntime").Loop;
const uuidv4 = @import("../id.zig").uuidv4;

const log = std.log.scoped(.telemetry);
const ID_FILE = "lightpanda.id";

pub const Telemetry = TelemetryT(blk: {
    if (builtin.mode == .Debug or builtin.is_test) break :blk NoopProvider;
    break :blk @import("lightpanda.zig").LightPanda;
});

fn TelemetryT(comptime P: type) type {
    return struct {
        // an "install" id that we [try to] persist and re-use between runs
        // null on IO error
        iid: ?[36]u8,

        // a "execution" id is an id that represents this specific run
        eid: [36]u8,
        provider: P,

        disabled: bool,

        const Self = @This();

        pub fn init(allocator: Allocator, loop: *Loop) Self {
            const disabled = std.process.hasEnvVarConstant("LIGHTPANDA_DISABLE_TELEMETRY");

            var eid: [36]u8 = undefined;
            uuidv4(&eid);

            return .{
                .iid = if (disabled) null else getOrCreateId(),
                .eid = eid,
                .disabled = disabled,
                .provider = try P.init(allocator, loop),
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
            self.provider.send(iid, &self.eid, &event) catch |err| {
                log.warn("failed to record event: {}", .{err});
            };
        }
    };
}

fn getOrCreateId() ?[36]u8 {
    var buf: [37]u8 = undefined;
    const data = std.fs.cwd().readFile(ID_FILE, &buf) catch |err| switch (err) {
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
    std.fs.cwd().writeFile(.{ .sub_path = ID_FILE, .data = &id }) catch |err| {
        log.warn("failed to write to id file: {}", .{err});
        return null;
    };
    return id;
}

pub const Event = union(enum) {
    run: Run,
    navigate: void,
    flag: []const u8, // used for testing

    const Run = struct {
        version: []const u8,
        mode: RunMode,

        const RunMode = enum {
            fetch,
            serve,
        };
    };
};

const NoopProvider = struct {
    fn init(_: Allocator, _: *Loop) !NoopProvider {
        return .{};
    }
    fn deinit(_: NoopProvider) void {}
    pub fn send(_: NoopProvider, _: ?[]const u8, _: []const u8, _: anytype) !void {}
};

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;
const testing = std.testing;
test "telemetry: disabled by environment" {
    _ = setenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"), @constCast(""), 0);
    defer _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"));

    const FailingProvider = struct {
        fn init(_: Allocator, _: *Loop) !@This() {
            return .{};
        }
        fn deinit(_: @This()) void {}
        pub fn send(_: @This(), _: ?[]const u8, _: []const u8, _: anytype) !void {
            unreachable;
        }
    };

    var telemetry = TelemetryT(FailingProvider).init(testing.allocator, undefined);
    defer telemetry.deinit();
    telemetry.record(.{ .run = .{ .mode = .serve, .version = "123" } });
}

test "telemetry: getOrCreateId" {
    defer std.fs.cwd().deleteFile(ID_FILE) catch {};

    std.fs.cwd().deleteFile(ID_FILE) catch {};

    const id1 = getOrCreateId().?;
    const id2 = getOrCreateId().?;
    try testing.expectEqualStrings(&id1, &id2);

    std.fs.cwd().deleteFile(ID_FILE) catch {};
    const id3 = getOrCreateId().?;
    try testing.expectEqual(false, std.mem.eql(u8, &id1, &id3));
}

test "telemetry: sends event to provider" {
    defer std.fs.cwd().deleteFile(ID_FILE) catch {};
    std.fs.cwd().deleteFile(ID_FILE) catch {};

    var telemetry = TelemetryT(MockProvider).init(testing.allocator, undefined);
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
    eid: ?[]const u8,
    allocator: Allocator,
    events: std.ArrayListUnmanaged(Event),

    fn init(allocator: Allocator, _: *Loop) !@This() {
        return .{
            .iid = null,
            .eid = null,
            .events = .{},
            .allocator = allocator,
        };
    }
    fn deinit(self: *MockProvider) void {
        self.events.deinit(self.allocator);
    }
    pub fn send(self: *MockProvider, iid: ?[]const u8, eid: []const u8, events: *const Event) !void {
        if (self.iid == null) {
            try testing.expectEqual(null, self.eid);
            self.iid = iid.?;
            self.eid = eid;
        } else {
            try testing.expectEqualStrings(self.iid.?, iid.?);
            try testing.expectEqualStrings(self.eid.?, eid);
        }
        try self.events.append(self.allocator, events.*);
    }
};
