// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const q = js.q;

const Array = @This();

local: *const js.Local,
handle: q.JSValue,

pub fn len(self: Array) usize {
    var out: i64 = 0;
    if (q.JS_GetLength(self.local.ctx.ctx, self.handle, &out) != 0) {
        return 0;
    }
    return @intCast(out);
}

pub fn get(self: Array, index: u32) !js.Value {
    const value = q.JS_GetPropertyUint32(self.local.ctx.ctx, self.handle, index);
    if (q.JS_IsException(value)) {
        return error.JsException;
    }
    self.local.track(value);
    return .{ .local = self.local, .handle = value };
}

pub fn set(self: Array, index: u32, value: anytype, comptime opts: js.Caller.CallOpts) !bool {
    const ctx = self.local.ctx.ctx;
    const js_value = try self.local.zigValueToJs(value, opts);
    // JS_SetPropertyUint32 consumes a reference
    const ret = q.JS_SetPropertyUint32(ctx, self.handle, index, q.JS_DupValue(ctx, js_value.handle));
    if (ret < 0) {
        return error.JsException;
    }
    return ret == 1;
}

pub fn toObject(self: Array) js.Object {
    return .{
        .local = self.local,
        .handle = self.handle,
    };
}

pub fn toValue(self: Array) js.Value {
    return .{
        .local = self.local,
        .handle = self.handle,
    };
}
