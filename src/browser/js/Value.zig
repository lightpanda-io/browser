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
handle: *const v8.Value,

pub fn isObject(self: Value) bool {
    return v8.v8__Value__IsObject(self.handle);
}

pub fn isString(self: Value) bool {
    return v8.v8__Value__IsString(self.handle);
}

pub fn isArray(self: Value) bool {
    return v8.v8__Value__IsArray(self.handle);
}

pub fn isSymbol(self: Value) bool {
    return v8.v8__Value__IsSymbol(self.handle);
}

pub fn isFunction(self: Value) bool {
    return v8.v8__Value__IsFunction(self.handle);
}

pub fn isNull(self: Value) bool {
    return v8.v8__Value__IsNull(self.handle);
}

pub fn isUndefined(self: Value) bool {
    return v8.v8__Value__IsUndefined(self.handle);
}

pub fn isNullOrUndefined(self: Value) bool {
    return v8.v8__Value__IsNullOrUndefined(self.handle);
}

pub fn isNumber(self: Value) bool {
    return v8.v8__Value__IsNumber(self.handle);
}

pub fn isNumberObject(self: Value) bool {
    return v8.v8__Value__IsNumberObject(self.handle);
}

pub fn isInt32(self: Value) bool {
    return v8.v8__Value__IsInt32(self.handle);
}

pub fn isUint32(self: Value) bool {
    return v8.v8__Value__IsUint32(self.handle);
}

pub fn isBigInt(self: Value) bool {
    return v8.v8__Value__IsBigInt(self.handle);
}

pub fn isBigIntObject(self: Value) bool {
    return v8.v8__Value__IsBigIntObject(self.handle);
}

pub fn isBoolean(self: Value) bool {
    return v8.v8__Value__IsBoolean(self.handle);
}

pub fn isBooleanObject(self: Value) bool {
    return v8.v8__Value__IsBooleanObject(self.handle);
}

pub fn isTrue(self: Value) bool {
    return v8.v8__Value__IsTrue(self.handle);
}

pub fn isFalse(self: Value) bool {
    return v8.v8__Value__IsFalse(self.handle);
}

pub fn isTypedArray(self: Value) bool {
    return v8.v8__Value__IsTypedArray(self.handle);
}

pub fn isArrayBufferView(self: Value) bool {
    return v8.v8__Value__IsArrayBufferView(self.handle);
}

pub fn isArrayBuffer(self: Value) bool {
    return v8.v8__Value__IsArrayBuffer(self.handle);
}

pub fn isUint8Array(self: Value) bool {
    return v8.v8__Value__IsUint8Array(self.handle);
}

pub fn isUint8ClampedArray(self: Value) bool {
    return v8.v8__Value__IsUint8ClampedArray(self.handle);
}

pub fn isInt8Array(self: Value) bool {
    return v8.v8__Value__IsInt8Array(self.handle);
}

pub fn isUint16Array(self: Value) bool {
    return v8.v8__Value__IsUint16Array(self.handle);
}

pub fn isInt16Array(self: Value) bool {
    return v8.v8__Value__IsInt16Array(self.handle);
}

pub fn isUint32Array(self: Value) bool {
    return v8.v8__Value__IsUint32Array(self.handle);
}

pub fn isInt32Array(self: Value) bool {
    return v8.v8__Value__IsInt32Array(self.handle);
}

pub fn isBigUint64Array(self: Value) bool {
    return v8.v8__Value__IsBigUint64Array(self.handle);
}

pub fn isBigInt64Array(self: Value) bool {
    return v8.v8__Value__IsBigInt64Array(self.handle);
}

pub fn isPromise(self: Value) bool {
    return v8.v8__Value__IsPromise(self.handle);
}

pub fn toBool(self: Value) bool {
    return v8.v8__Value__BooleanValue(self.handle, self.ctx.isolate.handle);
}

pub fn typeOf(self: Value) js.String {
    const str_handle = v8.v8__Value__TypeOf(self.handle, self.ctx.isolate.handle).?;
    return js.String{ .ctx = self.ctx, .handle = str_handle };
}

pub fn toF32(self: Value) !f32 {
    return @floatCast(try self.toF64());
}

