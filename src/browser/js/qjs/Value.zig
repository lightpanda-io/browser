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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("js.zig");

const q = js.q;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Value = @This();

local: *const js.Local,
handle: q.JSValue,

fn qctx(self: Value) *q.JSContext {
    return self.local.ctx.ctx;
}

pub fn isObject(self: Value) bool {
    return q.JS_IsObject(self.handle);
}

pub fn isString(self: Value) ?js.String {
    if (!q.JS_IsString(self.handle)) {
        return null;
    }
    return .{ .local = self.local, .handle = self.handle };
}

pub fn isArray(self: Value) bool {
    return q.JS_IsArray(self.handle);
}

pub fn isSymbol(self: Value) bool {
    return q.JS_IsSymbol(self.handle);
}

pub fn isFunction(self: Value) bool {
    return q.JS_IsFunction(self.qctx(), self.handle);
}

pub fn isNull(self: Value) bool {
    return q.JS_IsNull(self.handle);
}

pub fn isUndefined(self: Value) bool {
    return q.JS_IsUndefined(self.handle);
}

pub fn isNullOrUndefined(self: Value) bool {
    return self.isNull() or self.isUndefined();
}

pub fn isNumber(self: Value) bool {
    return q.JS_IsNumber(self.handle);
}

pub fn isInt32(self: Value) bool {
    return q.JS_VALUE_GET_TAG(self.handle) == q.JS_TAG_INT;
}

pub fn isBigInt(self: Value) bool {
    return q.JS_IsBigInt(self.handle);
}

pub fn isBoolean(self: Value) bool {
    return q.JS_IsBool(self.handle);
}

pub fn isTrue(self: Value) bool {
    return self.isBoolean() and q.JS_ToBool(self.qctx(), self.handle) == 1;
}

pub fn isFalse(self: Value) bool {
    return self.isBoolean() and q.JS_ToBool(self.qctx(), self.handle) == 0;
}

pub fn isTypedArray(self: Value) bool {
    return q.JS_GetTypedArrayType(self.handle) >= 0;
}

pub fn isArrayBufferView(self: Value) bool {
    // DataView isn't covered by JS_GetTypedArrayType; acceptable for now.
    return self.isTypedArray();
}

pub fn isArrayBuffer(self: Value) bool {
    return q.JS_IsArrayBuffer(self.handle);
}

pub fn isUint8Array(self: Value) bool {
    return q.JS_GetTypedArrayType(self.handle) == q.JS_TYPED_ARRAY_UINT8;
}

pub fn isUint8ClampedArray(self: Value) bool {
    return q.JS_GetTypedArrayType(self.handle) == q.JS_TYPED_ARRAY_UINT8C;
}

pub fn isPromise(self: Value) bool {
    return q.JS_IsPromise(self.handle);
}

// See v8/Value.zig: type-aware toString that unwraps strings, Blobs and
// buffers to their underlying bytes.
pub fn toStringSmart(self: Value) ![]const u8 {
    if (self.isString()) |js_str| {
        return try js_str.toSlice();
    }

    const Blob = @import("../../webapi/Blob.zig");
    if (self.local.jsValueToZig(*Blob, self)) |blob_obj| {
        return blob_obj._slice;
    } else |_| {}

    const ctx = self.qctx();
    if (self.isTypedArray()) {
        var byte_offset: usize = 0;
        var byte_len: usize = 0;
        var bytes_per_element: usize = 0;
        const buffer = q.JS_GetTypedArrayBuffer(ctx, self.handle, &byte_offset, &byte_len, &bytes_per_element);
        if (q.JS_IsException(buffer)) {
            return error.JsException;
        }
        defer q.JS_FreeValue(ctx, buffer);
        var size: usize = 0;
        const data = q.JS_GetArrayBuffer(ctx, &size, buffer) orelse return "";
        return data[byte_offset .. byte_offset + byte_len];
    }

    if (self.isArrayBuffer()) {
        var size: usize = 0;
        const data = q.JS_GetArrayBuffer(ctx, &size, self.handle) orelse return "";
        return data[0..size];
    }

    return self.toStringSlice();
}

pub fn toBool(self: Value) bool {
    return q.JS_ToBool(self.qctx(), self.handle) == 1;
}

pub fn typeOf(self: Value) js.String {
    const name: []const u8 = blk: {
        if (self.isUndefined()) break :blk "undefined";
        if (self.isNull()) break :blk "object";
        if (self.isBoolean()) break :blk "boolean";
        if (self.isBigInt()) break :blk "bigint";
        if (self.isNumber()) break :blk "number";
        if (self.isString() != null) break :blk "string";
        if (self.isSymbol()) break :blk "symbol";
        if (self.isFunction()) break :blk "function";
        break :blk "object";
    };
    return self.local.newString(name);
}

pub fn toF32(self: Value) !f32 {
    return @floatCast(try self.toF64());
}

pub fn toF64(self: Value) !f64 {
    var out: f64 = undefined;
    if (q.JS_ToFloat64(self.qctx(), &out, self.handle) != 0) {
        return error.JsException;
    }
    return out;
}

pub fn toI32(self: Value) !i32 {
    var out: i32 = undefined;
    if (q.JS_ToInt32(self.qctx(), &out, self.handle) != 0) {
        return error.JsException;
    }
    return out;
}

pub fn toU32(self: Value) !u32 {
    var out: u32 = undefined;
    if (q.JS_ToUint32(self.qctx(), &out, self.handle) != 0) {
        return error.JsException;
    }
    return out;
}

pub fn toI64(self: Value) !i64 {
    var out: i64 = undefined;
    if (q.JS_ToInt64Ext(self.qctx(), &out, self.handle) != 0) {
        return error.JsException;
    }
    return out;
}

