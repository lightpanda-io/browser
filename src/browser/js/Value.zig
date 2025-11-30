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

const Allocator = std.mem.Allocator;

const Value = @This();
js_val: v8.Value,
context: *js.Context,

pub fn isObject(self: Value) bool {
    return self.js_val.isObject();
}

pub fn isString(self: Value) bool {
    return self.js_val.isString();
}

pub fn isArray(self: Value) bool {
    return self.js_val.isArray();
}

pub fn toString(self: Value, allocator: Allocator) ![]const u8 {
    return self.context.valueToString(self.js_val, .{ .allocator = allocator });
}

pub fn toObject(self: Value) js.Object {
    return .{
        .context = self.context,
        .js_obj = self.js_val.castTo(v8.Object),
    };
}

pub fn toArray(self: Value) js.Array {
    return .{
        .context = self.context,
        .js_arr = self.js_val.castTo(v8.Array),
    };
}

// pub const Value = struct {
//     value: v8.Value,
//     context: *const Context,

//     // the caller needs to deinit the string returned
//     pub fn toString(self: Value, allocator: Allocator) ![]const u8 {
//         return self.context.valueToString(self.value, .{ .allocator = allocator });
//     }

//     pub fn fromJson(ctx: *Context, json: []const u8) !Value {
//         const json_string = v8.String.initUtf8(ctx.isolate, json);
//         const value = try v8.Json.parse(ctx.v8_context, json_string);
//         return Value{ .context = ctx, .value = value };
//     }
// };
