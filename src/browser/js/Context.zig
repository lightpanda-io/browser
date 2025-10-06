const std = @import("std");
const builtin = @import("builtin");

const js = @import("js.zig");
const v8 = js.v8;

const log = @import("../../log.zig");
const Page = @import("../page.zig").Page;
const ScriptManager = @import("../ScriptManager.zig");

const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const Caller = @import("Caller.zig");
const NamedFunction = Caller.NamedFunction;
const PersistentObject = v8.Persistent(v8.Object);
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

// references Env.templates
templates: []v8.FunctionTemplate,

// references the Env.meta_lookup
meta_lookup: []types.Meta,

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
module_identifier: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

// the page's script manager
script_manager: ?*ScriptManager,

// Global callback is called on missing property.
global_callback: ?js.GlobalMissingCallback = null,

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
    _ = try self.mapZigInstanceToJs(self.v8_context.getGlobal(), &self.page.window);
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
    if (cacheable) {
        if (self.module_cache.get(url)) |entry| {
            // The dynamic import will create an entry without the
            // module to prevent multiple calls from asynchronously
            // loading the same module. If we're here, without the
            // module, then it's time to load it.
            if (entry.module != null) {
                return if (comptime want_result) entry else {};
            }
        }
    }
    errdefer _ = self.module_cache.remove(url);

    const m = try compileModule(self.isolate, src, url);

    const arena = self.arena;
    const owned_url = try arena.dupe(u8, url);

    try self.module_identifier.putNoClobber(arena, m.getIdentityHash(), owned_url);
    errdefer _ = self.module_identifier.remove(m.getIdentityHash());

    const v8_context = self.v8_context;
    {
        // Non-async modules are blocking. We can download them in
        // parallel, but they need to be processed serially. So we
        // want to get the list of dependent modules this module has
        // and start downloading them asap.
        const requests = m.getModuleRequests();
        for (0..requests.length()) |i| {
            const req = requests.get(v8_context, @intCast(i)).castTo(v8.ModuleRequest);
            const specifier = try self.jsStringToZig(req.getSpecifier(), .{});
            const normalized_specifier = try @import("../../url.zig").stitch(
                self.call_arena,
                specifier,
                owned_url,
                .{ .alloc = .if_needed, .null_terminated = true },
            );
            const gop = try self.module_cache.getOrPut(self.arena, normalized_specifier);
            if (!gop.found_existing) {
                const owned_specifier = try self.arena.dupeZ(u8, normalized_specifier);
                gop.key_ptr.* = owned_specifier;
                gop.value_ptr.* = .{};
                try self.script_manager.?.getModule(owned_specifier, src);
            }
        }
    }

    if (try m.instantiate(v8_context, resolveModuleCallback) == false) {
        return error.ModuleInstantiationError;
    }

    const evaluated = try m.evaluate(v8_context);
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

    const persisted_module = PersistentModule.init(self.isolate, m);
    const persisted_promise = PersistentPromise.init(self.isolate, .{ .handle = evaluated.handle });

    var gop = try self.module_cache.getOrPut(arena, owned_url);
    if (gop.found_existing) {
        // If we're here, it's because we had a cache entry, but no
        // module. This happens because both our synch and async
        // module loaders create the entry to prevent concurrent
        // loads of the same resource (like Go's Singleflight).
        std.debug.assert(gop.value_ptr.module == null);
        std.debug.assert(gop.value_ptr.module_promise == null);

        gop.value_ptr.module = persisted_module;
        gop.value_ptr.module_promise = persisted_promise;
    } else {
        gop.value_ptr.* = ModuleEntry{
            .module = persisted_module,
            .module_promise = persisted_promise,
            .resolver_promise = null,
        };
    }
    return if (comptime want_result) gop.value_ptr.* else {};
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
pub fn createValue(self: *const Context, value: v8.Value) js.Value {
    return .{
        .value = value,
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

pub fn zigValueToJs(self: *Context, value: anytype) !v8.Value {
    const isolate = self.isolate;

    // Check if it's a "simple" type. This is extracted so that it can be
    // reused by other parts of the code. "simple" types only require an
    // isolate to create (specifically, they don't our templates array)
    if (js.simpleZigValueToJs(isolate, value, false)) |js_value| {
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
                const js_val = try self.zigValueToJs(v);
                if (js_obj.setValueAtIndex(v8_context, @intCast(i), js_val) == false) {
                    return error.FailedToCreateArray;
                }
            }
            return js_obj.toValue();
        },
        .pointer => |ptr| switch (ptr.size) {
            .one => {
                const type_name = @typeName(ptr.child);
                if (@hasField(types.Lookup, type_name)) {
                    const template = self.templates[@field(types.LOOKUP, type_name)];
                    const js_obj = try self.mapZigInstanceToJs(template, value);
                    return js_obj.toValue();
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
                    const js_val = try self.zigValueToJs(v);
                    if (js_obj.setValueAtIndex(v8_context, @intCast(i), js_val) == false) {
                        return error.FailedToCreateArray;
                    }
                }
                return js_obj.toValue();
            },
            else => {},
        },
        .@"struct" => |s| {
            const type_name = @typeName(T);
            if (@hasField(types.Lookup, type_name)) {
                const template = self.templates[@field(types.LOOKUP, type_name)];
                const js_obj = try self.mapZigInstanceToJs(template, value);
                return js_obj.toValue();
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
                return value.value;
            }

            if (T == js.Promise) {
                // we're returning a v8.Promise
                return value.toObject().toValue();
            }

            if (T == js.Exception) {
                return isolate.throwException(value.inner);
            }

            if (s.is_tuple) {
                // return the tuple struct as an array
                var js_arr = v8.Array.init(isolate, @intCast(s.fields.len));
                var js_obj = js_arr.castTo(v8.Object);
                inline for (s.fields, 0..) |f, i| {
                    const js_val = try self.zigValueToJs(@field(value, f.name));
                    if (js_obj.setValueAtIndex(v8_context, @intCast(i), js_val) == false) {
                        return error.FailedToCreateArray;
                    }
                }
                return js_obj.toValue();
            }

            // return the struct as a JS object
            const js_obj = v8.Object.init(isolate);
            inline for (s.fields) |f| {
                const js_val = try self.zigValueToJs(@field(value, f.name));
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
                        return self.zigValueToJs(@field(value, field.name));
                    }
                }
                unreachable;
            }
            @compileError("Cannot use untagged union: " ++ @typeName(T));
        },
        .optional => {
            if (value) |v| {
                return self.zigValueToJs(v);
            }
            return v8.initNull(isolate).toValue();
        },
        .error_union => return self.zigValueToJs(try value),
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
pub fn mapZigInstanceToJs(self: *Context, js_obj_or_template: anytype, value: anytype) !PersistentObject {
    const v8_context = self.v8_context;
    const arena = self.arena;

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            // Struct, has to be placed on the heap
            const heap = try arena.create(T);
            heap.* = value;
            return self.mapZigInstanceToJs(js_obj_or_template, heap);
        },
        .pointer => |ptr| {
            const gop = try self.identity_map.getOrPut(arena, @intFromPtr(value));
            if (gop.found_existing) {
                // we've seen this instance before, return the same
                // PersistentObject.
                return gop.value_ptr.*;
            }

            if (comptime @hasDecl(ptr.child, "destructor")) {
                try self.destructor_callbacks.append(arena, DestructorCallback.init(value));
            }

            // Sometimes we're creating a new v8.Object, like when
            // we're returning a value from a function. In those cases
            // we have the FunctionTemplate, and we can get an object
            // by calling initInstance its InstanceTemplate.
            // Sometimes though we already have the v8.Objct to bind to
            // for example, when we're executing a constructor, v8 has
            // already created the "this" object.
            const js_obj = switch (@TypeOf(js_obj_or_template)) {
                v8.Object => js_obj_or_template,
                v8.FunctionTemplate => js_obj_or_template.getInstanceTemplate().initInstance(v8_context),
                else => @compileError("mapZigInstanceToJs requires a v8.Object (constructors) or v8.FunctionTemplate, got: " ++ @typeName(@TypeOf(js_obj_or_template))),
            };

            const isolate = self.isolate;

            if (comptime types.isEmpty(ptr.child) == false) {
                // The TAO contains the pointer ot our Zig instance as
                // well as any meta data we'll need to use it later.
                // See the TaggedAnyOpaque struct for more details.
                const tao = try arena.create(TaggedAnyOpaque);
                const meta_index = @field(types.LOOKUP, @typeName(ptr.child));
                const meta = self.meta_lookup[meta_index];

                tao.* = .{
                    .ptr = value,
                    .index = meta.index,
                    .subtype = meta.subtype,
                };

                js_obj.setInternalField(0, v8.External.init(isolate, tao));
            } else {
                // If the struct is empty, we don't need to do all
                // the TOA stuff and setting the internal data.
                // When we try to map this from JS->Zig, in
                // typeTaggedAnyOpaque, we'll also know there that
                // the type is empty and can create an empty instance.
            }

            // Do not move this _AFTER_ the postAttach code.
            // postAttach is likely to call back into this function
            // mutating our identity_map, and making the gop pointers
            // invalid.
            const js_persistent = PersistentObject.init(isolate, js_obj);
            gop.value_ptr.* = js_persistent;

            if (@hasDecl(ptr.child, "postAttach")) {
                const obj_wrap = js.This{ .obj = .{ .js_obj = js_obj, .context = self } };
                switch (@typeInfo(@TypeOf(ptr.child.postAttach)).@"fn".params.len) {
                    2 => try value.postAttach(obj_wrap),
                    3 => try value.postAttach(self.page, obj_wrap),
                    else => @compileError(@typeName(ptr.child) ++ ".postAttach must take 2 or 3 parameters"),
                }
            }

            return js_persistent;
        },
        else => @compileError("Expected a struct or pointer, got " ++ @typeName(T) ++ " (constructors must return struct or pointers)"),
    }
}

