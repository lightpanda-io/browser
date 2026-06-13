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

// quickjs has no v8-style Local/HandleScope; this Local exists to keep the
// same API shape as the v8 backend. Every JSValue created through it is
// registered on the Context's handle stack (see Context.track) and freed
// when the enclosing Caller or Local.Scope exits - values that must outlive
// the scope are persisted (ref-counted) via .persist()/.temp().
const std = @import("std");
const lp = @import("lightpanda");

const string = @import("../../../string.zig");

const Page = @import("../../Page.zig");

const js = @import("js.zig");
const bridge = @import("bridge.zig");
const Caller = @import("Caller.zig");
const Context = @import("Context.zig");
const marshal = @import("../marshal.zig");
const registry = @import("../registry.zig");
const TaggedOpaque = @import("TaggedOpaque.zig");

const q = js.q;
const log = lp.log;
const CallOpts = Caller.CallOpts;
const FinalizerCallback = js.FinalizerCallback;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Local = @This();

ctx: *Context,
call_arena: std.mem.Allocator,

// quickjs has no isolate; zero-bit field so engine-neutral call sites
// (e.g. `unbound.persist(local.isolate)`) keep compiling.
isolate: @import("Env.zig").Isolate = .{},

// Register an owned JSValue on the handle stack; freed at scope exit.
pub fn track(self: *const Local, value: q.JSValue) void {
    self.ctx.track(value);
}

pub fn newString(self: *const Local, str: []const u8) js.String {
    const handle = q.JS_NewStringLen(self.ctx.ctx, str.ptr, str.len);
    self.track(handle);
    return .{ .local = self, .handle = handle };
}

// Creates a JS string by mapping each input byte 0..255 directly to a JS
// code unit, with no UTF-8 decoding (see v8/Local.zig).
pub fn newOneByteString(self: *const Local, bytes: []const u8) js.String {
    // quickjs only takes UTF-8; encode each byte as a codepoint.
    var buf = self.call_arena.alloc(u8, bytes.len * 2) catch {
        return self.newString("");
    };
    var pos: usize = 0;
    for (bytes) |b| {
        if (b < 0x80) {
            buf[pos] = b;
            pos += 1;
        } else {
            buf[pos] = 0xc0 | (b >> 6);
            buf[pos + 1] = 0x80 | (b & 0x3f);
            pos += 2;
        }
    }
    return self.newString(buf[0..pos]);
}

pub fn newObject(self: *const Local) js.Object {
    const handle = q.JS_NewObject(self.ctx.ctx);
    self.track(handle);
    return .{ .local = self, .handle = handle };
}

pub fn newArray(self: *const Local, len: u32) js.Array {
    _ = len; // quickjs arrays grow on demand
    const handle = q.JS_NewArray(self.ctx.ctx);
    self.track(handle);
    return .{ .local = self, .handle = handle };
}

/// Creates a new typed array. Memory is owned by the JS context.
pub fn createTypedArray(self: *const Local, comptime array_type: js.ArrayType, size: usize) js.ArrayBufferRef(array_type) {
    return .init(self, size);
}

// Creates a JS function that calls `callback` with `data` as its first
// argument (the v8 backend's External-data equivalent).
pub fn newCallback(
    self: *const Local,
    comptime callback: anytype,
    data: anytype,
) js.Function {
    const qctx = self.ctx.ctx;

    // Wrap the raw pointer in an object of our "external" class.
    const external = q.JS_NewObjectClass(qctx, @intCast(self.ctx.env.external_class_id));
    defer q.JS_FreeValue(qctx, external);
    _ = q.JS_SetOpaque(external, @ptrCast(@constCast(data)));

    var func_data = [_]q.JSValue{external};
    const handle = q.JS_NewCFunctionData(qctx, struct {
        fn wrap(c: ?*q.JSContext, this: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst, _: c_int, fdata: [*c]q.JSValue) callconv(.c) q.JSValue {
            var class_id: q.JSClassID = undefined;
            const ptr = q.JS_GetAnyOpaque(fdata[0], &class_id) orelse return js.UNDEFINED;
            return Caller.Function.callWithData(@TypeOf(data), c.?, this, argc, argv, callback, .{ .embedded_receiver = true }, @ptrCast(@alignCast(ptr)));
        }
    }.wrap, 0, 0, func_data.len, &func_data);
    self.track(handle);
    return .{ .local = self, .handle = handle };
}

pub fn runMacrotasks(self: *const Local) void {
    const env = self.ctx.env;
    env.pumpMessageLoop();
    env.runMicrotasks();
}

pub fn runMicrotasks(self: *const Local) void {
    self.ctx.env.runMicrotasks();
}

// == Executors ==
pub fn eval(self: *const Local, src: []const u8, name: ?[]const u8) !void {
    _ = try self.exec(src, name);
}

pub fn exec(self: *const Local, src: []const u8, name: ?[]const u8) !js.Value {
    return self.compileAndRun(src, name);
}

