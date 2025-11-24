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
const js = @import("../../js/js.zig");

const TextEncoder = @This();
_pad: bool = false,

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
