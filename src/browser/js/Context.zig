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

const log = @import("../../log.zig");

const js = @import("js.zig");
const v8 = js.v8;

const bridge = @import("bridge.zig");
const Caller = bridge.Caller;

const Page = @import("../Page.zig");
const ScriptManager = @import("../ScriptManager.zig");

const Allocator = std.mem.Allocator;
const TaggedAnyOpaque = js.TaggedAnyOpaque;

const IS_DEBUG = @import("builtin").mode == .Debug;

// Loosely maps to a Browser Page.
const Context = @This();

id: usize,
page: *Page,
isolate: js.Isolate,
// This context is a persistent object. The persistent needs to be recovered and reset.
handle: *const v8.Context,

handle_scope: ?js.HandleScope,

cpu_profiler: ?*v8.CpuProfiler = null,

// references Env.templates
templates: []*const v8.FunctionTemplate,

// Arena for the lifetime of the context
arena: Allocator,

// The page.call_arena
call_arena: Allocator,

// Because calls can be nested (i.e.a function calling a callback),
// we can only reset the call_arena when call_depth == 0. If we were
// to reset it within a callback, it would invalidate the data of
// the call which is calling the callback.
call_depth: usize = 0,

// Serves two purposes. Like `global_objects`, this is used to free
// every Global(Object) we've created during the lifetime of the context.
// More importantly, it serves as an identity map - for a given Zig
// instance, we map it to the same Global(Object).
// The key is the @intFromPtr of the Zig value
identity_map: std.AutoHashMapUnmanaged(usize, js.Global(js.Object)) = .empty,

// Some web APIs have to manage opaque values. Ideally, they use an
// js.Object, but the js.Object has no lifetime guarantee beyond the
// current call. They can call .persist() on their js.Object to get
// a `Global(Object)`. We need to track these to free them.
// This used to be a map and acted like identity_map; the key was
// the @intFromPtr(js_obj.handle). But v8 can re-use address. Without
// a reliable way to know if an object has already been persisted,
// we now simply persist every time persist() is called.
global_values: std.ArrayList(v8.Global) = .empty,
global_objects: std.ArrayList(v8.Global) = .empty,
global_modules: std.ArrayList(v8.Global) = .empty,
global_promises: std.ArrayList(v8.Global) = .empty,
global_functions: std.ArrayList(v8.Global) = .empty,
global_promise_resolvers: std.ArrayList(v8.Global) = .empty,

// Our module cache: normalized module specifier => module.
module_cache: std.StringHashMapUnmanaged(ModuleEntry) = .empty,

// Module => Path. The key is the module hashcode (module.getIdentityHash)
// and the value is the full path to the module. We need to capture this
// so that when we're asked to resolve a dependent module, and all we're
// given is the specifier, we can form the full path. The full path is
// necessary to lookup/store the dependent module in the module_cache.
module_identifier: std.AutoHashMapUnmanaged(u32, [:0]const u8) = .empty,

// the page's script manager
script_manager: ?*ScriptManager,

const ModuleEntry = struct {
    // Can be null if we're asynchrously loading the module, in
    // which case resolver_promise cannot be null.
    module: ?js.Module.Global = null,

    // The promise of the evaluating module. The resolved value is
    // meaningless to us, but the resolver promise needs to chain
    // to this, since we need to know when it's complete.
    module_promise: ?js.Promise.Global = null,

    // The promise for the resolver which is loading the module.
    // (AKA, the first time we try to load it). This resolver will
    // chain to the module_promise  and, when it's done evaluating
    // will resolve its namespace. Any other attempt to load the
    // module willchain to this.
    resolver_promise: ?js.Promise.Global = null,
};

pub fn fromC(c_context: *const v8.Context) *Context {
    const data = v8.v8__Context__GetEmbedderData(c_context, 1).?;
    const big_int = js.BigInt{ .handle = @ptrCast(data) };
    return @ptrFromInt(big_int.getUint64());
}

pub fn fromIsolate(isolate: js.Isolate) *Context {
    const v8_context = v8.v8__Isolate__GetCurrentContext(isolate.handle).?;
    const data = v8.v8__Context__GetEmbedderData(v8_context, 1).?;
    const big_int = js.BigInt{ .handle = @ptrCast(data) };
    return @ptrFromInt(big_int.getUint64());
}

pub fn setupGlobal(self: *Context) !void {
    const global = v8.v8__Context__Global(self.handle).?;
    _ = try self.mapZigInstanceToJs(global, self.page.window);
}

pub fn deinit(self: *Context) void {
    {
        var it = self.identity_map.valueIterator();
        while (it.next()) |p| {
            p.deinit();
        }
    }

    for (self.global_values.items) |*global| {
        v8.v8__Global__Reset(global);
    }

    for (self.global_objects.items) |*global| {
        v8.v8__Global__Reset(global);
    }

    for (self.global_modules.items) |*global| {
        v8.v8__Global__Reset(global);
    }

    for (self.global_functions.items) |*global| {
        v8.v8__Global__Reset(global);
    }

    for (self.global_promises.items) |*global| {
        v8.v8__Global__Reset(global);
    }

    for (self.global_promise_resolvers.items) |*global| {
        v8.v8__Global__Reset(global);
    }

    if (self.handle_scope) |*scope| {
        v8.v8__Context__Exit(self.handle);
        scope.deinit();
    }
}

// == Executors ==
pub fn eval(self: *Context, src: []const u8, name: ?[]const u8) !void {
    _ = try self.exec(src, name);
}

pub fn exec(self: *Context, src: []const u8, name: ?[]const u8) !js.Value {
    return self.compileAndRun(src, name);
}

