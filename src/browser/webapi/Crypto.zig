// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");

const SubtleCrypto = @import("SubtleCrypto.zig");

const Crypto = @This();
_subtle: SubtleCrypto = .{},

pub const init: Crypto = .{};

// We take a js.Value, because we want to return the same instance, not a new
// TypedArray
pub fn getRandomValues(_: *const Crypto, js_obj: js.Object) !js.Object {
    var into = try js_obj.toZig(RandomValues);
    const buf = into.asBuffer();
    if (buf.len > 65_536) {
        return error.QuotaExceededError;
    }
    std.crypto.random.bytes(buf);
    return js_obj;
}

pub fn randomUUID(_: *const Crypto) ![36]u8 {
    var hex: [36]u8 = undefined;
    @import("../../id.zig").uuidv4(&hex);
    return hex;
}

pub fn getSubtle(self: *Crypto) *SubtleCrypto {
    return &self._subtle;
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
        pub const empty_with_no_proto = true;
    };

    pub const getRandomValues = bridge.function(Crypto.getRandomValues, .{});
    pub const randomUUID = bridge.function(Crypto.randomUUID, .{});
    pub const subtle = bridge.accessor(Crypto.getSubtle, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Crypto" {
    try testing.htmlRunner("crypto.html", .{});
}
