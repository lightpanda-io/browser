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

const log = @import("../../log.zig");

const bridge = @import("bridge.zig");
const Caller = @import("Caller.zig");
const Context = @import("Context.zig");
const Platform = @import("Platform.zig");
const Inspector = @import("Inspector.zig");
const ExecutionWorld = @import("ExecutionWorld.zig");
const NamedFunction = Caller.NamedFunction;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const JsApis = bridge.JsApis;

// The Env maps to a V8 isolate, which represents a isolated sandbox for
// executing JavaScript. The Env is where we'll define our V8 <-> Zig bindings,
// and it's where we'll start ExecutionWorlds, which actually execute JavaScript.
// The `S` parameter is arbitrary state. When we start an ExecutionWorld, an instance
// of S must be given. This instance is available to any Zig binding.
// The `types` parameter is a tuple of Zig structures we want to bind to V8.
const Env = @This();

allocator: Allocator,

platform: *const Platform,

// the global isolate
isolate: v8.Isolate,

// just kept around because we need to free it on deinit
isolate_params: *v8.CreateParams,

// Given a type, we can lookup its index in JS_API_LOOKUP and then have
// access to its TunctionTemplate (the thing we need to create an instance
// of it)
// I.e.:
// const index = @field(JS_API_LOOKUP, @typeName(type_name))
// const template = templates[index];
templates: [JsApis.len]v8.FunctionTemplate,

context_id: usize,

const Opts = struct {};

pub fn init(allocator: Allocator, platform: *const Platform, _: Opts) !*Env {
    // var params = v8.initCreateParams();
    var params = try allocator.create(v8.CreateParams);
    errdefer allocator.destroy(params);

    v8.c.v8__Isolate__CreateParams__CONSTRUCT(params);

    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    errdefer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);

    var isolate = v8.Isolate.init(params);
    errdefer isolate.deinit();

    // This is the callback that runs whenever a module is dynamically imported.
    isolate.setHostImportModuleDynamicallyCallback(Context.dynamicModuleCallback);
    isolate.setPromiseRejectCallback(promiseRejectCallback);
    isolate.setMicrotasksPolicy(v8.c.kExplicit);

    isolate.enter();
    errdefer isolate.exit();

    isolate.setHostInitializeImportMetaObjectCallback(Context.metaObjectCallback);

    var temp_scope: v8.HandleScope = undefined;
    v8.HandleScope.init(&temp_scope, isolate);
    defer temp_scope.deinit();

    const env = try allocator.create(Env);
    errdefer allocator.destroy(env);

    env.* = .{
        .context_id = 0,
        .platform = platform,
        .isolate = isolate,
        .templates = undefined,
        .allocator = allocator,
        .isolate_params = params,
    };

    // Populate our templates lookup. generateClass creates the
    // v8.FunctionTemplate, which we store in our env.templates.
    // The ordering doesn't matter. What matters is that, given a type
    // we can get its index via: @field(types.LOOKUP, type_name)
    const templates = &env.templates;
    inline for (JsApis, 0..) |JsApi, i| {
        @setEvalBranchQuota(10_000);
        JsApi.Meta.class_id = i;
        templates[i] = v8.Persistent(v8.FunctionTemplate).init(isolate, generateClass(JsApi, isolate)).castToFunctionTemplate();
    }

    // Above, we've created all our our FunctionTemplates. Now that we
    // have them all, we can hook up the prototypes.
    inline for (JsApis, 0..) |JsApi, i| {
        if (comptime protoIndexLookup(JsApi)) |proto_index| {
            templates[i].inherit(templates[proto_index]);
        }
    }

    return env;
}

pub fn deinit(self: *Env) void {
    self.isolate.exit();
    self.isolate.deinit();
    v8.destroyArrayBufferAllocator(self.isolate_params.array_buffer_allocator.?);
    self.allocator.destroy(self.isolate_params);
    self.allocator.destroy(self);
}

pub fn newInspector(self: *Env, arena: Allocator, ctx: anytype) !Inspector {
    return Inspector.init(arena, self.isolate, ctx);
}

pub fn runMicrotasks(self: *const Env) void {
    self.isolate.performMicrotasksCheckpoint();
}

