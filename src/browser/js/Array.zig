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
js_arr: v8.Array,
context: *js.Context,

pub fn len(self: Array) usize {
    return @intCast(self.js_arr.length());
}

pub fn get(self: Array, index: usize) !js.Value {
    const idx_key = v8.Integer.initU32(self.context.isolate, @intCast(index));
    const js_obj = self.js_arr.castTo(v8.Object);
    return .{
        .context = self.context,
        .js_val = try js_obj.getValue(self.context.v8_context, idx_key.toValue()),
    };
}
