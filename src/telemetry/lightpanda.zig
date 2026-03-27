const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

const Allocator = std.mem.Allocator;

const log = @import("../log.zig");
const App = @import("../App.zig");
const Config = @import("../Config.zig");
const telemetry = @import("telemetry.zig");
const Runtime = @import("../network/Runtime.zig");

const URL = "https://telemetry.lightpanda.io";
const BUFFER_SIZE = 1024;
const MAX_BODY_SIZE = 500 * 1024; // 500KB server limit

const LightPanda = @This();

allocator: Allocator,
runtime: *Runtime,
writer: std.Io.Writer.Allocating,

/// Protects concurrent producers in send().
mutex: std.Thread.Mutex = .{},

iid: ?[36]u8 = null,
run_mode: Config.RunMode = .serve,

head: std.atomic.Value(usize) = .init(0),
tail: std.atomic.Value(usize) = .init(0),
dropped: std.atomic.Value(usize) = .init(0),
buffer: [BUFFER_SIZE]telemetry.Event = undefined,

pub fn init(self: *LightPanda, app: *App, iid: ?[36]u8, run_mode: Config.RunMode) !void {
    self.* = .{
        .iid = iid,
        .run_mode = run_mode,
        .allocator = app.allocator,
        .runtime = &app.network,
        .writer = std.Io.Writer.Allocating.init(app.allocator),
    };

    self.runtime.onTick(@ptrCast(self), flushCallback);
}

pub fn deinit(self: *LightPanda) void {
    self.writer.deinit();
}

pub fn send(self: *LightPanda, raw_event: telemetry.Event) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const t = self.tail.load(.monotonic);
    const h = self.head.load(.acquire);
    if (t - h >= BUFFER_SIZE) {
        _ = self.dropped.fetchAdd(1, .monotonic);
        return;
    }

    self.buffer[t % BUFFER_SIZE] = raw_event;
    self.tail.store(t + 1, .release);
}

fn flushCallback(ctx: *anyopaque) void {
    const self: *LightPanda = @ptrCast(@alignCast(ctx));
    self.postEvent() catch |err| {
        log.warn(.telemetry, "flush error", .{ .err = err });
    };
}

fn postEvent(self: *LightPanda) !void {
    const conn = self.runtime.getConnection() orelse {
        return;
    };
    errdefer self.runtime.releaseConnection(conn);

    const h = self.head.load(.monotonic);
    const t = self.tail.load(.acquire);
    const dropped = self.dropped.swap(0, .monotonic);

    if (h == t and dropped == 0) {
        self.runtime.releaseConnection(conn);
        return;
    }
    errdefer _ = self.dropped.fetchAdd(dropped, .monotonic);

    self.writer.clearRetainingCapacity();

    if (dropped > 0) {
        _ = try self.writeEvent(.{ .buffer_overflow = .{ .dropped = dropped } });
    }

    var sent: usize = 0;
    for (h..t) |i| {
        const fit = try self.writeEvent(self.buffer[i % BUFFER_SIZE]);
        if (!fit) break;

        sent += 1;
    }

    try conn.setURL(URL);
    try conn.setMethod(.POST);
    try conn.setBody(self.writer.written());

    self.head.store(h + sent, .release);
    self.runtime.submitRequest(conn);
}

fn writeEvent(self: *LightPanda, event: telemetry.Event) !bool {
    const iid: ?[]const u8 = if (self.iid) |*id| id else null;
    const wrapped = LightPandaEvent{ .iid = iid, .mode = self.run_mode, .event = event };

    const checkpoint = self.writer.written().len;

    try std.json.Stringify.value(&wrapped, .{ .emit_null_optional_fields = false }, &self.writer.writer);
    try self.writer.writer.writeByte('\n');

    if (self.writer.written().len > MAX_BODY_SIZE) {
        self.writer.shrinkRetainingCapacity(checkpoint);
        return false;
    }
    return true;
}

const LightPandaEvent = struct {
    iid: ?[]const u8,
    mode: Config.RunMode,
    event: telemetry.Event,

    pub fn jsonStringify(self: *const LightPandaEvent, writer: anytype) !void {
        try writer.beginObject();

        try writer.objectField("iid");
        try writer.write(self.iid);

        try writer.objectField("mode");
        try writer.write(self.mode);

        try writer.objectField("os");
        try writer.write(builtin.os.tag);

        try writer.objectField("arch");
        try writer.write(builtin.cpu.arch);

        try writer.objectField("version");
        try writer.write(build_config.version);

        try writer.objectField("event");
        try writer.write(@tagName(std.meta.activeTag(self.event)));

        inline for (@typeInfo(telemetry.Event).@"union".fields) |union_field| {
            if (self.event == @field(telemetry.Event, union_field.name)) {
                const inner = @field(self.event, union_field.name);
                const TI = @typeInfo(@TypeOf(inner));
                if (TI == .@"struct") {
                    inline for (TI.@"struct".fields) |field| {
                        try writer.objectField(field.name);
                        try writer.write(@field(inner, field.name));
                    }
                }
            }
        }

        try writer.endObject();
    }
};