pub fn module(self: *Context, comptime want_result: bool, src: []const u8, url: []const u8, cacheable: bool) !(if (want_result) ModuleEntry else void) {
    const mod, const owned_url = blk: {
        const arena = self.arena;

        // gop will _always_ initiated if cacheable == true
        var gop: std.StringHashMapUnmanaged(ModuleEntry).GetOrPutResult = undefined;
        if (cacheable) {
            gop = try self.module_cache.getOrPut(arena, url);
            if (gop.found_existing) {
                if (gop.value_ptr.module != null) {
                    return if (comptime want_result) gop.value_ptr.* else {};
                }
            } else {
                // first time seing this
                gop.value_ptr.* = .{};
            }
        }

        const owned_url = try arena.dupeZ(u8, url);
        const m = try self.compileModule(src, owned_url);

        if (cacheable) {
            // compileModule is synchronous - nothing can modify the cache during compilation
            std.debug.assert(gop.value_ptr.module == null);
            gop.value_ptr.module = try m.persist();
            if (!gop.found_existing) {
                gop.key_ptr.* = owned_url;
            }
        }

        break :blk .{ m, owned_url };
    };

    try self.postCompileModule(mod, owned_url);

    if (try mod.instantiate(resolveModuleCallback) == false) {
        return error.ModuleInstantiationError;
    }

    const evaluated = mod.evaluate() catch {
        std.debug.assert(mod.getStatus() == .kErrored);

        // Some module-loading errors aren't handled by TryCatch. We need to
        // get the error from the module itself.
        log.warn(.js, "evaluate module", .{
            .specifier = owned_url,
            .message = mod.getException().toString(.{}) catch "???",
        });
        return error.EvaluationError;
    };

    // https://v8.github.io/api/head/classv8_1_1Module.html#a1f1758265a4082595757c3251bb40e0f
    // Must be a promise that gets returned here.
    std.debug.assert(evaluated.isPromise());

    if (comptime !want_result) {
        // avoid creating a bunch of persisted objects if it isn't
        // cacheable and the caller doesn't care about results.
        // This is pretty common, i.e. every <script type=module>
        // within the html page.
        if (!cacheable) {
            return;
        }
    }

    // anyone who cares about the result, should also want it to
    // be cached
    std.debug.assert(cacheable);

    // entry has to have been created atop this function
    const entry = self.module_cache.getPtr(owned_url).?;

    // and the module must have been set after we compiled it
    std.debug.assert(entry.module != null);
    std.debug.assert(entry.module_promise == null);

    entry.module_promise = try evaluated.toPromise().persist();
    return if (comptime want_result) entry.* else {};
}

// This isn't expected to be called often. It's for converting attributes into
// function calls, e.g. <body onload="doSomething"> will turn that "doSomething"
// string into a js.Function which looks like: function(e) { doSomething(e) }
// There might be more efficient ways to do this, but doing it this way means
// our code only has to worry about js.Funtion, not some union of a js.Function
// or a string.
pub fn stringToFunction(self: *Context, str: []const u8) !js.Function {
    var extra: []const u8 = "";
    const normalized = std.mem.trim(u8, str, &std.ascii.whitespace);
    if (normalized.len > 0 and normalized[normalized.len - 1] != ')') {
        extra = "(e)";
    }
    const full = try std.fmt.allocPrintSentinel(self.call_arena, "(function(e) {{ {s}{s} }})", .{ normalized, extra }, 0);

    const js_value = try self.compileAndRun(full, null);
    if (!js_value.isFunction()) {
        return error.StringFunctionError;
    }
    return self.newFunction(js_value);
}

// After we compile a module, whether it's a top-level one, or a nested one,
// we always want to track its identity (so that, if this module imports other
// modules, we can resolve the full URL), and preload any dependent modules.
fn postCompileModule(self: *Context, mod: js.Module, url: [:0]const u8) !void {
    try self.module_identifier.putNoClobber(self.arena, mod.getIdentityHash(), url);

    // Non-async modules are blocking. We can download them in parallel, but
    // they need to be processed serially. So we want to get the list of
    // dependent modules this module has and start downloading them asap.
    const requests = mod.getModuleRequests();
    const request_len = requests.len();
    const script_manager = self.script_manager.?;
    for (0..request_len) |i| {
        const specifier = try self.jsStringToZigZ(requests.get(i).specifier(), .{});
        const normalized_specifier = try script_manager.resolveSpecifier(
            self.call_arena,
            url,
            specifier,
        );
        const nested_gop = try self.module_cache.getOrPut(self.arena, normalized_specifier);
        if (!nested_gop.found_existing) {
            const owned_specifier = try self.arena.dupeZ(u8, normalized_specifier);
            nested_gop.key_ptr.* = owned_specifier;
            nested_gop.value_ptr.* = .{};
            try script_manager.preloadImport(owned_specifier, url);
        }
    }
}

// == Creators ==
pub fn newFunction(self: *Context, js_value: js.Value) !js.Function {
    // caller should have made sure this was a function
    if (comptime IS_DEBUG) {
        std.debug.assert(js_value.isFunction());
    }

    return .{
        .ctx = self,
        .handle = @ptrCast(js_value.handle),
    };
}

pub fn newString(self: *Context, str: []const u8) js.String {
    return .{
        .ctx = self,
        .handle = self.isolate.initStringHandle(str),
    };
}

pub fn newObject(self: *Context) js.Object {
    return .{
        .ctx = self,
        .handle = v8.v8__Object__New(self.isolate.handle).?,
    };
}

pub fn newArray(self: *Context, len: u32) js.Array {
    return .{
        .ctx = self,
        .handle = v8.v8__Array__New(self.isolate.handle, @intCast(len)).?,
    };
}

fn newFunctionWithData(self: *Context, comptime callback: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void, data: *anyopaque) js.Function {
    const external = self.isolate.createExternal(data);
    const handle = v8.v8__Function__New__DEFAULT2(self.handle, callback, @ptrCast(external)).?;
    return .{
        .ctx = self,
        .handle = handle,
    };
}

pub fn parseJSON(self: *Context, json: []const u8) !js.Value {
    const string_handle = self.isolate.initStringHandle(json);
    const value_handle = v8.v8__JSON__Parse(self.handle, string_handle) orelse return error.JsException;
    return .{
        .ctx = self,
        .handle = value_handle,
    };
}

pub fn throw(self: *Context, err: []const u8) js.Exception {
    const handle = self.isolate.createError(err);
    return .{
        .ctx = self,
        .handle = handle,
    };
}

pub fn debugContextId(self: *const Context) i32 {
    return v8.v8__Context__DebugContextId(self.handle);
}