/// Compiles a function body into a function with the given parameters.
/// The v8 backend supports extension (with-scope) objects; nothing uses
/// them today and quickjs has no equivalent, so they are not supported.
pub fn compileFunction(
    self: *const Local,
    src: anytype,
    comptime parameter_names: []const []const u8,
    extensions: anytype,
) !js.Function {
    std.debug.assert(extensions.len == 0);

    const body: []const u8 = if (@TypeOf(src) == js.String) try src.toSlice() else src;

    comptime var params: []const u8 = "";
    comptime {
        for (parameter_names, 0..) |p, i| {
            if (i != 0) params = params ++ ",";
            params = params ++ p;
        }
    }

    const full = try std.fmt.allocPrint(self.call_arena, "(function({s}) {{ {s} }})", .{ params, body });

    const value = try self.compileAndRun(full, "<anonymous>");
    if (!value.isFunction()) {
        return error.CompilationError;
    }
    return .{ .local = self, .handle = value.handle };
}

// quickjs requires eval input to be NUL-terminated, valid UTF-8. Zig
// slices guarantee neither (an empty slice can have an undefined pointer,
// and v8 tolerates invalid UTF-8 by substituting U+FFFD), so all source
// text passes through here first.
pub fn prepareSource(self: *const Local, src: []const u8) ![:0]const u8 {
    if (std.unicode.utf8ValidateSlice(src)) {
        return self.call_arena.dupeZ(u8, src);
    }

    // replace invalid sequences with U+FFFD, mirroring v8
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(self.call_arena, src.len + 16);
    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            try out.appendSlice(self.call_arena, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + seq_len <= src.len and std.unicode.utf8ValidateSlice(src[i .. i + seq_len])) {
            try out.appendSlice(self.call_arena, src[i .. i + seq_len]);
            i += seq_len;
        } else {
            try out.appendSlice(self.call_arena, "\u{FFFD}");
            i += 1;
        }
    }
    try out.append(self.call_arena, 0);
    const slice = out.items;
    return slice[0 .. slice.len - 1 :0];
}

pub fn compileAndRun(self: *const Local, src: []const u8, name: ?[]const u8) !js.Value {
    const qctx = self.ctx.ctx;
    const filename = try self.call_arena.dupeZ(u8, name orelse "anonymous");
    const source = try self.prepareSource(src);

    var eval_opts = q.JSEvalOptions{
        .version = q.JS_EVAL_OPTIONS_VERSION,
        .filename = filename.ptr,
        .line_num = 1,
        .eval_flags = q.JS_EVAL_TYPE_GLOBAL,
    };

    const value = q.JS_Eval2(qctx, source.ptr, source.len, &eval_opts);
    if (q.JS_IsException(value)) {
        return error.JsException;
    }
    self.track(value);
    return .{ .local = self, .handle = value };
}

// Compile `src` without running it.
pub fn compile(self: *const Local, src: []const u8, name: ?[]const u8) !js.Script {
    const result = try self.compileWithCache(src, name, null);
    return result.script;
}

pub const CompileResult = struct {
    script: js.Script,
    cache_rejected: bool,
};

// The v8 backend supports a serialized code cache; quickjs compilation is
// cheap enough that we just ignore the cached bytes.
pub fn compileWithCache(self: *const Local, src: []const u8, name: ?[]const u8, cached_data: ?[]const u8) !CompileResult {
    _ = cached_data;
    const qctx = self.ctx.ctx;
    const filename = try self.call_arena.dupeZ(u8, name orelse "anonymous");
    const source = try self.prepareSource(src);

    var eval_opts = q.JSEvalOptions{
        .version = q.JS_EVAL_OPTIONS_VERSION,
        .filename = filename.ptr,
        .line_num = 1,
        .eval_flags = q.JS_EVAL_TYPE_GLOBAL | q.JS_EVAL_FLAG_COMPILE_ONLY,
    };

    const value = q.JS_Eval2(qctx, source.ptr, source.len, &eval_opts);
    if (q.JS_IsException(value)) {
        return error.CompilationError;
    }
    self.track(value);

    return .{
        .script = .{ .local = self, .handle = value },
        .cache_rejected = false,
    };
}

// == Zig -> JS ==

// Copies the prototype's own enumerable (string-keyed) properties onto
// `obj` as its own enumerable properties. Used for `own_properties` types
// (console) where the spec exposes members as the object's own props.
fn copyOwnEnumerableFromProto(qctx: *q.JSContext, obj: q.JSValue) void {
    const proto = q.JS_GetPrototype(qctx, obj);
    defer q.JS_FreeValue(qctx, proto);
    if (q.JS_IsNull(proto) or q.JS_IsException(proto)) {
        return;
    }

    var ptab: [*c]q.JSPropertyEnum = undefined;
    var plen: u32 = 0;
    if (q.JS_GetOwnPropertyNames(qctx, &ptab, &plen, proto, q.JS_GPN_STRING_MASK | q.JS_GPN_ENUM_ONLY) != 0) {
        return;
    }
    defer {
        for (0..plen) |i| q.JS_FreeAtom(qctx, ptab[i].atom);
        q.js_free(qctx, ptab);
    }

    for (0..plen) |i| {
        const atom = ptab[i].atom;
        // console's members are plain functions; JS_GetProperty returns them
        // without side effects (no [Replaceable] accessors live on the proto).
        const val = q.JS_GetProperty(qctx, proto, atom);
        if (q.JS_IsException(val)) {
            q.JS_FreeValue(qctx, val);
            continue;
        }
        // JS_DefinePropertyValue takes ownership of `val`.
        _ = q.JS_DefinePropertyValue(qctx, obj, atom, val, q.JS_PROP_C_W_E);
    }
}

