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
const log = @import("../../log.zig");

const js = @import("js.zig");
const bridge = @import("bridge.zig");
const Caller = @import("Caller.zig");
const Context = @import("Context.zig");
const Isolate = @import("Isolate.zig");
const TaggedOpaque = @import("TaggedOpaque.zig");

const v8 = js.v8;
const CallOpts = Caller.CallOpts;
const Allocator = std.mem.Allocator;

// Where js.Context has a lifetime tied to the page, and holds the
// v8::Global<v8::Context>, this has a much shorter lifetime and holds a
// v8::Local<v8::Context>. In V8, you need a Local<v8::Context> or get anything
// done, but the local only exists for the lifetime of the HandleScope it was
// created on. When V8 calls into Zig, things are pretty straightforward, since
// that callback gives us the currenty-entered V8::Local<Context>. But when Zig
// has to call into V8, it's a bit more messy.
// As a general rule, think of it this way:
// 1 - Caller.zig is for V8 -> Zig
// 2 - Context.zig is for Zig -> V8
// The Local is encapsulates the data and logic they both need. It just happens
// that it's easier to use Local from Caller than from Context.
const Local = @This();

ctx: *Context,
handle: *const v8.Context,

// available on ctx, but accessed often, so pushed into the Local
isolate: Isolate,
call_arena: std.mem.Allocator,

pub fn newString(self: *const Local, str: []const u8) js.String {
    return .{
        .local = self,
        .handle = self.isolate.initStringHandle(str),
    };
}

pub fn newObject(self: *const Local) js.Object {
    return .{
        .local = self,
        .handle = v8.v8__Object__New(self.isolate.handle).?,
    };
}

pub fn newArray(self: *const Local, len: u32) js.Array {
    return .{
        .local = self,
        .handle = v8.v8__Array__New(self.isolate.handle, @intCast(len)).?,
    };
}

// == Executors ==
pub fn eval(self: *const Local, src: []const u8, name: ?[]const u8) !void {
    _ = try self.exec(src, name);
}

pub fn exec(self: *const Local, src: []const u8, name: ?[]const u8) !js.Value {
    return self.compileAndRun(src, name);
}

pub fn compileAndRun(self: *const Local, src: []const u8, name: ?[]const u8) !js.Value {
    const script_name = self.isolate.initStringHandle(name orelse "anonymous");
    const script_source = self.isolate.initStringHandle(src);

    // Create ScriptOrigin
    var origin: v8.ScriptOrigin = undefined;
    v8.v8__ScriptOrigin__CONSTRUCT(&origin, @ptrCast(script_name));

    // Create ScriptCompilerSource
    var script_comp_source: v8.ScriptCompilerSource = undefined;
    v8.v8__ScriptCompiler__Source__CONSTRUCT2(script_source, &origin, null, &script_comp_source);
    defer v8.v8__ScriptCompiler__Source__DESTRUCT(&script_comp_source);

    // Compile the script
    const v8_script = v8.v8__ScriptCompiler__Compile(
        self.handle,
        &script_comp_source,
        v8.kNoCompileOptions,
        v8.kNoCacheNoReason,
    ) orelse return error.CompilationError;

    // Run the script
    const result = v8.v8__Script__Run(v8_script, self.handle) orelse return error.ExecutionError;
    return .{ .local = self, .handle = result };
}

// == Zig -> JS ==

// To turn a Zig instance into a v8 object, we need to do a number of things.
// First, if it's a struct, we need to put it on the heap.
// Second, if we've already returned this instance, we should return
// the same object. Hence, our executor maintains a map of Zig objects
// to v8.Global(js.Object) (the "identity_map").
// Finally, if this is the first time we've seen this instance, we need to:
//  1 - get the FunctionTemplate (from our templates slice)
//  2 - Create the TaggedAnyOpaque so that, if needed, we can do the reverse
//      (i.e. js -> zig)
//  3 - Create a v8.Global(js.Object) (because Zig owns this object, not v8)
//  4 - Store our TaggedAnyOpaque into the persistent object
//  5 - Update our identity_map (so that, if we return this same instance again,
//      we can just grab it from the identity_map)
pub fn mapZigInstanceToJs(self: *const Local, js_obj_handle: ?*const v8.Object, value: anytype) !js.Object {
    const ctx = self.ctx;
    const arena = ctx.arena;

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            // Struct, has to be placed on the heap
            const heap = try arena.create(T);
            heap.* = value;
            return self.mapZigInstanceToJs(js_obj_handle, heap);
        },
        .pointer => |ptr| {
            const resolved = resolveValue(value);

            const gop = try ctx.identity_map.getOrPut(arena, @intFromPtr(resolved.ptr));
            if (gop.found_existing) {
                // we've seen this instance before, return the same object
                return (js.Object.Global{ .handle = gop.value_ptr.* }).local(self);
            }

            const isolate = self.isolate;
            const JsApi = bridge.Struct(ptr.child).JsApi;

            // Sometimes we're creating a new Object, like when
            // we're returning a value from a function. In those cases
            // we have to get the object template, and we can get an object
            // by calling initInstance its InstanceTemplate.
            // Sometimes though we already have the Object to bind to
            // for example, when we're executing a constructor, v8 has
            // already created the "this" object.
            const js_obj = js.Object{
                .local = self,
                .handle = js_obj_handle orelse blk: {
                    const function_template_handle = ctx.templates[resolved.class_id];
                    const object_template_handle = v8.v8__FunctionTemplate__InstanceTemplate(function_template_handle).?;
                    break :blk v8.v8__ObjectTemplate__NewInstance(object_template_handle, self.handle).?;
                },
            };

            if (!@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
                // The TAO contains the pointer to our Zig instance as
                // well as any meta data we'll need to use it later.
                // See the TaggedOpaque struct for more details.
                const tao = try arena.create(TaggedOpaque);
                tao.* = .{
                    .value = resolved.ptr,
                    .prototype_chain = resolved.prototype_chain.ptr,
                    .prototype_len = @intCast(resolved.prototype_chain.len),
                    .subtype = if (@hasDecl(JsApi.Meta, "subtype")) JsApi.Meta.subype else .node,
                };

                // Skip setting internal field for the global object (Window)
                // Window accessors get the instance from context.page.window instead
                // if (resolved.class_id != @import("../webapi/Window.zig").JsApi.Meta.class_id) {
                v8.v8__Object__SetInternalField(js_obj.handle, 0, isolate.createExternal(tao));
                // }
            } else {
                // If the struct is empty, we don't need to do all
                // the TOA stuff and setting the internal data.
                // When we try to map this from JS->Zig, in
                // TaggedOpaque, we'll also know there that
                // the type is empty and can create an empty instance.
            }

            // dont' use js_obj.persist(), because we don't want to track this in
            // context.global_objects, we want to track it in context.identity_map.
            v8.v8__Global__New(isolate.handle, js_obj.handle, gop.value_ptr);
            return js_obj;
        },
        else => @compileError("Expected a struct or pointer, got " ++ @typeName(T) ++ " (constructors must return struct or pointers)"),
    }
}