pub fn toF64(self: Value) !f64 {
    var maybe: v8.MaybeF64 = undefined;
    v8.v8__Value__NumberValue(self.handle, self.ctx.handle, &maybe);
    if (!maybe.has_value) {
        return error.JsException;
    }
    return maybe.value;
}

pub fn toI32(self: Value) !i32 {
    var maybe: v8.MaybeI32 = undefined;
    v8.v8__Value__Int32Value(self.handle, self.ctx.handle, &maybe);
    if (!maybe.has_value) {
        return error.JsException;
    }
    return maybe.value;
}

pub fn toU32(self: Value) !u32 {
    var maybe: v8.MaybeU32 = undefined;
    v8.v8__Value__Uint32Value(self.handle, self.ctx.handle, &maybe);
    if (!maybe.has_value) {
        return error.JsException;
    }
    return maybe.value;
}

pub fn toPromise(self: Value) js.Promise {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isPromise());
    }
    return .{
        .ctx = self.ctx,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toString(self: Value, opts: js.String.ToZigOpts) ![]u8 {
    return self._toString(false, opts);
}
pub fn toStringZ(self: Value, opts: js.String.ToZigOpts) ![:0]u8 {
    return self._toString(true, opts);
}

pub fn toJson(self: Value, allocator: Allocator) ![]u8 {
    const json_str_handle = v8.v8__JSON__Stringify(self.ctx.handle, self.handle, null) orelse return error.JsException;
    return self.ctx.jsStringToZig(json_str_handle, .{ .allocator = allocator });
}

fn _toString(self: Value, comptime null_terminate: bool, opts: js.String.ToZigOpts) !(if (null_terminate) [:0]u8 else []u8) {
    const ctx = self.ctx;

    if (self.isSymbol()) {
        const sym_handle = v8.v8__Symbol__Description(@ptrCast(self.handle), ctx.isolate.handle).?;
        return _toString(.{ .handle = @ptrCast(sym_handle), .ctx = ctx }, null_terminate, opts);
    }

    const str_handle = v8.v8__Value__ToString(self.handle, ctx.handle) orelse {
        return error.JsException;
    };

    const str = js.String{ .ctx = ctx, .handle = str_handle };
    if (comptime null_terminate) {
        return js.String.toZigZ(str, opts);
    }
    return js.String.toZig(str, opts);
}

pub fn fromJson(ctx: *js.Context, json: []const u8) !Value {
    const v8_isolate = v8.Isolate{ .handle = ctx.isolate.handle };
    const json_string = v8.String.initUtf8(v8_isolate, json);
    const v8_context = v8.Context{ .handle = ctx.handle };
    const value = try v8.Json.parse(v8_context, json_string);
    return .{ .ctx = ctx, .handle = value.handle };
}

pub fn persist(self: Value) !Global {
    var ctx = self.ctx;

    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);

    try ctx.global_values.append(ctx.arena, global);

    return .{
        .handle = global,
        .ctx = ctx,
    };
}

pub fn toZig(self: Value, comptime T: type) !T {
    return self.ctx.jsValueToZig(T, self);
}

pub fn toObject(self: Value) js.Object {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isObject());
    }

    return .{
        .ctx = self.ctx,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toArray(self: Value) js.Array {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isArray());
    }

    return .{
        .ctx = self.ctx,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toBigInt(self: Value) js.BigInt {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isBigInt());
    }

    return .{
        .handle = @ptrCast(self.handle),
    };
}

pub fn format(self: Value, writer: *std.Io.Writer) !void {
    if (comptime IS_DEBUG) {
        return self.ctx.debugValue(self, writer);
    }
    const str = self.toString(.{}) catch return error.WriteFailed;
    return writer.writeAll(str);
}

pub const Global = struct {
    handle: v8.Global,
    ctx: *js.Context,

    pub fn deinit(self: *Global) void {
        v8.v8__Global__Reset(&self.handle);
    }

    pub fn local(self: *const Global) Value {
        return .{
            .ctx = self.ctx,
            .handle = @ptrCast(v8.v8__Global__Get(&self.handle, self.ctx.isolate.handle)),
        };
    }

    pub fn isEqual(self: *const Global, other: Value) bool {
        return v8.v8__Global__IsEqual(&self.handle, other.handle);
    }
};