pub fn jsValueToZig(self: *Context, comptime named_function: NamedFunction, comptime T: type, js_value: v8.Value) !T {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (comptime o.child == js.Object) {
                // If type type is a ?js.Object, then we want to pass
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
                return js.Object{
                    .context = self,
                    .js_obj = js_value.castTo(v8.Object),
                };
            }
            if (js_value.isNullOrUndefined()) {
                return null;
            }
            return try self.jsValueToZig(named_function, o.child, js_value);
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
                if (@hasField(types.Lookup, @typeName(ptr.child))) {
                    const js_obj = js_value.castTo(v8.Object);
                    return self.typeTaggedAnyOpaque(named_function, *types.Receiver(ptr.child), js_obj);
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
                    a.* = try self.jsValueToZig(named_function, ptr.child, try js_obj.getAtIndex(v8_context, @intCast(i)));
                }
                return arr;
            },
            else => {},
        },
        .array => |arr| {
            // Retrieve fixed-size array as slice
            const slice_type = []arr.child;
            const slice_value = try self.jsValueToZig(named_function, slice_type, js_value);
            if (slice_value.len != arr.len) {
                // Exact length match, we could allow smaller arrays, but we would not be able to communicate how many were written
                return error.InvalidArgument;
            }
            return @as(*T, @ptrCast(slice_value.ptr)).*;
        },
        .@"struct" => {
            return try (self.jsValueToStruct(named_function, T, js_value)) orelse {
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
                switch (try self.probeJsValueToZig(named_function, field.type, js_value)) {
                    .value => |v| return @unionInit(T, field.name, v),
                    .ok => {
                        // a perfect match like above case, except the probing
                        // didn't get the value for us.
                        return @unionInit(T, field.name, try self.jsValueToZig(named_function, field.type, js_value));
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
                    return @unionInit(T, field.name, try self.jsValueToZig(named_function, field.type, js_value));
                }
            }
            unreachable;
        },
        .@"enum" => |e| {
            switch (@typeInfo(e.tag_type)) {
                .int => return std.meta.intToEnum(T, try jsIntToZig(e.tag_type, js_value, self.v8_context)),
                else => @compileError(named_function.full_name ++ " has an unsupported enum parameter type: " ++ @typeName(T)),
            }
        },
        else => {},
    }

    @compileError(named_function.full_name ++ " has an unsupported parameter type: " ++ @typeName(T));
}

