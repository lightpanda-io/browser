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
const lp = @import("lightpanda");

const js = @import("js.zig");

const v8 = js.v8;

const IS_DEBUG = @import("builtin").mode == .Debug;

const Allocator = std.mem.Allocator;

const Value = @This();

local: *const js.Local,
handle: *const v8.Value,

pub fn isObject(self: Value) bool {
    return v8.v8__Value__IsObject(self.handle);
}

pub fn isString(self: Value) ?js.String {
    const handle = self.handle;
    if (!v8.v8__Value__IsString(handle)) {
        return null;
    }
    return .{ .local = self.local, .handle = @ptrCast(handle) };
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

pub fn isFloat32Array(self: Value) bool {
    return v8.v8__Value__IsFloat32Array(self.handle);
}

pub fn isFloat64Array(self: Value) bool {
    return v8.v8__Value__IsFloat64Array(self.handle);
}

// A few places in the code take various types, but want a string. This is a
// type-aware version of toString(). If you do:
//    (new ArrayBuffer(100)).toString()
// You'll get "[object ArrayBuffer]". But this `toStringSmart()` knows about
// buffers, and Blobs, etc and will try to return the real underlying string
// value. It _does_ ultimately fallback to toString() - callers should check
// for types they _don't_ want before calling this. For example, `Response`
// checks for null or undefined before calling this to apply specific handling
// to those cases.
pub fn toStringSmart(self: Value) ![]const u8 {
    if (self.isString()) |js_str| {
        return try js_str.toSlice();
    }

    const Blob = @import("../webapi/Blob.zig");
    if (self.local.jsValueToZig(*Blob, self)) |blob_obj| {
        return blob_obj._slice;
    } else |_| {}

    var byte_offset: usize = 0;
    var byte_len: usize = undefined;
    var array_buffer: ?*const v8.ArrayBuffer = null;

    if (self.isTypedArray() or self.isArrayBufferView()) {
        const buffer_handle: *const v8.ArrayBufferView = @ptrCast(self.handle);
        byte_len = v8.v8__ArrayBufferView__ByteLength(buffer_handle);
        byte_offset = v8.v8__ArrayBufferView__ByteOffset(buffer_handle);
        array_buffer = v8.v8__ArrayBufferView__Buffer(buffer_handle);
    } else if (self.isArrayBuffer()) {
        array_buffer = @ptrCast(self.handle);
        byte_len = v8.v8__ArrayBuffer__ByteLength(array_buffer);
    } else {
        return self.toStringSlice();
    }

    const backing_store_ptr = v8.v8__ArrayBuffer__GetBackingStore(array_buffer orelse return "");
    if (byte_len == 0) {
        return &[_]u8{};
    }

    const backing_store_handle = v8.std__shared_ptr__v8__BackingStore__get(&backing_store_ptr) orelse return "";
    const data = v8.v8__BackingStore__Data(backing_store_handle) orelse return "";
    const base = @as([*]const u8, @ptrCast(data)) + byte_offset;

    return base[0..byte_len];
}

pub fn isPromise(self: Value) bool {
    return v8.v8__Value__IsPromise(self.handle);
}

pub fn toBool(self: Value) bool {
    return v8.v8__Value__BooleanValue(self.handle, self.local.isolate.handle);
}

pub fn typeOf(self: Value) js.String {
    const str_handle = v8.v8__Value__TypeOf(self.handle, self.local.isolate.handle).?;
    return js.String{ .local = self.local, .handle = str_handle };
}

pub fn toF32(self: Value) !f32 {
    return @floatCast(try self.toF64());
}

pub fn toF64(self: Value) !f64 {
    var maybe: v8.MaybeF64 = undefined;
    v8.v8__Value__NumberValue(self.handle, self.local.handle, &maybe);
    if (!maybe.has_value) {
        return error.JsException;
    }
    return maybe.value;
}

pub fn toI32(self: Value) !i32 {
    var maybe: v8.MaybeI32 = undefined;
    v8.v8__Value__Int32Value(self.handle, self.local.handle, &maybe);
    if (!maybe.has_value) {
        return error.JsException;
    }
    return maybe.value;
}

pub fn toU32(self: Value) !u32 {
    var maybe: v8.MaybeU32 = undefined;
    v8.v8__Value__Uint32Value(self.handle, self.local.handle, &maybe);
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
        .local = self.local,
        .handle = @ptrCast(self.handle),
    };
}

pub fn toString(self: Value) !js.String {
    const l = self.local;
    const value_handle: *const v8.Value = blk: {
        if (self.isSymbol()) {
            break :blk @ptrCast(v8.v8__Symbol__Description(@ptrCast(self.handle), l.isolate.handle).?);
        }
        break :blk self.handle;
    };

    const str_handle = v8.v8__Value__ToString(value_handle, l.handle) orelse return error.JsException;
    return .{ .local = self.local, .handle = str_handle };
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
    const local = self.local;
    const str_handle = v8.v8__JSON__Stringify(local.handle, self.handle, null) orelse return error.JsException;
    return js.String.toSliceWithAlloc(.{ .local = local, .handle = str_handle }, allocator);
}

// Throws a DataCloneError for host objects (Blob, File, etc.) that cannot be serialized.
// Does not support transferables which require additional delegate callbacks.
pub fn structuredClone(self: Value) !Value {
    return self.structuredCloneTo(self.local);
}

