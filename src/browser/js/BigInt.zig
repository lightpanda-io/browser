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

const js = @import("js.zig");
const v8 = js.v8;

const BigInt = @This();

handle: *const v8.Integer,

pub fn init(isolate: *v8.Isolate, val: anytype) BigInt {
    const handle = switch (@TypeOf(val)) {
        i8, i16, i32, i64, isize => v8.v8__BigInt__New(isolate, val).?,
        u8, u16, u32, u64, usize => v8.v8__BigInt__NewFromUnsigned(isolate, val).?,
        else => |T| @compileError("cannot create v8::BigInt from: " ++ @typeName(T)),
    };
    return .{ .handle = handle };
}

pub fn getInt64(self: BigInt) i64 {
    return v8.v8__BigInt__Int64Value(self.handle, null);
}

pub fn getUint64(self: BigInt) u64 {
    return v8.v8__BigInt__Uint64Value(self.handle, null);
}

pub fn toValue(self: BigInt) js.Value {
    return .{
        .ctx = undefined, // Will be set by caller if needed
        .handle = @ptrCast(self.handle),
    };
}
