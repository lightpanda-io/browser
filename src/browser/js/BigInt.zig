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

handle: *const v8.c.Integer,

pub fn initI64(isolate_handle: *v8.c.Isolate, val: i64) BigInt {
    return .{
        .handle = v8.c.v8__BigInt__New(isolate_handle, val).?,
    };
}

pub fn initU64(isolate_handle: *v8.c.Isolate, val: u64) BigInt {
    return .{
        .handle = v8.c.v8__BigInt__NewFromUnsigned(isolate_handle, val).?,
    };
}

pub fn getUint64(self: BigInt) u64 {
    return v8.c.v8__BigInt__Uint64Value(self.handle, null);
}

pub fn getInt64(self: BigInt) i64 {
    return v8.c.v8__BigInt__Int64Value(self.handle, null);
}

pub fn toValue(self: BigInt) js.Value {
    return .{
        .ctx = undefined, // Will be set by caller if needed
        .handle = @ptrCast(self.handle),
    };
}