pub fn pumpMessageLoop(self: *const Env) bool {
    return self.platform.inner.pumpMessageLoop(self.isolate, false);
}

pub fn runIdleTasks(self: *const Env) void {
    return self.platform.inner.runIdleTasks(self.isolate, 1);
}

pub fn newExecutionWorld(self: *Env) !ExecutionWorld {
    return .{
        .env = self,
        .context = null,
        .context_arena = ArenaAllocator.init(self.allocator),
    };
}

// V8 doesn't immediately free memory associated with
// a Context, it's managed by the garbage collector. We use the
// `lowMemoryNotification` call on the isolate to encourage v8 to free
// any contexts which have been freed.
pub fn lowMemoryNotification(self: *Env) void {
    var handle_scope: v8.HandleScope = undefined;
    v8.HandleScope.init(&handle_scope, self.isolate);
    defer handle_scope.deinit();
    self.isolate.lowMemoryNotification();
}

pub fn dumpMemoryStats(self: *Env) void {
    const stats = self.isolate.getHeapStatistics();
    std.debug.print(
        \\ Total Heap Size: {d}
        \\ Total Heap Size Executable: {d}
        \\ Total Physical Size: {d}
        \\ Total Available Size: {d}
        \\ Used Heap Size: {d}
        \\ Heap Size Limit: {d}
        \\ Malloced Memory: {d}
        \\ External Memory: {d}
        \\ Peak Malloced Memory: {d}
        \\ Number Of Native Contexts: {d}
        \\ Number Of Detached Contexts: {d}
        \\ Total Global Handles Size: {d}
        \\ Used Global Handles Size: {d}
        \\ Zap Garbage: {any}
        \\
    , .{ stats.total_heap_size, stats.total_heap_size_executable, stats.total_physical_size, stats.total_available_size, stats.used_heap_size, stats.heap_size_limit, stats.malloced_memory, stats.external_memory, stats.peak_malloced_memory, stats.number_of_native_contexts, stats.number_of_detached_contexts, stats.total_global_handles_size, stats.used_global_handles_size, stats.does_zap_garbage });
}

fn promiseRejectCallback(v8_msg: v8.C_PromiseRejectMessage) callconv(.c) void {
    const msg = v8.PromiseRejectMessage.initFromC(v8_msg);
    const isolate = msg.getPromise().toObject().getIsolate();
    const context = Context.fromIsolate(isolate);

    const value =
        if (msg.getValue()) |v8_value| context.valueToString(v8_value, .{}) catch |err| @errorName(err) else "no value";

    log.debug(.js, "unhandled rejection", .{ .value = value });
}

// Give it a Zig struct, get back a v8.FunctionTemplate.
// The FunctionTemplate is a bit like a struct container - it's where
// we'll attach functions/getters/setters and where we'll "inherit" a
// prototype type (if there is any)
fn generateClass(comptime JsApi: type, isolate: v8.Isolate) v8.FunctionTemplate {
    const template = generateConstructor(JsApi, isolate);
    attachClass(JsApi, isolate, template);
    return template;
}