// See v8/Local.zig for the full walkthrough; the identity map keeps a
// strong reference, so the returned wrapper stays valid for the life of
// the page (no handle tracking needed).
pub fn mapZigInstanceToJs(self: *const Local, js_obj_handle: ?q.JSValue, value: anytype) !js.Object {
    const ctx = self.ctx;
    const context_arena = ctx.arena;

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            // Struct, has to be placed on the heap
            const heap = try context_arena.create(T);
            heap.* = value;
            return self.mapZigInstanceToJs(js_obj_handle, heap);
        },
        .pointer => |ptr| {
            const resolved = resolveValue(value);

            const resolved_ptr_id = @intFromPtr(resolved.ptr);
            const gop = try ctx.addIdentity(resolved_ptr_id);
            if (gop.found_existing) {
                // we've seen this instance before, return the same object
                return .{ .local = self, .handle = gop.value_ptr.*.value };
            }

            const qctx = ctx.ctx;
            const JsApi = bridge.Struct(ptr.child).JsApi;

            const js_obj_value = js_obj_handle orelse q.JS_NewObjectClass(qctx, @intCast(resolved.class_id));
            if (js_obj_handle == null) {
                self.track(js_obj_value);
            }

            if (!@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
                // The TAO maps the JS object back to the Zig instance. It
                // lives on the identity_arena so it survives context
                // destruction (the wrapper can outlive its creating
                // context via the page-level identity map).
                const tao = try ctx.identity_arena.create(TaggedOpaque);
                tao.* = .{
                    .value = resolved.ptr,
                    .prototype_chain = resolved.prototype_chain.ptr,
                    .prototype_len = @intCast(resolved.prototype_chain.len),
                };
                _ = q.JS_SetOpaque(js_obj_value, tao);
            }

            // [Replaceable]/namespace types (e.g. console) expose their members
            // as the instance's OWN enumerable properties per spec, so
            // Object.keys/entries see them. attachClass installed them
            // (enumerable) on the prototype; quickjs has no instance template,
            // so copy them onto this fresh instance.
            if (comptime @hasDecl(JsApi.Meta, "own_properties") and JsApi.Meta.own_properties) {
                copyOwnEnumerableFromProto(qctx, js_obj_value);
            }

            // The identity map owns a reference for the life of the scope.
            gop.value_ptr.* = ctx.persist(q.JS_DupValue(qctx, js_obj_value));

            if (resolved.finalizer) |finalizer| {
                const finalizer_ptr_id = finalizer.ptr_id;

                const page = ctx.page;
                const finalizer_gop = try page.finalizer_callbacks.getOrPut(page.frame_arena, finalizer_ptr_id);
                if (finalizer_gop.found_existing == false) {
                    // quickjs never finalizes our wrappers mid-page (the
                    // identity map pins them), so Page teardown is the one
                    // and only release point.
                    errdefer _ = page.finalizer_callbacks.remove(finalizer_ptr_id);
                    finalizer.acquire_ref(finalizer_ptr_id);
                    finalizer_gop.value_ptr.* = try self.createFinalizerCallback(resolved_ptr_id, finalizer_ptr_id, finalizer.release_ref_from_zig);
                }
            }

            return .{ .local = self, .handle = js_obj_value };
        },
        else => @compileError("Expected a struct or pointer, got " ++ @typeName(T) ++ " (constructors must return struct or pointers)"),
    }
}

