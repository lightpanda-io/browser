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
const builtin = @import("builtin");

const log = @import("../../log.zig");

const js = @import("js.zig");
const v8 = js.v8;

const bridge = @import("bridge.zig");
const Caller = @import("Caller.zig");

const Page = @import("../Page.zig");
const ScriptManager = @import("../ScriptManager.zig");

const Allocator = std.mem.Allocator;
const PersistentObject = v8.Persistent(v8.Object);
const PersistentValue = v8.Persistent(v8.Value);
const PersistentModule = v8.Persistent(v8.Module);
const PersistentPromise = v8.Persistent(v8.Promise);
const PersistentFunction = v8.Persistent(v8.Function);
const TaggedAnyOpaque = js.TaggedAnyOpaque;

// Loosely maps to a Browser Page.
const Context = @This();

id: usize,
page: *Page,
isolate: v8.Isolate,
// This context is a persistent object. The persistent needs to be recovered and reset.
v8_context: v8.Context,
handle_scope: ?v8.HandleScope,

cpu_profiler: ?v8.CpuProfiler = null,

// references Env.templates
templates: []v8.FunctionTemplate,

// Arena for the lifetime of the context
arena: Allocator,

// The page.call_arena
call_arena: Allocator,

// Because calls can be nested (i.e.a function calling a callback),
// we can only reset the call_arena when call_depth == 0. If we were
// to reset it within a callback, it would invalidate the data of
// the call which is calling the callback.
call_depth: usize = 0,

// Callbacks are PesistendObjects. When the context ends, we need
// to free every callback we created.
callbacks: std.ArrayListUnmanaged(v8.Persistent(v8.Function)) = .empty,

// Serves two purposes. Like `callbacks` above, this is used to free
// every PeristentObjet we've created during the lifetime of the context.
// More importantly, it serves as an identity map - for a given Zig
// instance, we map it to the same PersistentObject.
// The key is the @intFromPtr of the Zig value
identity_map: std.AutoHashMapUnmanaged(usize, PersistentObject) = .empty,

// Some web APIs have to manage opaque values. Ideally, they use an
// js.Object, but the js.Object has no lifetime guarantee beyond the
// current call. They can call .persist() on their js.Object to get
// a `*PersistentObject()`. We need to track these to free them.
// This used to be a map and acted like identity_map; the key was
// the @intFromPtr(js_obj.handle). But v8 can re-use address. Without
// a reliable way to know if an object has already been persisted,
// we now simply persist every time persist() is called.
js_object_list: std.ArrayListUnmanaged(PersistentObject) = .empty,

// js_value_list tracks persisted js values.
js_value_list: std.ArrayListUnmanaged(PersistentValue) = .empty,

// Various web APIs depend on having a persistent promise resolver. They
// require for this PromiseResolver to be valid for a lifetime longer than
// the function that resolves/rejects them.
persisted_promise_resolvers: std.ArrayListUnmanaged(v8.Persistent(v8.PromiseResolver)) = .empty,

// Some Zig types have code to execute to cleanup
destructor_callbacks: std.ArrayListUnmanaged(DestructorCallback) = .empty,

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
    module: ?PersistentModule = null,

    // The promise of the evaluating module. The resolved value is
    // meaningless to us, but the resolver promise needs to chain
    // to this, since we need to know when it's complete.
    module_promise: ?PersistentPromise = null,

    // The promise for the resolver which is loading the module.
    // (AKA, the first time we try to load it). This resolver will
    // chain to the module_promise  and, when it's done evaluating
    // will resolve its namespace. Any other attempt to load the
    // module willchain to this.
    resolver_promise: ?PersistentPromise = null,
};

pub fn fromC(c_context: *const v8.C_Context) *Context {
    const v8_context = v8.Context{ .handle = c_context };
    return @ptrFromInt(v8_context.getEmbedderData(1).castTo(v8.BigInt).getUint64());
}

pub fn fromIsolate(isolate: v8.Isolate) *Context {
    const v8_context = isolate.getCurrentContext();
    return @ptrFromInt(v8_context.getEmbedderData(1).castTo(v8.BigInt).getUint64());
}

pub fn setupGlobal(self: *Context) !void {
    _ = try self.mapZigInstanceToJs(self.v8_context.getGlobal(), self.page.window);
}

pub fn deinit(self: *Context) void {
    {
        // reverse order, as this has more chance of respecting any
        // dependencies objects might have with each other.
        const items = self.destructor_callbacks.items;
        var i = items.len;
        while (i > 0) {
            i -= 1;
            items[i].destructor();
        }
    }

    {
        var it = self.identity_map.valueIterator();
        while (it.next()) |p| {
            p.deinit();
        }
    }

    for (self.js_object_list.items) |*p| {
        p.deinit();
    }

    for (self.js_value_list.items) |*p| {
        p.deinit();
    }

    for (self.persisted_promise_resolvers.items) |*p| {
        p.deinit();
    }

    {
        var it = self.module_cache.valueIterator();
        while (it.next()) |entry| {
            if (entry.module) |*mod| {
                mod.deinit();
            }
            if (entry.module_promise) |*p| {
                p.deinit();
            }
            if (entry.resolver_promise) |*p| {
                p.deinit();
            }
        }
    }

    for (self.callbacks.items) |*cb| {
        cb.deinit();
    }
    if (self.handle_scope) |*scope| {
        scope.deinit();
        self.v8_context.exit();
    }
    var presistent_context = v8.Persistent(v8.Context).recoverCast(self.v8_context);
    presistent_context.deinit();
}

fn trackCallback(self: *Context, pf: PersistentFunction) !void {
    return self.callbacks.append(self.arena, pf);
}