pub fn zigValueToJs(self: *const Local, value: anytype, comptime opts: CallOpts) !js.Value {
    const isolate = self.isolate;

    // Check if it's a "simple" type. This is extracted so that it can be
    // reused by other parts of the code. "simple" types only require an
    // isolate to create (specifically, they don't our templates array)
    if (js.simpleZigValueToJs(isolate, value, false, opts.null_as_undefined)) |js_value_handle| {
        return .{ .local = self, .handle = js_value_handle };
    }

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void, .bool, .int, .comptime_int, .float, .comptime_float, .@"enum", .null => {
            // Need to do this to keep the compiler happy
            // simpleZigValueToJs handles all of these cases.
            unreachable;
        },
        .array => {
            var js_arr = self.newArray(value.len);
            for (value, 0..) |v, i| {
                if (try js_arr.set(@intCast(i), v, opts) == false) {
                    return error.FailedToCreateArray;
                }
            }
            return js_arr.toValue();
        },
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                if (@typeInfo(ptr.child) == .@"struct" and @hasDecl(ptr.child, "JsApi")) {
                    if (bridge.JsApiLookup.has(ptr.child.JsApi)) {
                        const js_obj = try self.mapZigInstanceToJs(null, value);
                        return js_obj.toValue();
                    }
                }

                if (@typeInfo(ptr.child) == .@"struct" and @hasDecl(ptr.child, "runtimeGenericWrap")) {
                    const wrap = try value.runtimeGenericWrap(self.ctx.page);
                    return self.zigValueToJs(wrap, opts);
                }

                const one_info = @typeInfo(ptr.child);
                if (one_info == .array and one_info.array.child == u8) {
                    // Need to do this to keep the compiler happy
                    // If this was the case, simpleZigValueToJs would
                    // have handled it
                    unreachable;
                }
            },
            .slice => {
                if (ptr.child == u8) {
                    // Need to do this to keep the compiler happy
                    // If this was the case, simpleZigValueToJs would
                    // have handled it
                    unreachable;
                }
                var js_arr = self.newArray(@intCast(value.len));
                for (value, 0..) |v, i| {
                    if (try js_arr.set(@intCast(i), v, opts) == false) {
                        return error.FailedToCreateArray;
                    }
                }
                return js_arr.toValue();
            },
            else => {},
        },
        .@"struct" => |s| {
            if (@hasDecl(T, "JsApi")) {
                if (bridge.JsApiLookup.has(T.JsApi)) {
                    const js_obj = try self.mapZigInstanceToJs(null, value);
                    return js_obj.toValue();
                }
            }

            if (T == js.Function) {
                // we're returning a callback
                return .{ .local = self, .handle = @ptrCast(value.handle) };
            }

            if (T == js.Function.Global) {
                // Auto-convert Global to local for bridge
                return .{ .local = self, .handle = @ptrCast(value.local(self).handle) };
            }

            if (T == js.Object) {
                // we're returning a v8.Object
                return .{ .local = self, .handle = @ptrCast(value.handle) };
            }

            if (T == js.Object.Global) {
                // Auto-convert Global to local for bridge
                return .{ .local = self, .handle = @ptrCast(value.local(self).handle) };
            }

            if (T == js.Value.Global) {
                // Auto-convert Global to local for bridge
                return .{ .local = self, .handle = @ptrCast(value.local(self).handle) };
            }

            if (T == js.Promise.Global) {
                // Auto-convert Global to local for bridge
                return .{ .local = self, .handle = @ptrCast(value.local(self).handle) };
            }

            if (T == js.PromiseResolver.Global) {
                // Auto-convert Global to local for bridge
                return .{ .local = self, .handle = @ptrCast(value.local(self).handle) };
            }

            if (T == js.Module.Global) {
                // Auto-convert Global to local for bridge
                return .{ .local = self, .handle = @ptrCast(value.local(self).handle) };
            }

            if (T == js.Value) {
                return value;
            }

            if (T == js.Promise) {
                return .{ .local = self, .handle = @ptrCast(value.handle) };
            }

            if (T == js.Exception) {
                return .{ .local = self, .handle = isolate.throwException(value.handle) };
            }

            if (T == js.String) {
                return .{ .local = self, .handle = @ptrCast(value.handle) };
            }

            if (@hasDecl(T, "runtimeGenericWrap")) {
                const wrap = try value.runtimeGenericWrap(self.ctx.page);
                return self.zigValueToJs(wrap, opts);
            }

            if (s.is_tuple) {
                // return the tuple struct as an array
                var js_arr = self.newArray(@intCast(s.fields.len));
                inline for (s.fields, 0..) |f, i| {
                    if (try js_arr.set(@intCast(i), @field(value, f.name), opts) == false) {
                        return error.FailedToCreateArray;
                    }
                }
                return js_arr.toValue();
            }

            const js_obj = self.newObject();
            inline for (s.fields) |f| {
                if (try js_obj.set(f.name, @field(value, f.name), opts) == false) {
                    return error.CreateObjectFailure;
                }
            }
            return js_obj.toValue();
        },
        .@"union" => |un| {
            if (T == std.json.Value) {
                return self.zigJsonToJs(value);
            }
            if (un.tag_type) |UnionTagType| {
                inline for (un.fields) |field| {
                    if (value == @field(UnionTagType, field.name)) {
                        return self.zigValueToJs(@field(value, field.name), opts);
                    }
                }
                unreachable;
            }
            @compileError("Cannot use untagged union: " ++ @typeName(T));
        },
        .optional => {
            if (value) |v| {
                return self.zigValueToJs(v, opts);
            }
            // would be handled by simpleZigValueToJs
            unreachable;
        },
        .error_union => return self.zigValueToJs(try value, opts),
        else => {},
    }

    @compileError("A function returns an unsupported type: " ++ @typeName(T));
}