pub fn zigValueToJs(self: *const Local, value: anytype, comptime opts: CallOpts) !js.Value {
    if (self.simpleZigValueToJs(value, false, opts.null_as_undefined)) |handle| {
        return .{ .local = self, .handle = handle };
    }

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void, .bool, .int, .comptime_int, .float, .comptime_float, .@"enum", .null => {
            // handled by simpleZigValueToJs
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
                    if (registry.JsApiLookup.has(ptr.child.JsApi)) {
                        const js_obj = try self.mapZigInstanceToJs(null, value);
                        return js_obj.toValue();
                    }
                }

                if (@typeInfo(ptr.child) == .@"struct" and @hasDecl(ptr.child, "runtimeGenericWrap")) {
                    const frame = switch (self.ctx.global) {
                        .frame => |f| f,
                        .worker => unreachable,
                    };
                    const wrap = try value.runtimeGenericWrap(frame);
                    return self.zigValueToJs(wrap, opts);
                }

                const one_info = @typeInfo(ptr.child);
                if (one_info == .array and one_info.array.child == u8) {
                    // handled by simpleZigValueToJs
                    unreachable;
                }
            },
            .slice => {
                if (ptr.child == u8) {
                    // handled by simpleZigValueToJs
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
                if (registry.JsApiLookup.has(T.JsApi)) {
                    const js_obj = try self.mapZigInstanceToJs(null, value);
                    return js_obj.toValue();
                }
            }
            if (T == string.String or T == string.Global) {
                // handled by simpleZigValueToJs
                unreachable;
            }

            // zig fmt: off
            switch (T) {
                js.Value => return value,
                js.Exception => {
                    const ex = q.JS_Throw(self.ctx.ctx, q.JS_DupValue(self.ctx.ctx, value.handle));
                    return .{ .local = self, .handle = ex };
                },

                js.ArrayBufferRef(.int8).Global, js.ArrayBufferRef(.uint8).Global,
                js.ArrayBufferRef(.uint8_clamped).Global, js.ArrayBufferRef(.int16).Global,
                js.ArrayBufferRef(.uint16).Global, js.ArrayBufferRef(.int32).Global,
                js.ArrayBufferRef(.uint32).Global, js.ArrayBufferRef(.float16).Global,
                js.ArrayBufferRef(.float32).Global, js.ArrayBufferRef(.float64).Global,
                => {
                    return .{ .local = self, .handle = value.local(self).handle };
                },

                inline
                js.Array,
                js.Function,
                js.Object,
                js.Promise,
                js.String => return .{ .local = self, .handle = value.handle },

                inline
                js.Function.Global,
                js.Function.Temp,
                js.Value.Global,
                js.Value.Temp,
                js.Object.Global,
                js.Promise.Global,
                js.Promise.Temp,
                js.PromiseResolver.Global => return .{ .local = self, .handle = value.local(self).handle },

                js.Undefined => return .{ .local = self, .handle = js.UNDEFINED },

                else => {}
            }
            // zig fmt: on

            if (@hasDecl(T, "runtimeGenericWrap")) {
                const frame = switch (self.ctx.global) {
                    .frame => |f| f,
                    .worker => unreachable,
                };
                const wrap = try value.runtimeGenericWrap(frame);
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

// "Simple" types requiring no identity tracking. Mirrors the v8 backend's
// simpleZigValueToJs (there it's separated because it only needs an
// isolate; here it's just a helper).
pub fn simpleZigValueToJs(self: *const Local, value: anytype, comptime fail: bool, comptime null_as_undefined: bool) if (fail) q.JSValue else ?q.JSValue {
    const qctx = self.ctx.ctx;
    switch (@typeInfo(@TypeOf(value))) {
        .void => return js.UNDEFINED,
        .null => return if (comptime null_as_undefined) js.UNDEFINED else js.NULL,
        .bool => return if (value) js.TRUE else js.FALSE,
        .int => |n| {
            if (comptime n.bits <= 32 and n.signedness == .signed) {
                return q.JS_NewInt32(qctx, value);
            }
            if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
                return q.JS_NewInt32(qctx, @intCast(value));
            }
            if (value >= 0 and value <= 4_294_967_295) {
                return q.JS_NewFloat64(qctx, @floatFromInt(value));
            }
            if (comptime n.signedness == .signed) {
                return q.JS_NewBigInt64(qctx, @intCast(value));
            }
            return q.JS_NewBigUint64(qctx, @intCast(value));
        },
        .comptime_int => {
            if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
                return q.JS_NewInt32(qctx, value);
            }
            if (value > 0 and value <= 4_294_967_295) {
                return q.JS_NewFloat64(qctx, value);
            }
            return q.JS_NewBigInt64(qctx, value);
        },
        .float, .comptime_float => return q.JS_NewFloat64(qctx, value),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return self.newString(value).handle;
            }
            if (ptr.size == .one) {
                const one_info = @typeInfo(ptr.child);
                if (one_info == .array and one_info.array.child == u8) {
                    return self.newString(value).handle;
                }
            }
        },
        .array => return self.simpleZigValueToJs(&value, fail, null_as_undefined),
        .optional => {
            if (value) |v| {
                return self.simpleZigValueToJs(v, fail, null_as_undefined);
            }
            return if (comptime null_as_undefined) js.UNDEFINED else js.NULL;
        },
        .@"struct" => {
            switch (@TypeOf(value)) {
                string.String => return self.newString(value.str()).handle,
                js.String.OneByte => return self.newOneByteString(value.bytes).handle,
                js.ArrayBuffer => {
                    const handle = q.JS_NewArrayBufferCopy(qctx, value.values.ptr, value.values.len);
                    self.track(handle);
                    return handle;
                },
                // zig fmt: off
                js.TypedArray(u8), js.TypedArray(u16), js.TypedArray(u32), js.TypedArray(u64),
                js.TypedArray(i8), js.TypedArray(i16), js.TypedArray(i32), js.TypedArray(i64),
                js.TypedArray(f32), js.TypedArray(f64),
                // zig fmt: on
                => {
                    const values = value.values;
                    const value_type = @typeInfo(@TypeOf(values)).pointer.child;
                    const bytes: []const u8 = @ptrCast(values);

                    const buffer = q.JS_NewArrayBufferCopy(qctx, bytes.ptr, bytes.len);
                    defer q.JS_FreeValue(qctx, buffer);

                    const array_type: q.JSTypedArrayEnum = switch (@typeInfo(value_type)) {
                        .int => |n| switch (n.signedness) {
                            .unsigned => switch (n.bits) {
                                8 => q.JS_TYPED_ARRAY_UINT8,
                                16 => q.JS_TYPED_ARRAY_UINT16,
                                32 => q.JS_TYPED_ARRAY_UINT32,
                                64 => q.JS_TYPED_ARRAY_BIG_UINT64,
                                else => @compileError("Invalid TypeArray type: " ++ @typeName(value_type)),
                            },
                            .signed => switch (n.bits) {
                                8 => q.JS_TYPED_ARRAY_INT8,
                                16 => q.JS_TYPED_ARRAY_INT16,
                                32 => q.JS_TYPED_ARRAY_INT32,
                                64 => q.JS_TYPED_ARRAY_BIG_INT64,
                                else => @compileError("Invalid TypeArray type: " ++ @typeName(value_type)),
                            },
                        },
                        .float => |f| switch (f.bits) {
                            32 => q.JS_TYPED_ARRAY_FLOAT32,
                            64 => q.JS_TYPED_ARRAY_FLOAT64,
                            else => @compileError("Invalid TypeArray type: " ++ @typeName(value_type)),
                        },
                        else => @compileError("Invalid TypeArray type: " ++ @typeName(value_type)),
                    };

                    // JS_NewTypedArray invokes `new TA(argv...)`, and the
                    // typed-array constructor reads argv[1]/argv[2] as
                    // byte-offset/length. Passing only the buffer leaves those
                    // as out-of-bounds garbage (yielding a zero-length view);
                    // explicit undefineds mean "offset 0, full buffer".
                    var args = [_]q.JSValue{ buffer, js.UNDEFINED, js.UNDEFINED };
                    const handle = q.JS_NewTypedArray(qctx, args.len, &args, array_type);
                    self.track(handle);
                    return handle;
                },
                inline js.String, js.Value, js.Object => return @as(q.JSValue, value.handle),
                else => {},
            }
        },
        .@"union" => return self.simpleZigValueToJs(std.meta.activeTag(value), fail, null_as_undefined),
        .@"enum" => {
            const T = @TypeOf(value);
            if (@hasDecl(T, "toString")) {
                return self.simpleZigValueToJs(value.toString(), fail, null_as_undefined);
            }
        },
        else => {},
    }
    if (fail) {
        @compileError("Unsupported Zig type " ++ @typeName(@TypeOf(value)));
    }
    return null;
}

