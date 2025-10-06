const std = @import("std");
const js = @import("js.zig");
const v8 = js.v8;

const log = @import("../../log.zig");

const types = @import("types.zig");
const Types = types.Types;
const Caller = @import("Caller.zig");
const Context = @import("Context.zig");
const Platform = @import("Platform.zig");
const Inspector = @import("Inspector.zig");
const ExecutionWorld = @import("ExecutionWorld.zig");
const NamedFunction = Caller.NamedFunction;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

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

// Given a type, we can lookup its index in TYPE_LOOKUP and then have
// access to its TunctionTemplate (the thing we need to create an instance
// of it)
// I.e.:
// const index = @field(TYPE_LOOKUP, @typeName(type_name))
// const template = templates[index];
templates: [Types.len]v8.FunctionTemplate,

// Given a type index (retrieved via the TYPE_LOOKUP), we can retrieve
// the index of its prototype. Types without a prototype have their own
// index.
prototype_lookup: [Types.len]u16,

meta_lookup: [Types.len]types.Meta,

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
        .meta_lookup = undefined,
        .prototype_lookup = undefined,
    };

    // Populate our templates lookup. generateClass creates the
    // v8.FunctionTemplate, which we store in our env.templates.
    // The ordering doesn't matter. What matters is that, given a type
    // we can get its index via: @field(types.LOOKUP, type_name)
    const templates = &env.templates;
    inline for (Types, 0..) |s, i| {
        @setEvalBranchQuota(10_000);
        templates[i] = v8.Persistent(v8.FunctionTemplate).init(isolate, generateClass(s.defaultValue().?, isolate)).castToFunctionTemplate();
    }

    // Above, we've created all our our FunctionTemplates. Now that we
    // have them all, we can hook up the prototypes.
    const meta_lookup = &env.meta_lookup;
    inline for (Types, 0..) |s, i| {
        const Struct = s.defaultValue().?;
        if (@hasDecl(Struct, "prototype")) {
            const TI = @typeInfo(Struct.prototype);
            const proto_name = @typeName(types.Receiver(TI.pointer.child));
            if (@hasField(types.Lookup, proto_name) == false) {
                @compileError(std.fmt.comptimePrint("Prototype '{s}' for '{s}' is undefined", .{ proto_name, @typeName(Struct) }));
            }
            // Hey, look! This is our first real usage of the types.LOOKUP.
            // Just like we said above, given a type, we can get its
            // template index.

            const proto_index = @field(types.LOOKUP, proto_name);
            templates[i].inherit(templates[proto_index]);
        }

        // while we're here, let's populate our meta lookup
        const subtype: ?types.Sub = if (@hasDecl(Struct, "subtype")) Struct.subtype else null;

        const proto_offset = comptime blk: {
            if (!@hasField(Struct, "proto")) {
                break :blk 0;
            }
            const proto_info = std.meta.fieldInfo(Struct, .proto);
            if (@typeInfo(proto_info.type) == .pointer) {
                // we store the offset as a negative, to so that,
                // when we reverse this, we know that it's
                // behind a pointer that we need to resolve.
                break :blk -@offsetOf(Struct, "proto");
            }
            break :blk @offsetOf(Struct, "proto");
        };

        meta_lookup[i] = .{
            .index = i,
            .subtype = subtype,
            .proto_offset = proto_offset,
        };
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
fn generateClass(comptime Struct: type, isolate: v8.Isolate) v8.FunctionTemplate {
    const template = generateConstructor(Struct, isolate);
    attachClass(Struct, isolate, template);
    return template;
}

// Normally this is called from generateClass. Where generateClass creates
// the constructor (hence, the FunctionTemplate), attachClass adds all
// of its functions, getters, setters, ...
// But it's extracted from generateClass because we also have 1 global
// object (i.e. the Window), which gets attached not only to the Window
// constructor/FunctionTemplate as normal, but also through the default
// FunctionTemplate of the isolate (in createContext)
pub fn attachClass(comptime Struct: type, isolate: v8.Isolate, template: v8.FunctionTemplate) void {
    const template_proto = template.getPrototypeTemplate();
    inline for (@typeInfo(Struct).@"struct".decls) |declaration| {
        const name = declaration.name;
        if (comptime name[0] == '_') {
            switch (@typeInfo(@TypeOf(@field(Struct, name)))) {
                .@"fn" => generateMethod(Struct, name, isolate, template_proto),
                else => |ti| if (!comptime js.isComplexAttributeType(ti)) {
                    generateAttribute(Struct, name, isolate, template, template_proto);
                },
            }
        } else if (comptime std.mem.startsWith(u8, name, "get_")) {
            generateProperty(Struct, name[4..], isolate, template_proto);
        } else if (comptime std.mem.startsWith(u8, name, "static_")) {
            generateFunction(Struct, name[7..], isolate, template);
        }
    }

    if (@hasDecl(Struct, "get_symbol_toStringTag") == false) {
        // If this WAS defined, then we would have created it in generateProperty.
        // But if it isn't, we create a default one
        const string_tag_callback = v8.FunctionTemplate.initCallback(isolate, struct {
            fn stringTag(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                const class_name = v8.String.initUtf8(info.getIsolate(), comptime js.classNameForStruct(Struct));
                info.getReturnValue().set(class_name);
            }
        }.stringTag);
        const key = v8.Symbol.getToStringTag(isolate).toName();
        template_proto.setAccessorGetter(key, string_tag_callback);
    }

    generateIndexer(Struct, template_proto);
    generateNamedIndexer(Struct, template.getInstanceTemplate());
    generateUndetectable(Struct, template.getInstanceTemplate());
}

// Even if a struct doesn't have a `constructor` function, we still
// `generateConstructor`, because this is how we create our
// FunctionTemplate. Such classes exist, but they can't be instantiated
// via `new ClassName()` - but they could, for example, be created in
// Zig and returned from a function call, which is why we need the
// FunctionTemplate.
fn generateConstructor(comptime Struct: type, isolate: v8.Isolate) v8.FunctionTemplate {
    const template = v8.FunctionTemplate.initCallback(isolate, struct {
        fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            var caller = Caller.init(info);
            defer caller.deinit();
            // See comment above. We generateConstructor on all types
            // in order to create the FunctionTemplate, but there might
            // not be an actual "constructor" function. So if someone
            // does `new ClassName()` where ClassName doesn't have
            // a constructor function, we'll return an error.
            if (@hasDecl(Struct, "constructor") == false) {
                const iso = caller.isolate;
                log.warn(.js, "Illegal constructor call", .{ .name = @typeName(Struct) });
                const js_exception = iso.throwException(js._createException(iso, "Illegal Constructor"));
                info.getReturnValue().set(js_exception);
                return;
            }

            // Safe to call now, because if Struct.constructor didn't
            // exist, the above if block would have returned.
            const named_function = comptime NamedFunction.init(Struct, "constructor");
            caller.constructor(Struct, named_function, info) catch |err| {
                caller.handleError(Struct, named_function, err, info);
            };
        }
    }.callback);

    if (comptime types.isEmpty(types.Receiver(Struct)) == false) {
        // If the struct is empty, we won't store a Zig reference inside
        // the JS object, so we don't need to set the internal field count
        template.getInstanceTemplate().setInternalFieldCount(1);
    }

    const class_name = v8.String.initUtf8(isolate, comptime js.classNameForStruct(Struct));
    template.setClassName(class_name);
    return template;
}