fn zigJsonToJs(self: *const Local, value: std.json.Value) !js.Value {
    const isolate = self.isolate;

    switch (value) {
        .bool => |v| return .{ .local = self, .handle = js.simpleZigValueToJs(isolate, v, true, false) },
        .float => |v| return .{ .local = self, .handle = js.simpleZigValueToJs(isolate, v, true, false) },
        .integer => |v| return .{ .local = self, .handle = js.simpleZigValueToJs(isolate, v, true, false) },
        .string => |v| return .{ .local = self, .handle = js.simpleZigValueToJs(isolate, v, true, false) },
        .null => return .{ .local = self, .handle = isolate.initNull() },

        // TODO handle number_string.
        // It is used to represent too big numbers.
        .number_string => return error.TODO,

        .array => |v| {
            const js_arr = self.newArray(@intCast(v.items.len));
            for (v.items, 0..) |array_value, i| {
                if (try js_arr.set(@intCast(i), array_value, .{}) == false) {
                    return error.JSObjectSetValue;
                }
            }
            return js_arr.toArray();
        },
        .object => |v| {
            var js_obj = self.newObject();
            var it = v.iterator();
            while (it.next()) |kv| {
                if (try js_obj.set(kv.key_ptr.*, kv.value_ptr.*, .{}) == false) {
                    return error.JSObjectSetValue;
                }
            }
            return .{ .local = self, .handle = @ptrCast(js_obj.handle) };
        },
    }
}

// == JS -> Zig ==

pub fn jsValueToZig(self: *const Local, comptime T: type, js_val: js.Value) !T {
    switch (@typeInfo(T)) {
        .optional => |o| {
            // If type type is a ?js.Value or a ?js.Object, then we want to pass
            // a js.Object, not null. Consider a function,
            //    _doSomething(arg: ?Env.JsObjet) void { ... }
            //
            // And then these two calls:
            //   doSomething();
            //   doSomething(null);
            //
            // In the first case, we'll pass `null`. But in the
            // second, we'll pass a js.Object which represents
            // null.
            // If we don't have this code, both cases will
            // pass in `null` and the the doSomething won't
            // be able to tell if `null` was explicitly passed
            // or whether no parameter was passed.
            if (comptime o.child == js.Value) {
                return js_val;
            }

            if (comptime o.child == js.Object) {
                return js.Object{
                    .local = self,
                    .handle = @ptrCast(js_val.handle),
                };
            }

            if (js_val.isNullOrUndefined()) {
                return null;
            }
            return try self.jsValueToZig(o.child, js_val);
        },
        .float => |f| switch (f.bits) {
            0...32 => return js_val.toF32(),
            33...64 => return js_val.toF64(),
            else => {},
        },
        .int => return jsIntToZig(T, js_val),
        .bool => return js_val.toBool(),
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                if (!js_val.isObject()) {
                    return error.InvalidArgument;
                }
                if (@hasDecl(ptr.child, "JsApi")) {
                    std.debug.assert(bridge.JsApiLookup.has(ptr.child.JsApi));
                    return TaggedOpaque.fromJS(*ptr.child, @ptrCast(js_val.handle));
                }
            },
            .slice => {
                if (ptr.sentinel() == null) {
                    if (try jsValueToTypedArray(ptr.child, js_val)) |value| {
                        return value;
                    }
                }

                if (ptr.child == u8) {
                    if (ptr.sentinel()) |s| {
                        if (comptime s == 0) {
                            return self.valueToStringZ(js_val, .{});
                        }
                    } else {
                        return self.valueToString(js_val, .{});
                    }
                }

                if (!js_val.isArray()) {
                    return error.InvalidArgument;
                }
                const js_arr = js_val.toArray();
                const arr = try self.call_arena.alloc(ptr.child, js_arr.len());
                for (arr, 0..) |*a, i| {
                    const item_value = try js_arr.get(@intCast(i));
                    a.* = try self.jsValueToZig(ptr.child, item_value);
                }
                return arr;
            },
            else => {},
        },
        .array => |arr| {
            // Retrieve fixed-size array as slice
            const slice_type = []arr.child;
            const slice_value = try self.jsValueToZig(slice_type, js_val);
            if (slice_value.len != arr.len) {
                // Exact length match, we could allow smaller arrays, but we would not be able to communicate how many were written
                return error.InvalidArgument;
            }
            return @as(*T, @ptrCast(slice_value.ptr)).*;
        },
        .@"struct" => {
            return try (self.jsValueToStruct(T, js_val)) orelse {
                return error.InvalidArgument;
            };
        },
        .@"union" => |u| {
            // see probeJsValueToZig for some explanation of what we're
            // trying to do

            // the first field that we find which the js_val could be
            // coerced to.
            var coerce_index: ?usize = null;

            // the first field that we find which the js_val is
            // compatible with. A compatible field has higher precedence
            // than a coercible, but still isn't a perfect match.
            var compatible_index: ?usize = null;
            inline for (u.fields, 0..) |field, i| {
                switch (try self.probeJsValueToZig(field.type, js_val)) {
                    .value => |v| return @unionInit(T, field.name, v),
                    .ok => {
                        // a perfect match like above case, except the probing
                        // didn't get the value for us.
                        return @unionInit(T, field.name, try self.jsValueToZig(field.type, js_val));
                    },
                    .coerce => if (coerce_index == null) {
                        coerce_index = i;
                    },
                    .compatible => if (compatible_index == null) {
                        compatible_index = i;
                    },
                    .invalid => {},
                }
            }

            // We didn't find a perfect match.
            const closest = compatible_index orelse coerce_index orelse return error.InvalidArgument;
            inline for (u.fields, 0..) |field, i| {
                if (i == closest) {
                    return @unionInit(T, field.name, try self.jsValueToZig(field.type, js_val));
                }
            }
            unreachable;
        },
        .@"enum" => |e| {
            if (@hasDecl(T, "js_enum_from_string")) {
                if (!js_val.isString()) {
                    return error.InvalidArgument;
                }
                return std.meta.stringToEnum(T, try self.valueToString(js_val, .{})) orelse return error.InvalidArgument;
            }
            switch (@typeInfo(e.tag_type)) {
                .int => return std.meta.intToEnum(T, try jsIntToZig(e.tag_type, js_val)),
                else => @compileError("unsupported enum parameter type: " ++ @typeName(T)),
            }
        },
        else => {},
    }

    @compileError("has an unsupported parameter type: " ++ @typeName(T));
}

