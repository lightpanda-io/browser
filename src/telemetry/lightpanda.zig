const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

const Allocator = std.mem.Allocator;

const log = @import("../log.zig");
const App = @import("../App.zig");
const Config = @import("../Config.zig");
const telemetry = @import("telemetry.zig");
const Runtime = @import("../network/Runtime.zig");
const Connection = @import("../network/http.zig").Connection;

// const URL = "https://telemetry.lightpanda.io";
const URL = "http://localhost:9876";
const BUFFER_SIZE = 1024;

const LightPanda = @This();

allocator: Allocator,
runtime: *Runtime,

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
        .allocator = app.allocator,
        .runtime = &app.network,
        .iid = iid,
        .run_mode = run_mode,
    };

    self.runtime.onTick(@ptrCast(self), flushCallback);
}

pub fn deinit(_: *LightPanda) void {}

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
    const h = self.head.load(.monotonic);
    const t = self.tail.load(.acquire);
    const dropped = self.dropped.swap(0, .monotonic);

    if (h == t and dropped == 0) return;
    errdefer _ = self.dropped.fetchAdd(dropped, .monotonic);

    var writer = std.Io.Writer.Allocating.init(self.allocator);
    defer writer.deinit();

    const iid: ?[]const u8 = if (self.iid) |*id| id else null;

    for (h..t) |i| {
        const wrapped = LightPandaEvent{ .iid = iid, .mode = self.run_mode, .event = self.buffer[i % BUFFER_SIZE] };
        try std.json.Stringify.value(&wrapped, .{ .emit_null_optional_fields = false }, &writer.writer);
        try writer.writer.writeByte('\n');
    }

    if (dropped > 0) {
        const wrapped = LightPandaEvent{ .iid = iid, .mode = self.run_mode, .event = .{ .buffer_overflow = .{ .dropped = dropped } } };
        try std.json.Stringify.value(&wrapped, .{ .emit_null_optional_fields = false }, &writer.writer);
        try writer.writer.writeByte('\n');
    }

    const conn = self.runtime.getConnection() orelse {
        _ = self.dropped.fetchAdd(dropped, .monotonic);
        return;
    };
    errdefer self.runtime.releaseConnection(conn);

    try conn.setURL(URL);
    try conn.setMethod(.POST);
    try conn.setBody(writer.written());

    self.head.store(t, .release);
    self.runtime.submitRequest(conn);
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
        try writer.write(build_config.git_version orelse build_config.git_commit);

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
