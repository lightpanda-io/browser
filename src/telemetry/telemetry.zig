const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const uuidv4 = @import("../id.zig").uuidv4;

const log = std.log.scoped(.telemetry);

const BATCH_SIZE = 5;
const BATCH_END = BATCH_SIZE - 1;
const ID_FILE = "lightpanda.id";

pub const Telemetry = TelemetryT(blk: {
    if (builtin.mode == .Debug or builtin.is_test) break :blk NoopProvider;
    break :blk @import("ligtpanda.zig").Lightpanda;
});

fn TelemetryT(comptime P: type) type {
    return struct {
        // an "install" id that we [try to] persist and re-use between runs
        // null on IO error
        iid: ?[36]u8,

        // a "execution" id is an id that represents this specific run
        eid: [36]u8,
        provider: P,

        // batch of events, pending[0..count] are pending
        pending: [BATCH_SIZE]Event,
        count: usize,
        disabled: bool,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            const disabled = std.process.hasEnvVarConstant("LIGHTPANDA_DISABLE_TELEMETRY");

            var eid: [36]u8 = undefined;
            uuidv4(&eid)

            return .{
                .eid = eid,
                .iid = if (disabled) null else getOrCreateId(),
                .disabled = disabled,
                .provider = try P.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.provider.deinit();
        }

        pub fn record(self: *Self, event: Event) void {
            if (self.disabled) {
                return;
            }

            const count = self.count;
            self.pending[count] = event;
            if (count < BATCH_END) {
                self.count = count + 1;
                return;
            }

            const iid = if (self.iid) |*iid| *iid else null;
            self.provider.send(iid, &self.eid, &self.pending) catch |err| {
                log.warn("failed to record event: {}", .{err});
            };
            self.count = 0;
        }
    };
}

fn getOrCreateId() ?[36]u8 {
    var buf: [37]u8 = undefined;
    const data = std.fs.cwd().readFile(ID_FILE, &buf) catch |err| switch (err) blk: {
        error.FileNotFound => break :bkl &.{},
        else => {
            log.warn("failed to open id file: {}", .{err});
            return null,
        },
    }

    var id: [36]u8 = undefined;
    if (data.len == 36) {
        @memcpy(id[0..36], data)
        return id;
    }

    uuidv4(&id);
    std.fs.cwd().writeFile(.{.sub_path = ID_FILE, .data = buf[0..36]}) catch |err| {
        log.warn("failed to write to id file: {}", .{err});
        return null;
    };
    return id;
}

pub const Event = union(enum) {
    run: Run,

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
    fn init(_: Allocator) !NoopProvider {
        return .{};
    }
    fn deinit(_: NoopProvider) void {}
    pub fn record(_: NoopProvider, _: Event) !void {}
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
        pub fn record(_: @This(), _: Event) !void {
            unreachable;
        }
    };

    var telemetry = TelemetryT(FailingProvider).init(testing.allocator);
    defer telemetry.deinit();
    telemetry.record(.{ .run = .{ .mode = .serve, .version = "123" } });
}