// Extracted so that it can be used in both jsValueToZig and in
// probeJsValueToZig. Avoids having to duplicate this logic when probing.
fn jsValueToStruct(self: *const Local, comptime T: type, js_val: js.Value) !?T {
    return switch (T) {
        js.Function => {
            if (!js_val.isFunction()) {
                return null;
            }
            return .{ .local = self, .handle = @ptrCast(js_val.handle) };
        },
        js.Function.Global => {
            if (!js_val.isFunction()) {
                return null;
            }
            return try (js.Function{ .local = self, .handle = @ptrCast(js_val.handle) }).persist();
        },
        // zig fmt: off
        js.TypedArray(u8), js.TypedArray(u16), js.TypedArray(u32), js.TypedArray(u64),
        js.TypedArray(i8), js.TypedArray(i16), js.TypedArray(i32), js.TypedArray(i64),
        js.TypedArray(f32), js.TypedArray(f64),
        // zig fmt: on
        => {
            const ValueType = @typeInfo(std.meta.fieldInfo(T, .values).type).pointer.child;
            const arr = (try jsValueToTypedArray(ValueType, js_val)) orelse return null;
            return .{ .values = arr };
        },
        js.Value => js_val,
        js.Value.Global => return try js_val.persist(),
        js.Object => {
            if (!js_val.isObject()) {
                return null;
            }
            return js.Object{
                .local = self,
                .handle = @ptrCast(js_val.handle),
            };
        },
        js.Object.Global => {
            if (!js_val.isObject()) {
                return null;
            }
            const obj = js.Object{
                .local = self,
                .handle = @ptrCast(js_val.handle),
            };
            return try obj.persist();
        },

        js.Promise.Global => {
            if (!js_val.isPromise()) {
                return null;
            }
            const promise = js.Promise{
                .ctx = self,
                .handle = @ptrCast(js_val.handle),
            };
            return try promise.persist();
        },
        else => {
            if (!js_val.isObject()) {
                return null;
            }

            const isolate = self.isolate;
            const js_obj = js_val.toObject();

            var value: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const name = field.name;
                const key = isolate.initStringHandle(name);
                if (js_obj.has(key)) {
                    @field(value, name) = try self.jsValueToZig(field.type, try js_obj.get(key));
                } else if (@typeInfo(field.type) == .optional) {
                    @field(value, name) = null;
                } else {
                    const dflt = field.defaultValue() orelse return null;
                    @field(value, name) = dflt;
                }
            }

            return value;
        },
    };
}