pub fn zigValueToJs(self: *Context, value: anytype, comptime opts: Caller.CallOpts) !js.Value {
    const isolate = self.isolate;

    // Check if it's a "simple" type. This is extracted so that it can be
    // reused by other parts of the code. "simple" types only require an
    // isolate to create (specifically, they don't our templates array)
    if (js.simpleZigValueToJs(isolate, value, false, opts.null_as_undefined)) |js_value_handle| {
        return .{ .ctx = self, .handle = js_value_handle };
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
                    const wrap = try value.runtimeGenericWrap(self.page);
                    return zigValueToJs(self, wrap, opts);
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
                return .{ .ctx = self, .handle = @ptrCast(value.handle) };
            }

            if (T == js.Function.Global) {
                // Auto-convert Global to local for bridge
                return .{ .ctx = self, .handle = @ptrCast(value.local().handle) };
            }

            if (T == js.Object) {
                // we're returning a v8.Object
                return .{ .ctx = self, .handle = @ptrCast(value.handle) };
            }

            if (T == js.Object.Global) {
                // Auto-convert Global to local for bridge
                return .{ .ctx = self, .handle = @ptrCast(value.local().handle) };
            }

            if (T == js.Value.Global) {
                // Auto-convert Global to local for bridge
                return .{ .ctx = self, .handle = @ptrCast(value.local().handle) };
            }

            if (T == js.Promise.Global) {
                // Auto-convert Global to local for bridge
                return .{ .ctx = self, .handle = @ptrCast(value.local().handle) };
            }

            if (T == js.PromiseResolver.Global) {
                // Auto-convert Global to local for bridge
                return .{ .ctx = self, .handle = @ptrCast(value.local().handle) };
            }

            if (T == js.Module.Global) {
                // Auto-convert Global to local for bridge
                return .{ .ctx = self, .handle = @ptrCast(value.local().handle) };
            }

            if (T == js.Value) {
                return value;
            }

            if (T == js.Promise) {
                return .{ .ctx = self, .handle = @ptrCast(value.handle) };
            }

            if (T == js.Exception) {
                return .{ .ctx = self, .handle = isolate.throwException(value.handle) };
            }

            if (T == js.String) {
                return .{ .ctx = self, .handle = @ptrCast(value.handle) };
            }

            if (@hasDecl(T, "runtimeGenericWrap")) {
                const wrap = try value.runtimeGenericWrap(self.page);
                return zigValueToJs(self, wrap, opts);
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
                return zigJsonToJs(self, value);
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
pub fn mapZigInstanceToJs(self: *Context, js_obj_handle: ?*const v8.Object, value: anytype) !js.Object {
    const arena = self.arena;

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

            const gop = try self.identity_map.getOrPut(arena, @intFromPtr(resolved.ptr));
            if (gop.found_existing) {
                // we've seen this instance before, return the same object
                return .{ .ctx = self, .handle = gop.value_ptr.*.local() };
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
                .ctx = self,
                .handle = js_obj_handle orelse blk: {
                    const function_template_handle = self.templates[resolved.class_id];
                    const object_template_handle = v8.v8__FunctionTemplate__InstanceTemplate(function_template_handle).?;
                    break :blk v8.v8__ObjectTemplate__NewInstance(object_template_handle, self.handle).?;
                },
            };

            if (!@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
                // The TAO contains the pointer to our Zig instance as
                // well as any meta data we'll need to use it later.
                // See the TaggedAnyOpaque struct for more details.
                const tao = try arena.create(TaggedAnyOpaque);
                tao.* = .{
                    .value = resolved.ptr,
                    .prototype_chain = resolved.prototype_chain.ptr,
                    .prototype_len = @intCast(resolved.prototype_chain.len),
                    .subtype = if (@hasDecl(JsApi.Meta, "subtype")) JsApi.Meta.subype else .node,
                };

                // Skip setting internal field for the global object (Window)
                // Window accessors get the instance from context.page.window instead
                if (resolved.class_id != @import("../webapi/Window.zig").JsApi.Meta.class_id) {
                    v8.v8__Object__SetInternalField(js_obj.handle, 0, isolate.createExternal(tao));
                }
            } else {
                // If the struct is empty, we don't need to do all
                // the TOA stuff and setting the internal data.
                // When we try to map this from JS->Zig, in
                // typeTaggedAnyOpaque, we'll also know there that
                // the type is empty and can create an empty instance.
            }

            // dont' use js_obj.persist(), because we don't want to track this in
            // context.global_objects, we want to track it in context.identity_map.
            const global = js.Global(js.Object).init(isolate.handle, js_obj.handle);
            gop.value_ptr.* = global;
            return .{ .ctx = self, .handle = global.local() };
        },
        else => @compileError("Expected a struct or pointer, got " ++ @typeName(T) ++ " (constructors must return struct or pointers)"),
    }
}

pub fn jsValueToZig(self: *Context, comptime T: type, js_value: js.Value) !T {
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
                return js.Value{
                    .ctx = self,
                    .handle = js_value.handle,
                };
            }

            if (comptime o.child == js.Object) {
                return js.Object{
                    .ctx = self,
                    .handle = @ptrCast(js_value.handle),
                };
            }

            if (js_value.isNullOrUndefined()) {
                return null;
            }
            return try self.jsValueToZig(o.child, js_value);
        },
        .float => |f| switch (f.bits) {
            0...32 => return js_value.toF32(),
            33...64 => return js_value.toF64(),
            else => {},
        },
        .int => return jsIntToZig(T, js_value),
        .bool => return js_value.toBool(),
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                if (!js_value.isObject()) {
                    return error.InvalidArgument;
                }
                if (@hasDecl(ptr.child, "JsApi")) {
                    std.debug.assert(bridge.JsApiLookup.has(ptr.child.JsApi));
                    return typeTaggedAnyOpaque(*ptr.child, js_value.handle);
                }
            },
            .slice => {
                if (ptr.sentinel() == null) {
                    if (try self.jsValueToTypedArray(ptr.child, js_value)) |value| {
                        return value;
                    }
                }

                if (ptr.child == u8) {
                    if (ptr.sentinel()) |s| {
                        if (comptime s == 0) {
                            return self.valueToStringZ(js_value, .{});
                        }
                    } else {
                        return self.valueToString(js_value, .{});
                    }
                }

                if (!js_value.isArray()) {
                    return error.InvalidArgument;
                }
                const js_arr = js_value.toArray();
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
            const slice_value = try self.jsValueToZig(slice_type, js_value);
            if (slice_value.len != arr.len) {
                // Exact length match, we could allow smaller arrays, but we would not be able to communicate how many were written
                return error.InvalidArgument;
            }
            return @as(*T, @ptrCast(slice_value.ptr)).*;
        },
        .@"struct" => {
            return try (self.jsValueToStruct(T, js_value)) orelse {
                return error.InvalidArgument;
            };
        },
        .@"union" => |u| {
            // see probeJsValueToZig for some explanation of what we're
            // trying to do

            // the first field that we find which the js_value could be
            // coerced to.
            var coerce_index: ?usize = null;

            // the first field that we find which the js_value is
            // compatible with. A compatible field has higher precedence
            // than a coercible, but still isn't a perfect match.
            var compatible_index: ?usize = null;
            inline for (u.fields, 0..) |field, i| {
                switch (try self.probeJsValueToZig(field.type, js_value)) {
                    .value => |v| return @unionInit(T, field.name, v),
                    .ok => {
                        // a perfect match like above case, except the probing
                        // didn't get the value for us.
                        return @unionInit(T, field.name, try self.jsValueToZig(field.type, js_value));
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
                    return @unionInit(T, field.name, try self.jsValueToZig(field.type, js_value));
                }
            }
            unreachable;
        },
        .@"enum" => |e| {
            if (@hasDecl(T, "js_enum_from_string")) {
                if (!js_value.isString()) {
                    return error.InvalidArgument;
                }
                return std.meta.stringToEnum(T, try self.valueToString(js_value, .{})) orelse return error.InvalidArgument;
            }
            switch (@typeInfo(e.tag_type)) {
                .int => return std.meta.intToEnum(T, try jsIntToZig(e.tag_type, js_value)),
                else => @compileError("unsupported enum parameter type: " ++ @typeName(T)),
            }
        },
        else => {},
    }

    @compileError("has an unsupported parameter type: " ++ @typeName(T));
}

