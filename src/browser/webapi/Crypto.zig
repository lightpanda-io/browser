const std = @import("std");
const js = @import("../js/js.zig");

const Crypto = @This();

// We take a js.Vale, because we want to return the same instance, not a new
// TypedArray
pub fn getRandomValues(js_obj: js.Object) !js.Object {
    var into = try js_obj.toZig(RandomValues);
    const buf = into.asBuffer();
    if (buf.len > 65_536) {
        return error.QuotaExceededError;
    }
    std.crypto.random.bytes(buf);
    return js_obj;
}

pub fn randomUUID() ![36]u8 {
    var hex: [36]u8 = undefined;
    @import("../../id.zig").uuidv4(&hex);
    return hex;
}

const RandomValues = union(enum) {
    int8: []i8,
    uint8: []u8,
    int16: []i16,
    uint16: []u16,
    int32: []i32,
    uint32: []u32,
    int64: []i64,
    uint64: []u64,

    fn asBuffer(self: RandomValues) []u8 {
        return switch (self) {
            .int8 => |b| (@as([]u8, @ptrCast(b)))[0..b.len],
            .uint8 => |b| (@as([]u8, @ptrCast(b)))[0..b.len],
            .int16 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 2],
            .uint16 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 2],
            .int32 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 4],
            .uint32 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 4],
            .int64 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 8],
            .uint64 => |b| (@as([]u8, @ptrCast(b)))[0 .. b.len * 8],
        };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Crypto);

    pub const Meta = struct {
        pub const name = "Crypto";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getRandomValues = bridge.function(Crypto.getRandomValues, .{ .static = true });
    pub const randomUUID = bridge.function(Crypto.randomUUID, .{ .static = true });
};

const testing = @import("../../testing.zig");
test "WebApi: Crypto" {
    try testing.htmlRunner("crypto.html", .{});
}