// Extracted so that it can be used in both jsValueToZig and in
// probeJsValueToZig. Avoids having to duplicate this logic when probing.
fn jsValueToStruct(self: *Context, comptime named_function: NamedFunction, comptime T: type, js_value: v8.Value) !?T {
    if (T == js.Function) {
        if (!js_value.isFunction()) {
            return null;
        }
        return try self.createFunction(js_value);
    }

    if (@hasDecl(T, "_TYPED_ARRAY_ID_KLUDGE")) {
        const VT = @typeInfo(std.meta.fieldInfo(T, .values).type).pointer.child;
        const arr = (try self.jsValueToTypedArray(VT, js_value)) orelse return null;
        return .{ .values = arr };
    }

    if (T == js.String) {
        return .{ .string = try self.valueToString(js_value, .{ .allocator = self.arena }) };
    }

    const js_obj = js_value.castTo(v8.Object);

    if (comptime T == js.Object) {
        // Caller wants an opaque js.Object. Probably a parameter
        // that it needs to pass back into a callback
        return js.Object{
            .js_obj = js_obj,
            .context = self,
        };
    }

    if (!js_value.isObject()) {
        return null;
    }

    const v8_context = self.v8_context;
    const isolate = self.isolate;

    var value: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const name = field.name;
        const key = v8.String.initUtf8(isolate, name);
        if (js_obj.has(v8_context, key.toValue())) {
            @field(value, name) = try self.jsValueToZig(named_function, field.type, try js_obj.getValue(v8_context, key));
        } else if (@typeInfo(field.type) == .optional) {
            @field(value, name) = null;
        } else {
            const dflt = field.defaultValue() orelse return null;
            @field(value, name) = dflt;
        }
    }
    return value;
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

