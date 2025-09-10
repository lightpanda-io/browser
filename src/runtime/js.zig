// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const v8 = @import("v8");

const log = @import("../log.zig");
const SubType = @import("subtype.zig").SubType;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const CALL_ARENA_RETAIN = 1024 * 16;
const CONTEXT_ARENA_RETAIN = 1024 * 64;

const js = @This();

// Global, should only be initialized once.
pub const Platform = struct {
    inner: v8.Platform,

    pub fn init() !Platform {
        if (v8.initV8ICU() == false) {
            return error.FailedToInitializeICU;
        }
        const platform = v8.Platform.initDefault(0, true);
        v8.initV8Platform(platform);
        v8.initV8();
        return .{ .inner = platform };
    }

    pub fn deinit(self: Platform) void {
        _ = v8.deinitV8();
        v8.deinitV8Platform();
        self.inner.deinit();
    }
};

// The Env maps to a V8 isolate, which represents a isolated sandbox for
// executing JavaScript. The Env is where we'll define our V8 <-> Zig bindings,
// and it's where we'll start ExecutionWorlds, which actually execute JavaScript.
// The `S` parameter is arbitrary state. When we start an ExecutionWorld, an instance
// of S must be given. This instance is available to any Zig binding.
// The `types` parameter is a tuple of Zig structures we want to bind to V8.
pub fn Env(comptime State: type, comptime WebApis: type) type {
    const Types = @typeInfo(WebApis.Interfaces).@"struct".fields;

    // Imagine we have a type Cat which has a getter:
    //
    //    fn get_owner(self: *Cat) *Owner {
    //        return self.owner;
    //    }
    //
    // When we execute caller.getter, we'll end up doing something like:
    //   const res = @call(.auto, Cat.get_owner, .{cat_instance});
    //
    // How do we turn `res`, which is an *Owner, into something we can return
    // to v8? We need the ObjectTemplate associated with Owner. How do we
    // get that? Well, we store all the ObjectTemplates in an array that's
    // tied to env. So we do something like:
    //
    //    env.templates[index_of_owner].initInstance(...);
    //
    // But how do we get that `index_of_owner`? `TypeLookup` is a struct
    // that looks like:
    //
    // const TypeLookup = struct {
    //     comptime cat: usize = 0,
    //     comptime owner: usize = 1,
    //     ...
    // }
    //
    // So to get the template index of `owner`, we can do:
    //
    //  const index_id = @field(type_lookup, @typeName(@TypeOf(res));
    //
    const TypeLookup = comptime blk: {
        var fields: [Types.len]std.builtin.Type.StructField = undefined;
        for (Types, 0..) |s, i| {

            // This prototype type check has nothing to do with building our
            // TypeLookup. But we put it here, early, so that the rest of the
            // code doesn't have to worry about checking if Struct.prototype is
            // a pointer.
            const Struct = s.defaultValue().?;
            if (@hasDecl(Struct, "prototype") and @typeInfo(Struct.prototype) != .pointer) {
                @compileError(std.fmt.comptimePrint("Prototype '{s}' for type '{s} must be a pointer", .{ @typeName(Struct.prototype), @typeName(Struct) }));
            }

            fields[i] = .{
                .name = @typeName(Receiver(Struct)),
                .type = usize,
                .is_comptime = true,
                .alignment = @alignOf(usize),
                .default_value_ptr = &i,
            };
        }
        break :blk @Type(.{ .@"struct" = .{
            .layout = .auto,
            .decls = &.{},
            .is_tuple = false,
            .fields = &fields,
        } });
    };

    // Creates a list where the index of a type contains its prototype index
    //   const Animal = struct{};
    //   const Cat = struct{
    //       pub const prototype = *Animal;
    // };
    //
    // Would create an array: [0, 0]
    // Animal, at index, 0, has no prototype, so we set it to itself
    // Cat, at index 1, has an Animal prototype, so we set it to 0.
    //
    // When we're trying to pass an argument to a Zig function, we'll know the
    // target type (the function parameter type), and we'll have a
    // TaggedAnyOpaque which will have the index of the type of that parameter.
    // We'll use the PROTOTYPE_TABLE to see if the TaggedAnyType should be
    // cast to a prototype.
    const PROTOTYPE_TABLE = comptime blk: {
        var table: [Types.len]u16 = undefined;
        const TYPE_LOOKUP = TypeLookup{};
        for (Types, 0..) |s, i| {
            var prototype_index = i;
            const Struct = s.defaultValue().?;
            if (@hasDecl(Struct, "prototype")) {
                const TI = @typeInfo(Struct.prototype);
                const proto_name = @typeName(Receiver(TI.pointer.child));
                prototype_index = @field(TYPE_LOOKUP, proto_name);
            }
            table[i] = prototype_index;
        }
        break :blk table;
    };

    return struct {
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

        meta_lookup: [Types.len]TypeMeta,

        const Self = @This();

        const TYPE_LOOKUP = TypeLookup{};

        const Opts = struct {};

        pub fn init(allocator: Allocator, platform: *const Platform, _: Opts) !*Self {
            // var params = v8.initCreateParams();
            var params = try allocator.create(v8.CreateParams);
            errdefer allocator.destroy(params);

            v8.c.v8__Isolate__CreateParams__CONSTRUCT(params);

            params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
            errdefer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);

            var isolate = v8.Isolate.init(params);
            errdefer isolate.deinit();

            // This is the callback that runs whenever a module is dynamically imported.
            isolate.setHostImportModuleDynamicallyCallback(JsContext.dynamicModuleCallback);
            isolate.setPromiseRejectCallback(promiseRejectCallback);

            isolate.enter();
            errdefer isolate.exit();

            isolate.setHostInitializeImportMetaObjectCallback(struct {
                fn callback(c_context: ?*v8.C_Context, c_module: ?*v8.C_Module, c_meta: ?*v8.C_Value) callconv(.c) void {
                    const v8_context = v8.Context{ .handle = c_context.? };
                    const js_context: *JsContext = @ptrFromInt(v8_context.getEmbedderData(1).castTo(v8.BigInt).getUint64());
                    js_context.initializeImportMeta(v8.Module{ .handle = c_module.? }, v8.Object{ .handle = c_meta.? }) catch |err| {
                        log.err(.js, "import meta", .{ .err = err });
                    };
                }
            }.callback);

            var temp_scope: v8.HandleScope = undefined;
            v8.HandleScope.init(&temp_scope, isolate);
            defer temp_scope.deinit();

            const env = try allocator.create(Self);
            errdefer allocator.destroy(env);

            env.* = .{
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
            // we can get its index via: @field(TYPE_LOOKUP, type_name)
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
                    const proto_name = @typeName(Receiver(TI.pointer.child));
                    if (@hasField(TypeLookup, proto_name) == false) {
                        @compileError(std.fmt.comptimePrint("Prototype '{s}' for '{s}' is undefined", .{ proto_name, @typeName(Struct) }));
                    }
                    // Hey, look! This is our first real usage of the TYPE_LOOKUP.
                    // Just like we said above, given a type, we can get its
                    // template index.

                    const proto_index = @field(TYPE_LOOKUP, proto_name);
                    templates[i].inherit(templates[proto_index]);
                }

                // while we're here, let's populate our meta lookup
                const subtype: ?SubType = if (@hasDecl(Struct, "subtype")) Struct.subtype else null;

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

        pub fn deinit(self: *Self) void {
            self.isolate.exit();
            self.isolate.deinit();
            v8.destroyArrayBufferAllocator(self.isolate_params.array_buffer_allocator.?);
            self.allocator.destroy(self.isolate_params);
            self.allocator.destroy(self);
        }

        pub fn newInspector(self: *Self, arena: Allocator, ctx: anytype) !Inspector {
            return Inspector.init(arena, self.isolate, ctx);
        }

        pub fn runMicrotasks(self: *const Self) void {
            self.isolate.performMicrotasksCheckpoint();
        }

        pub fn pumpMessageLoop(self: *const Self) bool {
            return self.platform.inner.pumpMessageLoop(self.isolate, false);
        }

        pub fn runIdleTasks(self: *const Self) void {
            return self.platform.inner.runIdleTasks(self.isolate, 1);
        }

        pub fn newExecutionWorld(self: *Self) !ExecutionWorld {
            return .{
                .env = self,
                .js_context = null,
                .call_arena = ArenaAllocator.init(self.allocator),
                .context_arena = ArenaAllocator.init(self.allocator),
            };
        }

        // V8 doesn't immediately free memory associated with
        // a Context, it's managed by the garbage collector. We use the
        // `lowMemoryNotification` call on the isolate to encourage v8 to free
        // any contexts which have been freed.
        pub fn lowMemoryNotification(self: *Self) void {
            var handle_scope: v8.HandleScope = undefined;
            v8.HandleScope.init(&handle_scope, self.isolate);
            defer handle_scope.deinit();
            self.isolate.lowMemoryNotification();
        }

        pub fn dumpMemoryStats(self: *Self) void {
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
            const v8_context = isolate.getCurrentContext();
            const context: *JsContext = @ptrFromInt(v8_context.getEmbedderData(1).castTo(v8.BigInt).getUint64());

            const value =
                if (msg.getValue()) |v8_value| valueToString(context.call_arena, v8_value, isolate, v8_context) catch |err| @errorName(err) else "no value";

            log.debug(.js, "unhandled rejection", .{ .value = value });
        }

        // ExecutionWorld closely models a JS World.
        // https://chromium.googlesource.com/chromium/src/+/master/third_party/blink/renderer/bindings/core/v8/V8BindingDesign.md#World
        // https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/scripting/ExecutionWorld
        pub const ExecutionWorld = struct {
            env: *Self,

            // Arena whose lifetime is for a single getter/setter/function/etc.
            // Largely used to get strings out of V8, like a stack trace from
            // a TryCatch. The allocator will be owned by the JsContext, but the
            // arena itself is owned by the ExecutionWorld so that we can re-use it
            // from context to context.
            call_arena: ArenaAllocator,

            // Arena whose lifetime is for a single page load. Where
            // the call_arena lives for a single function call, the context_arena
            // lives for the lifetime of the entire page. The allocator will be
            // owned by the JsContext, but the arena itself is owned by the ExecutionWorld
            // so that we can re-use it from context to context.
            context_arena: ArenaAllocator,

            // Currently a context maps to a Browser's Page. Here though, it's only a
            // mechanism to organization page-specific memory. The ExecutionWorld
            // does all the work, but having all page-specific data structures
            // grouped together helps keep things clean.
            js_context: ?JsContext = null,

            // no init, must be initialized via env.newExecutionWorld()

            pub fn deinit(self: *ExecutionWorld) void {
                if (self.js_context != null) {
                    self.removeJsContext();
                }

                self.call_arena.deinit();
                self.context_arena.deinit();
            }

            // Only the top JsContext in the Main ExecutionWorld should hold a handle_scope.
            // A v8.HandleScope is like an arena. Once created, any "Local" that
            // v8 creates will be released (or at least, releasable by the v8 GC)
            // when the handle_scope is freed.
            // We also maintain our own "context_arena" which allows us to have
            // all page related memory easily managed.
            pub fn createJsContext(self: *ExecutionWorld, global: anytype, state: State, module_loader: anytype, enter: bool, global_callback: ?GlobalMissingCallback) !*JsContext {
                std.debug.assert(self.js_context == null);

                const ModuleLoader = switch (@typeInfo(@TypeOf(module_loader))) {
                    .@"struct" => @TypeOf(module_loader),
                    .pointer => |ptr| ptr.child,
                    .void => ErrorModuleLoader,
                    else => @compileError("invalid module_loader"),
                };

                // If necessary, turn a void context into something we can safely ptrCast
                const safe_module_loader: *anyopaque = if (ModuleLoader == ErrorModuleLoader) @ptrCast(@constCast(&{})) else module_loader;

                const env = self.env;
                const isolate = env.isolate;
                const Global = @TypeOf(global.*);
                const templates = &self.env.templates;

                var v8_context: v8.Context = blk: {
                    var temp_scope: v8.HandleScope = undefined;
                    v8.HandleScope.init(&temp_scope, isolate);
                    defer temp_scope.deinit();

                    const js_global = v8.FunctionTemplate.initDefault(isolate);
                    attachClass(Global, isolate, js_global);

                    const global_template = js_global.getInstanceTemplate();
                    global_template.setInternalFieldCount(1);

                    // Configure the missing property callback on the global
                    // object.
                    if (global_callback != null) {
                        const configuration = v8.NamedPropertyHandlerConfiguration{
                            .getter = struct {
                                fn callback(c_name: ?*const v8.C_Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8 {
                                    const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                                    const _isolate = info.getIsolate();
                                    const v8_context = _isolate.getCurrentContext();

                                    const js_context: *JsContext = @ptrFromInt(v8_context.getEmbedderData(1).castTo(v8.BigInt).getUint64());

                                    const property = valueToString(js_context.call_arena, .{ .handle = c_name.? }, _isolate, v8_context) catch "???";
                                    if (js_context.global_callback.?.missing(property, js_context)) {
                                        return v8.Intercepted.Yes;
                                    }
                                    return v8.Intercepted.No;
                                }
                            }.callback,
                            .flags = v8.PropertyHandlerFlags.NonMasking | v8.PropertyHandlerFlags.OnlyInterceptStrings,
                        };
                        global_template.setNamedProperty(configuration, null);
                    }

                    // All the FunctionTemplates that we created and setup in Env.init
                    // are now going to get associated with our global instance.
                    inline for (Types, 0..) |s, i| {
                        const Struct = s.defaultValue().?;
                        const class_name = v8.String.initUtf8(isolate, comptime classNameForStruct(Struct));
                        global_template.set(class_name.toName(), templates[i], v8.PropertyAttribute.None);
                    }

                    // The global object (Window) has already been hooked into the v8
                    // engine when the Env was initialized - like every other type.
                    // But the V8 global is its own FunctionTemplate instance so even
                    // though it's also a Window, we need to set the prototype for this
                    // specific instance of the the Window.
                    if (@hasDecl(Global, "prototype")) {
                        const proto_type = Receiver(@typeInfo(Global.prototype).pointer.child);
                        const proto_name = @typeName(proto_type);
                        const proto_index = @field(TYPE_LOOKUP, proto_name);
                        js_global.inherit(templates[proto_index]);
                    }

                    const context_local = v8.Context.init(isolate, global_template, null);
                    const v8_context = v8.Persistent(v8.Context).init(isolate, context_local).castToContext();
                    v8_context.enter();
                    errdefer if (enter) v8_context.exit();
                    defer if (!enter) v8_context.exit();

                    // This shouldn't be necessary, but it is:
                    // https://groups.google.com/g/v8-users/c/qAQQBmbi--8
                    // TODO: see if newer V8 engines have a way around this.
                    inline for (Types, 0..) |s, i| {
                        const Struct = s.defaultValue().?;

                        if (@hasDecl(Struct, "prototype")) {
                            const proto_type = Receiver(@typeInfo(Struct.prototype).pointer.child);
                            const proto_name = @typeName(proto_type);
                            if (@hasField(TypeLookup, proto_name) == false) {
                                @compileError("Type '" ++ @typeName(Struct) ++ "' defines an unknown prototype: " ++ proto_name);
                            }

                            const proto_index = @field(TYPE_LOOKUP, proto_name);
                            const proto_obj = templates[proto_index].getFunction(v8_context).toObject();

                            const self_obj = templates[i].getFunction(v8_context).toObject();
                            _ = self_obj.setPrototype(v8_context, proto_obj);
                        }
                    }
                    break :blk v8_context;
                };

                // For a Page we only create one HandleScope, it is stored in the main World (enter==true). A page can have multple contexts, 1 for each World.
                // The main Context that enters and holds the HandleScope should therefore always be created first. Following other worlds for this page
                // like isolated Worlds, will thereby place their objects on the main page's HandleScope. Note: In the furure the number of context will multiply multiple frames support
                var handle_scope: ?v8.HandleScope = null;
                if (enter) {
                    handle_scope = @as(v8.HandleScope, undefined);
                    v8.HandleScope.init(&handle_scope.?, isolate);
                }
                errdefer if (enter) handle_scope.?.deinit();

                {
                    // If we want to overwrite the built-in console, we have to
                    // delete the built-in one.
                    const js_obj = v8_context.getGlobal();
                    const console_key = v8.String.initUtf8(isolate, "console");
                    if (js_obj.deleteValue(v8_context, console_key) == false) {
                        return error.ConsoleDeleteError;
                    }
                }

                self.js_context = JsContext{
                    .state = state,
                    .isolate = isolate,
                    .v8_context = v8_context,
                    .templates = &env.templates,
                    .meta_lookup = &env.meta_lookup,
                    .handle_scope = handle_scope,
                    .call_arena = self.call_arena.allocator(),
                    .context_arena = self.context_arena.allocator(),
                    .module_loader = .{
                        .ptr = safe_module_loader,
                        .func = ModuleLoader.fetchModuleSource,
                    },
                    .global_callback = global_callback,
                };

                var js_context = &self.js_context.?;
                {
                    // Given a context, we can get our executor.
                    // (we store a pointer to our executor in the context's
                    // embeddeder data)
                    const data = isolate.initBigIntU64(@intCast(@intFromPtr(js_context)));
                    v8_context.setEmbedderData(1, data);
                }

                {
                    // Not the prettiest but we want to make the `call_arena`
                    // optionally available to the WebAPIs. If `state` has a
                    // call_arena field, fill-it in now.
                    const state_type_info = @typeInfo(@TypeOf(state));
                    if (state_type_info == .pointer and @hasField(state_type_info.pointer.child, "call_arena")) {
                        js_context.state.call_arena = js_context.call_arena;
                    }
                }

                // Custom exception
                // NOTE: there is no way in v8 to subclass the Error built-in type
                // TODO: this is an horrible hack
                inline for (Types) |s| {
                    const Struct = s.defaultValue().?;
                    if (@hasDecl(Struct, "ErrorSet")) {
                        const script = comptime classNameForStruct(Struct) ++ ".prototype.__proto__ = Error.prototype";
                        _ = try js_context.exec(script, "errorSubclass");
                    }
                }

                // Primitive attributes are set directly on the FunctionTemplate
                // when we setup the environment. But we cannot set more complex
                // types (v8 will crash).
                //
                // Plus, just to create more complex types, we always need a
                // context, i.e. an Array has to have a Context to exist.
                //
                // As far as I can tell, getting the FunctionTemplate's object
                // and setting values directly on it, for each context, is the
                // way to do this.
                inline for (Types, 0..) |s, i| {
                    const Struct = s.defaultValue().?;
                    inline for (@typeInfo(Struct).@"struct".decls) |declaration| {
                        const name = declaration.name;
                        if (comptime name[0] == '_') {
                            const value = @field(Struct, name);

                            if (comptime isComplexAttributeType(@typeInfo(@TypeOf(value)))) {
                                const js_obj = templates[i].getFunction(v8_context).toObject();
                                const js_name = v8.String.initUtf8(isolate, name[1..]).toName();
                                const js_val = try js_context.zigValueToJs(value);
                                if (!js_obj.setValue(v8_context, js_name, js_val)) {
                                    log.fatal(.app, "set class attribute", .{
                                        .@"struct" = @typeName(Struct),
                                        .name = name,
                                    });
                                }
                            }
                        }
                    }
                }

                _ = try js_context._mapZigInstanceToJs(v8_context.getGlobal(), global);
                return js_context;
            }

            pub fn removeJsContext(self: *ExecutionWorld) void {
                self.js_context.?.deinit();
                self.js_context = null;
                _ = self.context_arena.reset(.{ .retain_with_limit = CONTEXT_ARENA_RETAIN });
            }

            pub fn terminateExecution(self: *const ExecutionWorld) void {
                self.env.isolate.terminateExecution();
            }

            pub fn resumeExecution(self: *const ExecutionWorld) void {
                self.env.isolate.cancelTerminateExecution();
            }
        };

        const PersistentObject = v8.Persistent(v8.Object);
        const PersistentModule = v8.Persistent(v8.Module);
        const PersistentFunction = v8.Persistent(v8.Function);

        // Loosely maps to a Browser Page.
        pub const JsContext = struct {
            state: State,
            isolate: v8.Isolate,
            // This context is a persistent object. The persistent needs to be recovered and reset.
            v8_context: v8.Context,
            handle_scope: ?v8.HandleScope,

            // references Env.templates
            templates: []v8.FunctionTemplate,

            // references the Env.meta_lookup
            meta_lookup: []TypeMeta,

            // An arena for the lifetime of a call-group. Gets reset whenever
            // call_depth reaches 0.
            call_arena: Allocator,

            // An arena for the lifetime of the context
            context_arena: Allocator,

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
            // JsObject, but the JsObject has no lifetime guarantee beyond the
            // current call. They can call .persist() on their JsObject to get
            // a `*PersistentObject()`. We need to track these to free them.
            // This used to be a map and acted like identity_map; the key was
            // the @intFromPtr(js_obj.handle). But v8 can re-use address. Without
            // a reliable way to know if an object has already been persisted,
            // we now simply persist every time persist() is called.
            js_object_list: std.ArrayListUnmanaged(PersistentObject) = .empty,

            // When we need to load a resource (i.e. an external script), we call
            // this function to get the source. This is always a reference to the
            // Page's fetchModuleSource, but we use a function pointer
            // since this js module is decoupled from the browser implementation.
            module_loader: ModuleLoader,

            // Some Zig types have code to execute to cleanup
            destructor_callbacks: std.ArrayListUnmanaged(DestructorCallback) = .empty,

            // Our module cache: normalized module specifier => module.
            module_cache: std.StringHashMapUnmanaged(PersistentModule) = .empty,

            // Module => Path. The key is the module hashcode (module.getIdentityHash)
            // and the value is the full path to the module. We need to capture this
            // so that when we're asked to resolve a dependent module, and all we're
            // given is the specifier, we can form the full path. The full path is
            // necessary to lookup/store the dependent module in the module_cache.
            module_identifier: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

            // Global callback is called on missing property.
            global_callback: ?GlobalMissingCallback = null,

            const ModuleLoader = struct {
                ptr: *anyopaque,
                func: *const fn (ptr: *anyopaque, url: [:0]const u8) anyerror!BlockingResult,

                // Don't like having to reach into ../browser/ here. But can't think
                // of a good way to fix this.
                const BlockingResult = @import("../browser/ScriptManager.zig").BlockingResult;
            };

            // no init, started with executor.createJsContext()

            fn deinit(self: *JsContext) void {
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

                {
                    var it = self.module_cache.valueIterator();
                    while (it.next()) |p| {
                        p.deinit();
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

            fn trackCallback(self: *JsContext, pf: PersistentFunction) !void {
                return self.callbacks.append(self.context_arena, pf);
            }

            // Given an anytype, turns it into a v8.Object. The anytype could be:
            // 1 - A V8.object already
            // 2 - Our JsObject wrapper around a V8.Object
            // 3 - A zig instance that has previously been given to V8
            //     (i.e., the value has to be known to the executor)
            fn valueToExistingObject(self: *const JsContext, value: anytype) !v8.Object {
                if (@TypeOf(value) == v8.Object) {
                    return value;
                }

                if (@TypeOf(value) == JsObject) {
                    return value.js_obj;
                }

                const persistent_object = self.identity_map.get(@intFromPtr(value)) orelse {
                    return error.InvalidThisForCallback;
                };

                return persistent_object.castToObject();
            }

            pub fn stackTrace(self: *const JsContext) !?[]const u8 {
                return stackForLogs(self.call_arena, self.isolate);
            }

            // Executes the src
            pub fn eval(self: *JsContext, src: []const u8, name: ?[]const u8) !void {
                _ = try self.exec(src, name);
            }

            pub fn exec(self: *JsContext, src: []const u8, name: ?[]const u8) !Value {
                const v8_context = self.v8_context;

                const scr = try compileScript(self.isolate, v8_context, src, name);

                const value = scr.run(v8_context) catch {
                    return error.ExecutionError;
                };

                return self.createValue(value);
            }

            // compile and eval a JS module
            // It returns null if the module is already compiled and in the cache.
            // It returns a v8.Promise if the module must be evaluated.
            pub fn module(self: *JsContext, src: []const u8, url: []const u8, cacheable: bool) !?v8.Promise {
                const arena = self.context_arena;

                if (cacheable and self.module_cache.contains(url)) {
                    return null;
                }
                errdefer _ = self.module_cache.remove(url);

                const m = try compileModule(self.isolate, src, url);

                const owned_url = try arena.dupe(u8, url);
                try self.module_identifier.putNoClobber(arena, m.getIdentityHash(), owned_url);
                errdefer _ = self.module_identifier.remove(m.getIdentityHash());

                if (cacheable) {
                    try self.module_cache.putNoClobber(
                        arena,
                        owned_url,
                        PersistentModule.init(self.isolate, m),
                    );
                }

                // resolveModuleCallback loads module's dependencies.
                const v8_context = self.v8_context;
                if (try m.instantiate(v8_context, resolveModuleCallback) == false) {
                    return error.ModuleInstantiationError;
                }

                const evaluated = try m.evaluate(v8_context);
                // https://v8.github.io/api/head/classv8_1_1Module.html#a1f1758265a4082595757c3251bb40e0f
                // Must be a promise that gets returned here.
                std.debug.assert(evaluated.isPromise());
                const promise = v8.Promise{ .handle = evaluated.handle };
                return promise;
            }

            pub fn newArray(self: *JsContext, len: u32) JsObject {
                const arr = v8.Array.init(self.isolate, len);
                return .{
                    .js_context = self,
                    .js_obj = arr.castTo(v8.Object),
                };
            }

            // Wrap a v8.Exception
            fn createException(self: *const JsContext, e: v8.Value) Exception {
                return .{
                    .inner = e,
                    .js_context = self,
                };
            }

            // Wrap a v8.Value, largely so that we can provide a convenient
            // toString function
            fn createValue(self: *const JsContext, value: v8.Value) Value {
                return .{
                    .value = value,
                    .js_context = self,
                };
            }

            fn zigValueToJs(self: *const JsContext, value: anytype) !v8.Value {
                return Self.zigValueToJs(self.templates, self.isolate, self.v8_context, value);
            }

            // See _mapZigInstanceToJs, this is wrapper that can be called
            // without a Context. This is possible because we store our
            // js_context in the EmbedderData of the v8.Context. So, as long as
            // we have a v8.Context, we can get the js_context.
            fn mapZigInstanceToJs(v8_context: v8.Context, js_obj_or_template: anytype, value: anytype) !PersistentObject {
                const js_context: *JsContext = @ptrFromInt(v8_context.getEmbedderData(1).castTo(v8.BigInt).getUint64());
                return js_context._mapZigInstanceToJs(js_obj_or_template, value);
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
            fn _mapZigInstanceToJs(self: *JsContext, js_obj_or_template: anytype, value: anytype) !PersistentObject {
                const v8_context = self.v8_context;
                const context_arena = self.context_arena;

                const T = @TypeOf(value);
                switch (@typeInfo(T)) {
                    .@"struct" => {
                        // Struct, has to be placed on the heap
                        const heap = try context_arena.create(T);
                        heap.* = value;
                        return self._mapZigInstanceToJs(js_obj_or_template, heap);
                    },
                    .pointer => |ptr| {
                        const gop = try self.identity_map.getOrPut(context_arena, @intFromPtr(value));
                        if (gop.found_existing) {
                            // we've seen this instance before, return the same
                            // PersistentObject.
                            return gop.value_ptr.*;
                        }

                        if (comptime @hasDecl(ptr.child, "destructor")) {
                            try self.destructor_callbacks.append(context_arena, DestructorCallback.init(value));
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

                        if (isEmpty(ptr.child) == false) {
                            // The TAO contains the pointer ot our Zig instance as
                            // well as any meta data we'll need to use it later.
                            // See the TaggedAnyOpaque struct for more details.
                            const tao = try context_arena.create(TaggedAnyOpaque);
                            const meta_index = @field(TYPE_LOOKUP, @typeName(ptr.child));
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
                            const obj_wrap = JsThis{ .obj = .{ .js_obj = js_obj, .js_context = self } };
                            switch (@typeInfo(@TypeOf(ptr.child.postAttach)).@"fn".params.len) {
                                2 => try value.postAttach(obj_wrap),
                                3 => try value.postAttach(self.state, obj_wrap),
                                else => @compileError(@typeName(ptr.child) ++ ".postAttach must take 2 or 3 parameters"),
                            }
                        }

                        return js_persistent;
                    },
                    else => @compileError("Expected a struct or pointer, got " ++ @typeName(T) ++ " (constructors must return struct or pointers)"),
                }
            }

            fn jsValueToZig(self: *JsContext, comptime named_function: NamedFunction, comptime T: type, js_value: v8.Value) !T {
                switch (@typeInfo(T)) {
                    .optional => |o| {
                        if (comptime isJsObject(o.child)) {
                            // If type type is a ?JsObject, then we want to pass
                            // a JsObject, not null. Consider a function,
                            //    _doSomething(arg: ?Env.JsObjet) void { ... }
                            //
                            // And then these two calls:
                            //   doSomething();
                            //   doSomething(null);
                            //
                            // In the first case, we'll pass `null`. But in the
                            // second, we'll pass a JsObject which represents
                            // null.
                            // If we don't have this code, both cases will
                            // pass in `null` and the the doSomething won't
                            // be able to tell if `null` was explicitly passed
                            // or whether no parameter was passed.
                            return JsObject{
                                .js_obj = js_value.castTo(v8.Object),
                                .js_context = self,
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
                            if (@hasField(TypeLookup, @typeName(ptr.child))) {
                                const js_obj = js_value.castTo(v8.Object);
                                return self.typeTaggedAnyOpaque(named_function, *Receiver(ptr.child), js_obj);
                            }
                        },
                        .slice => {
                            var force_u8 = false;
                            var array_buffer: ?v8.ArrayBuffer = null;
                            if (js_value.isTypedArray()) {
                                const buffer_view = js_value.castTo(v8.ArrayBufferView);
                                array_buffer = buffer_view.getBuffer();
                            } else if (js_value.isArrayBufferView()) {
                                force_u8 = true;
                                const buffer_view = js_value.castTo(v8.ArrayBufferView);
                                array_buffer = buffer_view.getBuffer();
                            } else if (js_value.isArrayBuffer()) {
                                force_u8 = true;
                                array_buffer = js_value.castTo(v8.ArrayBuffer);
                            }

                            if (array_buffer) |buffer| {
                                const backing_store = v8.BackingStore.sharedPtrGet(&buffer.getBackingStore());
                                const data = backing_store.getData();
                                const byte_len = backing_store.getByteLength();

                                switch (ptr.child) {
                                    u8 => {
                                        // need this sentinel check to keep the compiler happy
                                        if (ptr.sentinel() == null) {
                                            if (force_u8 or js_value.isUint8Array() or js_value.isUint8ClampedArray()) {
                                                if (byte_len == 0) return &[_]u8{};
                                                const arr_ptr = @as([*]u8, @ptrCast(@alignCast(data)));
                                                return arr_ptr[0..byte_len];
                                            }
                                        }
                                    },
                                    i8 => {
                                        if (js_value.isInt8Array()) {
                                            if (byte_len == 0) return &[_]i8{};
                                            const arr_ptr = @as([*]i8, @ptrCast(@alignCast(data)));
                                            return arr_ptr[0..byte_len];
                                        }
                                    },
                                    u16 => {
                                        if (js_value.isUint16Array()) {
                                            if (byte_len == 0) return &[_]u16{};
                                            const arr_ptr = @as([*]u16, @ptrCast(@alignCast(data)));
                                            return arr_ptr[0 .. byte_len / 2];
                                        }
                                    },
                                    i16 => {
                                        if (js_value.isInt16Array()) {
                                            if (byte_len == 0) return &[_]i16{};
                                            const arr_ptr = @as([*]i16, @ptrCast(@alignCast(data)));
                                            return arr_ptr[0 .. byte_len / 2];
                                        }
                                    },
                                    u32 => {
                                        if (js_value.isUint32Array()) {
                                            if (byte_len == 0) return &[_]u32{};
                                            const arr_ptr = @as([*]u32, @ptrCast(@alignCast(data)));
                                            return arr_ptr[0 .. byte_len / 4];
                                        }
                                    },
                                    i32 => {
                                        if (js_value.isInt32Array()) {
                                            if (byte_len == 0) return &[_]i32{};
                                            const arr_ptr = @as([*]i32, @ptrCast(@alignCast(data)));
                                            return arr_ptr[0 .. byte_len / 4];
                                        }
                                    },
                                    u64 => {
                                        if (js_value.isBigUint64Array()) {
                                            if (byte_len == 0) return &[_]u64{};
                                            const arr_ptr = @as([*]u64, @ptrCast(@alignCast(data)));
                                            return arr_ptr[0 .. byte_len / 8];
                                        }
                                    },
                                    i64 => {
                                        if (js_value.isBigInt64Array()) {
                                            if (byte_len == 0) return &[_]i64{};
                                            const arr_ptr = @as([*]i64, @ptrCast(@alignCast(data)));
                                            return arr_ptr[0 .. byte_len / 8];
                                        }
                                    },
                                    else => {},
                                }
                                return error.InvalidArgument;
                            }

                            if (ptr.child == u8) {
                                if (ptr.sentinel()) |s| {
                                    if (comptime s == 0) {
                                        return valueToStringZ(self.call_arena, js_value, self.isolate, self.v8_context);
                                    }
                                } else {
                                    return valueToString(self.call_arena, js_value, self.isolate, self.v8_context);
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
            fn jsValueToStruct(self: *JsContext, comptime named_function: NamedFunction, comptime T: type, js_value: v8.Value) !?T {
                if (@hasDecl(T, "_FUNCTION_ID_KLUDGE")) {
                    if (!js_value.isFunction()) {
                        return null;
                    }
                    return try self.createFunction(js_value);
                }

                const js_obj = js_value.castTo(v8.Object);

                if (comptime isJsObject(T)) {
                    // Caller wants an opaque JsObject. Probably a parameter
                    // that it needs to pass back into a callback
                    return JsObject{
                        .js_obj = js_obj,
                        .js_context = self,
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

            fn createFunction(self: *JsContext, js_value: v8.Value) !Function {
                // caller should have made sure this was a function
                std.debug.assert(js_value.isFunction());

                const func = v8.Persistent(v8.Function).init(self.isolate, js_value.castTo(v8.Function));
                try self.trackCallback(func);

                return .{
                    .func = func,
                    .js_context = self,
                    .id = js_value.castTo(v8.Object).getIdentityHash(),
                };
            }

            pub fn createPromiseResolver(self: *JsContext) PromiseResolver {
                return .{
                    .js_context = self,
                    .resolver = v8.PromiseResolver.init(self.v8_context),
                };
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
            fn probeJsValueToZig(self: *JsContext, comptime named_function: NamedFunction, comptime T: type, js_value: v8.Value) !ProbeResult(T) {
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
                            if (@hasField(TypeLookup, @typeName(ptr.child))) {
                                const js_obj = js_value.castTo(v8.Object);
                                // There's a bit of overhead in doing this, so instead
                                // of having a version of typeTaggedAnyOpaque which
                                // returns a boolean or an optional, we rely on the
                                // main implementation and just handle the error.
                                const attempt = self.typeTaggedAnyOpaque(named_function, *Receiver(ptr.child), js_obj);
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

            pub fn throw(self: *JsContext, err: []const u8) Exception {
                const js_value = js.createException(self.isolate, err);
                return self.createException(js_value);
            }

            fn initializeImportMeta(self: *JsContext, m: v8.Module, meta: v8.Object) !void {
                const url = self.module_identifier.get(m.getIdentityHash()) orelse {
                    // Shouldn't be possible.
                    return error.UnknownModuleReferrer;
                };

                const js_key = v8.String.initUtf8(self.isolate, "url");
                const js_value = try self.zigValueToJs(url);
                const res = meta.defineOwnProperty(self.v8_context, js_key.toName(), js_value, 0) orelse false;
                if (!res) {
                    return error.FailedToSet;
                }
            }

            // Callback from V8, asking us to load a module. The "specifier" is
            // the src of the module to load.
            fn resolveModuleCallback(
                c_context: ?*const v8.C_Context,
                c_specifier: ?*const v8.C_String,
                import_attributes: ?*const v8.C_FixedArray,
                c_referrer: ?*const v8.C_Module,
            ) callconv(.c) ?*const v8.C_Module {
                _ = import_attributes;

                const v8_context = v8.Context{ .handle = c_context.? };
                const self: *JsContext = @ptrFromInt(v8_context.getEmbedderData(1).castTo(v8.BigInt).getUint64());

                const specifier = jsStringToZig(self.call_arena, .{ .handle = c_specifier.? }, self.isolate) catch |err| {
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

            fn _resolveModuleCallback(self: *JsContext, referrer: v8.Module, specifier: []const u8) !?*const v8.C_Module {
                const referrer_path = self.module_identifier.get(referrer.getIdentityHash()) orelse {
                    // Shouldn't be possible.
                    return error.UnknownModuleReferrer;
                };

                const normalized_specifier = try @import("../url.zig").stitch(
                    self.call_arena,
                    specifier,
                    referrer_path,
                    .{ .alloc = .if_needed, .null_terminated = true },
                );

                if (self.module_cache.get(normalized_specifier)) |pm| {
                    return pm.handle;
                }

                const m: v8.Module = blk: {
                    const module_loader = self.module_loader;
                    var fetch_result = try module_loader.func(module_loader.ptr, normalized_specifier);
                    defer fetch_result.deinit();

                    var try_catch: TryCatch = undefined;
                    try_catch.init(self);
                    defer try_catch.deinit();

                    break :blk compileModule(self.isolate, fetch_result.src(), normalized_specifier) catch |err| {
                        log.warn(.js, "compile resolved module", .{
                            .specifier = specifier,
                            .stack = try_catch.stack(self.call_arena) catch null,
                            .src = try_catch.sourceLine(self.call_arena) catch "err",
                            .line = try_catch.sourceLineNumber() orelse 0,
                            .exception = (try_catch.exception(self.call_arena) catch @errorName(err)) orelse @errorName(err),
                        });
                        return null;
                    };
                };

                // We were hoping to find the module in our cache, and thus used
                // the short-lived call_arena to create the normalized_specifier.
                // But now this will live for the lifetime of the context.
                const arena = self.context_arena;
                const owned_specifier = try arena.dupe(u8, normalized_specifier);
                try self.module_cache.put(arena, owned_specifier, PersistentModule.init(self.isolate, m));
                try self.module_identifier.putNoClobber(arena, m.getIdentityHash(), owned_specifier);
                return m.handle;
            }

            // Reverses the mapZigInstanceToJs, making sure that our TaggedAnyOpaque
            // contains a ptr to the correct type.
            fn typeTaggedAnyOpaque(self: *const JsContext, comptime named_function: NamedFunction, comptime R: type, js_obj: v8.Object) !R {
                const ti = @typeInfo(R);
                if (ti != .pointer) {
                    @compileError(named_function.full_name ++ "has a non-pointer Zig parameter type: " ++ @typeName(R));
                }

                const T = ti.pointer.child;
                if (comptime isEmpty(T)) {
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
                if (@hasField(TypeLookup, type_name) == false) {
                    @compileError(named_function.full_name ++ "has an unknown Zig type: " ++ @typeName(R));
                }

                const op = js_obj.getInternalField(0).castTo(v8.External).get();
                const tao: *TaggedAnyOpaque = @ptrCast(@alignCast(op));
                const expected_type_index = @field(TYPE_LOOKUP, type_name);

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

                    const prototype_index = PROTOTYPE_TABLE[type_index];
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

            pub fn dynamicModuleCallback(
                v8_ctx: ?*const v8.c.Context,
                host_defined_options: ?*const v8.c.Data,
                resource_name: ?*const v8.c.Value,
                v8_specifier: ?*const v8.c.String,
                import_attrs: ?*const v8.c.FixedArray,
            ) callconv(.c) ?*v8.c.Promise {
                _ = host_defined_options;
                _ = import_attrs;
                const ctx: v8.Context = .{ .handle = v8_ctx.? };
                const context: *JsContext = @ptrFromInt(ctx.getEmbedderData(1).castTo(v8.BigInt).getUint64());
                const iso = context.isolate;
                const resolver = v8.PromiseResolver.init(context.v8_context);

                const specifier: v8.String = .{ .handle = v8_specifier.? };
                const specifier_str = jsStringToZig(context.context_arena, specifier, iso) catch {
                    const error_msg = v8.String.initUtf8(iso, "Failed to parse module specifier");
                    _ = resolver.reject(ctx, error_msg.toValue());
                    return @constCast(resolver.getPromise().handle);
                };
                const resource: v8.String = .{ .handle = resource_name.? };
                const resource_str = jsStringToZig(context.context_arena, resource, iso) catch {
                    const error_msg = v8.String.initUtf8(iso, "Failed to parse module resource");
                    _ = resolver.reject(ctx, error_msg.toValue());
                    return @constCast(resolver.getPromise().handle);
                };

                const normalized_specifier = @import("../url.zig").stitch(
                    context.context_arena,
                    specifier_str,
                    resource_str,
                    .{ .alloc = .if_needed, .null_terminated = true },
                ) catch unreachable;

                log.debug(.js, "dynamic import", .{
                    .specifier = specifier_str,
                    .resource = resource_str,
                    .normalized_specifier = normalized_specifier,
                });

                _dynamicModuleCallback(context, normalized_specifier, &resolver) catch |err| {
                    log.err(.js, "dynamic module callback", .{
                        .err = err,
                    });
                    // Must be rejected at this point
                    // otherwise, we will just wait on a pending promise.
                    std.debug.assert(resolver.getPromise().getState() == .kRejected);
                };
                return @constCast(resolver.getPromise().handle);
            }

            fn _dynamicModuleCallback(
                self: *JsContext,
                specifier: [:0]const u8,
                resolver: *const v8.PromiseResolver,
            ) !void {
                const iso = self.isolate;
                const ctx = self.v8_context;

                var try_catch: TryCatch = undefined;
                try_catch.init(self);
                defer try_catch.deinit();

                const maybe_promise: ?v8.Promise = blk: {
                    const module_loader = self.module_loader;
                    var fetch_result = module_loader.func(module_loader.ptr, specifier) catch {
                        const error_msg = v8.String.initUtf8(iso, "Failed to load module");
                        _ = resolver.reject(ctx, error_msg.toValue());
                        return;
                    };
                    defer fetch_result.deinit();

                    break :blk self.module(fetch_result.src(), specifier, true) catch {
                        log.err(.js, "module compilation failed", .{
                            .specifier = specifier,
                            .exception = try_catch.exception(self.call_arena) catch "unknown error",
                            .stack = try_catch.stack(self.call_arena) catch null,
                            .line = try_catch.sourceLineNumber() orelse 0,
                        });
                        const error_msg = if (try_catch.hasCaught()) eblk: {
                            const exception_str = try_catch.exception(self.call_arena) catch "Evaluation error";
                            break :eblk v8.String.initUtf8(iso, exception_str orelse "Evaluation error");
                        } else v8.String.initUtf8(iso, "Module evaluation failed");
                        _ = resolver.reject(ctx, error_msg.toValue());
                        return;
                    };
                };

                const new_module = self.module_cache.get(specifier).?.castToModule();

                if (maybe_promise) |promise| {
                    // This means we must wait for the evaluation.
                    const EvaluationData = struct {
                        specifier: []const u8,
                        module: v8.Persistent(v8.Module),
                        resolver: v8.Persistent(v8.PromiseResolver),

                        pub fn deinit(ev: *@This()) void {
                            ev.module.deinit();
                            ev.resolver.deinit();
                        }
                    };

                    const ev_data = try self.context_arena.create(EvaluationData);
                    ev_data.* = .{
                        .specifier = specifier,
                        .module = v8.Persistent(v8.Module).init(iso, new_module),
                        .resolver = v8.Persistent(v8.PromiseResolver).init(iso, resolver.*),
                    };
                    const external = v8.External.init(iso, @ptrCast(ev_data));

                    const then_callback = v8.Function.initWithData(ctx, struct {
                        pub fn callback(info: ?*const v8.c.FunctionCallbackInfo) callconv(.c) void {
                            const cb_info = v8.FunctionCallbackInfo{ .handle = info.? };
                            const cb_isolate = cb_info.getIsolate();
                            const cb_context = cb_isolate.getCurrentContext();
                            const data: *EvaluationData = @ptrCast(@alignCast(cb_info.getExternalValue()));
                            defer data.deinit();
                            const cb_module = data.module.castToModule();
                            const cb_resolver = data.resolver.castToPromiseResolver();

                            const namespace = cb_module.getModuleNamespace();
                            log.info(.js, "dynamic import complete", .{ .specifier = data.specifier });
                            _ = cb_resolver.resolve(cb_context, namespace);
                        }
                    }.callback, external);

                    const catch_callback = v8.Function.initWithData(ctx, struct {
                        pub fn callback(info: ?*const v8.c.FunctionCallbackInfo) callconv(.c) void {
                            const cb_info = v8.FunctionCallbackInfo{ .handle = info.? };
                            const cb_context = cb_info.getIsolate().getCurrentContext();
                            const data: *EvaluationData = @ptrCast(@alignCast(cb_info.getExternalValue()));
                            defer data.deinit();
                            const cb_resolver = data.resolver.castToPromiseResolver();

                            log.err(.js, "dynamic import failed", .{ .specifier = data.specifier });
                            _ = cb_resolver.reject(cb_context, cb_info.getData());
                        }
                    }.callback, external);

                    _ = promise.thenAndCatch(ctx, then_callback, catch_callback) catch {
                        log.err(.js, "module evaluation is promise", .{
                            .specifier = specifier,
                            .line = try_catch.sourceLineNumber() orelse 0,
                        });
                        defer ev_data.deinit();
                        const error_msg = v8.String.initUtf8(iso, "Evaluation is a promise");
                        _ = resolver.reject(ctx, error_msg.toValue());
                        return;
                    };
                } else {
                    // This means it is already present in the cache.
                    const namespace = new_module.getModuleNamespace();
                    log.info(.js, "dynamic import complete", .{
                        .module = new_module,
                        .namespace = namespace,
                    });
                    _ = resolver.resolve(ctx, namespace);
                    return;
                }
            }
        };

        pub const Function = struct {
            id: usize,
            js_context: *JsContext,
            this: ?v8.Object = null,
            func: PersistentFunction,

            // We use this when mapping a JS value to a Zig object. We can't
            // Say we have a Zig function that takes a Function, we can't just
            // check param.type == Function, because Function is a generic.
            // So, as a quick hack, we can determine if the Zig type is a
            // callback by checking @hasDecl(T, "_FUNCTION_ID_KLUDGE")
            const _FUNCTION_ID_KLUDGE = true;

            pub const Result = struct {
                stack: ?[]const u8,
                exception: []const u8,
            };

            pub fn getName(self: *const Function, allocator: Allocator) ![]const u8 {
                const name = self.func.castToFunction().getName();
                return valueToString(allocator, name, self.js_context.isolate, self.js_context.v8_context);
            }

            pub fn setName(self: *const Function, name: []const u8) void {
                const v8_name = v8.String.initUtf8(self.js_context.isolate, name);
                self.func.castToFunction().setName(v8_name);
            }

            pub fn withThis(self: *const Function, value: anytype) !Function {
                const this_obj = if (@TypeOf(value) == JsObject)
                    value.js_obj
                else
                    (try self.js_context.zigValueToJs(value)).castTo(v8.Object);

                return .{
                    .id = self.id,
                    .this = this_obj,
                    .func = self.func,
                    .js_context = self.js_context,
                };
            }

            pub fn newInstance(self: *const Function, result: *Result) !JsObject {
                const context = self.js_context;

                var try_catch: TryCatch = undefined;
                try_catch.init(context);
                defer try_catch.deinit();

                // This creates a new instance using this Function as a constructor.
                // This returns a generic Object
                const js_obj = self.func.castToFunction().initInstance(context.v8_context, &.{}) orelse {
                    if (try_catch.hasCaught()) {
                        const allocator = context.call_arena;
                        result.stack = try_catch.stack(allocator) catch null;
                        result.exception = (try_catch.exception(allocator) catch "???") orelse "???";
                    } else {
                        result.stack = null;
                        result.exception = "???";
                    }
                    return error.JsConstructorFailed;
                };

                return .{
                    .js_context = context,
                    .js_obj = js_obj,
                };
            }

            pub fn call(self: *const Function, comptime T: type, args: anytype) !T {
                return self.callWithThis(T, self.getThis(), args);
            }

            pub fn tryCall(self: *const Function, comptime T: type, args: anytype, result: *Result) !T {
                return self.tryCallWithThis(T, self.getThis(), args, result);
            }

            pub fn tryCallWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype, result: *Result) !T {
                var try_catch: TryCatch = undefined;
                try_catch.init(self.js_context);
                defer try_catch.deinit();

                return self.callWithThis(T, this, args) catch |err| {
                    if (try_catch.hasCaught()) {
                        const allocator = self.js_context.call_arena;
                        result.stack = try_catch.stack(allocator) catch null;
                        result.exception = (try_catch.exception(allocator) catch @errorName(err)) orelse @errorName(err);
                    } else {
                        result.stack = null;
                        result.exception = @errorName(err);
                    }
                    return err;
                };
            }

            pub fn callWithThis(self: *const Function, comptime T: type, this: anytype, args: anytype) !T {
                const js_context = self.js_context;

                const js_this = try js_context.valueToExistingObject(this);

                const aargs = if (comptime @typeInfo(@TypeOf(args)) == .null) struct {}{} else args;

                const js_args: []const v8.Value = switch (@typeInfo(@TypeOf(aargs))) {
                    .@"struct" => |s| blk: {
                        const fields = s.fields;
                        var js_args: [fields.len]v8.Value = undefined;
                        inline for (fields, 0..) |f, i| {
                            js_args[i] = try js_context.zigValueToJs(@field(aargs, f.name));
                        }
                        const cargs: [fields.len]v8.Value = js_args;
                        break :blk &cargs;
                    },
                    .pointer => blk: {
                        var values = try js_context.call_arena.alloc(v8.Value, args.len);
                        for (args, 0..) |a, i| {
                            values[i] = try js_context.zigValueToJs(a);
                        }
                        break :blk values;
                    },
                    else => @compileError("JS Function called with invalid paremter type"),
                };

                const result = self.func.castToFunction().call(js_context.v8_context, js_this, js_args);
                if (result == null) {
                    return error.JSExecCallback;
                }

                if (@typeInfo(T) == .void) return {};
                const named_function = comptime NamedFunction.init(T, "callResult");
                return js_context.jsValueToZig(named_function, T, result.?);
            }

            fn getThis(self: *const Function) v8.Object {
                return self.this orelse self.js_context.v8_context.getGlobal();
            }

            // debug/helper to print the source of the JS callback
            pub fn printFunc(self: Function) !void {
                const js_context = self.js_context;
                const value = self.func.castToFunction().toValue();
                const src = try valueToString(js_context.call_arena, value, js_context.isolate, js_context.v8_context);
                std.debug.print("{s}\n", .{src});
            }
        };

        pub const JsObject = struct {
            js_context: *JsContext,
            js_obj: v8.Object,

            // If a Zig struct wants the JsObject parameter, it'll declare a
            // function like:
            //    fn _length(self: *const NodeList, js_obj: Env.JsObject) usize
            //
            // When we're trying to call this function, we can't just do
            //    if (params[i].type.? == JsObject)
            // Because there is _no_ JsObject, there's only an Env.JsObject, where
            // Env is a generic.
            // We could probably figure out a way to do this, but simply checking
            // for this declaration is _a lot_ easier.
            const _JSOBJECT_ID_KLUDGE = true;

            const SetOpts = packed struct(u32) {
                READ_ONLY: bool = false,
                DONT_ENUM: bool = false,
                DONT_DELETE: bool = false,
                _: u29 = 0,
            };
            pub fn setIndex(self: JsObject, index: u32, value: anytype, opts: SetOpts) !void {
                @setEvalBranchQuota(10000);
                const key = switch (index) {
                    inline 0...20 => |i| std.fmt.comptimePrint("{d}", .{i}),
                    else => try std.fmt.allocPrint(self.js_context.context_arena, "{d}", .{index}),
                };
                return self.set(key, value, opts);
            }

            pub fn set(self: JsObject, key: []const u8, value: anytype, opts: SetOpts) !void {
                const js_context = self.js_context;

                const js_key = v8.String.initUtf8(js_context.isolate, key);
                const js_value = try js_context.zigValueToJs(value);

                const res = self.js_obj.defineOwnProperty(js_context.v8_context, js_key.toName(), js_value, @bitCast(opts)) orelse false;
                if (!res) {
                    return error.FailedToSet;
                }
            }

            pub fn get(self: JsObject, key: []const u8) !Value {
                const js_context = self.js_context;
                const js_key = v8.String.initUtf8(js_context.isolate, key);
                const js_val = try self.js_obj.getValue(js_context.v8_context, js_key);
                return js_context.createValue(js_val);
            }

            pub fn isTruthy(self: JsObject) bool {
                const js_value = self.js_obj.toValue();
                return js_value.toBool(self.js_context.isolate);
            }

            pub fn toString(self: JsObject) ![]const u8 {
                const js_context = self.js_context;
                const js_value = self.js_obj.toValue();
                return valueToString(js_context.call_arena, js_value, js_context.isolate, js_context.v8_context);
            }

            pub fn toDetailString(self: JsObject) ![]const u8 {
                const js_context = self.js_context;
                const js_value = self.js_obj.toValue();
                return valueToDetailString(js_context.call_arena, js_value, js_context.isolate, js_context.v8_context);
            }

            pub fn format(self: JsObject, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                return writer.writeAll(try self.toString());
            }

            pub fn persist(self: JsObject) !JsObject {
                var js_context = self.js_context;
                const js_obj = self.js_obj;

                const persisted = PersistentObject.init(js_context.isolate, js_obj);
                try js_context.js_object_list.append(js_context.context_arena, persisted);

                return .{
                    .js_context = js_context,
                    .js_obj = persisted.castToObject(),
                };
            }

            pub fn getFunction(self: JsObject, name: []const u8) !?Function {
                if (self.isNullOrUndefined()) {
                    return null;
                }
                const js_context = self.js_context;

                const js_name = v8.String.initUtf8(js_context.isolate, name);

                const js_value = try self.js_obj.getValue(js_context.v8_context, js_name.toName());
                if (!js_value.isFunction()) {
                    return null;
                }
                return try js_context.createFunction(js_value);
            }

            pub fn isNull(self: JsObject) bool {
                return self.js_obj.toValue().isNull();
            }

            pub fn isUndefined(self: JsObject) bool {
                return self.js_obj.toValue().isUndefined();
            }

            pub fn triState(self: JsObject, comptime Struct: type, comptime name: []const u8, comptime T: type) !TriState(T) {
                if (self.isNull()) {
                    return .{ .null = {} };
                }
                if (self.isUndefined()) {
                    return .{ .undefined = {} };
                }
                return .{ .value = try self.toZig(Struct, name, T) };
            }

            pub fn isNullOrUndefined(self: JsObject) bool {
                return self.js_obj.toValue().isNullOrUndefined();
            }

            pub fn nameIterator(self: JsObject) ValueIterator {
                const js_context = self.js_context;
                const js_obj = self.js_obj;

                const array = js_obj.getPropertyNames(js_context.v8_context);
                const count = array.length();

                return .{
                    .count = count,
                    .js_context = js_context,
                    .js_obj = array.castTo(v8.Object),
                };
            }

            pub fn constructorName(self: JsObject, allocator: Allocator) ![]const u8 {
                const str = try self.js_obj.getConstructorName();
                return jsStringToZig(allocator, str, self.js_context.isolate);
            }

            pub fn toZig(self: JsObject, comptime Struct: type, comptime name: []const u8, comptime T: type) !T {
                const named_function = comptime NamedFunction.init(Struct, name);
                return self.js_context.jsValueToZig(named_function, T, self.js_obj.toValue());
            }

            pub fn TriState(comptime T: type) type {
                return union(enum) {
                    null: void,
                    undefined: void,
                    value: T,
                };
            }
        };

        // This only exists so that we know whether a function wants the opaque
        // JS argument (JsObject), or if it wants the receiver as an opaque
        // value.
        // JsObject is normally used when a method wants an opaque JS object
        // that it'll pass into a callback.
        // JsThis is used when the function wants to do advanced manipulation
        // of the v8.Object bound to the instance. For example, postAttach is an
        // example of using JsThis.
        pub const JsThis = struct {
            obj: JsObject,

            const _JSTHIS_ID_KLUDGE = true;

            pub fn setIndex(self: JsThis, index: u32, value: anytype, opts: JsObject.SetOpts) !void {
                return self.obj.setIndex(index, value, opts);
            }

            pub fn set(self: JsThis, key: []const u8, value: anytype, opts: JsObject.SetOpts) !void {
                return self.obj.set(key, value, opts);
            }

            pub fn constructorName(self: JsThis, allocator: Allocator) ![]const u8 {
                return try self.obj.constructorName(allocator);
            }
        };

        pub const TryCatch = struct {
            inner: v8.TryCatch,
            js_context: *const JsContext,

            pub fn init(self: *TryCatch, js_context: *const JsContext) void {
                self.js_context = js_context;
                self.inner.init(js_context.isolate);
            }

            pub fn hasCaught(self: TryCatch) bool {
                return self.inner.hasCaught();
            }

            // the caller needs to deinit the string returned
            pub fn exception(self: TryCatch, allocator: Allocator) !?[]const u8 {
                const msg = self.inner.getException() orelse return null;
                const js_context = self.js_context;
                return try valueToString(allocator, msg, js_context.isolate, js_context.v8_context);
            }

            // the caller needs to deinit the string returned
            pub fn stack(self: TryCatch, allocator: Allocator) !?[]const u8 {
                const js_context = self.js_context;
                const s = self.inner.getStackTrace(js_context.v8_context) orelse return null;
                return try valueToString(allocator, s, js_context.isolate, js_context.v8_context);
            }

            // the caller needs to deinit the string returned
            pub fn sourceLine(self: TryCatch, allocator: Allocator) !?[]const u8 {
                const js_context = self.js_context;
                const msg = self.inner.getMessage() orelse return null;
                const sl = msg.getSourceLine(js_context.v8_context) orelse return null;
                return try jsStringToZig(allocator, sl, js_context.isolate);
            }

            pub fn sourceLineNumber(self: TryCatch) ?u32 {
                const js_context = self.js_context;
                const msg = self.inner.getMessage() orelse return null;
                return msg.getLineNumber(js_context.v8_context);
            }

            // a shorthand method to return either the entire stack message
            // or just the exception message
            // - in Debug mode return the stack if available
            // - otherwise return the exception if available
            // the caller needs to deinit the string returned
            pub fn err(self: TryCatch, allocator: Allocator) !?[]const u8 {
                if (builtin.mode == .Debug) {
                    if (try self.stack(allocator)) |msg| {
                        return msg;
                    }
                }
                return try self.exception(allocator);
            }

            pub fn deinit(self: *TryCatch) void {
                self.inner.deinit();
            }
        };

        // If a function returns a []i32, should that map to a plain-old
        // JavaScript array, or a Int32Array? It's ambiguous. By default, we'll
        // map arrays/slices to the JavaScript arrays. If you want a TypedArray
        // wrap it in this.
        // Also, this type has nothing to do with the Env. But we place it here
        // for consistency. Want a callback? Env.Callback. Want a JsObject?
        // Env.JsObject. Want a TypedArray? Env.TypedArray.
        pub fn TypedArray(comptime T: type) type {
            return struct {
                // See Function._FUNCTION_ID_KLUDGE
                const _TYPED_ARRAY_ID_KLUDGE = true;

                values: []const T,
            };
        }

        pub const PromiseResolver = struct {
            js_context: *JsContext,
            resolver: v8.PromiseResolver,

            pub fn promise(self: PromiseResolver) Promise {
                return .{
                    .promise = self.resolver.getPromise(),
                };
            }

            pub fn resolve(self: PromiseResolver, value: anytype) !void {
                const js_context = self.js_context;
                const js_value = try js_context.zigValueToJs(value);

                // resolver.resolve will return null if the promise isn't pending
                const ok = self.resolver.resolve(js_context.v8_context, js_value) orelse return;
                if (!ok) {
                    return error.FailedToResolvePromise;
                }
            }
        };

        pub const Promise = struct {
            promise: v8.Promise,
        };

        pub const Inspector = struct {
            isolate: v8.Isolate,
            inner: *v8.Inspector,
            session: v8.InspectorSession,

            // We expect allocator to be an arena
            pub fn init(allocator: Allocator, isolate: v8.Isolate, ctx: anytype) !Inspector {
                const ContextT = @TypeOf(ctx);

                const InspectorContainer = switch (@typeInfo(ContextT)) {
                    .@"struct" => ContextT,
                    .pointer => |ptr| ptr.child,
                    .void => NoopInspector,
                    else => @compileError("invalid context type"),
                };

                // If necessary, turn a void context into something we can safely ptrCast
                const safe_context: *anyopaque = if (ContextT == void) @ptrCast(@constCast(&{})) else ctx;

                const channel = v8.InspectorChannel.init(safe_context, InspectorContainer.onInspectorResponse, InspectorContainer.onInspectorEvent, isolate);

                const client = v8.InspectorClient.init();

                const inner = try allocator.create(v8.Inspector);
                v8.Inspector.init(inner, client, channel, isolate);
                return .{ .inner = inner, .isolate = isolate, .session = inner.connect() };
            }

            pub fn deinit(self: *const Inspector) void {
                self.session.deinit();
                self.inner.deinit();
            }

            pub fn send(self: *const Inspector, msg: []const u8) void {
                // Can't assume the main Context exists (with its HandleScope)
                // available when doing this. Pages (and thus the HandleScope)
                // comes and goes, but CDP can keep sending messages.
                const isolate = self.isolate;
                var temp_scope: v8.HandleScope = undefined;
                v8.HandleScope.init(&temp_scope, isolate);
                defer temp_scope.deinit();

                self.session.dispatchProtocolMessage(isolate, msg);
            }

            // From CDP docs
            // https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#type-ExecutionContextDescription
            // ----
            // - name: Human readable name describing given context.
            // - origin: Execution context origin (ie. URL who initialised the request)
            // - auxData: Embedder-specific auxiliary data likely matching
            // {isDefault: boolean, type: 'default'|'isolated'|'worker', frameId: string}
            // - is_default_context: Whether the execution context is default, should match the auxData
            pub fn contextCreated(
                self: *const Inspector,
                js_context: *const JsContext,
                name: []const u8,
                origin: []const u8,
                aux_data: ?[]const u8,
                is_default_context: bool,
            ) void {
                self.inner.contextCreated(js_context.v8_context, name, origin, aux_data, is_default_context);
            }

            // Retrieves the RemoteObject for a given value.
            // The value is loaded through the ExecutionWorld's mapZigInstanceToJs function,
            // just like a method return value. Therefore, if we've mapped this
            // value before, we'll get the existing JS PersistedObject and if not
            // we'll create it and track it for cleanup when the context ends.
            pub fn getRemoteObject(
                self: *const Inspector,
                js_context: *const JsContext,
                group: []const u8,
                value: anytype,
            ) !RemoteObject {
                const js_value = try zigValueToJs(
                    js_context.templates,
                    js_context.isolate,
                    js_context.v8_context,
                    value,
                );

                // We do not want to expose this as a parameter for now
                const generate_preview = false;
                return self.session.wrapObject(
                    js_context.isolate,
                    js_context.v8_context,
                    js_value,
                    group,
                    generate_preview,
                );
            }

            // Gets a value by object ID regardless of which context it is in.
            pub fn getNodePtr(self: *const Inspector, allocator: Allocator, object_id: []const u8) !?*anyopaque {
                const unwrapped = try self.session.unwrapObject(allocator, object_id);
                // The values context and groupId are not used here
                const toa = getTaggedAnyOpaque(unwrapped.value) orelse return null;
                if (toa.subtype == null or toa.subtype != .node) return error.ObjectIdIsNotANode;
                return toa.ptr;
            }
        };

        pub const RemoteObject = v8.RemoteObject;

        pub const Exception = struct {
            inner: v8.Value,
            js_context: *const JsContext,

            const _EXCEPTION_ID_KLUDGE = true;

            // the caller needs to deinit the string returned
            pub fn exception(self: Exception, allocator: Allocator) ![]const u8 {
                const js_context = self.js_context;
                return try valueToString(allocator, self.inner, js_context.isolate, js_context.v8_context);
            }
        };

        pub const Value = struct {
            value: v8.Value,
            js_context: *const JsContext,

            // the caller needs to deinit the string returned
            pub fn toString(self: Value, allocator: Allocator) ![]const u8 {
                const js_context = self.js_context;
                return valueToString(allocator, self.value, js_context.isolate, js_context.v8_context);
            }
        };

        pub const ValueIterator = struct {
            count: u32,
            idx: u32 = 0,
            js_obj: v8.Object,
            js_context: *const JsContext,

            pub fn next(self: *ValueIterator) !?Value {
                const idx = self.idx;
                if (idx == self.count) {
                    return null;
                }
                self.idx += 1;

                const js_context = self.js_context;
                const js_val = try self.js_obj.getAtIndex(js_context.v8_context, idx);
                return js_context.createValue(js_val);
            }
        };

        pub fn UndefinedOr(comptime T: type) type {
            return union(enum) {
                undefined: void,
                value: T,
            };
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
        // FunctionTemplate of the isolate (in createJsContext)
        fn attachClass(comptime Struct: type, isolate: v8.Isolate, template: v8.FunctionTemplate) void {
            const template_proto = template.getPrototypeTemplate();
            inline for (@typeInfo(Struct).@"struct".decls) |declaration| {
                const name = declaration.name;
                if (comptime name[0] == '_') {
                    switch (@typeInfo(@TypeOf(@field(Struct, name)))) {
                        .@"fn" => generateMethod(Struct, name, isolate, template_proto),
                        else => |ti| if (!comptime isComplexAttributeType(ti)) {
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
                        const class_name = v8.String.initUtf8(info.getIsolate(), comptime classNameForStruct(Struct));
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
                    var caller = Caller(JsContext, State).init(info);
                    defer caller.deinit();
                    // See comment above. We generateConstructor on all types
                    // in order to create the FunctionTemplate, but there might
                    // not be an actual "constructor" function. So if someone
                    // does `new ClassName()` where ClassName doesn't have
                    // a constructor function, we'll return an error.
                    if (@hasDecl(Struct, "constructor") == false) {
                        const iso = caller.isolate;
                        log.warn(.js, "Illegal constructor call", .{ .name = @typeName(Struct) });
                        const js_exception = iso.throwException(createException(iso, "Illegal Constructor"));
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

            if (comptime isEmpty(Receiver(Struct)) == false) {
                // If the struct is empty, we won't store a Zig reference inside
                // the JS object, so we don't need to set the internal field count
                template.getInstanceTemplate().setInternalFieldCount(1);
            }

            const class_name = v8.String.initUtf8(isolate, comptime classNameForStruct(Struct));
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
                    var caller = Caller(JsContext, State).init(info);
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
                    var caller = Caller(JsContext, State).init(info);
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
            const js_value = simpleZigValueToJs(isolate, zig_value, true);

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
                    var caller = Caller(JsContext, State).init(info);
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

                    var caller = Caller(JsContext, State).init(info);
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
                        var caller = Caller(JsContext, State).init(info);
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
                        var caller = Caller(JsContext, State).init(info);
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
                        var caller = Caller(JsContext, State).init(info);
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
                        var caller = Caller(JsContext, State).init(info);
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
                        var caller = Caller(JsContext, State).init(info);
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

        // Turns a Zig value into a JS one.
        fn zigValueToJs(
            templates: []v8.FunctionTemplate,
            isolate: v8.Isolate,
            v8_context: v8.Context,
            value: anytype,
        ) anyerror!v8.Value {
            // Check if it's a "simple" type. This is extracted so that it can be
            // reused by other parts of the code. "simple" types only require an
            // isolate to create (specifically, they don't our templates array)
            if (simpleZigValueToJs(isolate, value, false)) |js_value| {
                return js_value;
            }

            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .void, .bool, .int, .comptime_int, .float, .comptime_float, .@"enum" => {
                    // Need to do this to keep the compiler happy
                    // simpleZigValueToJs handles all of these cases.
                    unreachable;
                },
                .array => {
                    var js_arr = v8.Array.init(isolate, value.len);
                    var js_obj = js_arr.castTo(v8.Object);
                    for (value, 0..) |v, i| {
                        const js_val = try zigValueToJs(templates, isolate, v8_context, v);
                        if (js_obj.setValueAtIndex(v8_context, @intCast(i), js_val) == false) {
                            return error.FailedToCreateArray;
                        }
                    }
                    return js_obj.toValue();
                },
                .pointer => |ptr| switch (ptr.size) {
                    .one => {
                        const type_name = @typeName(ptr.child);
                        if (@hasField(TypeLookup, type_name)) {
                            const template = templates[@field(TYPE_LOOKUP, type_name)];
                            const js_obj = try JsContext.mapZigInstanceToJs(v8_context, template, value);
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
                            const js_val = try zigValueToJs(templates, isolate, v8_context, v);
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
                    if (@hasField(TypeLookup, type_name)) {
                        const template = templates[@field(TYPE_LOOKUP, type_name)];
                        const js_obj = try JsContext.mapZigInstanceToJs(v8_context, template, value);
                        return js_obj.toValue();
                    }

                    if (T == Function) {
                        // we're returning a callback
                        return value.func.toValue();
                    }

                    if (T == JsObject) {
                        // we're returning a v8.Object
                        return value.js_obj.toValue();
                    }

                    if (T == Promise) {
                        // we're returning a v8.Promise
                        return value.promise.toObject().toValue();
                    }

                    if (@hasDecl(T, "_EXCEPTION_ID_KLUDGE")) {
                        return isolate.throwException(value.inner);
                    }

                    if (s.is_tuple) {
                        // return the tuple struct as an array
                        var js_arr = v8.Array.init(isolate, @intCast(s.fields.len));
                        var js_obj = js_arr.castTo(v8.Object);
                        inline for (s.fields, 0..) |f, i| {
                            const js_val = try zigValueToJs(templates, isolate, v8_context, @field(value, f.name));
                            if (js_obj.setValueAtIndex(v8_context, @intCast(i), js_val) == false) {
                                return error.FailedToCreateArray;
                            }
                        }
                        return js_obj.toValue();
                    }

                    // return the struct as a JS object
                    const js_obj = v8.Object.init(isolate);
                    inline for (s.fields) |f| {
                        const js_val = try zigValueToJs(templates, isolate, v8_context, @field(value, f.name));
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
                                return zigValueToJs(templates, isolate, v8_context, @field(value, field.name));
                            }
                        }
                        unreachable;
                    }
                    @compileError("Cannot use untagged union: " ++ @typeName(T));
                },
                .optional => {
                    if (value) |v| {
                        return zigValueToJs(templates, isolate, v8_context, v);
                    }
                    return v8.initNull(isolate).toValue();
                },
                .error_union => return zigValueToJs(templates, isolate, v8_context, value catch |err| return err),
                else => {},
            }

            @compileError("A function returns an unsupported type: " ++ @typeName(T));
        }

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

        // An interface for types that want to have their jsScopeEnd function be
        // called when the call context ends
        const CallScopeEndCallback = struct {
            ptr: *anyopaque,
            callScopeEndFn: *const fn (ptr: *anyopaque) void,

            fn init(ptr: anytype) CallScopeEndCallback {
                const T = @TypeOf(ptr);
                const ptr_info = @typeInfo(T);

                const gen = struct {
                    pub fn callScopeEnd(pointer: *anyopaque) void {
                        const self: T = @ptrCast(@alignCast(pointer));
                        return ptr_info.pointer.child.jsCallScopeEnd(self);
                    }
                };

                return .{
                    .ptr = ptr,
                    .callScopeEndFn = gen.callScopeEnd,
                };
            }

            pub fn callScopeEnd(self: CallScopeEndCallback) void {
                self.callScopeEndFn(self.ptr);
            }
        };

        // Callback called on global's property missing.
        // Return true to intercept the execution or false to let the call
        // continue the chain.
        pub const GlobalMissingCallback = struct {
            ptr: *anyopaque,
            missingFn: *const fn (ptr: *anyopaque, name: []const u8, ctx: *JsContext) bool,

            pub fn init(ptr: anytype) GlobalMissingCallback {
                const T = @TypeOf(ptr);
                const ptr_info = @typeInfo(T);

                const gen = struct {
                    pub fn missing(pointer: *anyopaque, name: []const u8, ctx: *JsContext) bool {
                        const self: T = @ptrCast(@alignCast(pointer));
                        return ptr_info.pointer.child.missing(self, name, ctx);
                    }
                };

                return .{
                    .ptr = ptr,
                    .missingFn = gen.missing,
                };
            }

            pub fn missing(self: GlobalMissingCallback, name: []const u8, ctx: *JsContext) bool {
                return self.missingFn(self.ptr, name, ctx);
            }
        };
    };
}

// This is essentially meta data for each type. Each is stored in env.meta_lookup
// The index for a type can be retrieved via:
//   const index = @field(TYPE_LOOKUP, @typeName(Receiver(Struct)));
//   const meta = env.meta_lookup[index];
const TypeMeta = struct {
    // Every type is given a unique index. That index is used to lookup various
    // things, i.e. the prototype chain.
    index: u16,

    // We store the type's subtype here, so that when we create an instance of
    // the type, and bind it to JavaScript, we can store the subtype along with
    // the created TaggedAnyOpaque.s
    subtype: ?SubType,

    // If this type has composition-based prototype, represents the byte-offset
    // from ptr where the `proto` field is located. A negative offsets is used
    // to indicate that the prototype field is behind a pointer.
    proto_offset: i32,
};

// When we map a Zig instance into a JsObject, we'll normally store the a
// TaggedAnyOpaque (TAO) inside of the JsObject's internal field. This requires
// ensuring that the instance template has an InternalFieldCount of 1. However,
// for empty objects, we don't need to store the TAO, because we can't just cast
// one empty object to another, so for those, as an optimization, we do not set
// the InternalFieldCount.
fn isEmpty(comptime T: type) bool {
    return @typeInfo(T) != .@"opaque" and @sizeOf(T) == 0 and @hasDecl(T, "js_legacy_factory") == false;
}

// Attributes that return a primitive type are setup directly on the
// FunctionTemplate when the Env is setup. More complex types need a v8.Context
// and cannot be set directly on the FunctionTemplate.
// We default to saying types are primitives because that's mostly what
// we have. If we add a new complex type that isn't explictly handled here,
// we'll get a compiler error in simpleZigValueToJs, and can then explicitly
// add the type here.
fn isComplexAttributeType(ti: std.builtin.Type) bool {
    return switch (ti) {
        .array => true,
        else => false,
    };
}

// Responsible for calling Zig functions from JS invocations. This could
// probably just contained in ExecutionWorld, but having this specific logic, which
// is somewhat repetitive between constructors, functions, getters, etc contained
// here does feel like it makes it cleaner.
fn Caller(comptime JsContext: type, comptime State: type) type {
    return struct {
        js_context: *JsContext,
        v8_context: v8.Context,
        isolate: v8.Isolate,
        call_arena: Allocator,

        const Self = @This();

        // info is a v8.PropertyCallbackInfo or a v8.FunctionCallback
        // All we really want from it is the isolate.
        // executor = Isolate -> getCurrentContext -> getEmbedderData()
        fn init(info: anytype) Self {
            const isolate = info.getIsolate();
            const v8_context = isolate.getCurrentContext();
            const js_context: *JsContext = @ptrFromInt(v8_context.getEmbedderData(1).castTo(v8.BigInt).getUint64());

            js_context.call_depth += 1;
            return .{
                .js_context = js_context,
                .isolate = isolate,
                .v8_context = v8_context,
                .call_arena = js_context.call_arena,
            };
        }

        fn deinit(self: *Self) void {
            const js_context = self.js_context;
            const call_depth = js_context.call_depth - 1;

            // Because of callbacks, calls can be nested. Because of this, we
            // can't clear the call_arena after _every_ call. Imagine we have
            //    arr.forEach((i) => { console.log(i); }
            //
            // First we call forEach. Inside of our forEach call,
            // we call console.log. If we reset the call_arena after this call,
            // it'll reset it for the `forEach` call after, which might still
            // need the data.
            //
            // Therefore, we keep a call_depth, and only reset the call_arena
            // when a top-level (call_depth == 0) function ends.
            if (call_depth == 0) {
                const arena: *ArenaAllocator = @ptrCast(@alignCast(js_context.call_arena.ptr));
                _ = arena.reset(.{ .retain_with_limit = CALL_ARENA_RETAIN });
            }

            // Set this _after_ we've executed the above code, so that if the
            // above code executes any callbacks, they aren't being executed
            // at scope 0, which would be wrong.
            js_context.call_depth = call_depth;
        }

        fn constructor(self: *Self, comptime Struct: type, comptime named_function: NamedFunction, info: v8.FunctionCallbackInfo) !void {
            const args = try self.getArgs(Struct, named_function, 0, info);
            const res = @call(.auto, Struct.constructor, args);

            const ReturnType = @typeInfo(@TypeOf(Struct.constructor)).@"fn".return_type orelse {
                @compileError(@typeName(Struct) ++ " has a constructor without a return type");
            };

            const this = info.getThis();
            if (@typeInfo(ReturnType) == .error_union) {
                const non_error_res = res catch |err| return err;
                _ = try JsContext.mapZigInstanceToJs(self.v8_context, this, non_error_res);
            } else {
                _ = try JsContext.mapZigInstanceToJs(self.v8_context, this, res);
            }
            info.getReturnValue().set(this);
        }

        fn method(self: *Self, comptime Struct: type, comptime named_function: NamedFunction, info: v8.FunctionCallbackInfo) !void {
            if (comptime isSelfReceiver(Struct, named_function) == false) {
                return self.function(Struct, named_function, info);
            }

            const js_context = self.js_context;
            const func = @field(Struct, named_function.name);
            var args = try self.getArgs(Struct, named_function, 1, info);
            const zig_instance = try js_context.typeTaggedAnyOpaque(named_function, *Receiver(Struct), info.getThis());

            // inject 'self' as the first parameter
            @field(args, "0") = zig_instance;

            const res = @call(.auto, func, args);
            info.getReturnValue().set(try js_context.zigValueToJs(res));
        }

        fn function(self: *Self, comptime Struct: type, comptime named_function: NamedFunction, info: v8.FunctionCallbackInfo) !void {
            const js_context = self.js_context;
            const func = @field(Struct, named_function.name);
            const args = try self.getArgs(Struct, named_function, 0, info);
            const res = @call(.auto, func, args);
            info.getReturnValue().set(try js_context.zigValueToJs(res));
        }

        fn getIndex(self: *Self, comptime Struct: type, comptime named_function: NamedFunction, idx: u32, info: v8.PropertyCallbackInfo) !u8 {
            const js_context = self.js_context;
            const func = @field(Struct, named_function.name);
            const IndexedGet = @TypeOf(func);
            if (@typeInfo(IndexedGet).@"fn".return_type == null) {
                @compileError(named_function.full_name ++ " must have a return type");
            }

            var has_value = true;

            var args: ParamterTypes(IndexedGet) = undefined;
            const arg_fields = @typeInfo(@TypeOf(args)).@"struct".fields;
            switch (arg_fields.len) {
                0, 1, 2 => @compileError(named_function.full_name ++ " must take at least a u32 and *bool parameter"),
                3, 4 => {
                    const zig_instance = try js_context.typeTaggedAnyOpaque(named_function, *Receiver(Struct), info.getThis());
                    comptime assertSelfReceiver(Struct, named_function);
                    @field(args, "0") = zig_instance;
                    @field(args, "1") = idx;
                    @field(args, "2") = &has_value;
                    if (comptime arg_fields.len == 4) {
                        comptime assertIsStateArg(Struct, named_function, 3);
                        @field(args, "3") = js_context.state;
                    }
                },
                else => @compileError(named_function.full_name ++ " has too many parmaters"),
            }

            const res = @call(.auto, func, args);
            if (has_value == false) {
                return v8.Intercepted.No;
            }
            info.getReturnValue().set(try js_context.zigValueToJs(res));
            return v8.Intercepted.Yes;
        }

        fn getNamedIndex(self: *Self, comptime Struct: type, comptime named_function: NamedFunction, name: v8.Name, info: v8.PropertyCallbackInfo) !u8 {
            const js_context = self.js_context;
            const func = @field(Struct, named_function.name);
            comptime assertSelfReceiver(Struct, named_function);

            var has_value = true;
            var args = try self.getArgs(Struct, named_function, 3, info);
            const zig_instance = try js_context.typeTaggedAnyOpaque(named_function, *Receiver(Struct), info.getThis());
            @field(args, "0") = zig_instance;
            @field(args, "1") = try self.nameToString(name);
            @field(args, "2") = &has_value;

            const res = @call(.auto, func, args);
            if (has_value == false) {
                return v8.Intercepted.No;
            }
            info.getReturnValue().set(try self.js_context.zigValueToJs(res));
            return v8.Intercepted.Yes;
        }

        fn setNamedIndex(self: *Self, comptime Struct: type, comptime named_function: NamedFunction, name: v8.Name, js_value: v8.Value, info: v8.PropertyCallbackInfo) !u8 {
            const js_context = self.js_context;
            const func = @field(Struct, named_function.name);
            comptime assertSelfReceiver(Struct, named_function);

            var has_value = true;
            var args = try self.getArgs(Struct, named_function, 4, info);
            const zig_instance = try js_context.typeTaggedAnyOpaque(named_function, *Receiver(Struct), info.getThis());
            @field(args, "0") = zig_instance;
            @field(args, "1") = try self.nameToString(name);
            @field(args, "2") = try js_context.jsValueToZig(named_function, @TypeOf(@field(args, "2")), js_value);
            @field(args, "3") = &has_value;

            const res = @call(.auto, func, args);
            return namedSetOrDeleteCall(res, has_value);
        }

        fn deleteNamedIndex(self: *Self, comptime Struct: type, comptime named_function: NamedFunction, name: v8.Name, info: v8.PropertyCallbackInfo) !u8 {
            const js_context = self.js_context;
            const func = @field(Struct, named_function.name);
            comptime assertSelfReceiver(Struct, named_function);

            var has_value = true;
            var args = try self.getArgs(Struct, named_function, 3, info);
            const zig_instance = try js_context.typeTaggedAnyOpaque(named_function, *Receiver(Struct), info.getThis());
            @field(args, "0") = zig_instance;
            @field(args, "1") = try self.nameToString(name);
            @field(args, "2") = &has_value;

            const res = @call(.auto, func, args);
            return namedSetOrDeleteCall(res, has_value);
        }

        fn namedSetOrDeleteCall(res: anytype, has_value: bool) !u8 {
            if (@typeInfo(@TypeOf(res)) == .error_union) {
                _ = try res;
            }
            if (has_value == false) {
                return v8.Intercepted.No;
            }
            return v8.Intercepted.Yes;
        }

        fn nameToString(self: *Self, name: v8.Name) ![]const u8 {
            return valueToString(self.call_arena, .{ .handle = name.handle }, self.isolate, self.v8_context);
        }

        fn isSelfReceiver(comptime Struct: type, comptime named_function: NamedFunction) bool {
            return checkSelfReceiver(Struct, named_function, false);
        }
        fn assertSelfReceiver(comptime Struct: type, comptime named_function: NamedFunction) void {
            _ = checkSelfReceiver(Struct, named_function, true);
        }
        fn checkSelfReceiver(comptime Struct: type, comptime named_function: NamedFunction, comptime fail: bool) bool {
            const func = @field(Struct, named_function.name);
            const params = @typeInfo(@TypeOf(func)).@"fn".params;
            if (params.len == 0) {
                if (fail) {
                    @compileError(named_function.full_name ++ " must have a self parameter");
                }
                return false;
            }

            const R = Receiver(Struct);
            const first_param = params[0].type.?;
            if (first_param != *R and first_param != *const R) {
                if (fail) {
                    @compileError(std.fmt.comptimePrint("The first parameter to {s} must be a *{s} or *const {s}. Got: {s}", .{
                        named_function.full_name,
                        @typeName(R),
                        @typeName(R),
                        @typeName(first_param),
                    }));
                }
                return false;
            }
            return true;
        }

        fn assertIsStateArg(comptime Struct: type, comptime named_function: NamedFunction, index: comptime_int) void {
            const func = @field(Struct, named_function.name);
            const F = @TypeOf(func);
            const params = @typeInfo(F).@"fn".params;

            const param = params[index].type.?;
            if (param == State) {
                return;
            }

            if (@typeInfo(State) == .pointer) {
                if (param == *const @typeInfo(State).pointer.child) {
                    return;
                }
            }
            @compileError(std.fmt.comptimePrint("The {d} parameter to {s} must be a {s}. Got: {s}", .{ index, named_function.full_name, @typeName(State), @typeName(param) }));
        }

        fn handleError(self: *Self, comptime Struct: type, comptime named_function: NamedFunction, err: anyerror, info: anytype) void {
            const isolate = self.isolate;

            if (comptime builtin.mode == .Debug and @hasDecl(@TypeOf(info), "length")) {
                if (log.enabled(.js, .warn)) {
                    logFunctionCallError(self.call_arena, self.isolate, self.v8_context, err, named_function.full_name, info);
                }
            }

            var js_err: ?v8.Value = switch (err) {
                error.InvalidArgument => createTypeException(isolate, "invalid argument"),
                error.OutOfMemory => createException(isolate, "out of memory"),
                error.IllegalConstructor => createException(isolate, "Illegal Contructor"),
                else => blk: {
                    const func = @field(Struct, named_function.name);
                    const return_type = @typeInfo(@TypeOf(func)).@"fn".return_type orelse {
                        // void return type;
                        break :blk null;
                    };

                    if (@typeInfo(return_type) != .error_union) {
                        // type defines a custom exception, but this function should
                        // not fail. We failed somewhere inside of js.zig and
                        // should return the error as-is, since it isn't related
                        // to our Struct
                        break :blk null;
                    }

                    const function_error_set = @typeInfo(return_type).error_union.error_set;

                    const Exception = comptime getCustomException(Struct) orelse break :blk null;
                    if (function_error_set == Exception or isErrorSetException(Exception, err)) {
                        const custom_exception = Exception.init(self.call_arena, err, named_function.js_name) catch |init_err| {
                            switch (init_err) {
                                // if a custom exceptions' init wants to return a
                                // different error, we need to think about how to
                                // handle that failure.
                                error.OutOfMemory => break :blk createException(isolate, "out of memory"),
                            }
                        };
                        // ughh..how to handle an error here?
                        break :blk self.js_context.zigValueToJs(custom_exception) catch createException(isolate, "internal error");
                    }
                    // this error isn't part of a custom exception
                    break :blk null;
                },
            };

            if (js_err == null) {
                js_err = createException(isolate, @errorName(err));
            }
            const js_exception = isolate.throwException(js_err.?);
            info.getReturnValue().setValueHandle(js_exception.handle);
        }

        // walk the prototype chain to see if a type declares a custom Exception
        fn getCustomException(comptime Struct: type) ?type {
            var S = Struct;
            while (true) {
                if (@hasDecl(S, "Exception")) {
                    return S.Exception;
                }
                if (@hasDecl(S, "prototype") == false) {
                    return null;
                }
                // long ago, we validated that every prototype declaration
                // is a pointer.
                S = @typeInfo(S.prototype).pointer.child;
            }
        }

        // Does the error we want to return belong to the custom exeception's ErrorSet
        fn isErrorSetException(comptime Exception: type, err: anytype) bool {
            const Entry = std.meta.Tuple(&.{ []const u8, void });

            const error_set = @typeInfo(Exception.ErrorSet).error_set.?;
            const entries = comptime blk: {
                var kv: [error_set.len]Entry = undefined;
                for (error_set, 0..) |e, i| {
                    kv[i] = .{ e.name, {} };
                }
                break :blk kv;
            };
            const lookup = std.StaticStringMap(void).initComptime(entries);
            return lookup.has(@errorName(err));
        }

        // If we call a method in javascript: cat.lives('nine');
        //
        // Then we'd expect a Zig function with 2 parameters: a self and the string.
        // In this case, offset == 1. Offset is always 1 for setters or methods.
        //
        // Offset is always 0 for constructors.
        //
        // For constructors, setters and methods, we can further increase offset + 1
        // if the first parameter is an instance of State.
        //
        // Finally, if the JS function is called with _more_ parameters and
        // the last parameter in Zig is an array, we'll try to slurp the additional
        // parameters into the array.
        fn getArgs(self: *const Self, comptime Struct: type, comptime named_function: NamedFunction, comptime offset: usize, info: anytype) !ParamterTypes(@TypeOf(@field(Struct, named_function.name))) {
            const js_context = self.js_context;
            const F = @TypeOf(@field(Struct, named_function.name));
            var args: ParamterTypes(F) = undefined;

            const params = @typeInfo(F).@"fn".params[offset..];
            // Except for the constructor, the first parameter is always `self`
            // This isn't something we'll bind from JS, so skip it.
            const params_to_map = blk: {
                if (params.len == 0) {
                    return args;
                }

                // If the last parameter is the State, set it, and exclude it
                // from our params slice, because we don't want to bind it to
                // a JS argument
                if (comptime isState(params[params.len - 1].type.?)) {
                    @field(args, tupleFieldName(params.len - 1 + offset)) = self.js_context.state;
                    break :blk params[0 .. params.len - 1];
                }

                // If the last parameter is a special JsThis, set it, and exclude it
                // from our params slice, because we don't want to bind it to
                // a JS argument
                if (comptime isJsThis(params[params.len - 1].type.?)) {
                    @field(args, tupleFieldName(params.len - 1 + offset)) = .{ .obj = .{
                        .js_context = js_context,
                        .js_obj = info.getThis(),
                    } };

                    // AND the 2nd last parameter is state
                    if (params.len > 1 and comptime isState(params[params.len - 2].type.?)) {
                        @field(args, tupleFieldName(params.len - 2 + offset)) = self.js_context.state;
                        break :blk params[0 .. params.len - 2];
                    }

                    break :blk params[0 .. params.len - 1];
                }

                // we have neither a State nor a JsObject. All params must be
                // bound to a JavaScript value.
                break :blk params;
            };

            if (params_to_map.len == 0) {
                return args;
            }

            const js_parameter_count = info.length();
            const last_js_parameter = params_to_map.len - 1;
            var is_variadic = false;

            {
                // This is going to get complicated. If the last Zig parameter
                // is a slice AND the corresponding javascript parameter is
                // NOT an an array, then we'll treat it as a variadic.

                const last_parameter_type = params_to_map[params_to_map.len - 1].type.?;
                const last_parameter_type_info = @typeInfo(last_parameter_type);
                if (last_parameter_type_info == .pointer and last_parameter_type_info.pointer.size == .slice) {
                    const slice_type = last_parameter_type_info.pointer.child;
                    const corresponding_js_value = info.getArg(@as(u32, @intCast(last_js_parameter)));
                    if (corresponding_js_value.isArray() == false and corresponding_js_value.isTypedArray() == false and slice_type != u8) {
                        is_variadic = true;
                        if (js_parameter_count == 0) {
                            @field(args, tupleFieldName(params_to_map.len + offset - 1)) = &.{};
                        } else if (js_parameter_count >= params_to_map.len) {
                            const arr = try self.call_arena.alloc(last_parameter_type_info.pointer.child, js_parameter_count - params_to_map.len + 1);
                            for (arr, last_js_parameter..) |*a, i| {
                                const js_value = info.getArg(@as(u32, @intCast(i)));
                                a.* = try js_context.jsValueToZig(named_function, slice_type, js_value);
                            }
                            @field(args, tupleFieldName(params_to_map.len + offset - 1)) = arr;
                        } else {
                            @field(args, tupleFieldName(params_to_map.len + offset - 1)) = &.{};
                        }
                    }
                }
            }

            inline for (params_to_map, 0..) |param, i| {
                const field_index = comptime i + offset;
                if (comptime i == params_to_map.len - 1) {
                    if (is_variadic) {
                        break;
                    }
                }

                if (comptime isState(param.type.?)) {
                    @compileError("State must be the last parameter (or 2nd last if there's a JsThis): " ++ named_function.full_name);
                } else if (comptime isJsThis(param.type.?)) {
                    @compileError("JsThis must be the last parameter: " ++ named_function.full_name);
                } else if (i >= js_parameter_count) {
                    if (@typeInfo(param.type.?) != .optional) {
                        return error.InvalidArgument;
                    }
                    @field(args, tupleFieldName(field_index)) = null;
                } else {
                    const js_value = info.getArg(@as(u32, @intCast(i)));
                    @field(args, tupleFieldName(field_index)) = js_context.jsValueToZig(named_function, param.type.?, js_value) catch {
                        return error.InvalidArgument;
                    };
                }
            }

            return args;
        }

        fn isState(comptime T: type) bool {
            const ti = @typeInfo(State);
            const Const_State = if (ti == .pointer) *const ti.pointer.child else State;
            return T == State or T == Const_State;
        }
    };
}

fn isJsObject(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "_JSOBJECT_ID_KLUDGE");
}

fn isJsThis(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "_JSTHIS_ID_KLUDGE");
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

// These are simple types that we can convert to JS with only an isolate. This
// is separated from the Caller's zigValueToJs to make it available when we
// don't have a caller (i.e., when setting static attributes on types)
fn simpleZigValueToJs(isolate: v8.Isolate, value: anytype, comptime fail: bool) if (fail) v8.Value else ?v8.Value {
    switch (@typeInfo(@TypeOf(value))) {
        .void => return v8.initUndefined(isolate).toValue(),
        .bool => return v8.getValue(if (value) v8.initTrue(isolate) else v8.initFalse(isolate)),
        .int => |n| switch (n.signedness) {
            .signed => {
                if (value >= -2_147_483_648 and value <= 2_147_483_647) {
                    return v8.Integer.initI32(isolate, @intCast(value)).toValue();
                }
                if (comptime n.bits <= 64) {
                    return v8.getValue(v8.BigInt.initI64(isolate, @intCast(value)));
                }
                @compileError(@typeName(value) ++ " is not supported");
            },
            .unsigned => {
                if (value <= 4_294_967_295) {
                    return v8.Integer.initU32(isolate, @intCast(value)).toValue();
                }
                if (comptime n.bits <= 64) {
                    return v8.getValue(v8.BigInt.initU64(isolate, @intCast(value)));
                }
                @compileError(@typeName(value) ++ " is not supported");
            },
        },
        .comptime_int => {
            if (value >= 0) {
                if (value <= 4_294_967_295) {
                    return v8.Integer.initU32(isolate, @intCast(value)).toValue();
                }
                return v8.BigInt.initU64(isolate, @intCast(value)).toValue();
            }
            if (value >= -2_147_483_648) {
                return v8.Integer.initI32(isolate, @intCast(value)).toValue();
            }
            return v8.BigInt.initI64(isolate, @intCast(value)).toValue();
        },
        .comptime_float => return v8.Number.init(isolate, value).toValue(),
        .float => |f| switch (f.bits) {
            64 => return v8.Number.init(isolate, value).toValue(),
            32 => return v8.Number.init(isolate, @floatCast(value)).toValue(),
            else => @compileError(@typeName(value) ++ " is not supported"),
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return v8.String.initUtf8(isolate, value).toValue();
            }
            if (ptr.size == .one) {
                const one_info = @typeInfo(ptr.child);
                if (one_info == .array and one_info.array.child == u8) {
                    return v8.String.initUtf8(isolate, value).toValue();
                }
            }
        },
        .array => return simpleZigValueToJs(isolate, &value, fail),
        .optional => {
            if (value) |v| {
                return simpleZigValueToJs(isolate, v, fail);
            }
            return v8.initNull(isolate).toValue();
        },
        .@"struct" => {
            const T = @TypeOf(value);
            if (@hasDecl(T, "_TYPED_ARRAY_ID_KLUDGE")) {
                const values = value.values;
                const value_type = @typeInfo(@TypeOf(values)).pointer.child;
                const len = values.len;
                const bits = switch (@typeInfo(value_type)) {
                    .int => |n| n.bits,
                    .float => |f| f.bits,
                    else => @compileError("Invalid TypeArray type: " ++ @typeName(value_type)),
                };

                var array_buffer: v8.ArrayBuffer = undefined;
                if (len == 0) {
                    array_buffer = v8.ArrayBuffer.init(isolate, 0);
                } else {
                    const buffer_len = len * bits / 8;
                    const backing_store = v8.BackingStore.init(isolate, buffer_len);
                    const data: [*]u8 = @ptrCast(@alignCast(backing_store.getData()));
                    @memcpy(data[0..buffer_len], @as([]const u8, @ptrCast(values))[0..buffer_len]);
                    array_buffer = v8.ArrayBuffer.initWithBackingStore(isolate, &backing_store.toSharedPtr());
                }

                switch (@typeInfo(value_type)) {
                    .int => |n| switch (n.signedness) {
                        .unsigned => switch (n.bits) {
                            8 => return v8.Uint8Array.init(array_buffer, 0, len).toValue(),
                            16 => return v8.Uint16Array.init(array_buffer, 0, len).toValue(),
                            32 => return v8.Uint32Array.init(array_buffer, 0, len).toValue(),
                            64 => return v8.BigUint64Array.init(array_buffer, 0, len).toValue(),
                            else => {},
                        },
                        .signed => switch (n.bits) {
                            8 => return v8.Int8Array.init(array_buffer, 0, len).toValue(),
                            16 => return v8.Int16Array.init(array_buffer, 0, len).toValue(),
                            32 => return v8.Int32Array.init(array_buffer, 0, len).toValue(),
                            64 => return v8.BigInt64Array.init(array_buffer, 0, len).toValue(),
                            else => {},
                        },
                    },
                    .float => |f| switch (f.bits) {
                        32 => return v8.Float32Array.init(array_buffer, 0, len).toValue(),
                        64 => return v8.Float64Array.init(array_buffer, 0, len).toValue(),
                        else => {},
                    },
                    else => {},
                }
                // We normally don't fail in this function unless fail == true
                // but this can never be valid.
                @compileError("Invalid TypeArray type: " ++ @typeName(value_type));
            }
        },
        .@"union" => return simpleZigValueToJs(isolate, std.meta.activeTag(value), fail),
        .@"enum" => {
            const T = @TypeOf(value);
            if (@hasDecl(T, "toString")) {
                return simpleZigValueToJs(isolate, value.toString(), fail);
            }
        },
        else => {},
    }
    if (fail) {
        @compileError("Unsupported Zig type " ++ @typeName(@TypeOf(value)));
    }
    return null;
}

pub fn zigJsonToJs(isolate: v8.Isolate, v8_context: v8.Context, value: std.json.Value) !v8.Value {
    switch (value) {
        .bool => |v| return simpleZigValueToJs(isolate, v, true),
        .float => |v| return simpleZigValueToJs(isolate, v, true),
        .integer => |v| return simpleZigValueToJs(isolate, v, true),
        .string => |v| return simpleZigValueToJs(isolate, v, true),
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

// Takes a function, and returns a tuple for its argument. Used when we
// @call a function
fn ParamterTypes(comptime F: type) type {
    const params = @typeInfo(F).@"fn".params;
    var fields: [params.len]std.builtin.Type.StructField = undefined;

    inline for (params, 0..) |param, i| {
        fields[i] = .{
            .name = tupleFieldName(i),
            .type = param.type.?,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(param.type.?),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .decls = &.{},
        .fields = &fields,
        .is_tuple = true,
    } });
}

fn tupleFieldName(comptime i: usize) [:0]const u8 {
    return switch (i) {
        0 => "0",
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        6 => "6",
        7 => "7",
        8 => "8",
        9 => "9",
        else => std.fmt.comptimePrint("{d}", .{i}),
    };
}

fn createException(isolate: v8.Isolate, msg: []const u8) v8.Value {
    return v8.Exception.initError(v8.String.initUtf8(isolate, msg));
}

fn createTypeException(isolate: v8.Isolate, msg: []const u8) v8.Value {
    return v8.Exception.initTypeError(v8.String.initUtf8(isolate, msg));
}

fn classNameForStruct(comptime Struct: type) []const u8 {
    if (@hasDecl(Struct, "js_name")) {
        return Struct.js_name;
    }
    @setEvalBranchQuota(10_000);
    const full_name = @typeName(Struct);
    const last = std.mem.lastIndexOfScalar(u8, full_name, '.') orelse return full_name;
    return full_name[last + 1 ..];
}

// When we return a Zig object to V8, we put it on the heap and pass it into
// v8 as an *anyopaque (i.e. void *). When V8 gives us back the value, say, as a
// function parameter, we know what type it _should_ be. Above, in Caller.method
// (for example), we know all the parameter types. So if a Zig function takes
// a single parameter (its receiver), we know what that type is.
//
// In a simple/perfect world, we could use this knowledge to cast the *anyopaque
// to the parameter type:
//   const arg: @typeInfo(@TypeOf(function)).@"fn".params[0] = @ptrCast(v8_data);
//
// But there are 2 reasons we can't do that.
//
// == Reason 1 ==
// The JS code might pass the wrong type:
//
//   var cat = new Cat();
//   cat.setOwner(new Cat());
//
// The zig _setOwner method expects the 2nd parameter to be an *Owner, but
// the JS code passed a *Cat.
//
// To solve this issue, we tag every returned value so that we can check what
// type it is. In the above case, we'd expect an *Owner, but the tag would tell
// us that we got a *Cat. We use the type index in our Types lookup as the tag.
//
// == Reason 2 ==
// Because of prototype inheritance, even "correct" code can be a challenge. For
// example, say the above JavaScript is fixed:
//
//   var cat = new Cat();
//   cat.setOwner(new Owner("Leto"));
//
// The issue is that setOwner might not expect an *Owner, but rather a
// *Person, which is the prototype for Owner. Now our Zig code is expecting
// a *Person, but it was (correctly) given an *Owner.
// For this reason, we also store the prototype's type index.
//
// One of the prototype mechanisms that we support is via composition. Owner
// can have a "proto: *Person" field. For this reason, we also store the offset
// of the proto field, so that, given an intFromPtr(*Owner) we can access its
// proto field.
//
// The other prototype mechanism that we support is for netsurf, where we just
// cast one type to another. In this case, we'll store an offset of -1 (as a
// sentinel to indicate that we should just cast directly).
const TaggedAnyOpaque = struct {
    // The type of object this is. The type is captured as an index, which
    // corresponds to both a field in TYPE_LOOKUP and the index of
    // PROTOTYPE_TABLE
    index: u16,

    // Ptr to the Zig instance. Between the context where it's called (i.e.
    // we have the comptime parameter info for all functions), and the index field
    // we can figure out what type this is.
    ptr: *anyopaque,

    // When we're asked to describe an object via the Inspector, we _must_ include
    // the proper subtype (and description) fields in the returned JSON.
    // V8 will give us a Value and ask us for the subtype. From the v8.Value we
    // can get a v8.Object, and from the v8.Object, we can get out TaggedAnyOpaque
    // which is where we store the subtype.
    subtype: ?SubType,
};

fn valueToDetailString(arena: Allocator, value: v8.Value, isolate: v8.Isolate, v8_context: v8.Context) ![]u8 {
    var str: ?v8.String = null;
    if (value.isObject() and !value.isFunction()) blk: {
        str = v8.Json.stringify(v8_context, value, null) catch break :blk;

        if (str.?.lenUtf8(isolate) == 2) {
            // {} isn't useful, null this so that we can get the toDetailString
            // (which might also be useless, but maybe not)
            str = null;
        }
    }

    if (str == null) {
        str = try value.toDetailString(v8_context);
    }

    const s = try jsStringToZig(arena, str.?, isolate);
    if (comptime builtin.mode == .Debug) {
        if (std.mem.eql(u8, s, "[object Object]")) {
            if (debugValueToString(arena, value.castTo(v8.Object), isolate, v8_context)) |ds| {
                return ds;
            } else |err| {
                log.err(.js, "debug serialize value", .{ .err = err });
            }
        }
    }
    return s;
}

fn valueToString(allocator: Allocator, value: v8.Value, isolate: v8.Isolate, v8_context: v8.Context) ![]u8 {
    if (value.isSymbol()) {
        // symbol's can't be converted to a string
        return allocator.dupe(u8, "$Symbol");
    }
    const str = try value.toString(v8_context);
    return jsStringToZig(allocator, str, isolate);
}

fn valueToStringZ(allocator: Allocator, value: v8.Value, isolate: v8.Isolate, v8_context: v8.Context) ![:0]u8 {
    const str = try value.toString(v8_context);
    const len = str.lenUtf8(isolate);
    const buf = try allocator.allocSentinel(u8, len, 0);
    const n = str.writeUtf8(isolate, buf);
    std.debug.assert(n == len);
    return buf;
}

fn jsStringToZig(allocator: Allocator, str: v8.String, isolate: v8.Isolate) ![]u8 {
    const len = str.lenUtf8(isolate);
    const buf = try allocator.alloc(u8, len);
    const n = str.writeUtf8(isolate, buf);
    std.debug.assert(n == len);
    return buf;
}

fn debugValueToString(arena: Allocator, js_obj: v8.Object, isolate: v8.Isolate, v8_context: v8.Context) ![]u8 {
    if (comptime builtin.mode != .Debug) {
        @compileError("debugValue can only be called in debug mode");
    }

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    var writer = arr.writer(arena);

    const names_arr = js_obj.getOwnPropertyNames(v8_context);
    const names_obj = names_arr.castTo(v8.Object);
    const len = names_arr.length();

    try writer.writeAll("(JSON.stringify failed, dumping top-level fields)\n");
    for (0..len) |i| {
        const field_name = try names_obj.getAtIndex(v8_context, @intCast(i));
        const field_value = try js_obj.getValue(v8_context, field_name);
        const name = try valueToString(arena, field_name, isolate, v8_context);
        const value = try valueToString(arena, field_value, isolate, v8_context);
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

fn stackForLogs(arena: Allocator, isolate: v8.Isolate) !?[]const u8 {
    std.debug.assert(builtin.mode == .Debug);

    const separator = log.separator();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var writer = buf.writer(arena);

    const stack_trace = v8.StackTrace.getCurrentStackTrace(isolate, 30);
    const frame_count = stack_trace.getFrameCount();

    for (0..frame_count) |i| {
        const frame = stack_trace.getFrame(isolate, @intCast(i));
        if (frame.getScriptName()) |name| {
            const script = try jsStringToZig(arena, name, isolate);
            try writer.print("{s}{s}:{d}", .{ separator, script, frame.getLineNumber() });
        } else {
            try writer.print("{s}<anonymous>:{d}", .{ separator, frame.getLineNumber() });
        }
    }
    return buf.items;
}

const NoopInspector = struct {
    pub fn onInspectorResponse(_: *anyopaque, _: u32, _: []const u8) void {}
    pub fn onInspectorEvent(_: *anyopaque, _: []const u8) void {}
};

const ErrorModuleLoader = struct {
    // Don't like having to reach into ../browser/ here. But can't think
    // of a good way to fix this.
    const BlockingResult = @import("../browser/ScriptManager.zig").BlockingResult;

    pub fn fetchModuleSource(_: *anyopaque, _: [:0]const u8) !BlockingResult {
        return error.NoModuleLoadConfigured;
    }
};

// If we have a struct:
// const Cat = struct {
//    pub fn meow(self: *Cat) void { ... }
// }
// Then obviously, the receiver of its methods are going to be a *Cat (or *const Cat)
//
// However, we can also do:
// const Cat = struct {
//    pub const Self = OtherImpl;
//    pub fn meow(self: *OtherImpl) void { ... }
// }
// In which case, as we see above, the receiver is derived from the Self declaration
fn Receiver(comptime Struct: type) type {
    return if (@hasDecl(Struct, "Self")) Struct.Self else Struct;
}

// We want the function name, or more precisely, the "Struct.function" for
// displaying helpful @compileError.
// However, there's no way to get the name from a std.Builtin.Fn, so we create
// a NamedFunction as part of our binding, and pass it around incase we need
// to display an error
const NamedFunction = struct {
    name: []const u8,
    js_name: []const u8,
    full_name: []const u8,

    fn init(comptime Struct: type, comptime name: []const u8) NamedFunction {
        return .{
            .name = name,
            .js_name = if (name[0] == '_') name[1..] else name,
            .full_name = @typeName(Struct) ++ "." ++ name,
        };
    }
};

// This is extracted to speed up compilation. When left inlined in handleError,
// this can add as much as 10 seconds of compilation time.
fn logFunctionCallError(arena: Allocator, isolate: v8.Isolate, context: v8.Context, err: anyerror, function_name: []const u8, info: v8.FunctionCallbackInfo) void {
    const args_dump = serializeFunctionArgs(arena, isolate, context, info) catch "failed to serialize args";
    log.info(.js, "function call error", .{
        .name = function_name,
        .err = err,
        .args = args_dump,
        .stack = stackForLogs(arena, isolate) catch |err1| @errorName(err1),
    });
}

fn serializeFunctionArgs(arena: Allocator, isolate: v8.Isolate, context: v8.Context, info: v8.FunctionCallbackInfo) ![]const u8 {
    const separator = log.separator();
    const js_parameter_count = info.length();

    var arr: std.ArrayListUnmanaged(u8) = .{};
    for (0..js_parameter_count) |i| {
        const js_value = info.getArg(@intCast(i));
        const value_string = try valueToDetailString(arena, js_value, isolate, context);
        const value_type = try jsStringToZig(arena, try js_value.typeOf(isolate), isolate);
        try std.fmt.format(arr.writer(arena), "{s}{d}: {s} ({s})", .{
            separator,
            i + 1,
            value_string,
            value_type,
        });
    }
    return arr.items;
}

// This is called from V8. Whenever the v8 inspector has to describe a value
// it'll call this function to gets its [optional] subtype - which, from V8's
// point of view, is an arbitrary string.
pub export fn v8_inspector__Client__IMPL__valueSubtype(
    _: *v8.c.InspectorClientImpl,
    c_value: *const v8.C_Value,
) callconv(.c) [*c]const u8 {
    const external_entry = getTaggedAnyOpaque(.{ .handle = c_value }) orelse return null;
    return if (external_entry.subtype) |st| @tagName(st) else null;
}

// Same as valueSubType above, but for the optional description field.
// From what I can tell, some drivers _need_ the description field to be
// present, even if it's empty. So if we have a subType for the value, we'll
// put an empty description.
pub export fn v8_inspector__Client__IMPL__descriptionForValueSubtype(
    _: *v8.c.InspectorClientImpl,
    v8_context: *const v8.C_Context,
    c_value: *const v8.C_Value,
) callconv(.c) [*c]const u8 {
    _ = v8_context;

    // We _must_ include a non-null description in order for the subtype value
    // to be included. Besides that, I don't know if the value has any meaning
    const external_entry = getTaggedAnyOpaque(.{ .handle = c_value }) orelse return null;
    return if (external_entry.subtype == null) null else "";
}

fn getTaggedAnyOpaque(value: v8.Value) ?*TaggedAnyOpaque {
    if (value.isObject() == false) {
        return null;
    }
    const obj = value.castTo(v8.Object);
    if (obj.internalFieldCount() == 0) {
        return null;
    }

    const external_data = obj.getInternalField(0).castTo(v8.External).get().?;
    return @ptrCast(@alignCast(external_data));
}

test {
    std.testing.refAllDecls(@import("test_primitive_types.zig"));
    std.testing.refAllDecls(@import("test_complex_types.zig"));
    std.testing.refAllDecls(@import("test_object_types.zig"));
}
