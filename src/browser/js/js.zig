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
pub const v8 = @import("v8").c;

const string = @import("../../string.zig");

pub const Env = @import("Env.zig");
pub const bridge = @import("bridge.zig");
pub const Caller = @import("Caller.zig");
pub const Context = @import("Context.zig");
pub const Local = @import("Local.zig");
pub const Inspector = @import("Inspector.zig");
pub const Snapshot = @import("Snapshot.zig");
pub const Platform = @import("Platform.zig");
pub const Isolate = @import("Isolate.zig");
pub const HandleScope = @import("HandleScope.zig");

pub const Value = @import("Value.zig");
pub const Array = @import("Array.zig");
pub const String = @import("String.zig");
pub const Object = @import("Object.zig");
pub const TryCatch = @import("TryCatch.zig");
pub const Function = @import("Function.zig");
pub const Promise = @import("Promise.zig");
pub const Module = @import("Module.zig");
pub const BigInt = @import("BigInt.zig");
pub const Number = @import("Number.zig");
pub const Integer = @import("Integer.zig");
pub const PromiseResolver = @import("PromiseResolver.zig");
pub const PromiseRejection = @import("PromiseRejection.zig");

const Allocator = std.mem.Allocator;

pub fn Bridge(comptime T: type) type {
    return bridge.Builder(T);
}

// If a function returns a []i32, should that map to a plain-old
// JavaScript array, or a Int32Array? It's ambiguous. By default, we'll
// map arrays/slices to the JavaScript arrays. If you want a TypedArray
// wrap it in this.
// Also, this type has nothing to do with the Env. But we place it here
// for consistency. Want a callback? Env.Callback. Want a JsObject?
// Env.JsObject. Want a TypedArray? Env.TypedArray.
pub fn TypedArray(comptime T: type) type {
    return struct {
        values: []const T,

        pub fn dupe(self: TypedArray(T), allocator: Allocator) !TypedArray(T) {
            return .{ .values = try allocator.dupe(T, self.values) };
        }
    };
}

pub const ArrayBuffer = struct {
    values: []const u8,

    pub fn dupe(self: ArrayBuffer, allocator: Allocator) !ArrayBuffer {
        return .{ .values = try allocator.dupe(u8, self.values) };
    }
};

pub const ArrayType = enum(u8) {
    int8,
    uint8,
    uint8_clamped,
    int16,
    uint16,
    int32,
    uint32,
    float16,
    float32,
    float64,
};

pub fn ArrayBufferRef(comptime kind: ArrayType) type {
    return struct {
        const Self = @This();

        const BackingInt = switch (kind) {
            .int8 => i8,
            .uint8, .uint8_clamped => u8,
            .int16 => i16,
            .uint16 => u16,
            .int32 => i32,
            .uint32 => u32,
            .float16 => f16,
            .float32 => f32,
            .float64 => f64,
        };

        local: *const Local,
        handle: *const v8.Value,

        /// Persisted typed array.
        pub const Global = struct {
            handle: v8.Global,

            pub fn deinit(self: *Global) void {
                v8.v8__Global__Reset(&self.handle);
            }

            pub fn local(self: *const Global, l: *const Local) Self {
                return .{ .local = l, .handle = v8.v8__Global__Get(&self.handle, l.isolate.handle).? };
            }
        };

        pub fn init(local: *const Local, size: usize) Self {
            const ctx = local.ctx;
            const isolate = ctx.isolate;
            const bits = switch (@typeInfo(BackingInt)) {
                .int => |n| n.bits,
                .float => |f| f.bits,
                else => unreachable,
            };

            var array_buffer: *const v8.ArrayBuffer = undefined;
            if (size == 0) {
                array_buffer = v8.v8__ArrayBuffer__New(isolate.handle, 0).?;
            } else {
                const buffer_len = size * bits / 8;
                const backing_store = v8.v8__ArrayBuffer__NewBackingStore(isolate.handle, buffer_len).?;
                const backing_store_ptr = v8.v8__BackingStore__TO_SHARED_PTR(backing_store);
                array_buffer = v8.v8__ArrayBuffer__New2(isolate.handle, &backing_store_ptr).?;
            }

            const handle: *const v8.Value = switch (comptime kind) {
                .int8 => @ptrCast(v8.v8__Int8Array__New(array_buffer, 0, size).?),
                .uint8 => @ptrCast(v8.v8__Uint8Array__New(array_buffer, 0, size).?),
                .uint8_clamped => @ptrCast(v8.v8__Uint8ClampedArray__New(array_buffer, 0, size).?),
                .int16 => @ptrCast(v8.v8__Int16Array__New(array_buffer, 0, size).?),
                .uint16 => @ptrCast(v8.v8__Uint16Array__New(array_buffer, 0, size).?),
                .int32 => @ptrCast(v8.v8__Int32Array__New(array_buffer, 0, size).?),
                .uint32 => @ptrCast(v8.v8__Uint32Array__New(array_buffer, 0, size).?),
                .float16 => @ptrCast(v8.v8__Float16Array__New(array_buffer, 0, size).?),
                .float32 => @ptrCast(v8.v8__Float32Array__New(array_buffer, 0, size).?),
                .float64 => @ptrCast(v8.v8__Float64Array__New(array_buffer, 0, size).?),
            };

            return .{ .local = local, .handle = handle };
        }

        pub fn persist(self: *const Self) !Global {
            var ctx = self.local.ctx;
            var global: v8.Global = undefined;
            v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);
            try ctx.global_values.append(ctx.arena, global);

            return .{ .handle = global };
        }
    };
}

