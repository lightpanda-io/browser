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

const Allocator = std.mem.Allocator;

const Value = @This();

ctx: *js.Context,
handle: *const v8.c.Value,

pub fn isObject(self: Value) bool {
    return v8.c.v8__Value__IsObject(self.handle);
}

pub fn isString(self: Value) bool {
    return v8.c.v8__Value__IsString(self.handle);
}

pub fn isArray(self: Value) bool {
    return v8.c.v8__Value__IsArray(self.handle);
}

pub fn isNull(self: Value) bool {
    return self.js_val.isNull();
}

pub fn isUndefined(self: Value) bool {
    return self.js_val.isUndefined();
}

pub fn isSymbol(self: Value) bool {
    return v8.c.v8__Value__IsSymbol(self.handle);
}

pub fn toString(self: Value, opts: js.String.ToZigOpts) ![]u8 {
    return self._toString(false, opts);
}
pub fn toStringZ(self: Value, opts: js.String.ToZigOpts) ![:0]u8 {
    return self._toString(true, opts);
}

fn _toString(self: Value, comptime null_terminate: bool, opts: js.String.ToZigOpts) !(if (null_terminate) [:0]u8 else []u8) {
    const ctx = self.ctx;

    if (self.isSymbol()) {
        const sym_handle = v8.c.v8__Symbol__Description(@ptrCast(self.handle), ctx.isolate.handle).?;
        return _toString(.{ .handle = @ptrCast(sym_handle), .ctx = ctx }, null_terminate, opts);
    }

    const str_handle = v8.c.v8__Value__ToString(self.handle, ctx.v8_context.handle) orelse {
        return error.JsException;
    };

    const str = js.String{ .ctx = ctx, .handle = str_handle };
    if (comptime null_terminate) {
        return js.String.toZigZ(str, opts);
    }
    return js.String.toZig(str, opts);
}

pub fn toBool(self: Value) bool {
    return self.js_val.toBool(self.context.isolate);
}

pub fn fromJson(ctx: *js.Context, json: []const u8) !Value {
    const v8_isolate = v8.Isolate{ .handle = ctx.isolate.handle };
    const json_string = v8.String.initUtf8(v8_isolate, json);
    const value = try v8.Json.parse(ctx.v8_context, json_string);
    return .{ .ctx = ctx, .handle = value.handle };
}

pub fn persist(self: Value) !Value {
    var ctx = self.ctx;

    const global = js.Global(Value).init(ctx.isolate.handle, self.handle);
    try ctx.global_values.append(ctx.arena, global);

    return .{
        .ctx = ctx,
        .handle = global.local(),
    };
}

pub fn toZig(self: Value, comptime T: type) !T {
    return self.context.jsValueToZig(T, self.js_val);
}

pub fn toObject(self: Value) js.Object {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isObject());
    }

    return .{
        .ctx = self.ctx,
        .handle = self.handle,
    };
}

pub fn toArray(self: Value) js.Array {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isArray());
    }

    return .{
        .ctx = self.ctx,
        .handle = self.handle,
    };
}

pub fn format(self: Value, writer: *std.Io.Writer) !void {
    if (comptime IS_DEBUG) {
        return self.ctx.debugValue(.{ .handle = self.handle }, writer);
    }
    const str = self.toString(.{}) catch return error.WriteFailed;
    return writer.writeAll(str);
}