pub fn toU64(self: Value) !u64 {
    var out: i64 = undefined;
    if (q.JS_ToInt64Ext(self.qctx(), &out, self.handle) != 0) {
        return error.JsException;
    }
    return @bitCast(out);
}

pub fn toPromise(self: Value) js.Promise {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isPromise());
    }
    return .{
        .local = self.local,
        .handle = self.handle,
    };
}

pub fn toString(self: Value) !js.String {
    if (self.isString()) |s| {
        return s;
    }
    if (self.isSymbol()) {
        const desc = q.JS_GetPropertyStr(self.qctx(), self.handle, "description");
        self.local.track(desc);
        if (q.JS_IsString(desc)) {
            return .{ .local = self.local, .handle = desc };
        }
        return self.local.newString("Symbol()");
    }

    const str = q.JS_ToString(self.qctx(), self.handle);
    if (q.JS_IsException(str)) {
        return error.JsException;
    }
    self.local.track(str);
    return .{ .local = self.local, .handle = str };
}

pub fn toSSO(self: Value, comptime global: bool) !(if (global) lp.String.Global else lp.String) {
    return (try self.toString()).toSSO(global);
}

pub fn toSSOWithAlloc(self: Value, allocator: Allocator) !lp.String {
    return (try self.toString()).toSSOWithAlloc(allocator);
}

pub fn toStringSlice(self: Value) ![]u8 {
    return (try self.toString()).toSlice();
}

pub fn toStringSliceZ(self: Value) ![:0]u8 {
    return (try self.toString()).toSliceZ();
}

pub fn toStringSliceWithAlloc(self: Value, allocator: Allocator) ![]u8 {
    return (try self.toString()).toSliceWithAlloc(allocator);
}

pub fn toJson(self: Value, allocator: Allocator) ![]u8 {
    const ctx = self.qctx();
    const str = q.JS_JSONStringify(ctx, self.handle, js.UNDEFINED, js.UNDEFINED);
    if (q.JS_IsException(str)) {
        return error.JsException;
    }
    self.local.track(str);
    return js.String.toSliceWithAlloc(.{ .local = self.local, .handle = str }, allocator);
}

pub fn jsonStringify(self: Value, jws: anytype) !void {
    const local = self.local;
    const v = self.toJson(local.call_arena) catch return error.WriteFailed;
    // JSON.stringify yields no output for top-level undefined / functions /
    // symbols; map those to null so the produced JSON stays valid (see
    // v8/Value.zig).
    if (v.len == 0 or std.mem.eql(u8, v, "undefined")) {
        return jws.write(null);
    }
    jws.beginWriteRaw() catch return error.WriteFailed;
    jws.writer.writeAll(v) catch return error.WriteFailed;
    jws.endWriteRaw();
}

// Serialize + deserialize via quickjs' object writer. Host objects (Blob,
// File, ...) and SharedArrayBuffers cannot be cloned, matching the v8
// backend's behavior.
pub fn structuredClone(self: Value) !Value {
    return self.structuredCloneTo(self.local);
}

pub fn structuredCloneTo(self: Value, target: *const js.Local) !Value {
    const src_ctx = self.qctx();
    const dst_ctx = target.ctx.ctx;

    var len: usize = 0;
    const buf = q.JS_WriteObject(src_ctx, &len, self.handle, 0) orelse return error.JsException;
    defer q.js_free(src_ctx, buf);

    const cloned = q.JS_ReadObject(dst_ctx, buf, len, 0);
    if (q.JS_IsException(cloned)) {
        return error.JsException;
    }
    target.track(cloned);
    return .{ .local = target, .handle = cloned };
}

pub fn persist(self: Value) !Global {
    return self._persist(true);
}

pub fn temp(self: Value) !Temp {
    return self._persist(false);
}

fn _persist(self: *const Value, comptime is_global: bool) !(if (is_global) Global else Temp) {
    var ctx = self.local.ctx;
    const handle = ctx.persist(q.JS_DupValue(ctx.ctx, self.handle));
    if (comptime is_global) {
        try ctx.trackGlobal(handle);
        return .{ .handle = handle, .temps = {} };
    }
    try ctx.trackTemp(handle);
    return .{ .handle = handle, .temps = &ctx.page.temps };
}

pub fn toZig(self: Value, comptime T: type) !T {
    return self.local.jsValueToZig(T, self);
}

pub fn toObject(self: Value) js.Object {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isObject());
    }
    return .{
        .local = self.local,
        .handle = self.handle,
    };
}

pub fn toArray(self: Value) js.Array {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isArray());
    }
    return .{
        .local = self.local,
        .handle = self.handle,
    };
}

pub fn format(self: Value, writer: *std.Io.Writer) !void {
    const js_str = self.toString() catch return error.WriteFailed;
    return js_str.format(writer);
}

pub const Temp = G(.temp);
pub const Global = G(.global);

const GlobalType = enum(u8) {
    temp,
    global,
};

fn G(comptime global_type: GlobalType) type {
    return struct {
        handle: js.PersistentHandle,
        temps: if (global_type == .temp) *std.AutoHashMapUnmanaged(usize, js.PersistentHandle) else void,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            js.resetPersistentHandle(&self.handle);
        }

        pub fn local(self: *const Self, l: *const js.Local) Value {
            return .{
                .local = l,
                .handle = self.handle.value,
            };
        }

        pub fn isEqual(self: *const Self, other: Value) bool {
            return q.JS_IsSameValue(other.local.ctx.ctx, self.handle.value, other.handle);
        }

        pub fn release(self: *const Self) void {
            if (self.temps.fetchRemove(self.handle.key)) |kv| {
                var g = kv.value;
                js.resetPersistentHandle(&g);
            }
        }
    };
}