// If a WebAPI takes a []const u8, then we'll coerce any JS value to that string
// so null -> "null". But if a WebAPI takes an optional string, ?[]const u8,
// how should we handle null? If the parameter _isn't_ passed, then it's obvious
// that it should be null, but what if `null` is passed? It's ambiguous, should
// that be null, or "null"? It could depend on the api. So, `null` passed to
// ?[]const u8 will be `null`. If you want it to be "null", use a `.js.NullableString`.
pub const NullableString = struct {
    value: []const u8,
};

pub const Exception = struct {
    local: *const Local,
    handle: *const v8.Value,
};

// These are simple types that we can convert to JS with only an isolate. This
// is separated from the Caller's zigValueToJs to make it available when we
// don't have a caller (i.e., when setting static attributes on types)
pub fn simpleZigValueToJs(isolate: Isolate, value: anytype, comptime fail: bool, comptime null_as_undefined: bool) if (fail) *const v8.Value else ?*const v8.Value {
    switch (@typeInfo(@TypeOf(value))) {
        .void => return isolate.initUndefined(),
        .null => if (comptime null_as_undefined) return isolate.initUndefined() else return isolate.initNull(),
        .bool => return if (value) isolate.initTrue() else isolate.initFalse(),
        .int => |n| {
            if (comptime n.bits <= 32) {
                return @ptrCast(isolate.initInteger(value).handle);
            }
            if (value >= 0 and value <= 4_294_967_295) {
                return @ptrCast(isolate.initInteger(@as(u32, @intCast(value))).handle);
            }
            return @ptrCast(isolate.initBigInt(value).handle);
        },
        .comptime_int => {
            if (value > -2_147_483_648 and value <= 4_294_967_295) {
                return @ptrCast(isolate.initInteger(value).handle);
            }
            return @ptrCast(isolate.initBigInt(value).handle);
        },
        .float, .comptime_float => return @ptrCast(isolate.initNumber(value).handle),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return @ptrCast(isolate.initStringHandle(value));
            }
            if (ptr.size == .one) {
                const one_info = @typeInfo(ptr.child);
                if (one_info == .array and one_info.array.child == u8) {
                    return @ptrCast(isolate.initStringHandle(value));
                }
            }
        },
        .array => return simpleZigValueToJs(isolate, &value, fail, null_as_undefined),
        .optional => {
            if (value) |v| {
                return simpleZigValueToJs(isolate, v, fail, null_as_undefined);
            }
            if (comptime null_as_undefined) {
                return isolate.initUndefined();
            }
            return isolate.initNull();
        },
        .@"struct" => {
            switch (@TypeOf(value)) {
                string.String => return isolate.initStringHandle(value.str()),
                ArrayBuffer => {
                    const values = value.values;
                    const len = values.len;
                    const backing_store = v8.v8__ArrayBuffer__NewBackingStore(isolate.handle, len);
                    if (len > 0) {
                        const data: [*]u8 = @ptrCast(@alignCast(v8.v8__BackingStore__Data(backing_store)));
                        @memcpy(data[0..len], @as([]const u8, @ptrCast(values))[0..len]);
                    }
                    const backing_store_ptr = v8.v8__BackingStore__TO_SHARED_PTR(backing_store);
                    return @ptrCast(v8.v8__ArrayBuffer__New2(isolate.handle, &backing_store_ptr).?);
                },
                // zig fmt: off
                TypedArray(u8), TypedArray(u16), TypedArray(u32), TypedArray(u64),
                TypedArray(i8), TypedArray(i16), TypedArray(i32), TypedArray(i64),
                TypedArray(f32), TypedArray(f64),
                // zig fmt: on
                => {
                    const values = value.values;
                    const value_type = @typeInfo(@TypeOf(values)).pointer.child;
                    const len = values.len;
                    const bits = switch (@typeInfo(value_type)) {
                        .int => |n| n.bits,
                        .float => |f| f.bits,
                        else => @compileError("Invalid TypeArray type: " ++ @typeName(value_type)),
                    };

                    var array_buffer: *const v8.ArrayBuffer = undefined;
                    if (len == 0) {
                        array_buffer = v8.v8__ArrayBuffer__New(isolate.handle, 0).?;
                    } else {
                        const buffer_len = len * bits / 8;
                        const backing_store = v8.v8__ArrayBuffer__NewBackingStore(isolate.handle, buffer_len).?;
                        const data: [*]u8 = @ptrCast(@alignCast(v8.v8__BackingStore__Data(backing_store)));
                        @memcpy(data[0..buffer_len], @as([]const u8, @ptrCast(values))[0..buffer_len]);
                        const backing_store_ptr = v8.v8__BackingStore__TO_SHARED_PTR(backing_store);
                        array_buffer = v8.v8__ArrayBuffer__New2(isolate.handle, &backing_store_ptr).?;
                    }

                    switch (@typeInfo(value_type)) {
                        .int => |n| switch (n.signedness) {
                            .unsigned => switch (n.bits) {
                                8 => return @ptrCast(v8.v8__Uint8Array__New(array_buffer, 0, len).?),
                                16 => return @ptrCast(v8.v8__Uint16Array__New(array_buffer, 0, len).?),
                                32 => return @ptrCast(v8.v8__Uint32Array__New(array_buffer, 0, len).?),
                                64 => return @ptrCast(v8.v8__BigUint64Array__New(array_buffer, 0, len).?),
                                else => {},
                            },
                            .signed => switch (n.bits) {
                                8 => return @ptrCast(v8.v8__Int8Array__New(array_buffer, 0, len).?),
                                16 => return @ptrCast(v8.v8__Int16Array__New(array_buffer, 0, len).?),
                                32 => return @ptrCast(v8.v8__Int32Array__New(array_buffer, 0, len).?),
                                64 => return @ptrCast(v8.v8__BigInt64Array__New(array_buffer, 0, len).?),
                                else => {},
                            },
                        },
                        .float => |f| switch (f.bits) {
                            32 => return @ptrCast(v8.v8__Float32Array__New(array_buffer, 0, len).?),
                            64 => return @ptrCast(v8.v8__Float64Array__New(array_buffer, 0, len).?),
                            else => {},
                        },
                        else => {},
                    }
                    // We normally don't fail in this function unless fail == true
                    // but this can never be valid.
                    @compileError("Invalid TypeArray type: " ++ @typeName(value_type));
                },
                inline String, BigInt, Integer, Number, Value, Object => return value.handle,
                else => {},
            }
        },
        .@"union" => return simpleZigValueToJs(isolate, std.meta.activeTag(value), fail, null_as_undefined),
        .@"enum" => {
            const T = @TypeOf(value);
            if (@hasDecl(T, "toString")) {
                return simpleZigValueToJs(isolate, value.toString(), fail, null_as_undefined);
            }
        },
        else => {},
    }
    if (fail) {
        @compileError("Unsupported Zig type " ++ @typeName(@TypeOf(value)));
    }
    return null;
}