fn jsValueToTypedArray(comptime T: type, js_val: js.Value) !?[]T {
    var force_u8 = false;
    var array_buffer: ?*const v8.ArrayBuffer = null;
    var byte_len: usize = undefined;
    var byte_offset: usize = undefined;

    if (js_val.isTypedArray()) {
        const buffer_handle: *const v8.ArrayBufferView = @ptrCast(js_val.handle);
        byte_len = v8.v8__ArrayBufferView__ByteLength(buffer_handle);
        byte_offset = v8.v8__ArrayBufferView__ByteOffset(buffer_handle);
        array_buffer = v8.v8__ArrayBufferView__Buffer(buffer_handle).?;
    } else if (js_val.isArrayBufferView()) {
        force_u8 = true;
        const buffer_handle: *const v8.ArrayBufferView = @ptrCast(js_val.handle);
        byte_len = v8.v8__ArrayBufferView__ByteLength(buffer_handle);
        byte_offset = v8.v8__ArrayBufferView__ByteOffset(buffer_handle);
        array_buffer = v8.v8__ArrayBufferView__Buffer(buffer_handle).?;
    } else if (js_val.isArrayBuffer()) {
        force_u8 = true;
        array_buffer = @ptrCast(js_val.handle);
        byte_len = v8.v8__ArrayBuffer__ByteLength(array_buffer);
        byte_offset = 0;
    }

    const backing_store_ptr = v8.v8__ArrayBuffer__GetBackingStore(array_buffer orelse return null);
    const backing_store_handle = v8.std__shared_ptr__v8__BackingStore__get(&backing_store_ptr).?;
    const data = v8.v8__BackingStore__Data(backing_store_handle);

    switch (T) {
        u8 => {
            if (force_u8 or js_val.isUint8Array() or js_val.isUint8ClampedArray()) {
                if (byte_len == 0) return &[_]u8{};
                const arr_ptr = @as([*]u8, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len];
            }
        },
        i8 => {
            if (js_val.isInt8Array()) {
                if (byte_len == 0) return &[_]i8{};
                const arr_ptr = @as([*]i8, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len];
            }
        },
        u16 => {
            if (js_val.isUint16Array()) {
                if (byte_len == 0) return &[_]u16{};
                const arr_ptr = @as([*]u16, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 2];
            }
        },
        i16 => {
            if (js_val.isInt16Array()) {
                if (byte_len == 0) return &[_]i16{};
                const arr_ptr = @as([*]i16, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 2];
            }
        },
        u32 => {
            if (js_val.isUint32Array()) {
                if (byte_len == 0) return &[_]u32{};
                const arr_ptr = @as([*]u32, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 4];
            }
        },
        i32 => {
            if (js_val.isInt32Array()) {
                if (byte_len == 0) return &[_]i32{};
                const arr_ptr = @as([*]i32, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 4];
            }
        },
        u64 => {
            if (js_val.isBigUint64Array()) {
                if (byte_len == 0) return &[_]u64{};
                const arr_ptr = @as([*]u64, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 8];
            }
        },
        i64 => {
            if (js_val.isBigInt64Array()) {
                if (byte_len == 0) return &[_]i64{};
                const arr_ptr = @as([*]i64, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 8];
            }
        },
        else => {},
    }
    return error.InvalidArgument;
}

// Probing is part of trying to map a JS value to a Zig union. There's
// a lot of ambiguity in this process, in part because some JS values
// can almost always be coerced. For example, anything can be coerced
// into an integer (it just becomes 0), or a float (becomes NaN) or a
// string.
//
// The way we'll do this is that, if there's a direct match, we'll use it
// If there's a potential match, we'll keep looking for a direct match
// and only use the (first) potential match as a fallback.
//
// Finally, I considered adding this probing directly into jsValueToZig
// but I decided doing this separately was better. However, the goal is
// obviously that probing is consistent with jsValueToZig.
fn ProbeResult(comptime T: type) type {
    return union(enum) {
        // The js_value maps directly to T
        value: T,

        // The value is a T. This is almost the same as returning value: T,
        // but the caller still has to get T by calling jsValueToZig.
        // We prefer returning .{.ok => {}}, to avoid reducing duplication
        // with jsValueToZig, but in some cases where probing has a cost
        // AND yields the value anyways, we'll use .{.value = T}.
        ok: void,

        // the js_value is compatible with T (i.e. a int -> float),
        compatible: void,

        // the js_value can be coerced to T (this is a lower precedence
        // than compatible)
        coerce: void,

        // the js_value cannot be turned into T
        invalid: void,
    };
}
fn probeJsValueToZig(self: *const Local, comptime T: type, js_val: js.Value) !ProbeResult(T) {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (js_val.isNullOrUndefined()) {
                return .{ .value = null };
            }
            return self.probeJsValueToZig(o.child, js_val);
        },
        .float => {
            if (js_val.isNumber() or js_val.isNumberObject()) {
                if (js_val.isInt32() or js_val.isUint32() or js_val.isBigInt() or js_val.isBigIntObject()) {
                    // int => float is a reasonable match
                    return .{ .compatible = {} };
                }
                return .{ .ok = {} };
            }
            // anything can be coerced into a float, it becomes NaN
            return .{ .coerce = {} };
        },
        .int => {
            if (js_val.isNumber() or js_val.isNumberObject()) {
                if (js_val.isInt32() or js_val.isUint32() or js_val.isBigInt() or js_val.isBigIntObject()) {
                    return .{ .ok = {} };
                }
                // float => int is kind of reasonable, I guess
                return .{ .compatible = {} };
            }
            // anything can be coerced into a int, it becomes 0
            return .{ .coerce = {} };
        },
        .bool => {
            if (js_val.isBoolean() or js_val.isBooleanObject()) {
                return .{ .ok = {} };
            }
            // anything can be coerced into a boolean, it will become
            // true or false based on..some complex rules I don't know.
            return .{ .coerce = {} };
        },
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                if (!js_val.isObject()) {
                    return .{ .invalid = {} };
                }
                if (bridge.JsApiLookup.has(ptr.child.JsApi)) {
                    // There's a bit of overhead in doing this, so instead
                    // of having a version of TaggedOpaque which
                    // returns a boolean or an optional, we rely on the
                    // main implementation and just handle the error.
                    const attempt = TaggedOpaque.fromJS(*ptr.child, @ptrCast(js_val.handle));
                    if (attempt) |value| {
                        return .{ .value = value };
                    } else |_| {
                        return .{ .invalid = {} };
                    }
                }
                // probably an error, but not for us to deal with
                return .{ .invalid = {} };
            },
            .slice => {
                if (js_val.isTypedArray()) {
                    switch (ptr.child) {
                        u8 => if (ptr.sentinel() == null) {
                            if (js_val.isUint8Array() or js_val.isUint8ClampedArray()) {
                                return .{ .ok = {} };
                            }
                        },
                        i8 => if (js_val.isInt8Array()) {
                            return .{ .ok = {} };
                        },
                        u16 => if (js_val.isUint16Array()) {
                            return .{ .ok = {} };
                        },
                        i16 => if (js_val.isInt16Array()) {
                            return .{ .ok = {} };
                        },
                        u32 => if (js_val.isUint32Array()) {
                            return .{ .ok = {} };
                        },
                        i32 => if (js_val.isInt32Array()) {
                            return .{ .ok = {} };
                        },
                        u64 => if (js_val.isBigUint64Array()) {
                            return .{ .ok = {} };
                        },
                        i64 => if (js_val.isBigInt64Array()) {
                            return .{ .ok = {} };
                        },
                        else => {},
                    }
                    return .{ .invalid = {} };
                }

                if (ptr.child == u8) {
                    if (js_val.isString()) {
                        return .{ .ok = {} };
                    }
                    // anything can be coerced into a string
                    return .{ .coerce = {} };
                }

                if (!js_val.isArray()) {
                    return .{ .invalid = {} };
                }

                // This can get tricky.
                const js_arr = js_val.toArray();

                if (js_arr.len() == 0) {
                    // not so tricky in this case.
                    return .{ .value = &.{} };
                }

                // We settle for just probing the first value. Ok, actually
                // not tricky in this case either.
                const first_val = try js_arr.get(0);
                switch (try self.probeJsValueToZig(ptr.child, first_val)) {
                    .value, .ok => return .{ .ok = {} },
                    .compatible => return .{ .compatible = {} },
                    .coerce => return .{ .coerce = {} },
                    .invalid => return .{ .invalid = {} },
                }
            },
            else => {},
        },
        .array => |arr| {
            // Retrieve fixed-size array as slice then probe
            const slice_type = []arr.child;
            switch (try self.probeJsValueToZig(slice_type, js_val)) {
                .value => |slice_value| {
                    if (slice_value.len == arr.len) {
                        return .{ .value = @as(*T, @ptrCast(slice_value.ptr)).* };
                    }
                    return .{ .invalid = {} };
                },
                .ok => {
                    // Exact length match, we could allow smaller arrays as .compatible, but we would not be able to communicate how many were written
                    if (js_val.isArray()) {
                        const js_arr = js_val.toArray();
                        if (js_arr.len() == arr.len) {
                            return .{ .ok = {} };
                        }
                    } else if (js_val.isString() and arr.child == u8) {
                        const str = try js_val.toString(self.local);
                        if (str.lenUtf8(self.isolate) == arr.len) {
                            return .{ .ok = {} };
                        }
                    }
                    return .{ .invalid = {} };
                },
                .compatible => return .{ .compatible = {} },
                .coerce => return .{ .coerce = {} },
                .invalid => return .{ .invalid = {} },
            }
        },
        .@"struct" => {
            // We don't want to duplicate the code for this, so we call
            // the actual conversion function.
            const value = (try self.jsValueToStruct(T, js_val)) orelse {
                return .{ .invalid = {} };
            };
            return .{ .value = value };
        },
        else => {},
    }

    return .{ .invalid = {} };
}