// Extracted so that it can be used in both jsValueToZig and in
// probeJsValueToZig. Avoids having to duplicate this logic when probing.
fn jsValueToStruct(self: *Context, comptime T: type, js_value: js.Value) !?T {
    return switch (T) {
        js.Function => {
            if (!js_value.isFunction()) {
                return null;
            }
            return try self.newFunction(js_value);
        },
        js.Function.Global => {
            if (!js_value.isFunction()) {
                return null;
            }
            const func = try self.newFunction(js_value);
            return try func.persist();
        },
        // zig fmt: off
        js.TypedArray(u8), js.TypedArray(u16), js.TypedArray(u32), js.TypedArray(u64),
        js.TypedArray(i8), js.TypedArray(i16), js.TypedArray(i32), js.TypedArray(i64),
        js.TypedArray(f32), js.TypedArray(f64),
        // zig fmt: on
        => {
            const ValueType = @typeInfo(std.meta.fieldInfo(T, .values).type).pointer.child;
            const arr = (try self.jsValueToTypedArray(ValueType, js_value)) orelse return null;
            return .{ .values = arr };
        },
        js.String => .{ .string = try self.valueToString(js_value, .{ .allocator = self.arena }) },
        // Caller wants an opaque js.Object. Probably a parameter
        // that it needs to pass back into a callback.
        js.Value => js.Value{
            .ctx = self,
            .handle = js_value.handle,
        },
        // Caller wants an opaque js.Object. Probably a parameter
        // that it needs to pass back into a callback.
        js.Object => {
            if (!js_value.isObject()) {
                return null;
            }
            return js.Object{
                .ctx = self,
                .handle = @ptrCast(js_value.handle),
            };
        },
        js.Object.Global => {
            if (!js_value.isObject()) {
                return null;
            }
            const obj = js.Object{
                .ctx = self,
                .handle = @ptrCast(js_value.handle),
            };
            return try obj.persist();
        },
        js.Value.Global => {
            return try js_value.persist();
        },
        js.Promise.Global => {
            if (!js_value.isPromise()) {
                return null;
            }
            const promise = js.Promise{
                .ctx = self,
                .handle = @ptrCast(js_value.handle),
            };
            return try promise.persist();
        },
        else => {
            if (!js_value.isObject()) {
                return null;
            }

            const isolate = self.isolate;
            const js_obj = js_value.toObject();

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

fn jsValueToTypedArray(_: *Context, comptime T: type, js_value: js.Value) !?[]T {
    var force_u8 = false;
    var array_buffer: ?*const v8.ArrayBuffer = null;
    var byte_len: usize = undefined;
    var byte_offset: usize = undefined;

    if (js_value.isTypedArray()) {
        const buffer_handle: *const v8.ArrayBufferView = @ptrCast(js_value.handle);
        byte_len = v8.v8__ArrayBufferView__ByteLength(buffer_handle);
        byte_offset = v8.v8__ArrayBufferView__ByteOffset(buffer_handle);
        array_buffer = v8.v8__ArrayBufferView__Buffer(buffer_handle).?;
    } else if (js_value.isArrayBufferView()) {
        force_u8 = true;
        const buffer_handle: *const v8.ArrayBufferView = @ptrCast(js_value.handle);
        byte_len = v8.v8__ArrayBufferView__ByteLength(buffer_handle);
        byte_offset = v8.v8__ArrayBufferView__ByteOffset(buffer_handle);
        array_buffer = v8.v8__ArrayBufferView__Buffer(buffer_handle).?;
    } else if (js_value.isArrayBuffer()) {
        force_u8 = true;
        array_buffer = @ptrCast(js_value.handle);
        byte_len = v8.v8__ArrayBuffer__ByteLength(array_buffer);
        byte_offset = 0;
    }

    const backing_store_ptr = v8.v8__ArrayBuffer__GetBackingStore(array_buffer orelse return null);
    const backing_store_handle = v8.std__shared_ptr__v8__BackingStore__get(&backing_store_ptr).?;
    const data = v8.v8__BackingStore__Data(backing_store_handle);

    switch (T) {
        u8 => {
            if (force_u8 or js_value.isUint8Array() or js_value.isUint8ClampedArray()) {
                if (byte_len == 0) return &[_]u8{};
                const arr_ptr = @as([*]u8, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len];
            }
        },
        i8 => {
            if (js_value.isInt8Array()) {
                if (byte_len == 0) return &[_]i8{};
                const arr_ptr = @as([*]i8, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len];
            }
        },
        u16 => {
            if (js_value.isUint16Array()) {
                if (byte_len == 0) return &[_]u16{};
                const arr_ptr = @as([*]u16, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 2];
            }
        },
        i16 => {
            if (js_value.isInt16Array()) {
                if (byte_len == 0) return &[_]i16{};
                const arr_ptr = @as([*]i16, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 2];
            }
        },
        u32 => {
            if (js_value.isUint32Array()) {
                if (byte_len == 0) return &[_]u32{};
                const arr_ptr = @as([*]u32, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 4];
            }
        },
        i32 => {
            if (js_value.isInt32Array()) {
                if (byte_len == 0) return &[_]i32{};
                const arr_ptr = @as([*]i32, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 4];
            }
        },
        u64 => {
            if (js_value.isBigUint64Array()) {
                if (byte_len == 0) return &[_]u64{};
                const arr_ptr = @as([*]u64, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 8];
            }
        },
        i64 => {
            if (js_value.isBigInt64Array()) {
                if (byte_len == 0) return &[_]i64{};
                const arr_ptr = @as([*]i64, @ptrCast(@alignCast(data)));
                return arr_ptr[byte_offset .. byte_offset + byte_len / 8];
            }
        },
        else => {},
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
    prototype_chain: []const js.PrototypeChainEntry,
};
fn resolveValue(value: anytype) Resolved {
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

// == Stringifiers ==
pub fn valueToString(self: *Context, js_val: js.Value, opts: ToStringOpts) ![]u8 {
    return self._valueToString(false, js_val, opts);
}

pub fn valueToStringZ(self: *Context, js_val: js.Value, opts: ToStringOpts) ![:0]u8 {
    return self._valueToString(true, js_val, opts);
}

fn _valueToString(self: *Context, comptime null_terminate: bool, js_val: js.Value, opts: ToStringOpts) !(if (null_terminate) [:0]u8 else []u8) {
    if (js_val.isSymbol()) {
        const symbol_handle = v8.v8__Symbol__Description(@ptrCast(js_val.handle), self.isolate.handle).?;
        return self._valueToString(null_terminate, .{ .ctx = self, .handle = symbol_handle }, opts);
    }

    const string_handle = v8.v8__Value__ToString(js_val.handle, self.handle) orelse {
        return error.JsException;
    };

    return self._jsStringToZig(null_terminate, string_handle, opts);
}

const ToStringOpts = struct {
    allocator: ?Allocator = null,
};
pub fn jsStringToZig(self: *const Context, str: anytype, opts: ToStringOpts) ![]u8 {
    return self._jsStringToZig(false, str, opts);
}
pub fn jsStringToZigZ(self: *const Context, str: anytype, opts: ToStringOpts) ![:0]u8 {
    return self._jsStringToZig(true, str, opts);
}
fn _jsStringToZig(self: *const Context, comptime null_terminate: bool, str: anytype, opts: ToStringOpts) !(if (null_terminate) [:0]u8 else []u8) {
    const handle = if (@TypeOf(str) == js.String) str.handle else str;

    const len = v8.v8__String__Utf8Length(handle, self.isolate.handle);
    const allocator = opts.allocator orelse self.call_arena;
    const buf = try (if (comptime null_terminate) allocator.allocSentinel(u8, @intCast(len), 0) else allocator.alloc(u8, @intCast(len)));
    const n = v8.v8__String__WriteUtf8(handle, self.isolate.handle, buf.ptr, buf.len, v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8);
    std.debug.assert(n == len);

    return buf;
}

pub fn debugValue(self: *Context, js_val: js.Value, writer: *std.Io.Writer) !void {
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    return _debugValue(self, js_val, &seen, 0, writer) catch error.WriteFailed;
}

fn _debugValue(self: *Context, js_val: js.Value, seen: *std.AutoHashMapUnmanaged(u32, void), depth: usize, writer: *std.Io.Writer) !void {
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
            const js_sym_str = try self.valueToString(.{ .ctx = self, .handle = symbol_handle }, .{});
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

pub fn stackTrace(self: *const Context) !?[]const u8 {
    if (comptime !IS_DEBUG) {
        return "not available";
    }

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

// == Promise Helpers ==
pub fn rejectPromise(self: *Context, value: anytype) !js.Promise {
    var resolver = js.PromiseResolver.init(self);
    resolver.reject("Context.rejectPromise", value);
    return resolver.promise();
}

pub fn resolvePromise(self: *Context, value: anytype) !js.Promise {
    var resolver = js.PromiseResolver.init(self);
    resolver.resolve("Context.resolvePromise", value);
    return resolver.promise();
}

pub fn runMicrotasks(self: *Context) void {
    self.isolate.performMicrotasksCheckpoint();
}

pub fn createPromiseResolver(self: *Context) js.PromiseResolver {
    return js.PromiseResolver.init(self);
}

// == Callbacks ==
// Callback from V8, asking us to load a module. The "specifier" is
// the src of the module to load.
fn resolveModuleCallback(
    c_context: ?*const v8.Context,
    c_specifier: ?*const v8.String,
    import_attributes: ?*const v8.FixedArray,
    c_referrer: ?*const v8.Module,
) callconv(.c) ?*const v8.Module {
    _ = import_attributes;

    const self = fromC(c_context.?);

    const specifier = self.jsStringToZigZ(c_specifier.?, .{}) catch |err| {
        log.err(.js, "resolve module", .{ .err = err });
        return null;
    };
    const referrer = js.Module{ .ctx = self, .handle = c_referrer.? };

    return self._resolveModuleCallback(referrer, specifier) catch |err| {
        log.err(.js, "resolve module", .{
            .err = err,
            .specifier = specifier,
        });
        return null;
    };
}

pub fn dynamicModuleCallback(
    c_context: ?*const v8.Context,
    host_defined_options: ?*const v8.Data,
    resource_name: ?*const v8.Value,
    v8_specifier: ?*const v8.String,
    import_attrs: ?*const v8.FixedArray,
) callconv(.c) ?*v8.Promise {
    _ = host_defined_options;
    _ = import_attrs;

    const self = fromC(c_context.?);

    const resource = self.jsStringToZigZ(resource_name.?, .{}) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback1" });
        return @constCast((self.rejectPromise("Out of memory") catch return null).handle);
    };

    const specifier = self.jsStringToZigZ(v8_specifier.?, .{}) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback2" });
        return @constCast((self.rejectPromise("Out of memory") catch return null).handle);
    };

    const normalized_specifier = self.script_manager.?.resolveSpecifier(
        self.arena, // might need to survive until the module is loaded
        resource,
        specifier,
    ) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback3" });
        return @constCast((self.rejectPromise("Out of memory") catch return null).handle);
    };

    const promise = self._dynamicModuleCallback(normalized_specifier, resource) catch |err| blk: {
        log.err(.js, "dynamic module callback", .{
            .err = err,
        });
        break :blk self.rejectPromise("Failed to load module") catch return null;
    };
    return @constCast(promise.handle);
}

pub fn metaObjectCallback(c_context: ?*v8.Context, c_module: ?*v8.Module, c_meta: ?*v8.Value) callconv(.c) void {
    const self = fromC(c_context.?);
    const m = js.Module{ .ctx = self, .handle = c_module.? };
    const meta = js.Object{ .ctx = self, .handle = @ptrCast(c_meta.?) };

    const url = self.module_identifier.get(m.getIdentityHash()) orelse {
        // Shouldn't be possible.
        log.err(.js, "import meta", .{ .err = error.UnknownModuleReferrer });
        return;
    };

    const js_value = self.zigValueToJs(url, .{}) catch {
        log.err(.js, "import meta", .{ .err = error.FailedToConvertUrl });
        return;
    };
    const res = meta.defineOwnProperty("url", js_value, 0) orelse false;
    if (!res) {
        log.err(.js, "import meta", .{ .err = error.FailedToSet });
    }
}

fn _resolveModuleCallback(self: *Context, referrer: js.Module, specifier: [:0]const u8) !?*const v8.Module {
    const referrer_path = self.module_identifier.get(referrer.getIdentityHash()) orelse {
        // Shouldn't be possible.
        return error.UnknownModuleReferrer;
    };

    const normalized_specifier = try self.script_manager.?.resolveSpecifier(
        self.arena,
        referrer_path,
        specifier,
    );

    const entry = self.module_cache.getPtr(normalized_specifier).?;
    if (entry.module) |m| {
        return m.local().handle;
    }

    var source = try self.script_manager.?.waitForImport(normalized_specifier);
    defer source.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(self);
    defer try_catch.deinit();

    const mod = try self.compileModule(source.src(), normalized_specifier);
    try self.postCompileModule(mod, normalized_specifier);
    entry.module = try mod.persist();
    return entry.module.?.local().handle;
}

// Will get passed to ScriptManager and then passed back to us when
// the src of the module is loaded
const DynamicModuleResolveState = struct {
    // The module that we're resolving (we'll actually resolve its
    // namespace)
    module: ?js.Module.Global,
    context_id: usize,
    context: *Context,
    specifier: [:0]const u8,
    resolver: js.PromiseResolver.Global,
};

fn _dynamicModuleCallback(self: *Context, specifier: [:0]const u8, referrer: []const u8) !js.Promise {
    const gop = try self.module_cache.getOrPut(self.arena, specifier);
    if (gop.found_existing and gop.value_ptr.resolver_promise != null) {
        // This is easy, there's already something responsible
        // for loading the module. Maybe it's still loading, maybe
        // it's complete. Whatever, we can just return that promise.
        return gop.value_ptr.resolver_promise.?.local();
    }

    const resolver = try self.createPromiseResolver().persist();
    const state = try self.arena.create(DynamicModuleResolveState);

    state.* = .{
        .module = null,
        .context = self,
        .specifier = specifier,
        .context_id = self.id,
        .resolver = resolver,
    };

    const promise = try resolver.local().promise().persist();

    if (!gop.found_existing) {
        // this module hasn't been seen before. This is the most
        // complicated path.

        // First, we'll setup a bare entry into our cache. This will
        // prevent anyone one else from trying to asychronously load
        // it. Instead, they can just return our promise.
        gop.value_ptr.* = ModuleEntry{
            .module = null,
            .module_promise = null,
            .resolver_promise = promise,
        };

        // Next, we need to actually load it.
        self.script_manager.?.getAsyncImport(specifier, dynamicModuleSourceCallback, state, referrer) catch |err| {
            const error_msg = self.newString(@errorName(err));
            _ = resolver.local().reject("dynamic module get async", error_msg);
        };

        // For now, we're done. but this will be continued in
        // `dynamicModuleSourceCallback`, once the source for the
        // moduel is loaded.
        return promise.local();
    }

    // So we have a module, but no async resolver. This can only
    // happen if the module was first synchronously loaded (Does that
    // ever even happen?!) You'd think we cann just return the module
    // but no, we need to resolve the module namespace, and the
    // module could still be loading!
    // We need to do part of what the first case is going to do in
    // `dynamicModuleSourceCallback`, but we can skip some steps
    // since the module is alrady loaded,
    std.debug.assert(gop.value_ptr.module != null);

    // If the module hasn't been evaluated yet (it was only instantiated
    // as a static import dependency), we need to evaluate it now.
    if (gop.value_ptr.module_promise == null) {
        const mod_global = gop.value_ptr.module.?;
        const mod = mod_global.local();
        const status = mod.getStatus();
        if (status == .kEvaluated or status == .kEvaluating) {
            // Module was already evaluated (shouldn't normally happen, but handle it).
            // Create a pre-resolved promise with the module namespace.
            const module_resolver = try self.createPromiseResolver().persist();
            _ = module_resolver.local().resolve("resolve module", mod.getModuleNamespace());
            gop.value_ptr.module_promise = try module_resolver.local().promise().persist();
        } else {
            // the module was loaded, but not evaluated, we _have_ to evaluate it now
            const evaluated = mod.evaluate() catch {
                std.debug.assert(status == .kErrored);
                _ = resolver.local().reject("module evaluation", self.newString("Module evaluation failed"));
                return promise.local();
            };
            std.debug.assert(evaluated.isPromise());
            gop.value_ptr.module_promise = try evaluated.toPromise().persist();
        }
    }

    // like before, we want to set this up so that if anything else
    // tries to load this module, it can just return our promise
    // since we're going to be doing all the work.
    gop.value_ptr.resolver_promise = promise;

    // But we can skip direclty to `resolveDynamicModule` which is
    // what the above callback will eventually do.
    self.resolveDynamicModule(state, gop.value_ptr.*);
    return promise.local();
}

fn dynamicModuleSourceCallback(ctx: *anyopaque, module_source_: anyerror!ScriptManager.ModuleSource) void {
    const state: *DynamicModuleResolveState = @ptrCast(@alignCast(ctx));
    var self = state.context;

    var ms = module_source_ catch |err| {
        _ = state.resolver.local().reject("dynamic module source", self.newString(@errorName(err)));
        return;
    };

    const module_entry = blk: {
        defer ms.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(self);
        defer try_catch.deinit();

        break :blk self.module(true, ms.src(), state.specifier, true) catch |err| {
            const caught = try_catch.caughtOrError(self.call_arena, err);
            log.err(.js, "module compilation failed", .{
                .caught = caught,
                .specifier = state.specifier,
            });
            _ = state.resolver.local().reject("dynamic compilation failure", self.newString(caught.exception orelse ""));
            return;
        };
    };

    self.resolveDynamicModule(state, module_entry);
}

fn resolveDynamicModule(self: *Context, state: *DynamicModuleResolveState, module_entry: ModuleEntry) void {
    defer self.runMicrotasks();

    // we can only be here if the module has been evaluated and if
    // we have a resolve loading this asynchronously.
    std.debug.assert(module_entry.module_promise != null);
    std.debug.assert(module_entry.resolver_promise != null);
    std.debug.assert(self.module_cache.contains(state.specifier));
    state.module = module_entry.module.?;

    // We've gotten the source for the module and are evaluating it.
    // You might think we're done, but the module evaluation is
    // itself asynchronous. We need to chain to the module's own
    // promise. When the module is evaluated, it resolves to the
    // last value of the module. But, for module loading, we need to
    // resolve to the module's namespace.

    const then_callback = self.newFunctionWithData(struct {
        pub fn callback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(callback_handle).?;
            var caller = Caller.init(isolate);
            defer caller.deinit();

            const info_data = v8.v8__FunctionCallbackInfo__Data(callback_handle).?;
            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(v8.v8__External__Value(@ptrCast(info_data))));

            if (s.context_id != caller.context.id) {
                // The microtask is tied to the isolate, not the context
                // it can be resolved while another context is active
                // (Which seems crazy to me). If that happens, then
                // another page was loaded and we MUST ignore this
                // (most of the fields in state are not valid)
                return;
            }

            defer caller.context.runMicrotasks();
            const namespace = s.module.?.local().getModuleNamespace();
            _ = s.resolver.local().resolve("resolve namespace", namespace);
        }
    }.callback, @ptrCast(state));

    const catch_callback = self.newFunctionWithData(struct {
        pub fn callback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(callback_handle).?;
            var caller = Caller.init(isolate);
            defer caller.deinit();

            const info_data = v8.v8__FunctionCallbackInfo__Data(callback_handle).?;
            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(v8.v8__External__Value(@ptrCast(info_data))));

            const ctx = caller.context;
            if (s.context_id != ctx.id) {
                return;
            }

            defer ctx.runMicrotasks();
            _ = s.resolver.local().reject("catch callback", js.Value{
                .ctx = ctx,
                .handle = v8.v8__FunctionCallbackInfo__Data(callback_handle).?,
            });
        }
    }.callback, @ptrCast(state));

    _ = module_entry.module_promise.?.local().thenAndCatch(then_callback, catch_callback) catch |err| {
        log.err(.js, "module evaluation is promise", .{
            .err = err,
            .specifier = state.specifier,
        });
        _ = state.resolver.local().reject("module promise", self.newString("Failed to evaluate promise"));
    };
}

