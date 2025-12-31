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

const IS_DEBUG = @import("builtin").mode == .Debug;

const Context = @import("Context.zig");
const PersistentObject = v8.Persistent(v8.Object);

const Allocator = std.mem.Allocator;

const Object = @This();

ctx: *js.Context,
handle: *const v8.c.Object,

pub fn getId(self: Object) u32 {
    return @bitCast(v8.c.v8__Object__GetIdentityHash(self.handle));
}

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
    const ctx = self.ctx;

    const js_key = v8.c.v8__String__NewFromUtf8(ctx.isolate.handle, key.ptr, v8.c.kNormal, @intCast(key.len)).?;
    const js_value = try ctx.zigValueToJs(value, .{});

    var out: v8.c.MaybeBool = undefined;
    v8.c.v8__Object__DefineOwnProperty(self.handle, ctx.v8_context.handle, @ptrCast(js_key), js_value.handle, @bitCast(opts), &out);

    const res = if (out.has_value) out.value else false;
    if (!res) {
        return error.FailedToSet;
    }
}

pub fn get(self: Object, key: []const u8) !js.Value {
    const ctx = self.ctx;
    const js_key = v8.c.v8__String__NewFromUtf8(ctx.isolate.handle, key.ptr, v8.c.kNormal, @intCast(key.len)).?;
    const js_val_handle = v8.c.v8__Object__Get(self.handle, ctx.v8_context.handle, js_key) orelse return error.JsException;
    const js_val = v8.Value{ .handle = js_val_handle };
    return ctx.createValue(js_val);
}

pub fn toString(self: Object) ![]const u8 {
    const js_value = v8.Value{ .handle = @ptrCast(self.handle) };
    return self.ctx.valueToString(js_value, .{});
}

pub fn format(self: Object, writer: *std.Io.Writer) !void {
    if (comptime IS_DEBUG) {
        const js_value = v8.Value{ .handle = @ptrCast(self.handle) };
        return self.ctx.debugValue(js_value, writer);
    }
    const str = self.toString() catch return error.WriteFailed;
    return writer.writeAll(str);
}

pub fn toJson(self: Object, allocator: Allocator) ![]u8 {
    const json_str_handle = v8.c.v8__JSON__Stringify(self.ctx.v8_context.handle, @ptrCast(self.handle), null) orelse return error.JsException;
    const json_string = v8.String{ .handle = json_str_handle };
    return self.ctx.jsStringToZig(json_string, .{ .allocator = allocator });
}

pub fn persist(self: Object) !Object {
    var ctx = self.ctx;

    const global = js.Global(Object).init(ctx.isolate.handle, self.handle);
    try ctx.global_objects.append(ctx.arena, global);

    return .{
        .ctx = ctx,
        .handle = global.local(),
    };
}

pub fn getFunction(self: Object, name: []const u8) !?js.Function {
    if (self.isNullOrUndefined()) {
        return null;
    }
    const ctx = self.ctx;

    const js_name = v8.c.v8__String__NewFromUtf8(ctx.isolate.handle, name.ptr, v8.c.kNormal, @intCast(name.len)).?;
    const js_val_handle = v8.c.v8__Object__Get(self.handle, ctx.v8_context.handle, js_name) orelse return error.JsException;
    const js_value = v8.Value{ .handle = js_val_handle };

    if (!js_value.isFunction()) {
        return null;
    }
    return try ctx.createFunction(js_value);
}

pub fn callMethod(self: Object, comptime T: type, method_name: []const u8, args: anytype) !T {
    const func = try self.getFunction(method_name) orelse return error.MethodNotFound;
    return func.callWithThis(T, self, args);
}

pub fn isNullOrUndefined(self: Object) bool {
    return v8.c.v8__Value__IsNullOrUndefined(@ptrCast(self.handle));
}

pub fn nameIterator(self: Object) NameIterator {
    const ctx = self.ctx;

    const handle = v8.c.v8__Object__GetPropertyNames(self.handle, ctx.v8_context.handle).?;
    const count = v8.c.v8__Array__Length(handle);

    return .{
        .ctx = ctx,
        .handle = handle,
        .count = count,
    };
}

pub fn toZig(self: Object, comptime T: type) !T {
    const js_value = v8.Value{ .handle = @ptrCast(self.handle) };
    return self.ctx.jsValueToZig(T, js_value);
}

pub const NameIterator = struct {
    count: u32,
    idx: u32 = 0,
    ctx: *const Context,
    handle: *const v8.c.Array,

    pub fn next(self: *NameIterator) !?[]const u8 {
        const idx = self.idx;
        if (idx == self.count) {
            return null;
        }
        self.idx += 1;

        const js_val_handle = v8.c.v8__Object__GetIndex(@ptrCast(self.handle), self.ctx.v8_context.handle, idx) orelse return error.JsException;
        const js_val = v8.Value{ .handle = js_val_handle };
        return try self.ctx.valueToString(js_val, .{});
    }
};