fn generateMethod(comptime Struct: type, comptime name: []const u8, isolate: v8.Isolate, template_proto: v8.ObjectTemplate) void {
    var js_name: v8.Name = undefined;
    if (comptime std.mem.eql(u8, name, "_symbol_iterator")) {
        js_name = v8.Symbol.getIterator(isolate).toName();
    } else {
        js_name = v8.String.initUtf8(isolate, name[1..]).toName();
    }
    const function_template = v8.FunctionTemplate.initCallback(isolate, struct {
        fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            var caller = Caller.init(info);
            defer caller.deinit();

            const named_function = comptime NamedFunction.init(Struct, name);
            caller.method(Struct, named_function, info) catch |err| {
                caller.handleError(Struct, named_function, err, info);
            };
        }
    }.callback);
    template_proto.set(js_name, function_template, v8.PropertyAttribute.None);
}

fn generateFunction(comptime Struct: type, comptime name: []const u8, isolate: v8.Isolate, template: v8.FunctionTemplate) void {
    const js_name = v8.String.initUtf8(isolate, name).toName();
    const function_template = v8.FunctionTemplate.initCallback(isolate, struct {
        fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            var caller = Caller.init(info);
            defer caller.deinit();

            const named_function = comptime NamedFunction.init(Struct, "static_" ++ name);
            caller.function(Struct, named_function, info) catch |err| {
                caller.handleError(Struct, named_function, err, info);
            };
        }
    }.callback);
    template.set(js_name, function_template, v8.PropertyAttribute.None);
}

fn generateAttribute(comptime Struct: type, comptime name: []const u8, isolate: v8.Isolate, template: v8.FunctionTemplate, template_proto: v8.ObjectTemplate) void {
    const zig_value = @field(Struct, name);
    const js_value = js.simpleZigValueToJs(isolate, zig_value, true);

    const js_name = v8.String.initUtf8(isolate, name[1..]).toName();

    // apply it both to the type itself
    template.set(js_name, js_value, v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);

    // and to instances of the type
    template_proto.set(js_name, js_value, v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);
}