// ==  Zig <-> JS ==

// Reverses the mapZigInstanceToJs, making sure that our TaggedAnyOpaque
// contains a ptr to the correct type.
pub fn typeTaggedAnyOpaque(comptime R: type, js_obj_handle: *const v8.Object) !R {
    const ti = @typeInfo(R);
    if (ti != .pointer) {
        @compileError("non-pointer Zig parameter type: " ++ @typeName(R));
    }

    const T = ti.pointer.child;
    const JsApi = bridge.Struct(T).JsApi;

    if (@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
        // Empty structs aren't stored as TOAs and there's no data
        // stored in the JSObject's IntenrnalField. Why bother when
        // we can just return an empty struct here?
        return @constCast(@as(*const T, &.{}));
    }

    const internal_field_count = v8.v8__Object__InternalFieldCount(js_obj_handle);
    // Special case for Window: the global object doesn't have internal fields
    // Window instance is stored in context.page.window instead
    if (internal_field_count == 0) {
        // Normally, this would be an error. All JsObject that map to a Zig type
        // are either `empty_with_no_proto` (handled above) or have an
        // interalFieldCount. The only exception to that is the Window...
        const isolate = v8.v8__Object__GetIsolate(js_obj_handle).?;
        const context = fromIsolate(.{ .handle = isolate });

        const Window = @import("../webapi/Window.zig");
        if (T == Window) {
            return context.page.window;
        }

        // ... Or the window's prototype.
        // We could make this all comptime-fancy, but it's easier to hard-code
        // the EventTarget

        const EventTarget = @import("../webapi/EventTarget.zig");
        if (T == EventTarget) {
            return context.page.window._proto;
        }

        // Type not found in Window's prototype chain
        return error.InvalidArgument;
    }

    // if it isn't an empty struct, then the v8.Object should have an
    // InternalFieldCount > 0, since our toa pointer should be embedded
    // at index 0 of the internal field count.
    if (internal_field_count == 0) {
        return error.InvalidArgument;
    }

    if (!bridge.JsApiLookup.has(JsApi)) {
        @compileError("unknown Zig type: " ++ @typeName(R));
    }

    const internal_field_handle = v8.v8__Object__GetInternalField(js_obj_handle, 0).?;
    const tao: *TaggedAnyOpaque = @ptrCast(@alignCast(v8.v8__External__Value(internal_field_handle)));
    const expected_type_index = bridge.JsApiLookup.getId(JsApi);

    const prototype_chain = tao.prototype_chain[0..tao.prototype_len];
    if (prototype_chain[0].index == expected_type_index) {
        return @ptrCast(@alignCast(tao.value));
    }

    // Ok, let's walk up the chain
    var ptr = @intFromPtr(tao.value);
    for (prototype_chain[1..]) |proto| {
        ptr += proto.offset; // the offset to the _proto field
        const proto_ptr: **anyopaque = @ptrFromInt(ptr);
        if (proto.index == expected_type_index) {
            return @ptrCast(@alignCast(proto_ptr.*));
        }
        ptr = @intFromPtr(proto_ptr.*);
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
fn probeJsValueToZig(self: *Context, comptime T: type, js_value: js.Value) !ProbeResult(T) {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (js_value.isNullOrUndefined()) {
                return .{ .value = null };
            }
            return self.probeJsValueToZig(o.child, js_value);
        },
        .float => {
            if (js_value.isNumber() or js_value.isNumberObject()) {
                if (js_value.isInt32() or js_value.isUint32() or js_value.isBigInt() or js_value.isBigIntObject()) {
                    // int => float is a reasonable match
                    return .{ .compatible = {} };
                }
                return .{ .ok = {} };
            }
            // anything can be coerced into a float, it becomes NaN
            return .{ .coerce = {} };
        },
        .int => {
            if (js_value.isNumber() or js_value.isNumberObject()) {
                if (js_value.isInt32() or js_value.isUint32() or js_value.isBigInt() or js_value.isBigIntObject()) {
                    return .{ .ok = {} };
                }
                // float => int is kind of reasonable, I guess
                return .{ .compatible = {} };
            }
            // anything can be coerced into a int, it becomes 0
            return .{ .coerce = {} };
        },
        .bool => {
            if (js_value.isBoolean() or js_value.isBooleanObject()) {
                return .{ .ok = {} };
            }
            // anything can be coerced into a boolean, it will become
            // true or false based on..some complex rules I don't know.
            return .{ .coerce = {} };
        },
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                if (!js_value.isObject()) {
                    return .{ .invalid = {} };
                }
                if (bridge.JsApiLookup.has(ptr.child.JsApi)) {
                    // There's a bit of overhead in doing this, so instead
                    // of having a version of typeTaggedAnyOpaque which
                    // returns a boolean or an optional, we rely on the
                    // main implementation and just handle the error.
                    const attempt = typeTaggedAnyOpaque(*ptr.child, @ptrCast(js_value.handle));
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
                if (js_value.isTypedArray()) {
                    switch (ptr.child) {
                        u8 => if (ptr.sentinel() == null) {
                            if (js_value.isUint8Array() or js_value.isUint8ClampedArray()) {
                                return .{ .ok = {} };
                            }
                        },
                        i8 => if (js_value.isInt8Array()) {
                            return .{ .ok = {} };
                        },
                        u16 => if (js_value.isUint16Array()) {
                            return .{ .ok = {} };
                        },
                        i16 => if (js_value.isInt16Array()) {
                            return .{ .ok = {} };
                        },
                        u32 => if (js_value.isUint32Array()) {
                            return .{ .ok = {} };
                        },
                        i32 => if (js_value.isInt32Array()) {
                            return .{ .ok = {} };
                        },
                        u64 => if (js_value.isBigUint64Array()) {
                            return .{ .ok = {} };
                        },
                        i64 => if (js_value.isBigInt64Array()) {
                            return .{ .ok = {} };
                        },
                        else => {},
                    }
                    return .{ .invalid = {} };
                }

                if (ptr.child == u8) {
                    if (js_value.isString()) {
                        return .{ .ok = {} };
                    }
                    // anything can be coerced into a string
                    return .{ .coerce = {} };
                }

                if (!js_value.isArray()) {
                    return .{ .invalid = {} };
                }

                // This can get tricky.
                const js_arr = js_value.toArray();

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
            switch (try self.probeJsValueToZig(slice_type, js_value)) {
                .value => |slice_value| {
                    if (slice_value.len == arr.len) {
                        return .{ .value = @as(*T, @ptrCast(slice_value.ptr)).* };
                    }
                    return .{ .invalid = {} };
                },
                .ok => {
                    // Exact length match, we could allow smaller arrays as .compatible, but we would not be able to communicate how many were written
                    if (js_value.isArray()) {
                        const js_arr = js_value.toArray();
                        if (js_arr.len() == arr.len) {
                            return .{ .ok = {} };
                        }
                    } else if (js_value.isString() and arr.child == u8) {
                        const str = try js_value.toString(self.handle);
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
            const value = (try self.jsValueToStruct(T, js_value)) orelse {
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

fn compileAndRun(self: *Context, src: []const u8, name: ?[]const u8) !js.Value {
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
    return .{ .ctx = self, .handle = result };
}

fn compileModule(self: *Context, src: []const u8, name: []const u8) !js.Module {
    var origin_handle: v8.ScriptOrigin = undefined;
    v8.v8__ScriptOrigin__CONSTRUCT2(
        &origin_handle,
        self.isolate.initStringHandle(name),
        0, // resource_line_offset
        0, // resource_column_offset
        false, // resource_is_shared_cross_origin
        -1, // script_id
        null, // source_map_url
        false, // resource_is_opaque
        false, // is_wasm
        true, // is_module
        null, // host_defined_options
    );

    var source_handle: v8.ScriptCompilerSource = undefined;
    v8.v8__ScriptCompiler__Source__CONSTRUCT2(
        self.isolate.initStringHandle(src),
        &origin_handle,
        null, // cached data
        &source_handle,
    );

    defer v8.v8__ScriptCompiler__Source__DESTRUCT(&source_handle);

    const module_handle = v8.v8__ScriptCompiler__CompileModule(
        self.isolate.handle,
        &source_handle,
        v8.kNoCompileOptions,
        v8.kNoCacheNoReason,
    ) orelse {
        return error.JsException;
    };

    return .{
        .ctx = self,
        .handle = module_handle,
    };
}

fn zigJsonToJs(self: *Context, value: std.json.Value) !js.Value {
    const isolate = self.isolate;

    switch (value) {
        .bool => |v| return .{ .ctx = self, .handle = js.simpleZigValueToJs(isolate, v, true, false) },
        .float => |v| return .{ .ctx = self, .handle = js.simpleZigValueToJs(isolate, v, true, false) },
        .integer => |v| return .{ .ctx = self, .handle = js.simpleZigValueToJs(isolate, v, true, false) },
        .string => |v| return .{ .ctx = self, .handle = js.simpleZigValueToJs(isolate, v, true, false) },
        .null => return .{ .ctx = self, .handle = isolate.initNull() },

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
            return .{ .ctx = self, .handle = @ptrCast(js_obj.handle) };
        },
    }
}

// Microtasks
pub fn queueMutationDelivery(self: *Context) !void {
    self.isolate.enqueueMicrotask(struct {
        fn run(data: ?*anyopaque) callconv(.c) void {
            const page: *Page = @ptrCast(@alignCast(data.?));
            page.deliverMutations();
        }
    }.run, self.page);
}

pub fn queueIntersectionChecks(self: *Context) !void {
    self.isolate.enqueueMicrotask(struct {
        fn run(data: ?*anyopaque) callconv(.c) void {
            const page: *Page = @ptrCast(@alignCast(data.?));
            page.performScheduledIntersectionChecks();
        }
    }.run, self.page);
}

pub fn queueIntersectionDelivery(self: *Context) !void {
    self.isolate.enqueueMicrotask(struct {
        fn run(data: ?*anyopaque) callconv(.c) void {
            const page: *Page = @ptrCast(@alignCast(data.?));
            page.deliverIntersections();
        }
    }.run, self.page);
}

pub fn queueSlotchangeDelivery(self: *Context) !void {
    self.isolate.enqueueMicrotask(struct {
        fn run(data: ?*anyopaque) callconv(.c) void {
            const page: *Page = @ptrCast(@alignCast(data.?));
            page.deliverSlotchangeEvents();
        }
    }.run, self.page);
}

pub fn queueMicrotaskFunc(self: *Context, cb: js.Function) void {
    self.isolate.enqueueMicrotaskFunc(cb);
}

// == Misc ==
// An interface for types that want to have their jsDeinit function to be
// called when the call context ends
const DestructorCallback = struct {
    ptr: *anyopaque,
    destructorFn: *const fn (ptr: *anyopaque) void,

    fn init(ptr: anytype) DestructorCallback {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const gen = struct {
            pub fn destructor(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.destructor(self);
            }
        };

        return .{
            .ptr = ptr,
            .destructorFn = gen.destructor,
        };
    }

    pub fn destructor(self: DestructorCallback) void {
        self.destructorFn(self.ptr);
    }
};

// == Profiler ==
pub fn startCpuProfiler(self: *Context) void {
    if (comptime !IS_DEBUG) {
        // Still testing this out, don't have it properly exposed, so add this
        // guard for the time being to prevent any accidental/weird prod issues.
        @compileError("CPU Profiling is only available in debug builds");
    }

    std.debug.assert(self.cpu_profiler == null);
    v8.v8__CpuProfiler__UseDetailedSourcePositionsForProfiling(self.isolate.handle);

    const cpu_profiler = v8.v8__CpuProfiler__Get(self.isolate.handle).?;
    const title = self.isolate.initStringHandle("v8_cpu_profile");
    v8.v8__CpuProfiler__StartProfiling(cpu_profiler, title);
    self.cpu_profiler = cpu_profiler;
}

pub fn stopCpuProfiler(self: *Context) ![]const u8 {
    const title = self.isolate.initStringHandle("v8_cpu_profile");
    const handle = v8.v8__CpuProfiler__StopProfiling(self.cpu_profiler.?, title) orelse return error.NoProfiles;
    const string_handle = v8.v8__CpuProfile__Serialize(handle, self.isolate.handle) orelse return error.NoProfile;
    return self.jsStringToZig(string_handle, .{});
}