fn jsIntToZig(comptime T: type, js_value: js.Value) !T {
    const n = @typeInfo(T).int;
    switch (n.signedness) {
        .signed => switch (n.bits) {
            8 => return jsSignedIntToZig(i8, -128, 127, try js_value.toI32()),
            16 => return jsSignedIntToZig(i16, -32_768, 32_767, try js_value.toI32()),
            32 => return jsSignedIntToZig(i32, -2_147_483_648, 2_147_483_647, try js_value.toI32()),
            64 => {
                if (js_value.isBigInt()) {
                    const v = js_value.toBigInt();
                    return v.getInt64();
                }
                return jsSignedIntToZig(i64, -2_147_483_648, 2_147_483_647, try js_value.toI32());
            },
            else => {},
        },
        .unsigned => switch (n.bits) {
            8 => return jsUnsignedIntToZig(u8, 255, try js_value.toU32()),
            16 => return jsUnsignedIntToZig(u16, 65_535, try js_value.toU32()),
            32 => {
                if (js_value.isBigInt()) {
                    const v = js_value.toBigInt();
                    const large = v.getUint64();
                    if (large <= 4_294_967_295) {
                        return @intCast(large);
                    }
                    return error.InvalidArgument;
                }
                return jsUnsignedIntToZig(u32, 4_294_967_295, try js_value.toU32());
            },
            64 => {
                if (js_value.isBigInt()) {
                    const v = js_value.toBigInt();
                    return v.getUint64();
                }
                return jsUnsignedIntToZig(u64, 4_294_967_295, try js_value.toU32());
            },
            else => {},
        },
    }
    @compileError("Only i8, i16, i32, i64, u8, u16, u32 and u64 are supported");
}

fn jsSignedIntToZig(comptime T: type, comptime min: comptime_int, max: comptime_int, maybe: i32) !T {
    if (maybe >= min and maybe <= max) {
        return @intCast(maybe);
    }
    return error.InvalidArgument;
}

fn jsUnsignedIntToZig(comptime T: type, max: comptime_int, maybe: u32) !T {
    if (maybe <= max) {
        return @intCast(maybe);
    }
    return error.InvalidArgument;
}

// Every WebApi type has a class_id as T.JsApi.Meta.class_id. We use this to create
// a JSValue class of the correct type. However, given a Node, we don't want
// to create a Node class, we want to create a class of the most specific type.
// In other words, given a Node{._type = .{.document .{}}}, we want to create
// a Document, not a Node.
// This function recursively walks the _type union field (if there is one) to
// get the most specific class_id possible.
const Resolved = struct {
    ptr: *anyopaque,
    class_id: u16,
    prototype_chain: []const @import("TaggedOpaque.zig").PrototypeChainEntry,
};
pub fn resolveValue(value: anytype) Resolved {
    const T = bridge.Struct(@TypeOf(value));
    if (!@hasField(T, "_type") or @typeInfo(@TypeOf(value._type)) != .@"union") {
        return resolveT(T, value);
    }

    const U = @typeInfo(@TypeOf(value._type)).@"union";
    inline for (U.fields) |field| {
        if (value._type == @field(U.tag_type.?, field.name)) {
            const child = switch (@typeInfo(field.type)) {
                .pointer => @field(value._type, field.name),
                .@"struct" => &@field(value._type, field.name),
                .void => {
                    // Unusual case, but the Event (and maybe others) can be
                    // returned as-is. In that case, it has a dummy void type.
                    return resolveT(T, value);
                },
                else => @compileError(@typeName(field.type) ++ " has an unsupported _type field"),
            };
            return resolveValue(child);
        }
    }
    unreachable;
}