// Clone a value to a different context (within the same isolate).
// Used for cross-context messaging (e.g., Worker <-> Page).
pub fn structuredCloneTo(self: Value, target: *const js.Local) !Value {
    const source_context = self.local.handle;
    const target_context = target.handle;
    const v8_isolate = target.isolate.handle;

    const SerializerDelegate = struct {
        // Called when V8 encounters a host object it doesn't know how to serialize.
        // Returns false to indicate the object cannot be cloned, and throws a DataCloneError.
        // V8 asserts has_exception() after this returns false, so we must throw here.
        fn writeHostObject(_: ?*anyopaque, isolate: ?*v8.Isolate, _: ?*const v8.Object) callconv(.c) v8.MaybeBool {
            const iso = isolate orelse return .{ .has_value = true, .value = false };
            const message = v8.v8__String__NewFromUtf8(iso, "The object cannot be cloned.", v8.kNormal, -1);
            const error_value = v8.v8__Exception__Error(message) orelse return .{ .has_value = true, .value = false };
            _ = v8.v8__Isolate__ThrowException(iso, error_value);
            return .{ .has_value = true, .value = false };
        }

        // Called by V8 to report serialization errors. The exception should already be thrown.
        fn throwDataCloneError(_: ?*anyopaque, _: ?*const v8.String) callconv(.c) void {}

        // Called when V8 encounters a SharedArrayBuffer. We don't support sharing them across
        // contexts, so throw a DataCloneError and return false. V8's WriteJSArrayBuffer calls
        // RETURN_VALUE_IF_EXCEPTION after this, so throwing prevents the fatal FromJust call.
        fn getSharedArrayBufferId(_: ?*anyopaque, isolate: ?*v8.Isolate, _: ?*const v8.SharedArrayBuffer, _: ?*u32) callconv(.c) bool {
            const iso = isolate orelse return false;
            const message = v8.v8__String__NewFromUtf8(iso, "SharedArrayBuffer cannot be cloned.", v8.kNormal, -1);
            const error_value = v8.v8__Exception__Error(message) orelse return false;
            _ = v8.v8__Isolate__ThrowException(iso, error_value);
            return false;
        }
    };

    const size, const data = blk: {
        const serializer = v8.v8__ValueSerializer__New(v8_isolate, &.{
            .data = null,
            .get_shared_array_buffer_id = SerializerDelegate.getSharedArrayBufferId,
            .write_host_object = SerializerDelegate.writeHostObject,
            .throw_data_clone_error = SerializerDelegate.throwDataCloneError,
        }) orelse return error.JsException;

        defer v8.v8__ValueSerializer__DELETE(serializer);

        var write_result: v8.MaybeBool = undefined;
        v8.v8__ValueSerializer__WriteHeader(serializer);
        v8.v8__ValueSerializer__WriteValue(serializer, source_context, self.handle, &write_result);
        if (!write_result.has_value or !write_result.value) {
            return error.JsException;
        }

        var size: usize = undefined;
        const data = v8.v8__ValueSerializer__Release(serializer, &size) orelse return error.JsException;
        break :blk .{ size, data };
    };

    defer v8.v8__ValueSerializer__FreeBuffer(data);

    const cloned_handle = blk: {
        const deserializer = v8.v8__ValueDeserializer__New(v8_isolate, data, size, null) orelse return error.JsException;
        defer v8.v8__ValueDeserializer__DELETE(deserializer);

        var read_header_result: v8.MaybeBool = undefined;
        v8.v8__ValueDeserializer__ReadHeader(deserializer, target_context, &read_header_result);
        if (!read_header_result.has_value or !read_header_result.value) {
            return error.JsException;
        }
        break :blk v8.v8__ValueDeserializer__ReadValue(deserializer, target_context) orelse return error.JsException;
    };

    return .{ .local = target, .handle = cloned_handle };
}

pub fn persist(self: Value) !Global {
    return self._persist(true);
}

pub fn temp(self: Value) !Temp {
    return self._persist(false);
}

fn _persist(self: *const Value, comptime is_global: bool) !(if (is_global) Global else Temp) {
    var ctx = self.local.ctx;

    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);
    if (comptime is_global) {
        try ctx.trackGlobal(global);
        return .{ .handle = global, .temps = {} };
    }
    try ctx.trackTemp(global);
    return .{ .handle = global, .temps = &ctx.page.temps };
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
        .handle = @ptrCast(self.handle),
    };
}

pub fn toArray(self: Value) js.Array {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.isArray());
    }

    return .{
        .local = self.local,
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
        return self.local.debugValue(self, writer);
    }
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
        handle: v8.Global,
        temps: if (global_type == .temp) *std.AutoHashMapUnmanaged(usize, v8.Global) else void,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            v8.v8__Global__Reset(&self.handle);
        }

        pub fn local(self: *const Self, l: *const js.Local) Value {
            return .{
                .local = l,
                .handle = @ptrCast(v8.v8__Global__Get(&self.handle, l.isolate.handle)),
            };
        }

        pub fn isEqual(self: *const Self, other: Value) bool {
            return v8.v8__Global__IsEqual(&self.handle, other.handle);
        }

        pub fn release(self: *const Self) void {
            if (self.temps.fetchRemove(self.handle.data_ptr)) |kv| {
                var g = kv.value;
                v8.v8__Global__Reset(&g);
            }
        }
    };
}