// == Stringifiers ==
const valueToStringOpts = struct {
    allocator: ?Allocator = null,
};
pub fn valueToString(self: *const Context, value: v8.Value, opts: valueToStringOpts) ![]u8 {
    const allocator = opts.allocator orelse self.call_arena;
    if (value.isSymbol()) {
        // symbol's can't be converted to a string
        return allocator.dupe(u8, "$Symbol");
    }
    const str = try value.toString(self.v8_context);
    return self.jsStringToZig(str, .{ .allocator = allocator });
}

pub fn valueToStringZ(self: *const Context, value: v8.Value, opts: valueToStringOpts) ![:0]u8 {
    const allocator = opts.allocator orelse self.call_arena;
    const str = try value.toString(self.v8_context);
    const len = str.lenUtf8(self.isolate);
    const buf = try allocator.allocSentinel(u8, len, 0);
    const n = str.writeUtf8(self.isolate, buf);
    std.debug.assert(n == len);
    return buf;
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

pub fn valueToDetailString(self: *const Context, value: v8.Value) ![]u8 {
    var str: ?v8.String = null;
    const v8_context = self.v8_context;

    if (value.isObject() and !value.isFunction()) blk: {
        str = v8.Json.stringify(v8_context, value, null) catch break :blk;

        if (str.?.lenUtf8(self.isolate) == 2) {
            // {} isn't useful, null this so that we can get the toDetailString
            // (which might also be useless, but maybe not)
            str = null;
        }
    }

    if (str == null) {
        str = try value.toDetailString(v8_context);
    }

    const s = try self.jsStringToZig(str.?, .{});
    if (comptime builtin.mode == .Debug) {
        if (std.mem.eql(u8, s, "[object Object]")) {
            if (self.debugValueToString(value.castTo(v8.Object))) |ds| {
                return ds;
            } else |err| {
                log.err(.js, "debug serialize value", .{ .err = err });
            }
        }
    }
    return s;
}

fn debugValueToString(self: *const Context, js_obj: v8.Object) ![]u8 {
    if (comptime builtin.mode != .Debug) {
        @compileError("debugValue can only be called in debug mode");
    }
    const v8_context = self.v8_context;

    const names_arr = js_obj.getOwnPropertyNames(v8_context);
    const names_obj = names_arr.castTo(v8.Object);
    const len = names_arr.length();

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    var writer = arr.writer(self.call_arena);
    try writer.writeAll("(JSON.stringify failed, dumping top-level fields)\n");
    for (0..len) |i| {
        const field_name = try names_obj.getAtIndex(v8_context, @intCast(i));
        const field_value = try js_obj.getValue(v8_context, field_name);
        const name = try self.valueToString(field_name, .{});
        const value = try self.valueToString(field_value, .{});
        try writer.writeAll(name);
        try writer.writeAll(": ");
        if (std.mem.indexOfAny(u8, value, &std.ascii.whitespace) == null) {
            try writer.writeAll(value);
        } else {
            try writer.writeByte('"');
            try writer.writeAll(value);
            try writer.writeByte('"');
        }
        try writer.writeByte(' ');
    }
    return arr.items;
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
pub fn rejectPromise(self: *Context, value: anytype) js.Promise {
    const ctx = self.v8_context;
    const js_value = try self.zigValueToJs(value);

    var resolver = v8.PromiseResolver.init(ctx);
    _ = resolver.reject(ctx, js_value);

    return resolver.getPromise();
}

pub fn resolvePromise(self: *Context, value: anytype) !js.Promise {
    const ctx = self.v8_context;
    const js_value = try self.zigValueToJs(value);

    var resolver = v8.PromiseResolver.init(ctx);
    _ = resolver.resolve(ctx, js_value);

    return resolver.getPromise();
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

    const specifier = self.jsStringToZig(.{ .handle = c_specifier.? }, .{}) catch |err| {
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

    const resource = self.jsStringToZig(.{ .handle = resource_name.? }, .{}) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback1" });
        return @constCast(self.rejectPromise("Out of memory").handle);
    };

    const specifier = self.jsStringToZig(.{ .handle = v8_specifier.? }, .{}) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback2" });
        return @constCast(self.rejectPromise("Out of memory").handle);
    };

    const normalized_specifier = @import("../../url.zig").stitch(
        self.arena, // might need to survive until the module is loaded
        specifier,
        resource,
        .{ .alloc = .if_needed, .null_terminated = true },
    ) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback3" });
        return @constCast(self.rejectPromise("Out of memory").handle);
    };

    const promise = self._dynamicModuleCallback(normalized_specifier, resource) catch |err| blk: {
        log.err(.js, "dynamic module callback", .{
            .err = err,
        });
        break :blk self.rejectPromise("Failed to load module");
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
    const js_value = try self.zigValueToJs(url);
    const res = meta.defineOwnProperty(self.v8_context, js_key.toName(), js_value, 0) orelse false;
    if (!res) {
        log.err(.js, "import meta", .{ .err = error.FailedToSet });
    }
}

fn _resolveModuleCallback(self: *Context, referrer: v8.Module, specifier: []const u8) !?*const v8.C_Module {
    const referrer_path = self.module_identifier.get(referrer.getIdentityHash()) orelse {
        // Shouldn't be possible.
        return error.UnknownModuleReferrer;
    };

    const normalized_specifier = try @import("../../url.zig").stitch(
        self.call_arena,
        specifier,
        referrer_path,
        .{ .alloc = .if_needed, .null_terminated = true },
    );

    const gop = try self.module_cache.getOrPut(self.arena, normalized_specifier);
    if (gop.found_existing) {
        if (gop.value_ptr.module) |m| {
            return m.handle;
        }
        // We don't have a module, but we do have a cache entry for it
        // That means we're already trying to load it. We just have
        // to wait for it to be done.
    } else {
        // I don't think it's possible for us to be here. This is
        // only ever called by v8 when we evaluate a module. But
        // before evaluating, we should have already started
        // downloading all of the module's nested modules. So it
        // should be impossible that this is the first time we've
        // heard about this module.
        // But, I'm not confident enough in that, and ther's little
        // harm in handling this case.
        @branchHint(.unlikely);
        gop.value_ptr.* = .{};
        try self.script_manager.?.getModule(normalized_specifier, referrer_path);
    }

    var fetch_result = try self.script_manager.?.waitForModule(normalized_specifier);
    defer fetch_result.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(self);
    defer try_catch.deinit();

    const entry = self.module(true, fetch_result.src(), normalized_specifier, true) catch |err| {
        log.warn(.js, "compile resolved module", .{
            .specifier = specifier,
            .stack = try_catch.stack(self.call_arena) catch null,
            .src = try_catch.sourceLine(self.call_arena) catch "err",
            .line = try_catch.sourceLineNumber() orelse 0,
            .exception = (try_catch.exception(self.call_arena) catch @errorName(err)) orelse @errorName(err),
        });
        return null;
    };
    // entry.module is always set when returning from self.module()
    return entry.module.?.handle;
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
        self.script_manager.?.getAsyncModule(specifier, dynamicModuleSourceCallback, state, referrer) catch |err| {
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
    std.debug.assert(gop.value_ptr.module_promise != null);

    // like before, we want to set this up so that if anything else
    // tries to load this module, it can just return our promise
    // since we're going to be doing all the work.
    gop.value_ptr.resolver_promise = persisted_promise;

    // But we can skip direclty to `resolveDynamicModule` which is
    // what the above callback will eventually do.
    self.resolveDynamicModule(state, gop.value_ptr.*);
    return promise;
}

fn dynamicModuleSourceCallback(ctx: *anyopaque, fetch_result_: anyerror!ScriptManager.GetResult) void {
    const state: *DynamicModuleResolveState = @ptrCast(@alignCast(ctx));
    var self = state.context;

    var fetch_result = fetch_result_ catch |err| {
        const error_msg = v8.String.initUtf8(self.isolate, @errorName(err));
        _ = state.resolver.castToPromiseResolver().reject(self.v8_context, error_msg.toValue());
        return;
    };

    const module_entry = blk: {
        defer fetch_result.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(self);
        defer try_catch.deinit();

        break :blk self.module(true, fetch_result.src(), state.specifier, true) catch {
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
pub fn typeTaggedAnyOpaque(self: *const Context, comptime named_function: NamedFunction, comptime R: type, js_obj: v8.Object) !R {
    const ti = @typeInfo(R);
    if (ti != .pointer) {
        @compileError(named_function.full_name ++ "has a non-pointer Zig parameter type: " ++ @typeName(R));
    }

    const T = ti.pointer.child;
    if (comptime types.isEmpty(T)) {
        // Empty structs aren't stored as TOAs and there's no data
        // stored in the JSObject's IntenrnalField. Why bother when
        // we can just return an empty struct here?
        return @constCast(@as(*const T, &.{}));
    }

    // if it isn't an empty struct, then the v8.Object should have an
    // InternalFieldCount > 0, since our toa pointer should be embedded
    // at index 0 of the internal field count.
    if (js_obj.internalFieldCount() == 0) {
        return error.InvalidArgument;
    }

    const type_name = @typeName(T);
    if (@hasField(types.Lookup, type_name) == false) {
        @compileError(named_function.full_name ++ "has an unknown Zig type: " ++ @typeName(R));
    }

    const op = js_obj.getInternalField(0).castTo(v8.External).get();
    const tao: *TaggedAnyOpaque = @ptrCast(@alignCast(op));
    const expected_type_index = @field(types.LOOKUP, type_name);

    var type_index = tao.index;
    if (type_index == expected_type_index) {
        return @ptrCast(@alignCast(tao.ptr));
    }

    const meta_lookup = self.meta_lookup;

    // If we have N levels deep of prototypes, then the offset is the
    // sum at each level...
    var total_offset: usize = 0;

    // ...unless, the proto is behind a pointer, then total_offset will
    // get reset to 0, and our base_ptr will move to the address
    // referenced by the proto field.
    var base_ptr: usize = @intFromPtr(tao.ptr);

    // search through the prototype tree
    while (true) {
        const proto_offset = meta_lookup[type_index].proto_offset;
        if (proto_offset < 0) {
            base_ptr = @as(*align(1) usize, @ptrFromInt(base_ptr + total_offset + @as(usize, @intCast(-proto_offset)))).*;
            total_offset = 0;
        } else {
            total_offset += @intCast(proto_offset);
        }

        const prototype_index = types.PROTOTYPE_TABLE[type_index];
        if (prototype_index == expected_type_index) {
            return @ptrFromInt(base_ptr + total_offset);
        }

        if (prototype_index == type_index) {
            // When a type has itself as the prototype, then we've
            // reached the end of the chain.
            return error.InvalidArgument;
        }
        type_index = prototype_index;
    }
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
fn probeJsValueToZig(self: *Context, comptime named_function: NamedFunction, comptime T: type, js_value: v8.Value) !ProbeResult(T) {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (js_value.isNullOrUndefined()) {
                return .{ .value = null };
            }
            return self.probeJsValueToZig(named_function, o.child, js_value);
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
                if (@hasField(types.Lookup, @typeName(ptr.child))) {
                    const js_obj = js_value.castTo(v8.Object);
                    // There's a bit of overhead in doing this, so instead
                    // of having a version of typeTaggedAnyOpaque which
                    // returns a boolean or an optional, we rely on the
                    // main implementation and just handle the error.
                    const attempt = self.typeTaggedAnyOpaque(named_function, *types.Receiver(ptr.child), js_obj);
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
                switch (try self.probeJsValueToZig(named_function, ptr.child, try js_obj.getAtIndex(v8_context, 0))) {
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
            switch (try self.probeJsValueToZig(named_function, slice_type, js_value)) {
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
            const value = (try self.jsValueToStruct(named_function, T, js_value)) orelse {
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
            32 => return jsUnsignedIntToZig(u32, 4_294_967_295, try js_value.toU32(v8_context)),
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
        .bool => |v| return js.simpleZigValueToJs(isolate, v, true),
        .float => |v| return js.simpleZigValueToJs(isolate, v, true),
        .integer => |v| return js.simpleZigValueToJs(isolate, v, true),
        .string => |v| return js.simpleZigValueToJs(isolate, v, true),
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