fn resolveT(comptime T: type, value: *anyopaque) Resolved {
    return .{
        .ptr = value,
        .class_id = T.JsApi.Meta.class_id,
        .prototype_chain = &T.JsApi.Meta.prototype_chain,
    };
}

pub fn stackTrace(self: *const Local) !?[]const u8 {
    const isolate = self.isolate;
    const separator = log.separator();

    var buf: std.ArrayList(u8) = .empty;
    var writer = buf.writer(self.call_arena);

    const stack_trace_handle = v8.v8__StackTrace__CurrentStackTrace__STATIC(isolate.handle, 30).?;
    const frame_count = v8.v8__StackTrace__GetFrameCount(stack_trace_handle);

    if (v8.v8__StackTrace__CurrentScriptNameOrSourceURL__STATIC(isolate.handle)) |script| {
        try writer.print("{s}<{s}>", .{ separator, try self.jsStringToZig(script, .{}) });
    }

    for (0..@intCast(frame_count)) |i| {
        const frame_handle = v8.v8__StackTrace__GetFrame(stack_trace_handle, isolate.handle, @intCast(i)).?;
        if (v8.v8__StackFrame__GetFunctionName(frame_handle)) |name| {
            const script = try self.jsStringToZig(name, .{});
            try writer.print("{s}{s}:{d}", .{ separator, script, v8.v8__StackFrame__GetLineNumber(frame_handle) });
        } else {
            try writer.print("{s}<anonymous>:{d}", .{ separator, v8.v8__StackFrame__GetLineNumber(frame_handle) });
        }
    }
    return buf.items;
}

// == Stringifiers ==
const ToStringOpts = struct {
    allocator: ?Allocator = null,
};
pub fn valueToString(self: *const Local, js_val: js.Value, opts: ToStringOpts) ![]u8 {
    return self.valueHandleToString(js_val.handle, opts);
}
pub fn valueToStringZ(self: *const Local, js_val: js.Value, opts: ToStringOpts) ![:0]u8 {
    return self.valueHandleToStringZ(js_val.handle, opts);
}

pub fn valueHandleToString(self: *const Local, js_val: *const v8.Value, opts: ToStringOpts) ![]u8 {
    return self._valueToString(false, js_val, opts);
}
pub fn valueHandleToStringZ(self: *const Local, js_val: *const v8.Value, opts: ToStringOpts) ![:0]u8 {
    return self._valueToString(true, js_val, opts);
}

fn _valueToString(self: *const Local, comptime null_terminate: bool, value_handle: *const v8.Value, opts: ToStringOpts) !(if (null_terminate) [:0]u8 else []u8) {
    var resolved_value_handle = value_handle;
    if (v8.v8__Value__IsSymbol(value_handle)) {
        const symbol_handle = v8.v8__Symbol__Description(@ptrCast(value_handle), self.isolate.handle).?;
        resolved_value_handle = @ptrCast(symbol_handle);
    }

    const string_handle = v8.v8__Value__ToString(resolved_value_handle, self.handle) orelse {
        return error.JsException;
    };

    return self._jsStringToZig(null_terminate, string_handle, opts);
}