// These are here, and not in Inspector.zig, because Inspector.zig isn't always
// included (e.g. in the wpt build).

// This is called from V8. Whenever the v8 inspector has to describe a value
// it'll call this function to gets its [optional] subtype - which, from V8's
// point of view, is an arbitrary string.
pub export fn v8_inspector__Client__IMPL__valueSubtype(
    _: *v8.InspectorClientImpl,
    c_value: *const v8.Value,
) callconv(.c) [*c]const u8 {
    const external_entry = Inspector.getTaggedOpaque(c_value) orelse return null;
    return if (external_entry.subtype) |st| @tagName(st) else null;
}

// Same as valueSubType above, but for the optional description field.
// From what I can tell, some drivers _need_ the description field to be
// present, even if it's empty. So if we have a subType for the value, we'll
// put an empty description.
pub export fn v8_inspector__Client__IMPL__descriptionForValueSubtype(
    _: *v8.InspectorClientImpl,
    v8_context: *const v8.Context,
    c_value: *const v8.Value,
) callconv(.c) [*c]const u8 {
    _ = v8_context;

    // We _must_ include a non-null description in order for the subtype value
    // to be included. Besides that, I don't know if the value has any meaning
    const external_entry = Inspector.getTaggedOpaque(c_value) orelse return null;
    return if (external_entry.subtype == null) null else "";
}

test "TaggedAnyOpaque" {
    // If we grow this, fine, but it should be a conscious decision
    try std.testing.expectEqual(24, @sizeOf(@import("TaggedOpaque.zig")));
}
