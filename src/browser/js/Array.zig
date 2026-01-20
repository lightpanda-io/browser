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
const js = @import("js.zig");
const v8 = js.v8;

const Array = @This();

local: *const js.Local,
handle: *const v8.Array,

pub fn len(self: Array) usize {
    return v8.v8__Array__Length(self.handle);
}

pub fn get(self: Array, index: u32) !js.Value {
    const ctx = self.local.ctx;

    const idx = js.Integer.init(ctx.isolate.handle, index);
    const handle = v8.v8__Object__Get(@ptrCast(self.handle), self.local.handle, idx.handle) orelse {
        return error.JsException;
    };

    return .{
        .local = self.local,
        .handle = handle,
    };
}

pub fn set(self: Array, index: u32, value: anytype, comptime opts: js.Caller.CallOpts) !bool {
    const js_value = try self.local.zigValueToJs(value, opts);

    var out: v8.MaybeBool = undefined;
    v8.v8__Object__SetAtIndex(@ptrCast(self.handle), self.local.handle, index, js_value.handle, &out);
    return out.has_value;
}

pub fn toObject(self: Array) js.Object {
    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toValue(self: Array) js.Value {
    return .{
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}
