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

const lp = @import("lightpanda");
const js = @import("../js/js.zig");

const SubtleCrypto = @import("SubtleCrypto.zig");
const QuotaExceededError = @import("QuotaExceededError.zig");

const Crypto = @This();
_subtle: SubtleCrypto = .{},

pub const init: Crypto = .{};

// We take a js.Value, because we want to return the same instance, not a new
// TypedArray
fn getRandomValues(_: *const Crypto, js_obj: js.Object, exec: *const js.Execution) !js.Object {
    const value = js_obj.toValue();
    // An ArrayBufferView, not [AllowShared]: a view onto a SharedArrayBuffer
    // is a TypeError too. (AllowSharedBufferSource below would also take an
    // ArrayBuffer, or a shared buffer.)
    if (value.isArrayBufferView() == false or value.isBufferSource() == false) {
        return error.InvalidArgument;
    }
    if (value.isFloat16Array() or value.isFloat32Array() or value.isFloat64Array() or value.isTypedArray() == false) {
        // only integer TypedArrays are supported
        return error.TypeMismatch;
    }

    const buf = (try js_obj.toZig(js.AllowSharedBufferSource)).bytes();
    if (buf.len > 65_536) {
        return QuotaExceededError.throw(js_obj.local, exec);
    }
    lp.io.random(buf);
    return js_obj;
}

fn randomUUID(_: *const Crypto) ![36]u8 {
    var hex: [36]u8 = undefined;
    @import("../../id.zig").uuidv4(&hex);
    return hex;
}

fn getSubtle(self: *Crypto) *SubtleCrypto {
    return &self._subtle;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Crypto);

    pub const Meta = struct {
        pub const name = "Crypto";
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const getRandomValues = bridge.function(Crypto.getRandomValues, .{});
    pub const randomUUID = bridge.function(Crypto.randomUUID, .{});
    pub const subtle = bridge.accessor(Crypto.getSubtle, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Crypto" {
    // pbkdf2 limit tests
    testing.expectLog(&.{ .js, .js });
    try testing.htmlRunner("crypto.html", .{});
}