fn generateProperty(comptime Struct: type, comptime name: []const u8, isolate: v8.Isolate, template_proto: v8.ObjectTemplate) void {
    var js_name: v8.Name = undefined;
    if (comptime std.mem.eql(u8, name, "symbol_toStringTag")) {
        js_name = v8.Symbol.getToStringTag(isolate).toName();
    } else {
        js_name = v8.String.initUtf8(isolate, name).toName();
    }

    const getter_callback = v8.FunctionTemplate.initCallback(isolate, struct {
        fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            var caller = Caller.init(info);
            defer caller.deinit();

            const named_function = comptime NamedFunction.init(Struct, "get_" ++ name);
            caller.method(Struct, named_function, info) catch |err| {
                caller.handleError(Struct, named_function, err, info);
            };
        }
    }.callback);

    const setter_name = "set_" ++ name;
    if (@hasDecl(Struct, setter_name) == false) {
        template_proto.setAccessorGetter(js_name, getter_callback);
        return;
    }

    const setter_callback = v8.FunctionTemplate.initCallback(isolate, struct {
        fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            std.debug.assert(info.length() == 1);

            var caller = Caller.init(info);
            defer caller.deinit();

            const named_function = comptime NamedFunction.init(Struct, "set_" ++ name);
            caller.method(Struct, named_function, info) catch |err| {
                caller.handleError(Struct, named_function, err, info);
            };
        }
    }.callback);

    template_proto.setAccessorGetterAndSetter(js_name, getter_callback, setter_callback);
}

fn generateIndexer(comptime Struct: type, template_proto: v8.ObjectTemplate) void {
    if (@hasDecl(Struct, "indexed_get") == false) {
        return;
    }
    const configuration = v8.IndexedPropertyHandlerConfiguration{
        .getter = struct {
            fn callback(idx: u32, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8 {
                const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();

                const named_function = comptime NamedFunction.init(Struct, "indexed_get");
                return caller.getIndex(Struct, named_function, idx, info) catch |err| blk: {
                    caller.handleError(Struct, named_function, err, info);
                    break :blk v8.Intercepted.No;
                };
            }
        }.callback,
    };

    // If you're trying to implement setter, read:
    // https://groups.google.com/g/v8-users/c/8tahYBsHpgY/m/IteS7Wn2AAAJ
    // The issue I had was
    // (a) where to attache it: does it go on the instance_template
    //     instead of the prototype?
    // (b) defining the getter or query to respond with the
    //     PropertyAttribute to indicate if the property can be set
    template_proto.setIndexedProperty(configuration, null);
}

fn generateNamedIndexer(comptime Struct: type, template_proto: v8.ObjectTemplate) void {
    if (@hasDecl(Struct, "named_get") == false) {
        return;
    }

    var configuration = v8.NamedPropertyHandlerConfiguration{
        .getter = struct {
            fn callback(c_name: ?*const v8.C_Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8 {
                const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();

                const named_function = comptime NamedFunction.init(Struct, "named_get");
                return caller.getNamedIndex(Struct, named_function, .{ .handle = c_name.? }, info) catch |err| blk: {
                    caller.handleError(Struct, named_function, err, info);
                    break :blk v8.Intercepted.No;
                };
            }
        }.callback,

        // This is really cool. Without this, we'd intercept _all_ properties
        // even those explicitly set. So, node.length for example would get routed
        // to our `named_get`, rather than a `get_length`. This might be
        // useful if we run into a type that we can't model properly in Zig.
        .flags = v8.PropertyHandlerFlags.OnlyInterceptStrings | v8.PropertyHandlerFlags.NonMasking,
    };

    if (@hasDecl(Struct, "named_set")) {
        configuration.setter = struct {
            fn callback(c_name: ?*const v8.C_Name, c_value: ?*const v8.C_Value, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8 {
                const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();

                const named_function = comptime NamedFunction.init(Struct, "named_set");
                return caller.setNamedIndex(Struct, named_function, .{ .handle = c_name.? }, .{ .handle = c_value.? }, info) catch |err| blk: {
                    caller.handleError(Struct, named_function, err, info);
                    break :blk v8.Intercepted.No;
                };
            }
        }.callback;
    }

    if (@hasDecl(Struct, "named_delete")) {
        configuration.deleter = struct {
            fn callback(c_name: ?*const v8.C_Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8 {
                const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();

                const named_function = comptime NamedFunction.init(Struct, "named_delete");
                return caller.deleteNamedIndex(Struct, named_function, .{ .handle = c_name.? }, info) catch |err| blk: {
                    caller.handleError(Struct, named_function, err, info);
                    break :blk v8.Intercepted.No;
                };
            }
        }.callback;
    }
    template_proto.setNamedProperty(configuration, null);
}

fn generateUndetectable(comptime Struct: type, template: v8.ObjectTemplate) void {
    const has_js_call_as_function = @hasDecl(Struct, "jsCallAsFunction");

    if (has_js_call_as_function) {
        template.setCallAsFunctionHandler(struct {
            fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();

                const named_function = comptime NamedFunction.init(Struct, "jsCallAsFunction");
                caller.method(Struct, named_function, info) catch |err| {
                    caller.handleError(Struct, named_function, err, info);
                };
            }
        }.callback);
    }

    if (@hasDecl(Struct, "mark_as_undetectable") and Struct.mark_as_undetectable) {
        if (!has_js_call_as_function) {
            @compileError(@typeName(Struct) ++ ": mark_as_undetectable required jsCallAsFunction to be defined. This is a hard-coded requirement in V8, because mark_as_undetectable only exists for HTMLAllCollection which is also callable.");
        }
        template.markAsUndetectable();
    }
}