// Normally this is called from generateClass. Where generateClass creates
// the constructor (hence, the FunctionTemplate), attachClass adds all
// of its functions, getters, setters, ...
// But it's extracted from generateClass because we also have 1 global
// object (i.e. the Window), which gets attached not only to the Window
// constructor/FunctionTemplate as normal, but also through the default
// FunctionTemplate of the isolate (in createContext)
pub fn attachClass(comptime JsApi: type, isolate: v8.Isolate, template: v8.FunctionTemplate) void {
    const template_proto = template.getPrototypeTemplate();

    const declarations = @typeInfo(JsApi).@"struct".decls;
    inline for (declarations) |d| {
        const name: [:0]const u8 = d.name;
        const value = @field(JsApi, name);
        const definition = @TypeOf(value);

        switch (definition) {
            bridge.Accessor => {
                const js_name = v8.String.initUtf8(isolate, name).toName();
                const getter_callback = v8.FunctionTemplate.initCallback(isolate, value.getter);
                if (value.setter == null) {
                    template_proto.setAccessorGetter(js_name, getter_callback);
                } else {
                    const setter_callback = v8.FunctionTemplate.initCallback(isolate, value.setter);
                    template_proto.setAccessorGetterAndSetter(js_name, getter_callback, setter_callback);
                }
            },
            bridge.Function => {
                const function_template = v8.FunctionTemplate.initCallback(isolate, value.func);
                const js_name: v8.Name = v8.String.initUtf8(isolate, name).toName();
                if (value.static) {
                    template.set(js_name, function_template, v8.PropertyAttribute.None);
                } else {
                    template_proto.set(js_name, function_template, v8.PropertyAttribute.None);
                }
            },
            bridge.Indexed => {
                const configuration = v8.IndexedPropertyHandlerConfiguration{
                    .getter = value.getter,
                };
                template_proto.setIndexedProperty(configuration, null);
            },
            bridge.NamedIndexed => template.getInstanceTemplate().setNamedProperty(.{
                .getter = value.getter,
                .setter = value.setter,
                .deleter = value.deleter,
                .flags = v8.PropertyHandlerFlags.OnlyInterceptStrings | v8.PropertyHandlerFlags.NonMasking,
            }, null),
            bridge.Iterator => {
                // Same as a function, but with a specific name
                const function_template = v8.FunctionTemplate.initCallback(isolate, value.func);
                const js_name = v8.Symbol.getIterator(isolate).toName();
                template_proto.set(js_name, function_template, v8.PropertyAttribute.None);
            },
            bridge.Property.Int => {
                const js_value = js.simpleZigValueToJs(isolate, value.int, true, false);
                const js_name = v8.String.initUtf8(isolate, name).toName();
                // apply it both to the type itself
                template.set(js_name, js_value, v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);

                // and to instances of the type
                template_proto.set(js_name, js_value, v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);
            },
            bridge.Constructor => {}, // already handled in generateClasss
            else => {},
        }
    }

    if (@hasDecl(JsApi.Meta, "htmldda")) {
        const instance_template = template.getInstanceTemplate();
        instance_template.markAsUndetectable();
        instance_template.setCallAsFunctionHandler(JsApi.Meta.callable.func);
    }
}

// Even if a struct doesn't have a `constructor` function, we still
// `generateConstructor`, because this is how we create our
// FunctionTemplate. Such classes exist, but they can't be instantiated
// via `new ClassName()` - but they could, for example, be created in
// Zig and returned from a function call, which is why we need the
// FunctionTemplate.
fn generateConstructor(comptime JsApi: type, isolate: v8.Isolate) v8.FunctionTemplate {
    const callback = blk: {
        if (@hasDecl(JsApi, "constructor")) {
            break :blk JsApi.constructor.func;
        }

        break :blk struct {
            fn wrap(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();

                const iso = caller.isolate;
                log.warn(.js, "Illegal constructor call", .{ .name = @typeName(JsApi) });
                const js_exception = iso.throwException(js._createException(iso, "Illegal Constructor"));
                info.getReturnValue().set(js_exception);
                return;
            }
        }.wrap;
    };

    const template = v8.FunctionTemplate.initCallback(isolate, callback);
    if (!@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
        template.getInstanceTemplate().setInternalFieldCount(1);
    }
    const class_name = v8.String.initUtf8(isolate, if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi));
    template.setClassName(class_name);
    return template;
}

// fn generateUndetectable(comptime Struct: type, template: v8.ObjectTemplate) void {
//     const has_js_call_as_function = @hasDecl(Struct, "jsCallAsFunction");

//     if (has_js_call_as_function) {

//     if (@hasDecl(Struct, "htmldda") and Struct.htmldda) {
//         if (!has_js_call_as_function) {
//             @compileError(@typeName(Struct) ++ ": htmldda required jsCallAsFunction to be defined. This is a hard-coded requirement in V8, because mark_as_undetectable only exists for HTMLAllCollection which is also callable.");
//         }
//         template.markAsUndetectable();
//     }
// }

pub fn protoIndexLookup(comptime JsApi: type) ?u16 {
    @setEvalBranchQuota(2000);
    comptime {
        const T = JsApi.bridge.type;
        if (!@hasField(T, "_proto")) {
            return null;
        }
        const Ptr = std.meta.fieldInfo(T, ._proto).type;
        const F = @typeInfo(Ptr).pointer.child;
        return @field(bridge.JS_API_LOOKUP, @typeName(F.JsApi));
    }
}
