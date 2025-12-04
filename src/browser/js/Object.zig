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

const Caller = @import("Caller.zig");
const Context = @import("Context.zig");
const PersistentObject = v8.Persistent(v8.Object);

const Allocator = std.mem.Allocator;

const Object = @This();
js_obj: v8.Object,
context: *js.Context,

pub const SetOpts = packed struct(u32) {
    READ_ONLY: bool = false,
    DONT_ENUM: bool = false,
    DONT_DELETE: bool = false,
    _: u29 = 0,
};
pub fn setIndex(self: Object, index: u32, value: anytype, opts: SetOpts) !void {
    @setEvalBranchQuota(10000);
    const key = switch (index) {
        inline 0...20 => |i| std.fmt.comptimePrint("{d}", .{i}),
        else => try std.fmt.allocPrint(self.context.arena, "{d}", .{index}),
    };
    return self.set(key, value, opts);
}

pub fn set(self: Object, key: []const u8, value: anytype, opts: SetOpts) error{ FailedToSet, OutOfMemory }!void {
    const context = self.context;

    const js_key = v8.String.initUtf8(context.isolate, key);
    const js_value = try context.zigValueToJs(value);

    const res = self.js_obj.defineOwnProperty(context.v8_context, js_key.toName(), js_value, @bitCast(opts)) orelse false;
    if (!res) {
        return error.FailedToSet;
    }
}

pub fn get(self: Object, key: []const u8) !js.Value {
    const context = self.context;
    const js_key = v8.String.initUtf8(context.isolate, key);
    const js_val = try self.js_obj.getValue(context.v8_context, js_key);
    return context.createValue(js_val);
}

pub fn isTruthy(self: Object) bool {
    const js_value = self.js_obj.toValue();
    return js_value.toBool(self.context.isolate);
}

pub fn toString(self: Object) ![]const u8 {
    const js_value = self.js_obj.toValue();
    return self.context.valueToString(js_value, .{});
}

pub fn toDetailString(self: Object) ![]const u8 {
    const js_value = self.js_obj.toValue();
    return self.context.valueToDetailString(js_value);
}

pub fn format(self: Object, writer: *std.Io.Writer) !void {
    const str = self.toString() catch return error.WriteFailed;
    return writer.writeAll(str);
}

pub fn toJson(self: Object, allocator: Allocator) ![]u8 {
    const json_string = try v8.Json.stringify(self.context.v8_context, self.js_obj.toValue(), null);
    const str = try self.context.jsStringToZig(json_string, .{ .allocator = allocator });
    return str;
}

pub fn persist(self: Object) !Object {
    var context = self.context;
    const js_obj = self.js_obj;

    const persisted = PersistentObject.init(context.isolate, js_obj);
    try context.js_object_list.append(context.arena, persisted);

    return .{
        .context = context,
        .js_obj = persisted.castToObject(),
    };
}

pub fn getFunction(self: Object, name: []const u8) !?js.Function {
    if (self.isNullOrUndefined()) {
        return null;
    }
    const context = self.context;

    const js_name = v8.String.initUtf8(context.isolate, name);

    const js_value = try self.js_obj.getValue(context.v8_context, js_name.toName());
    if (!js_value.isFunction()) {
        return null;
    }
    return try context.createFunction(js_value);
}

pub fn callMethod(self: Object, comptime T: type, method_name: []const u8, args: anytype) !T {
    const func = try self.getFunction(method_name) orelse return error.MethodNotFound;
    return func.callWithThis(T, self, args);
}

pub fn isNull(self: Object) bool {
    return self.js_obj.toValue().isNull();
}

pub fn isUndefined(self: Object) bool {
    return self.js_obj.toValue().isUndefined();
}

pub fn isNullOrUndefined(self: Object) bool {
    return self.js_obj.toValue().isNullOrUndefined();
}

pub fn nameIterator(self: Object) NameIterator {
    const context = self.context;
    const js_obj = self.js_obj;

    const array = js_obj.getPropertyNames(context.v8_context);
    const count = array.length();

    return .{
        .count = count,
        .context = context,
        .js_obj = array.castTo(v8.Object),
    };
}

pub fn toZig(self: Object, comptime T: type) !T {
    return self.context.jsValueToZig(T, self.js_obj.toValue());
}

pub const NameIterator = struct {
    count: u32,
    idx: u32 = 0,
    js_obj: v8.Object,
    context: *const Context,

    pub fn next(self: *NameIterator) !?[]const u8 {
        const idx = self.idx;
        if (idx == self.count) {
            return null;
        }
        self.idx += 1;

        const context = self.context;
        const js_val = try self.js_obj.getAtIndex(context.v8_context, idx);
        return try context.valueToString(js_val, .{});
    }
};