pub fn jsStringToZig(self: *const Local, str: anytype, opts: ToStringOpts) ![]u8 {
    return self._jsStringToZig(false, str, opts);
}
pub fn jsStringToZigZ(self: *const Local, str: anytype, opts: ToStringOpts) ![:0]u8 {
    return self._jsStringToZig(true, str, opts);
}
fn _jsStringToZig(self: *const Local, comptime null_terminate: bool, str: anytype, opts: ToStringOpts) !(if (null_terminate) [:0]u8 else []u8) {
    const handle = if (@TypeOf(str) == js.String) str.handle else str;

    const len = v8.v8__String__Utf8Length(handle, self.isolate.handle);
    const allocator = opts.allocator orelse self.call_arena;
    const buf = try (if (comptime null_terminate) allocator.allocSentinel(u8, @intCast(len), 0) else allocator.alloc(u8, @intCast(len)));
    const n = v8.v8__String__WriteUtf8(handle, self.isolate.handle, buf.ptr, buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
    std.debug.assert(n == len);

    return buf;
}

// == Promise Helpers ==
pub fn rejectPromise(self: *const Local, value: anytype) !js.Promise {
    var resolver = js.PromiseResolver.init(self);
    resolver.reject("Local.rejectPromise", value);
    return resolver.promise();
}

pub fn resolvePromise(self: *const Local, value: anytype) !js.Promise {
    var resolver = js.PromiseResolver.init(self);
    resolver.resolve("Local.resolvePromise", value);
    return resolver.promise();
}

pub fn createPromiseResolver(self: *const Local) js.PromiseResolver {
    return js.PromiseResolver.init(self);
}

pub fn debugValue(self: *const Local, js_val: js.Value, writer: *std.Io.Writer) !void {
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    return self._debugValue(js_val, &seen, 0, writer) catch error.WriteFailed;
}

fn _debugValue(self: *const Local, js_val: js.Value, seen: *std.AutoHashMapUnmanaged(u32, void), depth: usize, writer: *std.Io.Writer) !void {
    if (js_val.isNull()) {
        // I think null can sometimes appear as an object, so check this and
        // handle it first.
        return writer.writeAll("null");
    }

    if (!js_val.isObject()) {
        // handle these explicitly, so we don't include the type (we only want to include
        // it when there's some ambiguity, e.g. the string "true")
        if (js_val.isUndefined()) {
            return writer.writeAll("undefined");
        }
        if (js_val.isTrue()) {
            return writer.writeAll("true");
        }
        if (js_val.isFalse()) {
            return writer.writeAll("false");
        }

        if (js_val.isSymbol()) {
            const symbol_handle = v8.v8__Symbol__Description(@ptrCast(js_val.handle), self.isolate.handle).?;
            const js_sym_str = try self.valueToString(.{ .local = self, .handle = symbol_handle }, .{});
            return writer.print("{s} (symbol)", .{js_sym_str});
        }
        const js_type = try self.jsStringToZig(js_val.typeOf(), .{});
        const js_val_str = try self.valueToString(js_val, .{});
        if (js_val_str.len > 2000) {
            try writer.writeAll(js_val_str[0..2000]);
            try writer.writeAll(" ... (truncated)");
        } else {
            try writer.writeAll(js_val_str);
        }
        return writer.print(" ({s})", .{js_type});
    }

    const js_obj = js_val.toObject();
    {
        // explicit scope because gop will become invalid in recursive call
        const gop = try seen.getOrPut(self.call_arena, js_obj.getId());
        if (gop.found_existing) {
            return writer.writeAll("<circular>\n");
        }
        gop.value_ptr.* = {};
    }

    const names_arr = js_obj.getOwnPropertyNames();
    const len = names_arr.len();

    if (depth > 20) {
        return writer.writeAll("...deeply nested object...");
    }
    const own_len = js_obj.getOwnPropertyNames().len();
    if (own_len == 0) {
        const js_val_str = try self.valueToString(js_val, .{});
        if (js_val_str.len > 2000) {
            try writer.writeAll(js_val_str[0..2000]);
            return writer.writeAll(" ... (truncated)");
        }
        return writer.writeAll(js_val_str);
    }

    const all_len = js_obj.getPropertyNames().len();
    try writer.print("({d}/{d})", .{ own_len, all_len });
    for (0..len) |i| {
        if (i == 0) {
            try writer.writeByte('\n');
        }
        const field_name = try names_arr.get(@intCast(i));
        const name = try self.valueToString(field_name, .{});
        try writer.splatByteAll(' ', depth);
        try writer.writeAll(name);
        try writer.writeAll(": ");
        const field_val = try js_obj.get(name);
        try self._debugValue(field_val, seen, depth + 1, writer);
        if (i != len - 1) {
            try writer.writeByte('\n');
        }
    }
}

// == Misc ==
pub fn parseJSON(self: *const Local, json: []const u8) !js.Value {
    const string_handle = self.isolate.initStringHandle(json);
    const value_handle = v8.v8__JSON__Parse(self.handle, string_handle) orelse return error.JsException;
    return .{
        .local = self,
        .handle = value_handle,
    };
}

pub fn throw(self: *const Local, err: []const u8) js.Exception {
    const handle = self.isolate.createError(err);
    return .{
        .local = self,
        .handle = handle,
    };
}

// Convert a Global (or optional Global) to a Local (or optional Local).
// Meant to be used from either page.js.toLocal, where the context must have an
// non-null local (orelse panic), or from a LocalScope
pub fn toLocal(self: *const Local, global: anytype) ToLocalReturnType(@TypeOf(global)) {
    const T = @TypeOf(global);
    if (@typeInfo(T) == .optional) {
        const unwrapped = global orelse return null;
        return unwrapped.local(self);
    }
    return global.local(self);
}

pub fn ToLocalReturnType(comptime T: type) type {
    if (@typeInfo(T) == .optional) {
        const GlobalType = @typeInfo(T).optional.child;
        const struct_info = @typeInfo(GlobalType).@"struct";
        inline for (struct_info.decls) |decl| {
            if (std.mem.eql(u8, decl.name, "local")) {
                const Fn = @TypeOf(@field(GlobalType, "local"));
                const fn_info = @typeInfo(Fn).@"fn";
                return ?fn_info.return_type.?;
            }
        }
        @compileError("Type does not have local method");
    } else {
        const struct_info = @typeInfo(T).@"struct";
        inline for (struct_info.decls) |decl| {
            if (std.mem.eql(u8, decl.name, "local")) {
                const Fn = @TypeOf(@field(T, "local"));
                const fn_info = @typeInfo(Fn).@"fn";
                return fn_info.return_type.?;
            }
        }
        @compileError("Type does not have local method");
    }
}

pub fn debugContextId(self: *const Local) i32 {
    return v8.v8__Context__DebugContextId(self.handle);
}

// Encapsulates a Local and a HandleScope (TODO). When we're going from V8->Zig
// we easily get both a Local and a HandleScope via Caller.init.
// But when we're going from Zig -> V8, things are more complicated.

// 1 - In some cases, we're going from Zig -> V8, but the origin is actually V8,
// so it's really V8 -> Zig -> V8. For example, when element.click() is called,
// V8 will call the Element.click method, which could then call back into V8 for
// a click handler.
//
// 2 - In other cases, it's always initiated from Zig, e.g. window.setTimeout or
// window.onload.
//
// 3 - Yet in other cases, it might could be either. Event dispatching can both be
// initiated from Zig and from V8.
//
// When JS execution is Zig initiated (or if we aren't sure whether it's Zig
// initiated or not), we need to create a Local.Scope:
//
//   var ls: js.Local.Scope = udnefined;
//   page.js.localScope(&ls);
//   defer ls.deinit();
//   // can use ls.local as needed.
//
// Note: Zig code that is 100% guaranteed to be v8-initiated can get a local via:
//   page.js.local.?
pub const Scope = struct {
    local: Local,

    pub fn deinit(self: *const Scope) void {
        _ = self;
    }

    pub fn toLocal(self: *Scope, global: anytype) ToLocalReturnType(@TypeOf(global)) {
        return self.local.toLocal(global);
    }
};