// Given an anytype, turns it into a v8.Object. The anytype could be:
// 1 - A V8.object already
// 2 - Our js.Object wrapper around a V8.Object
// 3 - A zig instance that has previously been given to V8
//     (i.e., the value has to be known to the executor)
pub fn valueToExistingObject(self: *const Context, value: anytype) !v8.Object {
    if (@TypeOf(value) == v8.Object) {
        return value;
    }

    if (@TypeOf(value) == js.Object) {
        return value.js_obj;
    }

    const persistent_object = self.identity_map.get(@intFromPtr(value)) orelse {
        return error.InvalidThisForCallback;
    };

    return persistent_object.castToObject();
}

// == Executors ==
pub fn eval(self: *Context, src: []const u8, name: ?[]const u8) !void {
    _ = try self.exec(src, name);
}

pub fn exec(self: *Context, src: []const u8, name: ?[]const u8) !js.Value {
    const v8_context = self.v8_context;

    const scr = try compileScript(self.isolate, v8_context, src, name);

    const value = scr.run(v8_context) catch {
        return error.ExecutionError;
    };

    return self.createValue(value);
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
        const m = try compileModule(self.isolate, src, owned_url);

        if (cacheable) {
            // compileModule is synchronous - nothing can modify the cache during compilation
            std.debug.assert(gop.value_ptr.module == null);

            gop.value_ptr.module = PersistentModule.init(self.isolate, m);
            if (!gop.found_existing) {
                gop.key_ptr.* = owned_url;
            }
        }

        break :blk .{ m, owned_url };
    };

    try self.postCompileModule(mod, owned_url);

    const v8_context = self.v8_context;
    if (try mod.instantiate(v8_context, resolveModuleCallback) == false) {
        return error.ModuleInstantiationError;
    }

    const evaluated = mod.evaluate(v8_context) catch {
        std.debug.assert(mod.getStatus() == .kErrored);

        // Some module-loading errors aren't handled by TryCatch. We need to
        // get the error from the module itself.
        log.warn(.js, "evaluate module", .{
            .specifier = owned_url,
            .message = self.valueToString(mod.getException(), .{}) catch "???",
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

    entry.module_promise = PersistentPromise.init(self.isolate, .{ .handle = evaluated.handle });
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

    const v8_context = self.v8_context;
    const script = try compileScript(self.isolate, v8_context, full, null);
    const js_value = script.run(v8_context) catch {
        return error.ExecutionError;
    };
    if (!js_value.isFunction()) {
        return error.StringFunctionError;
    }
    return self.createFunction(js_value);
}

// After we compile a module, whether it's a top-level one, or a nested one,
// we always want to track its identity (so that, if this module imports other
// modules, we can resolve the full URL), and preload any dependent modules.
fn postCompileModule(self: *Context, mod: v8.Module, url: [:0]const u8) !void {
    try self.module_identifier.putNoClobber(self.arena, mod.getIdentityHash(), url);

    const v8_context = self.v8_context;

    // Non-async modules are blocking. We can download them in parallel, but
    // they need to be processed serially. So we want to get the list of
    // dependent modules this module has and start downloading them asap.
    const requests = mod.getModuleRequests();
    const script_manager = self.script_manager.?;
    for (0..requests.length()) |i| {
        const req = requests.get(v8_context, @intCast(i)).castTo(v8.ModuleRequest);
        const specifier = try self.jsStringToZigZ(req.getSpecifier(), .{});
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
pub fn createArray(self: *Context, len: u32) js.Object {
    const arr = v8.Array.init(self.isolate, len);
    return .{
        .context = self,
        .js_obj = arr.castTo(v8.Object),
    };
}

pub fn createException(self: *const Context, e: v8.Value) js.Exception {
    return .{
        .inner = e,
        .context = self,
    };
}

// Wrap a v8.Value, largely so that we can provide a convenient
// toString function
pub fn createValue(self: *Context, value: v8.Value) js.Value {
    return .{
        .js_val = value,
        .context = self,
    };
}

pub fn createObject(self: *Context, js_value: v8.Value) js.Object {
    return .{
        .js_obj = js_value.castTo(v8.Object),
        .context = self,
    };
}

pub fn createFunction(self: *Context, js_value: v8.Value) !js.Function {
    // caller should have made sure this was a function
    std.debug.assert(js_value.isFunction());

    const func = v8.Persistent(v8.Function).init(self.isolate, js_value.castTo(v8.Function));
    try self.trackCallback(func);

    return .{
        .func = func,
        .context = self,
        .id = js_value.castTo(v8.Object).getIdentityHash(),
    };
}

pub fn throw(self: *Context, err: []const u8) js.Exception {
    const js_value = js._createException(self.isolate, err);
    return self.createException(js_value);
}

pub fn zigValueToJs(self: *Context, value: anytype, comptime opts: Caller.CallOpts) !v8.Value {
    const isolate = self.isolate;

    // Check if it's a "simple" type. This is extracted so that it can be
    // reused by other parts of the code. "simple" types only require an
    // isolate to create (specifically, they don't our templates array)
    if (js.simpleZigValueToJs(isolate, value, false, opts.null_as_undefined)) |js_value| {
        return js_value;
    }

    const v8_context = self.v8_context;
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void, .bool, .int, .comptime_int, .float, .comptime_float, .@"enum", .null => {
            // Need to do this to keep the compiler happy
            // simpleZigValueToJs handles all of these cases.
            unreachable;
        },
        .array => {
            var js_arr = v8.Array.init(isolate, value.len);
            var js_obj = js_arr.castTo(v8.Object);
            for (value, 0..) |v, i| {
                const js_val = try self.zigValueToJs(v, .{});
                if (js_obj.setValueAtIndex(v8_context, @intCast(i), js_val) == false) {
                    return error.FailedToCreateArray;
                }
            }
            return js_obj.toValue();
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
                var js_arr = v8.Array.init(isolate, @intCast(value.len));
                var js_obj = js_arr.castTo(v8.Object);

                for (value, 0..) |v, i| {
                    const js_val = try self.zigValueToJs(v, opts);
                    if (js_obj.setValueAtIndex(v8_context, @intCast(i), js_val) == false) {
                        return error.FailedToCreateArray;
                    }
                }
                return js_obj.toValue();
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
                return value.func.toValue();
            }

            if (T == js.Object) {
                // we're returning a v8.Object
                return value.js_obj.toValue();
            }

            if (T == js.Value) {
                return value.js_val;
            }

            if (T == js.Promise) {
                // we're returning a v8.Promise
                return value.toObject().toValue();
            }

            if (T == js.Exception) {
                return isolate.throwException(value.inner);
            }

            if (@hasDecl(T, "runtimeGenericWrap")) {
                const wrap = try value.runtimeGenericWrap(self.page);
                return zigValueToJs(self, wrap, opts);
            }

            if (s.is_tuple) {
                // return the tuple struct as an array
                var js_arr = v8.Array.init(isolate, @intCast(s.fields.len));
                var js_obj = js_arr.castTo(v8.Object);
                inline for (s.fields, 0..) |f, i| {
                    const js_val = try self.zigValueToJs(@field(value, f.name), opts);
                    if (js_obj.setValueAtIndex(v8_context, @intCast(i), js_val) == false) {
                        return error.FailedToCreateArray;
                    }
                }
                return js_obj.toValue();
            }

            // return the struct as a JS object
            const js_obj = v8.Object.init(isolate);
            inline for (s.fields) |f| {
                const js_val = try self.zigValueToJs(@field(value, f.name), opts);
                const key = v8.String.initUtf8(isolate, f.name);
                if (!js_obj.setValue(v8_context, key, js_val)) {
                    return error.CreateObjectFailure;
                }
            }
            return js_obj.toValue();
        },
        .@"union" => |un| {
            if (T == std.json.Value) {
                return zigJsonToJs(isolate, v8_context, value);
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
                return self.zigValueToJs(v, .{});
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
// First, if it's a struct, we need to put it on the heap
// Second, if we've already returned this instance, we should return
// the same object. Hence, our executor maintains a map of Zig objects
// to v8.PersistentObject (the "identity_map").
// Finally, if this is the first time we've seen this instance, we need to:
//  1 - get the FunctionTemplate (from our templates slice)
//  2 - Create the TaggedAnyOpaque so that, if needed, we can do the reverse
//      (i.e. js -> zig)
//  3 - Create a v8.PersistentObject (because Zig owns this object, not v8)
//  4 - Store our TaggedAnyOpaque into the persistent object
//  5 - Update our identity_map (so that, if we return this same instance again,
//      we can just grab it from the identity_map)
pub fn mapZigInstanceToJs(self: *Context, js_obj_: ?v8.Object, value: anytype) !PersistentObject {
    const v8_context = self.v8_context;
    const arena = self.arena;

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            // Struct, has to be placed on the heap
            const heap = try arena.create(T);
            heap.* = value;
            return self.mapZigInstanceToJs(js_obj_, heap);
        },
        .pointer => |ptr| {
            const resolved = resolveValue(value);

            const gop = try self.identity_map.getOrPut(arena, @intFromPtr(resolved.ptr));
            if (gop.found_existing) {
                // we've seen this instance before, return the same
                // PersistentObject.
                return gop.value_ptr.*;
            }

            const isolate = self.isolate;
            const JsApi = bridge.Struct(ptr.child).JsApi;

            // Sometimes we're creating a new v8.Object, like when
            // we're returning a value from a function. In those cases
            // we have to get the object template, and we can get an object
            // by calling initInstance its InstanceTemplate.
            // Sometimes though we already have the v8.Objct to bind to
            // for example, when we're executing a constructor, v8 has
            // already created the "this" object.
            const js_obj = js_obj_ orelse blk: {
                const template = self.templates[resolved.class_id];
                break :blk template.getInstanceTemplate().initInstance(v8_context);
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
                    js_obj.setInternalField(0, v8.External.init(isolate, tao));
                }
            } else {
                // If the struct is empty, we don't need to do all
                // the TOA stuff and setting the internal data.
                // When we try to map this from JS->Zig, in
                // typeTaggedAnyOpaque, we'll also know there that
                // the type is empty and can create an empty instance.
            }

            const js_persistent = PersistentObject.init(isolate, js_obj);
            gop.value_ptr.* = js_persistent;
            return js_persistent;
        },
        else => @compileError("Expected a struct or pointer, got " ++ @typeName(T) ++ " (constructors must return struct or pointers)"),
    }
}

pub fn jsValueToZig(self: *Context, comptime T: type, js_value: v8.Value) !T {
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
                    .context = self,
                    .js_val = js_value,
                };
            }

            if (comptime o.child == js.Object) {
                return js.Object{
                    .context = self,
                    .js_obj = js_value.castTo(v8.Object),
                };
            }

            if (js_value.isNullOrUndefined()) {
                return null;
            }
            return try self.jsValueToZig(o.child, js_value);
        },
        .float => |f| switch (f.bits) {
            0...32 => return js_value.toF32(self.v8_context),
            33...64 => return js_value.toF64(self.v8_context),
            else => {},
        },
        .int => return jsIntToZig(T, js_value, self.v8_context),
        .bool => return js_value.toBool(self.isolate),
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                if (!js_value.isObject()) {
                    return error.InvalidArgument;
                }
                if (@hasDecl(ptr.child, "JsApi")) {
                    std.debug.assert(bridge.JsApiLookup.has(ptr.child.JsApi));
                    const js_obj = js_value.castTo(v8.Object);
                    return typeTaggedAnyOpaque(*ptr.child, js_obj);
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

                const v8_context = self.v8_context;
                const js_arr = js_value.castTo(v8.Array);
                const js_obj = js_arr.castTo(v8.Object);

                // Newer version of V8 appear to have an optimized way
                // to do this (V8::Array has an iterate method on it)
                const arr = try self.call_arena.alloc(ptr.child, js_arr.length());
                for (arr, 0..) |*a, i| {
                    a.* = try self.jsValueToZig(ptr.child, try js_obj.getAtIndex(v8_context, @intCast(i)));
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
                .int => return std.meta.intToEnum(T, try jsIntToZig(e.tag_type, js_value, self.v8_context)),
                else => @compileError("unsupported enum parameter type: " ++ @typeName(T)),
            }
        },
        else => {},
    }

    @compileError("has an unsupported parameter type: " ++ @typeName(T));
}

