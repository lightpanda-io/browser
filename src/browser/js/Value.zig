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
const TaggedOpaque = @import("TaggedOpaque.zig");

const v8 = js.v8;
const bridge = js.bridge;

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

pub fn isNativeError(self: Value) bool {
    return v8.v8__Value__IsNativeError(self.handle);
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

pub fn jsonStringify(self: Value, jws: anytype) !void {
    const local = self.local;
    const v = self.toJson(local.call_arena) catch return error.WriteFailed;
    // V8's JSON::Stringify finishes by calling Object::ToString on whatever
    // i::JsonStringify returns. For values that JSON.stringify treats as
    // non-serializable at the top level (undefined, functions, symbols),
    // i::JsonStringify yields the undefined sentinel, and ToString coerces
    // it to the JS string "undefined". Writing those 9 bytes raw embeds a
    // bare `undefined` token into the JSON stream — invalid per RFC 8259.
    // Map that case to `null`, matching what JSON.stringify emits when an
    // unserializable value sits in an array slot.
    if (std.mem.eql(u8, v, "undefined")) {
        return jws.write(null);
    }
    jws.beginWriteRaw() catch return error.WriteFailed;
    jws.writer.writeAll(v) catch return error.WriteFailed;
    jws.endWriteRaw();
}

// Clones host objects listed in cloneable_types; throws a DataCloneError for
// any other. Does not support transferables which require additional delegate
// callbacks.
pub fn structuredClone(self: Value) !Value {
    return self.structuredCloneTo(self.local);
}

// Clone a value to a different context (within the same isolate).
// Used for cross-context messaging (e.g., Worker <-> Page).
pub fn structuredCloneTo(self: Value, target: *const js.Local) !Value {
    const serialized = try self.serialize();
    defer serialized.deinit();
    return deserialize(target, serialized.bytes());
}

// A structured-serialized value: a V8-owned byte buffer. Caller must free it
// and must dupe the bytes if they want it to outlive the current local scope.
pub const Serialized = struct {
    data: [*c]u8,
    size: usize,

    pub fn bytes(self: Serialized) []const u8 {
        return self.data[0..self.size];
    }

    pub fn deinit(self: Serialized) void {
        v8.v8__ValueSerializer__FreeBuffer(self.data);
    }
};

// Serialize `self` into a V8-owned buffer. The caller must call deinit on the
// result. Raises a JS exception (DataCloneError) for unserializable values.
pub fn serialize(self: Value) !Serialized {
    var delegate_ctx = CloneDelegate.SerializeContext{
        .local = self.local,
        .serializer = undefined,
    };
    const serializer = v8.v8__ValueSerializer__New(self.local.isolate.handle, &.{
        .data = &delegate_ctx,
        .get_shared_array_buffer_id = CloneDelegate.getSharedArrayBufferId,
        .write_host_object = CloneDelegate.writeHostObject,
        .throw_data_clone_error = CloneDelegate.throwDataCloneError,
    }) orelse return error.JsException;
    defer v8.v8__ValueSerializer__DELETE(serializer);
    // the delegate callbacks only fire during WriteValue, after this is set
    delegate_ctx.serializer = serializer;

    var write_result: v8.MaybeBool = undefined;
    v8.v8__ValueSerializer__WriteHeader(serializer);
    v8.v8__ValueSerializer__WriteValue(serializer, self.local.handle, self.handle, &write_result);
    if (!write_result.has_value or !write_result.value) {
        return error.JsException;
    }

    var size: usize = undefined;
    const data = v8.v8__ValueSerializer__Release(serializer, &size) orelse return error.JsException;
    return .{ .data = data, .size = size };
}

// Deserialize a structured-serialized buffer (from `serialize`) into a value in
// `local`'s context. A malformed buffer surfaces as error.JsException.
pub fn deserialize(local: *const js.Local, bytes: []const u8) !Value {
    var delegate_ctx = CloneDelegate.DeserializeContext{
        .local = local,
        .deserializer = undefined,
    };
    const deserializer = v8.v8__ValueDeserializer__New(local.isolate.handle, bytes.ptr, bytes.len, &.{
        .data = &delegate_ctx,
        .read_host_object = CloneDelegate.readHostObject,
    }) orelse return error.JsException;
    defer v8.v8__ValueDeserializer__DELETE(deserializer);
    delegate_ctx.deserializer = deserializer;

    var read_header_result: v8.MaybeBool = undefined;
    v8.v8__ValueDeserializer__ReadHeader(deserializer, local.handle, &read_header_result);
    if (!read_header_result.has_value or !read_header_result.value) {
        return error.JsException;
    }

    const handle = v8.v8__ValueDeserializer__ReadValue(deserializer, local.handle) orelse return error.JsException;
    return .{ .local = local, .handle = handle };
}

// Host object types that support structured cloning via structuredSerialize /
// structuredDeserialize hooks. The serialized payload tags each host object
// with its position in this list; buffers never outlive the process, so the
// order only has to be consistent within a build.
const cloneable_types = .{
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/FileList.zig"),
    @import("../webapi/ImageData.zig"),
    @import("../webapi/DOMPointReadOnly.zig"),
    @import("../webapi/DOMPoint.zig"),
};

// Passed to a type's structuredSerialize hook to write its payload into the
// V8 serialization buffer.
pub const StructuredWriter = struct {
    local: *const js.Local,
    serializer: *v8.ValueSerializer,

    pub fn writeUint32(self: *const StructuredWriter, value: u32) void {
        v8.v8__ValueSerializer__WriteUint32(self.serializer, value);
    }

    pub fn writeUint64(self: *const StructuredWriter, value: u64) void {
        v8.v8__ValueSerializer__WriteUint64(self.serializer, value);
    }

    pub fn writeBytes(self: *const StructuredWriter, bytes: []const u8) void {
        v8.v8__ValueSerializer__WriteUint32(self.serializer, @intCast(bytes.len));
        if (bytes.len > 0) {
            v8.v8__ValueSerializer__WriteRawBytes(self.serializer, bytes.ptr, bytes.len);
        }
    }
};

// Passed to a type's structuredDeserialize hook to read back the payload its
// structuredSerialize hook wrote.
pub const StructuredReader = struct {
    local: *const js.Local,
    deserializer: *v8.ValueDeserializer,

    pub fn readUint32(self: *const StructuredReader) !u32 {
        var out: u32 = undefined;
        if (!v8.v8__ValueDeserializer__ReadUint32(self.deserializer, &out)) {
            return error.DataClone;
        }
        return out;
    }

    pub fn readUint64(self: *const StructuredReader) !u64 {
        var out: u64 = undefined;
        if (!v8.v8__ValueDeserializer__ReadUint64(self.deserializer, &out)) {
            return error.DataClone;
        }
        return out;
    }

    // The returned slice points into the serialization buffer; dupe anything
    // that must outlive deserialization.
    pub fn readBytes(self: *const StructuredReader) ![]const u8 {
        const len = try self.readUint32();
        if (len == 0) {
            return "";
        }
        var ptr: ?*const anyopaque = null;
        if (!v8.v8__ValueDeserializer__ReadRawBytes(self.deserializer, len, &ptr)) {
            return error.DataClone;
        }
        return @as([*]const u8, @ptrCast(ptr.?))[0..len];
    }
};

const CloneDelegate = struct {
    const SerializeContext = struct {
        local: *const js.Local,
        serializer: *v8.ValueSerializer,
    };

    const DeserializeContext = struct {
        local: *const js.Local,
        deserializer: *v8.ValueDeserializer,
    };

    // Called when V8 encounters an object with embedder fields, i.e. one of
    // our wrapped Zig instances. Serialize it if its type (or a prototype)
    // is in cloneable_types, otherwise throw a DataCloneError. V8 asserts
    // has_exception() after a false return, so we must throw here.
    fn writeHostObject(data: ?*anyopaque, _: ?*v8.Isolate, object: ?*const v8.Object) callconv(.c) v8.MaybeBool {
        const ctx: *SerializeContext = @ptrCast(@alignCast(data.?));

        blk: {
            const obj = object orelse break :blk;
            if (v8.v8__Object__InternalFieldCount(obj) == 0) {
                break :blk;
            }
            const tao_ptr = v8.v8__Object__GetAlignedPointerFromInternalField(obj, 0) orelse break :blk;
            const tao: *TaggedOpaque = @ptrCast(@alignCast(tao_ptr));

            const prototype_chain = tao.prototype_chain[0..tao.prototype_len];
            if (writeCloneable(ctx, prototype_chain[0].index, tao.value)) |result| {
                return result;
            }

            // Walk up the prototype chain so a subtype serializes as its
            // closest cloneable supertype (mirrors TaggedOpaque.fromJS).
            var ptr = @intFromPtr(tao.value);
            for (prototype_chain[1..]) |proto| {
                ptr += proto.offset;
                const proto_ptr: **anyopaque = @ptrFromInt(ptr);
                if (writeCloneable(ctx, proto.index, proto_ptr.*)) |result| {
                    return result;
                }
                ptr = @intFromPtr(proto_ptr.*);
            }
        }

        throwDataCloneException(ctx.local, null);
        return .{ .has_value = true, .value = false };
    }

    fn writeCloneable(
        ctx: *SerializeContext,
        type_index: bridge.JsApiLookup.BackingInt,
        value_ptr: *anyopaque,
    ) ?v8.MaybeBool {
        inline for (cloneable_types, 0..) |T, tag| {
            if (type_index == bridge.JsApiLookup.getId(T.JsApi)) {
                v8.v8__ValueSerializer__WriteUint32(ctx.serializer, tag);
                var writer = StructuredWriter{ .local = ctx.local, .serializer = ctx.serializer };
                const instance: *const T = @ptrCast(@alignCast(value_ptr));
                instance.structuredSerialize(&writer) catch {
                    throwDataCloneException(ctx.local, null);
                    return .{ .has_value = true, .value = false };
                };
                return .{ .has_value = true, .value = true };
            }
        }
        return null;
    }

    // Called by V8 to read back what writeHostObject wrote. Returning null
    // aborts deserialization, so we throw first to surface a proper error.
    fn readHostObject(data: ?*anyopaque, _: ?*v8.Isolate) callconv(.c) ?*const v8.Object {
        const ctx: *DeserializeContext = @ptrCast(@alignCast(data.?));
        const local = ctx.local;

        var tag: u32 = undefined;
        if (v8.v8__ValueDeserializer__ReadUint32(ctx.deserializer, &tag)) {
            var reader = StructuredReader{ .local = local, .deserializer = ctx.deserializer };
            inline for (cloneable_types, 0..) |T, i| {
                if (tag == i) {
                    return readCloneable(T, &reader) orelse {
                        throwDataCloneException(local, null);
                        return null;
                    };
                }
            }
        }

        throwDataCloneException(local, null);
        return null;
    }

    fn readCloneable(comptime T: type, reader: *StructuredReader) ?*const v8.Object {
        const local = reader.local;
        const instance = T.structuredDeserialize(reader, local.ctx.page) catch return null;
        const js_obj = local.mapZigInstanceToJs(null, instance) catch return null;
        return js_obj.handle;
    }

    // Called by V8 when a built-in can't be serialized (e.g. an out-of-bounds
    // TypedArray). The delegate is responsible for actually throwing.
    fn throwDataCloneError(data: ?*anyopaque, message: ?*const v8.String) callconv(.c) void {
        const ctx: *SerializeContext = @ptrCast(@alignCast(data.?));
        const local = ctx.local;
        const msg: ?[]const u8 = blk: {
            const handle = message orelse break :blk null;
            const str = js.String{ .local = local, .handle = handle };
            // the exception can outlive this call; dupe onto the context arena
            break :blk str.toSliceWithAlloc(local.ctx.arena) catch null;
        };
        throwDataCloneException(local, msg);
    }

    // Called when V8 encounters a SharedArrayBuffer. We don't support sharing
    // them across contexts, so throw a DataCloneError and return false. V8's
    // WriteJSArrayBuffer calls RETURN_VALUE_IF_EXCEPTION after this, so
    // throwing prevents the fatal FromJust call.
    fn getSharedArrayBufferId(data: ?*anyopaque, _: ?*v8.Isolate, _: ?*const v8.SharedArrayBuffer, _: ?*u32) callconv(.c) bool {
        const ctx: *SerializeContext = @ptrCast(@alignCast(data.?));
        throwDataCloneException(ctx.local, "SharedArrayBuffer cannot be cloned");
        return false;
    }

    fn throwDataCloneException(local: *const js.Local, message: ?[]const u8) void {
        const DOMException = @import("../webapi/DOMException.zig");
        const isolate = local.isolate;
        const js_value = local.zigValueToJs(DOMException.init(message, "DataCloneError"), .{}) catch {
            const str = v8.v8__String__NewFromUtf8(isolate.handle, "The object can not be cloned", v8.kNormal, -1);
            const error_value = v8.v8__Exception__Error(str) orelse return;
            _ = v8.v8__Isolate__ThrowException(isolate.handle, error_value);
            return;
        };
        _ = isolate.throwException(js_value.handle);
    }
};

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

const testing = @import("../../testing.zig");
test "Value: jsonStringify maps unserializable JS values to null" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // V8::JSON::Stringify finishes with Object::ToString on whatever
    // i::JsonStringify returns. For values JSON.stringify treats as
    // non-serializable at the top level (undefined, functions, symbols),
    // i::JsonStringify yields the undefined sentinel, and ToString coerces
    // it to the JS string "undefined". Without the jsonStringify fix, those
    // 9 bytes get written raw and the produced JSON is invalid.
    const Wrapper = struct { v: Value };
    const cases = .{
        .{ .name = "undefined", .expr = "undefined" },
        .{ .name = "function", .expr = "(function(){})" },
        .{ .name = "symbol", .expr = "Symbol('s')" },
    };
    inline for (cases) |case| {
        const value = try ls.local.exec(case.expr, null);
        const out = try std.json.Stringify.valueAlloc(
            testing.allocator,
            Wrapper{ .v = value },
            .{},
        );
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, "{\"v\":null}", out);
    }

    // Values that DO serialize must pass through unchanged.
    const ok_cases = .{
        .{ .expr = "null", .expected = "{\"v\":null}" },
        .{ .expr = "42", .expected = "{\"v\":42}" },
        .{ .expr = "'hi'", .expected = "{\"v\":\"hi\"}" },
        .{ .expr = "true", .expected = "{\"v\":true}" },
        .{ .expr = "({a:1})", .expected = "{\"v\":{\"a\":1}}" },
        .{ .expr = "[undefined]", .expected = "{\"v\":[null]}" },
        .{ .expr = "({x:undefined})", .expected = "{\"v\":{}}" },
        // A string literally equal to "undefined" must keep its quotes.
        .{ .expr = "'undefined'", .expected = "{\"v\":\"undefined\"}" },
    };
    inline for (ok_cases) |case| {
        const value = try ls.local.exec(case.expr, null);
        const out = try std.json.Stringify.valueAlloc(
            testing.allocator,
            Wrapper{ .v = value },
            .{},
        );
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, case.expected, out);
    }
}
