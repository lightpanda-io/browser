const std = @import("std");
const js = @import("../js/js.zig");

const logger = @import("../../log.zig");

const Console = @This();

pub const init: Console = .{};

pub fn log(_: *const Console, values: []js.Object) void {
    logger.info(.js, "console.log", .{ValueWriter{ .values = values }});
}

pub fn warn(_: *const Console, values: []js.Object) void {
    logger.warn(.js, "console.warn", .{ValueWriter{ .values = values }});
}

pub fn @"error"(_: *const Console, values: []js.Object) void {
    logger.warn(.js, "console.error", .{ValueWriter{ .values = values }});
}

const ValueWriter = struct {
    values: []js.Object,

    pub fn format(self: ValueWriter, writer: *std.io.Writer) !void {
        for (self.values, 1..) |value, i| {
            try writer.print("\n  arg({d}): {f}", .{ i, value });
        }
    }
    pub fn jsonStringify(self: ValueWriter, writer: *std.json.Stringify) !void {
        try writer.beginArray();
        for (self.values) |value| {
            try writer.write(value);
        }
        return writer.endArray();
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Console);

    pub const Meta = struct {
        pub const name = "Console";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const log = bridge.function(Console.log, .{});
    pub const warn = bridge.function(Console.warn, .{});
    pub const @"error" = bridge.function(Console.@"error", .{});
};