// Extracted so that it can be used in both jsValueToZig and in
// probeJsValueToZig. Avoids having to duplicate this logic when probing.
fn jsValueToStruct(self: *Context, comptime T: type, js_value: v8.Value) !?T {
    return switch (T) {
        js.Function => {
            if (!js_value.isFunction()) {
                return null;
            }
            return try self.createFunction(js_value);
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
            .js_val = js_value,
            .context = self,
        },
        // Caller wants an opaque js.Object. Probably a parameter
        // that it needs to pass back into a callback.
        js.Object => js.Object{
            .js_obj = js_value.castTo(v8.Object),
            .context = self,
        },
        else => {
            if (!js_value.isObject()) {
                return null;
            }

            const js_obj = js_value.castTo(v8.Object);
            const v8_context = self.v8_context;
            const isolate = self.isolate;

            var value: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const name = field.name;
                const key = v8.String.initUtf8(isolate, name);
                if (js_obj.has(v8_context, key.toValue())) {
                    @field(value, name) = try self.jsValueToZig(field.type, try js_obj.getValue(v8_context, key));
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

fn jsValueToTypedArray(_: *Context, comptime T: type, js_value: v8.Value) !?[]T {
    var force_u8 = false;
    var array_buffer: ?v8.ArrayBuffer = null;
    var byte_len: usize = undefined;
    var byte_offset: usize = undefined;

    if (js_value.isTypedArray()) {
        const buffer_view = js_value.castTo(v8.ArrayBufferView);
        byte_len = buffer_view.getByteLength();
        byte_offset = buffer_view.getByteOffset();
        array_buffer = buffer_view.getBuffer();
    } else if (js_value.isArrayBufferView()) {
        force_u8 = true;
        const buffer_view = js_value.castTo(v8.ArrayBufferView);
        byte_len = buffer_view.getByteLength();
        byte_offset = buffer_view.getByteOffset();
        array_buffer = buffer_view.getBuffer();
    } else if (js_value.isArrayBuffer()) {
        force_u8 = true;
        array_buffer = js_value.castTo(v8.ArrayBuffer);
        byte_len = array_buffer.?.getByteLength();
        byte_offset = 0;
    }

    const buffer = array_buffer orelse return null;

    const backing_store = v8.BackingStore.sharedPtrGet(&buffer.getBackingStore());
    const data = backing_store.getData();

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
const valueToStringOpts = struct {
    allocator: ?Allocator = null,
};
pub fn valueToString(self: *const Context, js_val: v8.Value, opts: valueToStringOpts) ![]u8 {
    const allocator = opts.allocator orelse self.call_arena;
    if (js_val.isSymbol()) {
        const js_sym = v8.Symbol{ .handle = js_val.handle };
        const js_sym_desc = js_sym.getDescription(self.isolate);
        return self.valueToString(js_sym_desc, .{});
    }
    const str = try js_val.toString(self.v8_context);
    return self.jsStringToZig(str, .{ .allocator = allocator });
}

pub fn valueToStringZ(self: *const Context, js_val: v8.Value, opts: valueToStringOpts) ![:0]u8 {
    const allocator = opts.allocator orelse self.call_arena;
    if (js_val.isSymbol()) {
        const js_sym = v8.Symbol{ .handle = js_val.handle };
        const js_sym_desc = js_sym.getDescription(self.isolate);
        return self.valueToStringZ(js_sym_desc, .{});
    }
    const str = try js_val.toString(self.v8_context);
    return self.jsStringToZigZ(str, .{ .allocator = allocator });
}

const JsStringToZigOpts = struct {
    allocator: ?Allocator = null,
};
pub fn jsStringToZig(self: *const Context, str: v8.String, opts: JsStringToZigOpts) ![]u8 {
    const allocator = opts.allocator orelse self.call_arena;
    const len = str.lenUtf8(self.isolate);
    const buf = try allocator.alloc(u8, len);
    const n = str.writeUtf8(self.isolate, buf);
    std.debug.assert(n == len);
    return buf;
}

pub fn jsStringToZigZ(self: *const Context, str: v8.String, opts: JsStringToZigOpts) ![:0]u8 {
    const allocator = opts.allocator orelse self.call_arena;
    const len = str.lenUtf8(self.isolate);
    const buf = try allocator.allocSentinel(u8, len, 0);
    const n = str.writeUtf8(self.isolate, buf);
    std.debug.assert(n == len);
    return buf;
}

pub fn debugValue(self: *const Context, js_val: v8.Value, writer: *std.Io.Writer) !void {
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    return _debugValue(self, js_val, &seen, 0, writer) catch error.WriteFailed;
}

fn _debugValue(self: *const Context, js_val: v8.Value, seen: *std.AutoHashMapUnmanaged(u32, void), depth: usize, writer: *std.Io.Writer) !void {
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
            const js_sym = v8.Symbol{ .handle = js_val.handle };
            const js_sym_desc = js_sym.getDescription(self.isolate);
            const js_sym_str = try self.valueToString(js_sym_desc, .{});
            return writer.print("{s} (symbol)", .{js_sym_str});
        }
        const js_type = try self.jsStringToZig(try js_val.typeOf(self.isolate), .{});
        const js_val_str = try self.valueToString(js_val, .{});
        if (js_val_str.len > 2000) {
            try writer.writeAll(js_val_str[0..2000]);
            try writer.writeAll(" ... (truncated)");
        } else {
            try writer.writeAll(js_val_str);
        }
        return writer.print(" ({s})", .{js_type});
    }

    const js_obj = js_val.castTo(v8.Object);
    {
        // explicit scope because gop will become invalid in recursive call
        const gop = try seen.getOrPut(self.call_arena, js_obj.getIdentityHash());
        if (gop.found_existing) {
            return writer.writeAll("<circular>\n");
        }
        gop.value_ptr.* = {};
    }

    const v8_context = self.v8_context;
    const names_arr = js_obj.getOwnPropertyNames(v8_context);
    const names_obj = names_arr.castTo(v8.Object);
    const len = names_arr.length();

    if (depth > 20) {
        return writer.writeAll("...deeply nested object...");
    }
    const own_len = js_obj.getOwnPropertyNames(v8_context).length();
    if (own_len == 0) {
        const js_val_str = try self.valueToString(js_val, .{});
        if (js_val_str.len > 2000) {
            try writer.writeAll(js_val_str[0..2000]);
            return writer.writeAll(" ... (truncated)");
        }
        return writer.writeAll(js_val_str);
    }

    const all_len = js_obj.getPropertyNames(v8_context).length();
    try writer.print("({d}/{d})", .{ own_len, all_len });
    for (0..len) |i| {
        if (i == 0) {
            try writer.writeByte('\n');
        }
        const field_name = try names_obj.getAtIndex(v8_context, @intCast(i));
        const name = try self.valueToString(field_name, .{});
        try writer.splatByteAll(' ', depth);
        try writer.writeAll(name);
        try writer.writeAll(": ");
        try self._debugValue(try js_obj.getValue(v8_context, field_name), seen, depth + 1, writer);
        if (i != len - 1) {
            try writer.writeByte('\n');
        }
    }
}

pub fn stackTrace(self: *const Context) !?[]const u8 {
    if (comptime @import("builtin").mode != .Debug) {
        return "not available";
    }

    const isolate = self.isolate;
    const separator = log.separator();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var writer = buf.writer(self.call_arena);

    const stack_trace = v8.StackTrace.getCurrentStackTrace(isolate, 30);
    const frame_count = stack_trace.getFrameCount();

    if (v8.StackTrace.getCurrentScriptNameOrSourceUrl(isolate)) |script| {
        try writer.print("{s}<{s}>", .{ separator, try self.jsStringToZig(script, .{}) });
    }

    for (0..frame_count) |i| {
        const frame = stack_trace.getFrame(isolate, @intCast(i));
        if (frame.getScriptName()) |name| {
            const script = try self.jsStringToZig(name, .{});
            try writer.print("{s}{s}:{d}", .{ separator, script, frame.getLineNumber() });
        } else {
            try writer.print("{s}<anonymous>:{d}", .{ separator, frame.getLineNumber() });
        }
    }
    return buf.items;
}

// == Promise Helpers ==
pub fn rejectPromise(self: *Context, value: anytype) !js.Promise {
    const ctx = self.v8_context;
    var resolver = v8.PromiseResolver.init(ctx);
    const js_value = try self.zigValueToJs(value, .{});
    if (resolver.reject(ctx, js_value) == null) {
        return error.FailedToResolvePromise;
    }
    self.runMicrotasks();
    return resolver.getPromise();
}

pub fn resolvePromise(self: *Context, value: anytype) !js.Promise {
    const ctx = self.v8_context;
    const js_value = try self.zigValueToJs(value, .{});

    var resolver = v8.PromiseResolver.init(ctx);
    if (resolver.resolve(ctx, js_value) == null) {
        return error.FailedToResolvePromise;
    }
    self.runMicrotasks();
    return resolver.getPromise();
}

pub fn runMicrotasks(self: *Context) void {
    self.isolate.performMicrotasksCheckpoint();
}

// creates a PersistentPromiseResolver, taking in a lifetime parameter.
// If the lifetime is page, the page will clean up the PersistentPromiseResolver.
// If the lifetime is self, you will be expected to deinitalize the PersistentPromiseResolver.
const PromiseResolverLifetime = enum {
    none,
    self, // it's a persisted promise, but it'll be managed by the caller
    page, // it's a persisted promise, tied to the page lifetime
};
fn PromiseResolverType(comptime lifetime: PromiseResolverLifetime) type {
    if (lifetime == .none) {
        return js.PromiseResolver;
    }
    return error{OutOfMemory}!js.PersistentPromiseResolver;
}
pub fn createPromiseResolver(self: *Context, comptime lifetime: PromiseResolverLifetime) PromiseResolverType(lifetime) {
    const resolver = v8.PromiseResolver.init(self.v8_context);
    if (comptime lifetime == .none) {
        return .{ .context = self, .resolver = resolver };
    }

    const persisted = v8.Persistent(v8.PromiseResolver).init(self.isolate, resolver);

    if (comptime lifetime == .page) {
        try self.persisted_promise_resolvers.append(self.arena, persisted);
    }

    return .{
        .context = self,
        .resolver = persisted,
    };
}

// == Callbacks ==
// Callback from V8, asking us to load a module. The "specifier" is
// the src of the module to load.
fn resolveModuleCallback(
    c_context: ?*const v8.C_Context,
    c_specifier: ?*const v8.C_String,
    import_attributes: ?*const v8.C_FixedArray,
    c_referrer: ?*const v8.C_Module,
) callconv(.c) ?*const v8.C_Module {
    _ = import_attributes;

    const self = fromC(c_context.?);

    const specifier = self.jsStringToZigZ(.{ .handle = c_specifier.? }, .{}) catch |err| {
        log.err(.js, "resolve module", .{ .err = err });
        return null;
    };
    const referrer = v8.Module{ .handle = c_referrer.? };

    return self._resolveModuleCallback(referrer, specifier) catch |err| {
        log.err(.js, "resolve module", .{
            .err = err,
            .specifier = specifier,
        });
        return null;
    };
}

pub fn dynamicModuleCallback(
    c_context: ?*const v8.c.Context,
    host_defined_options: ?*const v8.c.Data,
    resource_name: ?*const v8.c.Value,
    v8_specifier: ?*const v8.c.String,
    import_attrs: ?*const v8.c.FixedArray,
) callconv(.c) ?*v8.c.Promise {
    _ = host_defined_options;
    _ = import_attrs;

    const self = fromC(c_context.?);

    const resource = self.jsStringToZigZ(.{ .handle = resource_name.? }, .{}) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback1" });
        return @constCast((self.rejectPromise("Out of memory") catch return null).handle);
    };

    const specifier = self.jsStringToZigZ(.{ .handle = v8_specifier.? }, .{}) catch |err| {
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

pub fn metaObjectCallback(c_context: ?*v8.C_Context, c_module: ?*v8.C_Module, c_meta: ?*v8.C_Value) callconv(.c) void {
    const self = fromC(c_context.?);
    const m = v8.Module{ .handle = c_module.? };
    const meta = v8.Object{ .handle = c_meta.? };

    const url = self.module_identifier.get(m.getIdentityHash()) orelse {
        // Shouldn't be possible.
        log.err(.js, "import meta", .{ .err = error.UnknownModuleReferrer });
        return;
    };

    const js_key = v8.String.initUtf8(self.isolate, "url");
    const js_value = try self.zigValueToJs(url, .{});
    const res = meta.defineOwnProperty(self.v8_context, js_key.toName(), js_value, 0) orelse false;
    if (!res) {
        log.err(.js, "import meta", .{ .err = error.FailedToSet });
    }
}

fn _resolveModuleCallback(self: *Context, referrer: v8.Module, specifier: [:0]const u8) !?*const v8.C_Module {
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
        return m.castToModule().handle;
    }

    var source = try self.script_manager.?.waitForImport(normalized_specifier);
    defer source.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(self);
    defer try_catch.deinit();

    const mod = try compileModule(self.isolate, source.src(), normalized_specifier);
    try self.postCompileModule(mod, normalized_specifier);
    entry.module = PersistentModule.init(self.isolate, mod);
    return entry.module.?.castToModule().handle;
}

// Will get passed to ScriptManager and then passed back to us when
// the src of the module is loaded
const DynamicModuleResolveState = struct {
    // The module that we're resolving (we'll actually resolve its
    // namespace)
    module: ?v8.Module,
    context_id: usize,
    context: *Context,
    specifier: [:0]const u8,
    resolver: v8.Persistent(v8.PromiseResolver),
};

fn _dynamicModuleCallback(self: *Context, specifier: [:0]const u8, referrer: []const u8) !v8.Promise {
    const isolate = self.isolate;
    const gop = try self.module_cache.getOrPut(self.arena, specifier);
    if (gop.found_existing and gop.value_ptr.resolver_promise != null) {
        // This is easy, there's already something responsible
        // for loading the module. Maybe it's still loading, maybe
        // it's complete. Whatever, we can just return that promise.
        return gop.value_ptr.resolver_promise.?.castToPromise();
    }

    const persistent_resolver = v8.Persistent(v8.PromiseResolver).init(isolate, v8.PromiseResolver.init(self.v8_context));
    try self.persisted_promise_resolvers.append(self.arena, persistent_resolver);
    var resolver = persistent_resolver.castToPromiseResolver();

    const state = try self.arena.create(DynamicModuleResolveState);

    state.* = .{
        .module = null,
        .context = self,
        .specifier = specifier,
        .context_id = self.id,
        .resolver = persistent_resolver,
    };

    const persisted_promise = PersistentPromise.init(self.isolate, resolver.getPromise());
    const promise = persisted_promise.castToPromise();

    if (!gop.found_existing) {
        // this module hasn't been seen before. This is the most
        // complicated path.

        // First, we'll setup a bare entry into our cache. This will
        // prevent anyone one else from trying to asychronously load
        // it. Instead, they can just return our promise.
        gop.value_ptr.* = ModuleEntry{
            .module = null,
            .module_promise = null,
            .resolver_promise = persisted_promise,
        };

        // Next, we need to actually load it.
        self.script_manager.?.getAsyncImport(specifier, dynamicModuleSourceCallback, state, referrer) catch |err| {
            const error_msg = v8.String.initUtf8(isolate, @errorName(err));
            _ = resolver.reject(self.v8_context, error_msg.toValue());
        };

        // For now, we're done. but this will be continued in
        // `dynamicModuleSourceCallback`, once the source for the
        // moduel is loaded.
        return promise;
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
        const mod = gop.value_ptr.module.?.castToModule();
        const status = mod.getStatus();
        if (status == .kEvaluated or status == .kEvaluating) {
            // Module was already evaluated (shouldn't normally happen, but handle it).
            // Create a pre-resolved promise with the module namespace.
            const persisted_module_resolver = v8.Persistent(v8.PromiseResolver).init(isolate, v8.PromiseResolver.init(self.v8_context));
            try self.persisted_promise_resolvers.append(self.arena, persisted_module_resolver);
            var module_resolver = persisted_module_resolver.castToPromiseResolver();
            _ = module_resolver.resolve(self.v8_context, mod.getModuleNamespace());
            gop.value_ptr.module_promise = PersistentPromise.init(self.isolate, module_resolver.getPromise());
        } else {
            // the module was loaded, but not evaluated, we _have_ to evaluate it now
            const evaluated = mod.evaluate(self.v8_context) catch {
                std.debug.assert(status == .kErrored);
                const error_msg = v8.String.initUtf8(isolate, "Module evaluation failed");
                _ = resolver.reject(self.v8_context, error_msg.toValue());
                return promise;
            };
            std.debug.assert(evaluated.isPromise());
            gop.value_ptr.module_promise = PersistentPromise.init(self.isolate, .{ .handle = evaluated.handle });
        }
    }

    // like before, we want to set this up so that if anything else
    // tries to load this module, it can just return our promise
    // since we're going to be doing all the work.
    gop.value_ptr.resolver_promise = persisted_promise;

    // But we can skip direclty to `resolveDynamicModule` which is
    // what the above callback will eventually do.
    self.resolveDynamicModule(state, gop.value_ptr.*);
    return promise;
}

fn dynamicModuleSourceCallback(ctx: *anyopaque, module_source_: anyerror!ScriptManager.ModuleSource) void {
    const state: *DynamicModuleResolveState = @ptrCast(@alignCast(ctx));
    var self = state.context;

    var ms = module_source_ catch |err| {
        const error_msg = v8.String.initUtf8(self.isolate, @errorName(err));
        _ = state.resolver.castToPromiseResolver().reject(self.v8_context, error_msg.toValue());
        return;
    };

    const module_entry = blk: {
        defer ms.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(self);
        defer try_catch.deinit();

        break :blk self.module(true, ms.src(), state.specifier, true) catch {
            const ex = try_catch.exception(self.call_arena) catch |err| @errorName(err) orelse "unknown error";
            log.err(.js, "module compilation failed", .{
                .specifier = state.specifier,
                .exception = ex,
                .stack = try_catch.stack(self.call_arena) catch null,
                .line = try_catch.sourceLineNumber() orelse 0,
            });
            const error_msg = v8.String.initUtf8(self.isolate, ex);
            _ = state.resolver.castToPromiseResolver().reject(self.v8_context, error_msg.toValue());
            return;
        };
    };

    self.resolveDynamicModule(state, module_entry);
}

fn resolveDynamicModule(self: *Context, state: *DynamicModuleResolveState, module_entry: ModuleEntry) void {
    defer self.runMicrotasks();
    const ctx = self.v8_context;
    const isolate = self.isolate;
    const external = v8.External.init(self.isolate, @ptrCast(state));

    // we can only be here if the module has been evaluated and if
    // we have a resolve loading this asynchronously.
    std.debug.assert(module_entry.module_promise != null);
    std.debug.assert(module_entry.resolver_promise != null);
    std.debug.assert(self.module_cache.contains(state.specifier));
    state.module = module_entry.module.?.castToModule();

    // We've gotten the source for the module and are evaluating it.
    // You might think we're done, but the module evaluation is
    // itself asynchronous. We need to chain to the module's own
    // promise. When the module is evaluated, it resolves to the
    // last value of the module. But, for module loading, we need to
    // resolve to the module's namespace.

    const then_callback = v8.Function.initWithData(ctx, struct {
        pub fn callback(raw_info: ?*const v8.c.FunctionCallbackInfo) callconv(.c) void {
            var info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            var caller = Caller.init(info);
            defer caller.deinit();

            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(info.getExternalValue()));

            if (s.context_id != caller.context.id) {
                // The microtask is tied to the isolate, not the context
                // it can be resolved while another context is active
                // (Which seems crazy to me). If that happens, then
                // another page was loaded and we MUST ignore this
                // (most of the fields in state are not valid)
                return;
            }

            defer caller.context.runMicrotasks();
            const namespace = s.module.?.getModuleNamespace();
            _ = s.resolver.castToPromiseResolver().resolve(caller.context.v8_context, namespace);
        }
    }.callback, external);

    const catch_callback = v8.Function.initWithData(ctx, struct {
        pub fn callback(raw_info: ?*const v8.c.FunctionCallbackInfo) callconv(.c) void {
            var info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            var caller = Caller.init(info);
            defer caller.deinit();

            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(info.getExternalValue()));
            if (s.context_id != caller.context.id) {
                return;
            }
            defer caller.context.runMicrotasks();
            _ = s.resolver.castToPromiseResolver().reject(caller.context.v8_context, info.getData());
        }
    }.callback, external);

    _ = module_entry.module_promise.?.castToPromise().thenAndCatch(ctx, then_callback, catch_callback) catch |err| {
        log.err(.js, "module evaluation is promise", .{
            .err = err,
            .specifier = state.specifier,
        });
        const error_msg = v8.String.initUtf8(isolate, "Failed to evaluate promise");
        _ = state.resolver.castToPromiseResolver().reject(ctx, error_msg.toValue());
    };
}

// ==  Zig <-> JS ==

// Reverses the mapZigInstanceToJs, making sure that our TaggedAnyOpaque
// contains a ptr to the correct type.
pub fn typeTaggedAnyOpaque(comptime R: type, js_obj: v8.Object) !R {
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

    // Special case for Window: the global object doesn't have internal fields
    // Window instance is stored in context.page.window instead
    if (js_obj.internalFieldCount() == 0) {
        // Normally, this would be an error. All JsObject that map to a Zig type
        // are either `empty_with_no_proto` (handled above) or have an
        // interalFieldCount. The only exception to that is the Window...
        const isolate = js_obj.getIsolate();
        const context = fromIsolate(isolate);

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
    if (js_obj.internalFieldCount() == 0) {
        return error.InvalidArgument;
    }

    if (!bridge.JsApiLookup.has(JsApi)) {
        @compileError("unknown Zig type: " ++ @typeName(R));
    }

    const op = js_obj.getInternalField(0).castTo(v8.External).get();
    const tao: *TaggedAnyOpaque = @ptrCast(@alignCast(op));
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
fn probeJsValueToZig(self: *Context, comptime T: type, js_value: v8.Value) !ProbeResult(T) {
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
                    const js_obj = js_value.castTo(v8.Object);
                    // There's a bit of overhead in doing this, so instead
                    // of having a version of typeTaggedAnyOpaque which
                    // returns a boolean or an optional, we rely on the
                    // main implementation and just handle the error.
                    const attempt = typeTaggedAnyOpaque(*ptr.child, js_obj);
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
                const js_arr = js_value.castTo(v8.Array);

                if (js_arr.length() == 0) {
                    // not so tricky in this case.
                    return .{ .value = &.{} };
                }

                // We settle for just probing the first value. Ok, actually
                // not tricky in this case either.
                const v8_context = self.v8_context;
                const js_obj = js_arr.castTo(v8.Object);
                switch (try self.probeJsValueToZig(ptr.child, try js_obj.getAtIndex(v8_context, 0))) {
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
                        const js_arr = js_value.castTo(v8.Array);
                        if (js_arr.length() == arr.len) {
                            return .{ .ok = {} };
                        }
                    } else if (js_value.isString() and arr.child == u8) {
                        const str = try js_value.toString(self.v8_context);
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

fn jsIntToZig(comptime T: type, js_value: v8.Value, v8_context: v8.Context) !T {
    const n = @typeInfo(T).int;
    switch (n.signedness) {
        .signed => switch (n.bits) {
            8 => return jsSignedIntToZig(i8, -128, 127, try js_value.toI32(v8_context)),
            16 => return jsSignedIntToZig(i16, -32_768, 32_767, try js_value.toI32(v8_context)),
            32 => return jsSignedIntToZig(i32, -2_147_483_648, 2_147_483_647, try js_value.toI32(v8_context)),
            64 => {
                if (js_value.isBigInt()) {
                    const v = js_value.castTo(v8.BigInt);
                    return v.getInt64();
                }
                return jsSignedIntToZig(i64, -2_147_483_648, 2_147_483_647, try js_value.toI32(v8_context));
            },
            else => {},
        },
        .unsigned => switch (n.bits) {
            8 => return jsUnsignedIntToZig(u8, 255, try js_value.toU32(v8_context)),
            16 => return jsUnsignedIntToZig(u16, 65_535, try js_value.toU32(v8_context)),
            32 => {
                if (js_value.isBigInt()) {
                    const v = js_value.castTo(v8.BigInt);
                    const large = v.getUint64();
                    if (large <= 4_294_967_295) {
                        return @intCast(large);
                    }
                    return error.InvalidArgument;
                }
                return jsUnsignedIntToZig(u32, 4_294_967_295, try js_value.toU32(v8_context));
            },
            64 => {
                if (js_value.isBigInt()) {
                    const v = js_value.castTo(v8.BigInt);
                    return v.getUint64();
                }
                return jsUnsignedIntToZig(u64, 4_294_967_295, try js_value.toU32(v8_context));
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

fn compileScript(isolate: v8.Isolate, ctx: v8.Context, src: []const u8, name: ?[]const u8) !v8.Script {
    // compile
    const script_name = v8.String.initUtf8(isolate, name orelse "anonymous");
    const script_source = v8.String.initUtf8(isolate, src);

    const origin = v8.ScriptOrigin.initDefault(script_name.toValue());

    var script_comp_source: v8.ScriptCompilerSource = undefined;
    v8.ScriptCompilerSource.init(&script_comp_source, script_source, origin, null);
    defer script_comp_source.deinit();

    return v8.ScriptCompiler.compile(
        ctx,
        &script_comp_source,
        .kNoCompileOptions,
        .kNoCacheNoReason,
    ) catch return error.CompilationError;
}

fn compileModule(isolate: v8.Isolate, src: []const u8, name: []const u8) !v8.Module {
    // compile
    const script_name = v8.String.initUtf8(isolate, name);
    const script_source = v8.String.initUtf8(isolate, src);

    const origin = v8.ScriptOrigin.init(
        script_name.toValue(),
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

    var script_comp_source: v8.ScriptCompilerSource = undefined;
    v8.ScriptCompilerSource.init(&script_comp_source, script_source, origin, null);
    defer script_comp_source.deinit();

    return v8.ScriptCompiler.compileModule(
        isolate,
        &script_comp_source,
        .kNoCompileOptions,
        .kNoCacheNoReason,
    ) catch return error.CompilationError;
}

fn zigJsonToJs(isolate: v8.Isolate, v8_context: v8.Context, value: std.json.Value) !v8.Value {
    switch (value) {
        .bool => |v| return js.simpleZigValueToJs(isolate, v, true, false),
        .float => |v| return js.simpleZigValueToJs(isolate, v, true, false),
        .integer => |v| return js.simpleZigValueToJs(isolate, v, true, false),
        .string => |v| return js.simpleZigValueToJs(isolate, v, true, false),
        .null => return isolate.initNull().toValue(),

        // TODO handle number_string.
        // It is used to represent too big numbers.
        .number_string => return error.TODO,

        .array => |v| {
            const a = v8.Array.init(isolate, @intCast(v.items.len));
            const obj = a.castTo(v8.Object);
            for (v.items, 0..) |array_value, i| {
                const js_val = try zigJsonToJs(isolate, v8_context, array_value);
                if (!obj.setValueAtIndex(v8_context, @intCast(i), js_val)) {
                    return error.JSObjectSetValue;
                }
            }
            return obj.toValue();
        },
        .object => |v| {
            var obj = v8.Object.init(isolate);
            var it = v.iterator();
            while (it.next()) |kv| {
                const js_key = v8.String.initUtf8(isolate, kv.key_ptr.*);
                const js_val = try zigJsonToJs(isolate, v8_context, kv.value_ptr.*);
                if (!obj.setValue(v8_context, js_key, js_val)) {
                    return error.JSObjectSetValue;
                }
            }
            return obj.toValue();
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
    self.isolate.enqueueMicrotaskFunc(cb.func.castToFunction());
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
    if (builtin.mode != .Debug) {
        // Still testing this out, don't have it properly exposed, so add this
        // guard for the time being to prevent any accidental/weird prod issues.
        @compileError("CPU Profiling is only available in debug builds");
    }

    std.debug.assert(self.cpu_profiler == null);
    v8.CpuProfiler.useDetailedSourcePositionsForProfiling(self.isolate);
    const cpu_profiler = v8.CpuProfiler.init(self.isolate);
    const title = self.isolate.initStringUtf8("v8_cpu_profile");
    cpu_profiler.startProfiling(title);
    self.cpu_profiler = cpu_profiler;
}

pub fn stopCpuProfiler(self: *Context) ![]const u8 {
    const title = self.isolate.initStringUtf8("v8_cpu_profile");
    const profile = self.cpu_profiler.?.stopProfiling(title) orelse unreachable;
    const serialized = profile.serialize(self.isolate).?;
    return self.jsStringToZig(serialized, .{});
}
