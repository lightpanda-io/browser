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

const URL = "https://telemetry.lightpanda.io";
const BATCH_SIZE = 20;
const BUFFER_SIZE = BATCH_SIZE * 2;

const LightPanda = @This();

allocator: Allocator,
runtime: *Runtime,
mutex: std.Thread.Mutex = .{},

pcount: usize = 0,
pending: [BUFFER_SIZE]LightPandaEvent = undefined,

pub fn init(app: *App) !LightPanda {
    return .{
        .allocator = app.allocator,
        .runtime = &app.network,
    };
}

pub fn deinit(self: *LightPanda) void {
    self.flush();
}

pub fn send(self: *LightPanda, iid: ?[]const u8, run_mode: Config.RunMode, raw_event: telemetry.Event) !void {
    const pending_count = blk: {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pcount == BUFFER_SIZE) {
            log.err(.telemetry, "telemetry buffer exhausted", .{});
            return;
        }

        self.pending[self.pcount] = .{
            .iid = iid,
            .mode = run_mode,
            .event = raw_event,
        };
        self.pcount += 1;

        break :blk self.pcount;
    };

    if (pending_count >= BATCH_SIZE) {
        self.flush();
    }
}

pub fn flush(self: *LightPanda) void {
    self.postEvent() catch |err| {
        log.warn(.telemetry, "flush error", .{ .err = err });
    };
}

fn postEvent(self: *LightPanda) !void {
    var writer = std.Io.Writer.Allocating.init(self.allocator);
    defer writer.deinit();

    self.mutex.lock();
    defer self.mutex.unlock();

    const events = self.pending[0..self.pcount];
    if (events.len == 0) return;

    for (events) |*event| {
        try std.json.Stringify.value(event, .{ .emit_null_optional_fields = false }, &writer.writer);
        try writer.writer.writeByte('\n');
    }

    const conn = self.runtime.getConnection() orelse return;
    errdefer self.runtime.releaseConnection(conn);

    try conn.setURL(URL);
    try conn.setMethod(.POST);
    try conn.setBody(writer.written());

    self.pcount = 0;
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