fn zigJsonToJs(self: *const Local, value: std.json.Value) !js.Value {
    switch (value) {
        .bool => |v| return .{ .local = self, .handle = self.simpleZigValueToJs(v, true, false) },
        .float => |v| return .{ .local = self, .handle = self.simpleZigValueToJs(v, true, false) },
        .integer => |v| return .{ .local = self, .handle = self.simpleZigValueToJs(v, true, false) },
        .string => |v| return .{ .local = self, .handle = self.simpleZigValueToJs(v, true, false) },
        .null => return .{ .local = self, .handle = js.NULL },
        .number_string => return error.TODO,
        .array => |v| {
            const js_arr = self.newArray(@intCast(v.items.len));
            for (v.items, 0..) |array_value, i| {
                if (try js_arr.set(@intCast(i), array_value, .{}) == false) {
                    return error.JSObjectSetValue;
                }
            }
            return js_arr.toValue();
        },
        .object => |v| {
            var js_obj = self.newObject();
            var it = v.iterator();
            while (it.next()) |kv| {
                if (try js_obj.set(kv.key_ptr.*, kv.value_ptr.*, .{}) == false) {
                    return error.JSObjectSetValue;
                }
            }
            return js_obj.toValue();
        },
    }
}

// == JS -> Zig ==

