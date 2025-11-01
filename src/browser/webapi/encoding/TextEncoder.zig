const std = @import("std");
const js = @import("../../js/js.zig");

const TextEncoder = @This();

pub fn init() TextEncoder {
    return .{};
}

pub fn getEncoding(_: *const TextEncoder) []const u8 {
    return "utf-8";
}

pub fn encode(_: *const TextEncoder, v: []const u8) !js.TypedArray(u8) {
    if (!std.unicode.utf8ValidateSlice(v)) {
        return error.InvalidUtf8;
    }

    return .{ .values = v };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextEncoder);

    pub const Meta = struct {
        pub const name = "TextEncoder";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(TextEncoder.init, .{});
    pub const encode = bridge.function(TextEncoder.encode, .{ .as_typed_array = true });
    pub const encoding = bridge.accessor(TextEncoder.getEncoding, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextEncoder" {
    try testing.htmlRunner("encoding/text_encoder.html", .{});
}