pub fn jsValueToZig(self: *const Local, comptime T: type, js_val: js.Value) !T {
    switch (@typeInfo(T)) {
        .optional => |o| {
            // see v8/Local.zig for the ?js.Value / ?js.Object rationale
            if (comptime o.child == js.Value) {
                return js_val;
            }

            if (comptime o.child == js.NullableString) {
                if (js_val.isUndefined()) {
                    return null;
                }
                return .{ .value = try js_val.toStringSlice() };
            }

            if (comptime o.child == js.Object) {
                return js.Object{
                    .local = self,
                    .handle = js_val.handle,
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
                if (@hasDecl(ptr.child, "JsApi")) {
                    std.debug.assert(registry.JsApiLookup.has(ptr.child.JsApi));
                    return TaggedOpaque.fromJS(*ptr.child, self.ctx, js_val.handle);
                }
            },
            .slice => {
                if (ptr.sentinel() == null) {
                    if (try self.jsValueToTypedArray(ptr.child, js_val)) |value| {
                        return value;
                    }
                }

                if (ptr.child == u8) {
                    if (ptr.sentinel()) |s| {
                        if (comptime s == 0) {
                            return try js_val.toStringSliceZ();
                        }
                    } else {
                        return try js_val.toStringSlice();
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
            const slice_type = []arr.child;
            const slice_value = try self.jsValueToZig(slice_type, js_val);
            if (slice_value.len != arr.len) {
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
            // see v8/Local.zig probeJsValueToZig
            var coerce_index: ?usize = null;
            var compatible_index: ?usize = null;
            inline for (u.fields, 0..) |field, i| {
                switch (try self.probeJsValueToZig(field.type, js_val)) {
                    .value => |v| return @unionInit(T, field.name, v),
                    .ok => {
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
                const js_str = js_val.isString() orelse return error.InvalidArgument;
                return std.meta.stringToEnum(T, try js_str.toSlice()) orelse return error.InvalidArgument;
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

fn jsValueToStruct(self: *const Local, comptime T: type, js_val: js.Value) !?T {
    return switch (T) {
        js.Function, js.Function.Global, js.Function.Temp => {
            if (!js_val.isFunction()) {
                return null;
            }
            const js_func = js.Function{ .local = self, .handle = js_val.handle };
            return switch (T) {
                js.Function => js_func,
                js.Function.Temp => try js_func.temp(),
                js.Function.Global => try js_func.persist(),
                else => unreachable,
            };
        },
        // zig fmt: off
        js.TypedArray(u8), js.TypedArray(u16), js.TypedArray(u32), js.TypedArray(u64),
        js.TypedArray(i8), js.TypedArray(i16), js.TypedArray(i32), js.TypedArray(i64),
        js.TypedArray(f32), js.TypedArray(f64),
        // zig fmt: on
        => {
            const ValueType = @typeInfo(std.meta.fieldInfo(T, .values).type).pointer.child;
            const arr = (try self.jsValueToTypedArray(ValueType, js_val)) orelse return null;
            return .{ .values = arr };
        },
        js.Value => js_val,
        js.Value.Global => return try js_val.persist(),
        js.Value.Temp => return try js_val.temp(),
        js.Object => {
            if (!js_val.isObject()) {
                return null;
            }
            return js.Object{
                .local = self,
                .handle = js_val.handle,
            };
        },
        js.Object.Global => {
            if (!js_val.isObject()) {
                return null;
            }
            const obj = js.Object{
                .local = self,
                .handle = js_val.handle,
            };
            return try obj.persist();
        },
        js.Promise.Global, js.Promise.Temp => {
            if (!js_val.isPromise()) {
                return null;
            }
            const js_promise = js.Promise{
                .local = self,
                .handle = js_val.handle,
            };
            return switch (T) {
                js.Promise.Temp => try js_promise.temp(),
                js.Promise.Global => try js_promise.persist(),
                else => unreachable,
            };
        },
        js.String => return js_val.isString(),
        js.String.OneByte => {
            // See v8/Local.zig: a "binary string" - each JS code unit must
            // fit in a byte.
            const js_str = js_val.isString() orelse return null;
            if (!js_str.containsOnlyOneByte()) return error.InvalidCharacterError;
            return .{ .bytes = try js_str.toOneByteSlice(self.call_arena) };
        },
        string.String => try js_val.toSSO(false),
        string.Global => try js_val.toSSO(true),
        else => {
            if (!js_val.isObject()) {
                return null;
            }

            const js_obj = js_val.toObject();

            var value: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const name = field.name;
                if (js_obj.has(name)) {
                    @field(value, name) = try self.jsValueToZig(field.type, try js_obj.get(name));
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

fn jsValueToTypedArray(self: *const Local, comptime T: type, js_val: js.Value) !?[]T {
    const qctx = self.ctx.ctx;

    var force_u8 = false;
    var buffer: q.JSValue = js.UNDEFINED;
    var byte_offset: usize = 0;
    var byte_len: usize = 0;

    const array_type = q.JS_GetTypedArrayType(js_val.handle);
    if (array_type >= 0) {
        var bytes_per_element: usize = 0;
        buffer = q.JS_GetTypedArrayBuffer(qctx, js_val.handle, &byte_offset, &byte_len, &bytes_per_element);
        if (q.JS_IsException(buffer)) {
            return error.InvalidArgument;
        }
        self.track(buffer);
    } else if (q.JS_IsArrayBuffer(js_val.handle)) {
        force_u8 = true;
        buffer = js_val.handle;
        var size: usize = 0;
        _ = q.JS_GetArrayBuffer(qctx, &size, buffer) orelse return error.InvalidArgument;
        byte_len = size;
    } else {
        return null;
    }

    if (byte_len == 0) {
        return &[_]T{};
    }

    var size: usize = 0;
    const data = q.JS_GetArrayBuffer(qctx, &size, buffer) orelse return error.InvalidArgument;
    const base = data + byte_offset;

    if (@intFromPtr(base) % @alignOf(T) != 0) {
        return error.InvalidAlignment;
    }
    const num_elements = byte_len / @sizeOf(T);

    if (force_u8) {
        if (T != u8) return error.InvalidArgument;
        const ptr = @as([*]T, @ptrCast(@alignCast(base)));
        return ptr[0..num_elements];
    }

    const expected: c_int = switch (T) {
        u8 => blk: {
            if (array_type == q.JS_TYPED_ARRAY_UINT8C) break :blk q.JS_TYPED_ARRAY_UINT8C;
            break :blk q.JS_TYPED_ARRAY_UINT8;
        },
        i8 => q.JS_TYPED_ARRAY_INT8,
        u16 => q.JS_TYPED_ARRAY_UINT16,
        i16 => q.JS_TYPED_ARRAY_INT16,
        u32 => q.JS_TYPED_ARRAY_UINT32,
        i32 => q.JS_TYPED_ARRAY_INT32,
        u64 => q.JS_TYPED_ARRAY_BIG_UINT64,
        i64 => q.JS_TYPED_ARRAY_BIG_INT64,
        f32 => q.JS_TYPED_ARRAY_FLOAT32,
        f64 => q.JS_TYPED_ARRAY_FLOAT64,
        else => return error.InvalidArgument,
    };

    if (array_type != expected) {
        // u8 also accepts any view as raw bytes, mirroring the v8 backend's
        // ArrayBufferView handling.
        if (T != u8) {
            return error.InvalidArgument;
        }
    }

    const ptr = @as([*]T, @ptrCast(@alignCast(base)));
    return ptr[0..num_elements];
}

fn probeJsValueToZig(self: *const Local, comptime T: type, js_val: js.Value) !marshal.ProbeResult(T) {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (js_val.isNullOrUndefined()) {
                return .{ .value = null };
            }
            return self.probeJsValueToZig(o.child, js_val);
        },
        .float => {
            if (js_val.isNumber()) {
                if (js_val.isInt32() or js_val.isBigInt()) {
                    return .{ .compatible = {} };
                }
                return .{ .ok = {} };
            }
            return .{ .coerce = {} };
        },
        .int => {
            if (js_val.isNumber()) {
                if (js_val.isInt32() or js_val.isBigInt()) {
                    return .{ .ok = {} };
                }
                return .{ .compatible = {} };
            }
            return .{ .coerce = {} };
        },
        .bool => {
            if (js_val.isBoolean()) {
                return .{ .ok = {} };
            }
            return .{ .coerce = {} };
        },
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                if (!js_val.isObject()) {
                    return .{ .invalid = {} };
                }
                if (registry.JsApiLookup.has(ptr.child.JsApi)) {
                    const attempt = TaggedOpaque.fromJS(*ptr.child, self.ctx, js_val.handle);
                    if (attempt) |value| {
                        return .{ .value = value };
                    } else |_| {
                        return .{ .invalid = {} };
                    }
                }
                return .{ .invalid = {} };
            },
            .slice => {
                if (js_val.isTypedArray()) {
                    const array_type = q.JS_GetTypedArrayType(js_val.handle);
                    const matches = switch (ptr.child) {
                        u8 => ptr.sentinel() == null and (array_type == q.JS_TYPED_ARRAY_UINT8 or array_type == q.JS_TYPED_ARRAY_UINT8C),
                        i8 => array_type == q.JS_TYPED_ARRAY_INT8,
                        u16 => array_type == q.JS_TYPED_ARRAY_UINT16,
                        i16 => array_type == q.JS_TYPED_ARRAY_INT16,
                        u32 => array_type == q.JS_TYPED_ARRAY_UINT32,
                        i32 => array_type == q.JS_TYPED_ARRAY_INT32,
                        u64 => array_type == q.JS_TYPED_ARRAY_BIG_UINT64,
                        i64 => array_type == q.JS_TYPED_ARRAY_BIG_INT64,
                        f32 => array_type == q.JS_TYPED_ARRAY_FLOAT32,
                        f64 => array_type == q.JS_TYPED_ARRAY_FLOAT64,
                        else => false,
                    };
                    return if (matches) .{ .ok = {} } else .{ .invalid = {} };
                }

                if (ptr.child == u8) {
                    if (js_val.isString() != null) {
                        return .{ .ok = {} };
                    }
                    return .{ .coerce = {} };
                }

                if (!js_val.isArray()) {
                    return .{ .invalid = {} };
                }

                const js_arr = js_val.toArray();
                if (js_arr.len() == 0) {
                    return .{ .value = &.{} };
                }

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
            const slice_type = []arr.child;
            switch (try self.probeJsValueToZig(slice_type, js_val)) {
                .value => |slice_value| {
                    if (slice_value.len == arr.len) {
                        return .{ .value = @as(*T, @ptrCast(slice_value.ptr)).* };
                    }
                    return .{ .invalid = {} };
                },
                .ok => {
                    if (js_val.isArray()) {
                        const js_arr = js_val.toArray();
                        if (js_arr.len() == arr.len) {
                            return .{ .ok = {} };
                        }
                    } else if (arr.child == u8) {
                        if (js_val.isString()) |js_str| {
                            if (js_str.len() == arr.len) {
                                return .{ .ok = {} };
                            }
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
            if (T == string.String or T == string.Global) {
                if (js_val.isString() != null) {
                    return .{ .ok = {} };
                }
                return .{ .coerce = {} };
            }

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
            8 => return marshal.jsSignedIntToZig(i8, -128, 127, try js_value.toI32()),
            16 => return marshal.jsSignedIntToZig(i16, -32_768, 32_767, try js_value.toI32()),
            32 => return marshal.jsSignedIntToZig(i32, -2_147_483_648, 2_147_483_647, try js_value.toI32()),
            64 => {
                if (js_value.isBigInt()) {
                    return js_value.toI64();
                }
                return marshal.jsSignedIntToZig(i64, -2_147_483_648, 2_147_483_647, try js_value.toI32());
            },
            else => {},
        },
        .unsigned => switch (n.bits) {
            8 => return marshal.jsUnsignedIntToZig(u8, 255, try js_value.toU32()),
            16 => return marshal.jsUnsignedIntToZig(u16, 65_535, try js_value.toU32()),
            32 => {
                if (js_value.isBigInt()) {
                    const large = try js_value.toU64();
                    if (large <= 4_294_967_295) {
                        return @intCast(large);
                    }
                    return error.InvalidArgument;
                }
                return marshal.jsUnsignedIntToZig(u32, 4_294_967_295, try js_value.toU32());
            },
            64 => {
                if (js_value.isBigInt()) {
                    return js_value.toU64();
                }
                return marshal.jsUnsignedIntToZig(u64, 4_294_967_295, try js_value.toU32());
            },
            else => {},
        },
    }
    @compileError("Only i8, i16, i32, i64, u8, u16, u32 and u64 are supported");
}

// See v8/Local.zig resolveValue: walks the _type union to the most
// specific type and finds the finalizer (acquireRef) owner.
const Resolved = struct {
    ptr: *anyopaque,
    class_id: u32,
    prototype_chain: []const registry.PrototypeChainEntry,
    finalizer: ?Finalizer,

    const Finalizer = struct {
        ptr_id: usize,
        acquire_ref: *const fn (ptr_id: usize) void,
        release_ref_from_zig: *const fn (ptr_id: usize, page: *Page) void,
    };
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
                    return resolveT(T, value);
                },
                else => @compileError(@typeName(field.type) ++ " has an unsupported _type field"),
            };
            return resolveValue(child);
        }
    }
    unreachable;
}

fn resolveT(comptime T: type, value: *T) Resolved {
    const Meta = T.JsApi.Meta;
    return .{
        .ptr = value,
        .class_id = Meta.class_id,
        .prototype_chain = &Meta.prototype_chain,
        .finalizer = blk: {
            const FT = (comptime marshal.findFinalizerType(T)) orelse break :blk null;
            const getFinalizerPtr = comptime marshal.finalizerPtrGetter(T, FT);
            const finalizer_ptr = getFinalizerPtr(value);

            const Wrap = struct {
                fn acquireRef(ptr_id: usize) void {
                    FT.acquireRef(@ptrFromInt(ptr_id));
                }

                fn releaseRefFromZig(ptr_id: usize, page: *Page) void {
                    FT.releaseRef(@ptrFromInt(ptr_id), page);
                }
            };
            break :blk .{
                .ptr_id = @intFromPtr(finalizer_ptr),
                .acquire_ref = Wrap.acquireRef,
                .release_ref_from_zig = Wrap.releaseRefFromZig,
            };
        },
    };
}

fn createFinalizerCallback(
    self: *const Local,
    resolved_ptr_id: usize,
    finalizer_ptr_id: usize,
    release_ref: *const fn (ptr_id: usize, page: *Page) void,
) !*FinalizerCallback {
    const page = self.ctx.page;

    const arena = try page.getArena(.tiny, "FinalizerCallback");
    errdefer page.releaseArena(arena);

    const fc = try arena.create(FinalizerCallback);
    fc.* = .{
        .page = page,
        .arena = arena,
        .release_ref = release_ref,
        .resolved_ptr_id = resolved_ptr_id,
        .finalizer_ptr_id = finalizer_ptr_id,
    };
    return fc;
}

pub fn stackTrace(self: *const Local) !?[]const u8 {
    // quickjs only exposes stacks on Error objects; there's no API for the
    // current stack outside of an exception. Used for debug logging only.
    _ = self;
    return null;
}

// == Promise Helpers ==
pub fn rejectPromise(self: *const Local, err: js.PromiseResolver.RejectError) js.Promise {
    var resolver = js.PromiseResolver.init(self);
    resolver.rejectError("Local.rejectPromise", err);
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
    const str = js_val.toStringSlice() catch "???";
    writer.writeAll(str) catch return error.WriteFailed;
    _ = self;
}

pub fn parseJSON(self: *const Local, json: []const u8) !js.Value {
    // @QJS: Should we change the input type to be [:0]const u8
    const null_terminated = try self.call_arena.dupeZ(u8, json);
    const handle = q.JS_ParseJSON(self.ctx.ctx, null_terminated.ptr, null_terminated.len, "<json>");
    if (q.JS_IsException(handle)) {
        return error.JsException;
    }
    self.track(handle);
    return .{ .local = self, .handle = handle };
}

pub fn newException(self: *const Local, ex: anytype) js.Exception {
    const js_val = self.zigValueToJs(ex, .{}) catch {
        const qctx = self.ctx.ctx;
        const err = q.JS_NewError(qctx);
        self.track(err);
        return .{ .local = self, .handle = err };
    };
    return .{ .local = self, .handle = js_val.handle };
}

pub fn getGlobal(self: *const Local) js.Object {
    const handle = q.JS_GetGlobalObject(self.ctx.ctx);
    self.track(handle);
    return .{ .local = self, .handle = handle };
}

// Convert a Global (or optional Global) to a Local (or optional Local).
pub fn toLocal(self: *const Local, global: anytype) ToLocalReturnType(@TypeOf(global)) {
    const T = @TypeOf(global);
    if (@typeInfo(T) == .optional) {
        const unwrapped = global orelse return null;
        return unwrapped.local(self);
    }
    return global.local(self);
}

pub const ToLocalReturnType = marshal.ToLocalReturnType;

// Encapsulates a "handle scope" for Zig -> JS calls. See v8/Local.zig for
// when a Scope is required.
pub const Scope = struct {
    local: Local,
    mark: usize,

    // quickjs has no HandleScope, but shared callers take its address
    // (`self.js.enter(&ls.handle_scope)` in Frame.zig); a zero-bit stub
    // keeps those call sites engine-neutral.
    handle_scope: js.HandleScope = .{},

    pub fn deinit(self: *Scope) void {
        self.local.ctx.freeHandles(self.mark);
    }

    pub fn toLocal(self: *Scope, global: anytype) ToLocalReturnType(@TypeOf(global)) {
        return self.local.toLocal(global);
    }
};
