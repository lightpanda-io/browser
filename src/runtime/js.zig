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

const SubType = @import("subtype.zig").SubType;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const log = std.log.scoped(.js);

const CALL_ARENA_RETAIN = 1024 * 16;
const SCOPE_ARENA_RETAIN = 1024 * 64;

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
// and it's where we'll start Executors, which actually execute JavaScript.
// The `S` parameter is arbitrary state. When we start an Executor, an instance
// of S must be given. This instance is available to any Zig binding.
// The `types` parameter is a tuple of Zig structures we want to bind to V8.
pub fn Env(comptime S: type, comptime types: anytype) type {
    const Types = @typeInfo(@TypeOf(types)).@"struct".fields;

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
    //     comptime cat: usize = TypeMeta{.index = 0, ...},
    //     comptime owner: usize = TypeMeta{.index = 1, ...},
    //     ...
    // }
    //
    // So to get the template index of `owner`, we can do:
    //
    //  const index_id = @field(type_lookup, @typeName(@TypeOf(res)).index;
    //
    const TypeLookup = comptime blk: {
        var fields: [Types.len]std.builtin.Type.StructField = undefined;
        for (Types, 0..) |s, i| {

            // This prototype type check has nothing to do with building our
            // TypeLookup. But we put it here, early, so that the rest of the
            // code doesn't have to worry about checking if Struct.prototype is
            // a pointer.
            const Struct = @field(types, s.name);
            if (@hasDecl(Struct, "prototype") and @typeInfo(Struct.prototype) != .pointer) {
                @compileError(std.fmt.comptimePrint("Prototype '{s}' for type '{s} must be a pointer", .{ @typeName(Struct.prototype), @typeName(Struct) }));
            }

            const subtype: ?SubType = if (@hasDecl(Struct, "subtype")) Struct.subtype else null;

            const R = Receiver(@field(types, s.name));
            fields[i] = .{
                .name = @typeName(R),
                .type = TypeMeta,
                .is_comptime = true,
                .alignment = @alignOf(usize),
                .default_value_ptr = &TypeMeta{ .index = i, .subtype = subtype },
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
            const Struct = @field(types, s.name);
            if (@hasDecl(Struct, "prototype")) {
                const TI = @typeInfo(Struct.prototype);
                const proto_name = @typeName(Receiver(TI.pointer.child));
                prototype_index = @field(TYPE_LOOKUP, proto_name).index;
            }
            table[i] = prototype_index;
        }
        break :blk table;
    };

    return struct {
        allocator: Allocator,

        // the global isolate
        isolate: v8.Isolate,

        // just kept around because we need to free it on deinit
        isolate_params: *v8.CreateParams,

        // Given a type, we can lookup its index in TYPE_LOOKUP and then have
        // access to its TunctionTemplate (the thing we need to create an instance
        // of it)
        // I.e.:
        // const index = @field(TYPE_LOOKUP, @typeName(type_name)).index
        // const template = templates[index];
        templates: [Types.len]v8.FunctionTemplate,

        // Given a type index (retrieved via the TYPE_LOOKUP), we can retrieve
        // the index of its prototype. Types without a prototype have their own
        // index.
        prototype_lookup: [Types.len]u16,

        // Send a lowMemoryNotification whenever we stop an executor
        gc_hints: bool,

        const Self = @This();

        const State = S;
        const TYPE_LOOKUP = TypeLookup{};

        const Opts = struct {
            gc_hints: bool = false,
        };

        pub fn init(allocator: Allocator, opts: Opts) !*Self {
            // var params = v8.initCreateParams();
            var params = try allocator.create(v8.CreateParams);
            errdefer allocator.destroy(params);

            v8.c.v8__Isolate__CreateParams__CONSTRUCT(params);

            params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
            errdefer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);

            var isolate = v8.Isolate.init(params);
            errdefer isolate.deinit();

            isolate.enter();
            errdefer isolate.exit();

            var temp_scope: v8.HandleScope = undefined;
            v8.HandleScope.init(&temp_scope, isolate);
            defer temp_scope.deinit();

            const env = try allocator.create(Self);
            errdefer allocator.destroy(env);

            env.* = .{
                .isolate = isolate,
                .templates = undefined,
                .allocator = allocator,
                .isolate_params = params,
                .gc_hints = opts.gc_hints,
                .prototype_lookup = undefined,
            };

            // Populate our templates lookup. generateClass creates the
            // v8.FunctionTemplate, which we store in our env.templates.
            // The ordering doesn't matter. What matters is that, given a type
            // we can get its index via: @field(TYPE_LOOKUP, type_name).index
            const templates = &env.templates;
            inline for (Types, 0..) |s, i| {
                @setEvalBranchQuota(10_000);
                templates[i] = v8.Persistent(v8.FunctionTemplate).init(isolate, generateClass(@field(types, s.name), isolate)).castToFunctionTemplate();
            }

            // Above, we've created all our our FunctionTemplates. Now that we
            // have them all, we can hook up the prototypes.
            inline for (Types, 0..) |s, i| {
                const Struct = @field(types, s.name);
                if (@hasDecl(Struct, "prototype")) {
                    const TI = @typeInfo(Struct.prototype);
                    const proto_name = @typeName(Receiver(TI.pointer.child));
                    if (@hasField(TypeLookup, proto_name) == false) {
                        @compileError(std.fmt.comptimePrint("Prototype '{s}' for '{s}' is undefined", .{ proto_name, @typeName(Struct) }));
                    }
                    // Hey, look! This is our first real usage of the TYPE_LOOKUP.
                    // Just like we said above, given a type, we can get its
                    // template index.

                    const proto_index = @field(TYPE_LOOKUP, proto_name).index;
                    templates[i].inherit(templates[proto_index]);
                }
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

        pub fn newExecutor(self: *Self) !Executor {
            return .{
                .env = self,
                .scope = null,
                .call_arena = ArenaAllocator.init(self.allocator),
                .scope_arena = ArenaAllocator.init(self.allocator),
            };
        }

        pub const Executor = struct {
            env: *Self,

            // Arena whose lifetime is for a single getter/setter/function/etc.
            // Largely used to get strings out of V8, like a stack trace from
            // a TryCatch. The allocator will be owned by the Scope, but the
            // arena itself is owned by the Executor so that we can re-use it
            // from scope to scope.
            call_arena: ArenaAllocator,

            // Arena whose lifetime is for a single page load, aka a Scope. Where
            // the call_arena lives for a single function call, the scope_arena
            // lives for the lifetime of the entire page. The allocator will be
            // owned by the Scope, but the arena itself is owned by the Executor
            // so that we can re-use it from scope to scope.
            scope_arena: ArenaAllocator,

            // A Scope maps to a Browser's Page. Here though, it's only a
            // mechanism to organization page-specific memory. The Executor
            // does all the work, but having all page-specific data structures
            // grouped together helps keep things clean.
            scope: ?Scope = null,

            // no init, must be initialized via env.newExecutor()

            pub fn deinit(self: *Executor) void {
                if (self.scope) |scope| {
                    const isolate = scope.isolate;
                    self.endScope();

                    // V8 doesn't immediately free memory associated with
                    // a Context, it's managed by the garbage collector. So, when the
                    // `gc_hints` option is enabled, we'll use the `lowMemoryNotification`
                    // call on the isolate to encourage v8 to free any contexts which
                    // have been freed.
                    if (self.env.gc_hints) {
                        var handle_scope: v8.HandleScope = undefined;
                        v8.HandleScope.init(&handle_scope, isolate);
                        defer handle_scope.deinit();

                        self.env.isolate.lowMemoryNotification();
                    }
                }
                self.call_arena.deinit();
                self.scope_arena.deinit();
            }

            // Our scope maps to a "browser.Page".
            // A v8.HandleScope is like an arena. Once created, any "Local" that
            // v8 creates will be released (or at least, releasable by the v8 GC)
            // when the handle_scope is freed.
            // We also maintain our own "scope_arena" which allows us to have
            // all page related memory easily managed.
            pub fn startScope(self: *Executor, global: anytype, state: State, module_loader: anytype, enter: bool) !*Scope {
                std.debug.assert(self.scope == null);

                const ModuleLoader = switch (@typeInfo(@TypeOf(module_loader))) {
                    .@"struct" => @TypeOf(module_loader),
                    .pointer => |ptr| ptr.child,
                    .void => ErrorModuleLoader,
                    else => @compileError("invalid module_loader"),
                };

                // If necessary, turn a void context into something we can safely ptrCast
                const safe_module_loader: *anyopaque = if (ModuleLoader == ErrorModuleLoader) @constCast(@ptrCast(&{})) else module_loader;

                const env = self.env;
                const isolate = env.isolate;
                const Global = @TypeOf(global.*);

                var context: v8.Context = blk: {
                    var handle_scope: v8.HandleScope = undefined;
                    v8.HandleScope.init(&handle_scope, isolate);
                    defer handle_scope.deinit();

                    const js_global = v8.FunctionTemplate.initDefault(isolate);
                    attachClass(Global, isolate, js_global);

                    const global_template = js_global.getInstanceTemplate();
                    global_template.setInternalFieldCount(1);

                    // All the FunctionTemplates that we created and setup in Env.init
                    // are now going to get associated with our global instance.
                    const templates = &self.env.templates;
                    inline for (Types, 0..) |s, i| {
                        const Struct = @field(types, s.name);
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
                        const proto_index = @field(TYPE_LOOKUP, proto_name).index;
                        js_global.inherit(templates[proto_index]);
                    }

                    const context_local = v8.Context.init(isolate, global_template, null);
                    const context = v8.Persistent(v8.Context).init(isolate, context_local).castToContext();
                    context.enter();
                    errdefer if (enter) context.exit();
                    defer if (!enter) context.exit();

                    // This shouldn't be necessary, but it is:
                    // https://groups.google.com/g/v8-users/c/qAQQBmbi--8
                    // TODO: see if newer V8 engines have a way around this.
                    inline for (Types, 0..) |s, i| {
                        const Struct = @field(types, s.name);

                        if (@hasDecl(Struct, "prototype")) {
                            const proto_type = Receiver(@typeInfo(Struct.prototype).pointer.child);
                            const proto_name = @typeName(proto_type);
                            if (@hasField(TypeLookup, proto_name) == false) {
                                @compileError("Type '" ++ @typeName(Struct) ++ "' defines an unknown prototype: " ++ proto_name);
                            }

                            const proto_index = @field(TYPE_LOOKUP, proto_name).index;
                            const proto_obj = templates[proto_index].getFunction(context).toObject();

                            const self_obj = templates[i].getFunction(context).toObject();
                            _ = self_obj.setPrototype(context, proto_obj);
                        }
                    }
                    break :blk context;
                };

                // For a Page we only create one HandleScope, it is stored in the main World (enter==true). A page can have multple contexts, 1 for each World.
                // The main Context/Scope that enters and holds the HandleScope should therefore always be created first. Following other worlds for this page
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
                    const js_obj = context.getGlobal();
                    const console_key = v8.String.initUtf8(isolate, "console");
                    if (js_obj.deleteValue(context, console_key) == false) {
                        return error.ConsoleDeleteError;
                    }
                }

                self.scope = Scope{
                    .state = state,
                    .isolate = isolate,
                    .context = context,
                    .templates = &env.templates,
                    .handle_scope = handle_scope,
                    .call_arena = self.call_arena.allocator(),
                    .scope_arena = self.scope_arena.allocator(),
                    .module_loader = .{
                        .ptr = safe_module_loader,
                        .func = ModuleLoader.fetchModuleSource,
                    },
                };

                var scope = &self.scope.?;
                {
                    // Given a context, we can get our executor.
                    // (we store a pointer to our executor in the context's
                    // embeddeder data)
                    const data = isolate.initBigIntU64(@intCast(@intFromPtr(scope)));
                    context.setEmbedderData(1, data);
                }

                {
                    // Not the prettiest but we want to make the `call_arena`
                    // optionally available to the WebAPIs. If `state` has a
                    // call_arena field, fill-it in now.
                    const state_type_info = @typeInfo(@TypeOf(state));
                    if (state_type_info == .pointer and @hasField(state_type_info.pointer.child, "call_arena")) {
                        scope.state.call_arena = scope.call_arena;
                    }
                }

                // Custom exception
                // NOTE: there is no way in v8 to subclass the Error built-in type
                // TODO: this is an horrible hack
                inline for (Types) |s| {
                    const Struct = @field(types, s.name);
                    if (@hasDecl(Struct, "ErrorSet")) {
                        const script = comptime classNameForStruct(Struct) ++ ".prototype.__proto__ = Error.prototype";
                        _ = try scope.exec(script, "errorSubclass");
                    }
                }

                _ = try scope._mapZigInstanceToJs(context.getGlobal(), global);
                return scope;
            }

            pub fn endScope(self: *Executor) void {
                self.scope.?.deinit();
                self.scope = null;
                _ = self.scope_arena.reset(.{ .retain_with_limit = SCOPE_ARENA_RETAIN });
            }
        };

        const PersistentObject = v8.Persistent(v8.Object);
        const PersistentFunction = v8.Persistent(v8.Function);

        // Loosely maps to a Browser Page.
        pub const Scope = struct {
            state: State,
            isolate: v8.Isolate,
            // This context is a persistent object. The persistent needs to be recovered and reset.
            context: v8.Context,
            handle_scope: ?v8.HandleScope,

            // references the Env.template array
            templates: []v8.FunctionTemplate,

            // An arena for the lifetime of a call-group. Gets reset whenever
            // call_depth reaches 0.
            call_arena: Allocator,

            // An arena for the lifetime of the scope
            scope_arena: Allocator,

            // Because calls can be nested (i.e.a function calling a callback),
            // we can only reset the call_arena when call_depth == 0. If we were
            // to reset it within a callback, it would invalidate the data of
            // the call which is calling the callback.
            call_depth: usize = 0,

            // Callbacks are PesistendObjects. When the scope ends, we need
            // to free every callback we created.
            callbacks: std.ArrayListUnmanaged(v8.Persistent(v8.Function)) = .{},

            // Serves two purposes. Like `callbacks` above, this is used to free
            // every PeristentObjet we've created during the lifetime of the scope.
            // More importantly, it serves as an identity map - for a given Zig
            // instance, we map it to the same PersistentObject.
            identity_map: std.AutoHashMapUnmanaged(usize, PersistentObject) = .{},

            // When we need to load a resource (i.e. an external script), we call
            // this function to get the source. This is always a reference to the
            // Page's fetchModuleSource, but we use a function pointer
            // since this js module is decoupled from the browser implementation.
            module_loader: ModuleLoader,

            // Some Zig types have code to execute when the call scope ends
            call_scope_end_callbacks: std.ArrayListUnmanaged(CallScopeEndCallback) = .{},

            const ModuleLoader = struct {
                ptr: *anyopaque,
                func: *const fn (ptr: *anyopaque, specifier: []const u8) anyerror![]const u8,
            };

            // no init, started with executor.startScope()

            fn deinit(self: *Scope) void {
                var it = self.identity_map.valueIterator();
                while (it.next()) |p| {
                    p.deinit();
                }
                for (self.callbacks.items) |*cb| {
                    cb.deinit();
                }
                if (self.handle_scope) |*scope| {
                    scope.deinit();
                    self.context.exit();
                }
                var presistent_context = v8.Persistent(v8.Context).recoverCast(self.context);
                presistent_context.deinit();
            }

            fn trackCallback(self: *Scope, pf: PersistentFunction) !void {
                return self.callbacks.append(self.scope_arena, pf);
            }

            // Given an anytype, turns it into a v8.Object. The anytype could be:
            // 1 - A V8.object already
            // 2 - Our this JsObject wrapper around a V8.Object
            // 3 - A zig instance that has previously been given to V8
            //     (i.e., the value has to be known to the executor)
            fn valueToExistingObject(self: *const Scope, value: anytype) !v8.Object {
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

            // Executes the src
            pub fn exec(self: *Scope, src: []const u8, name: ?[]const u8) !Value {
                const isolate = self.isolate;
                const context = self.context;

                var origin: ?v8.ScriptOrigin = null;
                if (name) |n| {
                    const scr_name = v8.String.initUtf8(isolate, n);
                    origin = v8.ScriptOrigin.initDefault(self.isolate, scr_name.toValue());
                }
                const scr_js = v8.String.initUtf8(isolate, src);
                const scr = v8.Script.compile(context, scr_js, origin) catch {
                    return error.CompilationError;
                };

                const value = scr.run(context) catch {
                    return error.ExecutionError;
                };

                return self.createValue(value);
            }

            // compile and eval a JS module
            // It doesn't wait for callbacks execution
            pub fn module(self: *Scope, src: []const u8, name: []const u8) !Value {
                const context = self.context;
                const m = try compileModule(self.isolate, src, name);

                // instantiate
                // TODO handle ResolveModuleCallback parameters to load module's
                // dependencies.
                const ok = m.instantiate(context, resolveModuleCallback) catch {
                    return error.ExecutionError;
                };

                if (!ok) {
                    return error.ModuleInstantiationError;
                }

                // evaluate
                const value = m.evaluate(context) catch return error.ExecutionError;
                return self.createValue(value);
            }

            // Wrap a v8.Value, largely so that we can provide a convenient
            // toString function
            fn createValue(self: *const Scope, value: v8.Value) Value {
                return .{
                    .value = value,
                    .scope = self,
                };
            }

            fn zigValueToJs(self: *const Scope, value: anytype) !v8.Value {
                return Self.zigValueToJs(self.templates, self.isolate, self.context, value);
            }

            // See _mapZigInstanceToJs, this is wrapper that can be called
            // without a Scope. This is possible because we store our
            // scope in the EmbedderData of the v8.Context. So, as long as
            // we have a v8.Context, we can get the scope.
            fn mapZigInstanceToJs(context: v8.Context, js_obj_or_template: anytype, value: anytype) !PersistentObject {
                const scope: *Scope = @ptrFromInt(context.getEmbedderData(1).castTo(v8.BigInt).getUint64());
                return scope._mapZigInstanceToJs(js_obj_or_template, value);
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
            fn _mapZigInstanceToJs(self: *Scope, js_obj_or_template: anytype, value: anytype) !PersistentObject {
                const context = self.context;
                const scope_arena = self.scope_arena;

                const T = @TypeOf(value);
                switch (@typeInfo(T)) {
                    .@"struct" => {
                        // Struct, has to be placed on the heap
                        const heap = try scope_arena.create(T);
                        heap.* = value;
                        return self._mapZigInstanceToJs(js_obj_or_template, heap);
                    },
                    .pointer => |ptr| {
                        const gop = try self.identity_map.getOrPut(scope_arena, @intFromPtr(value));
                        if (gop.found_existing) {
                            // we've seen this instance before, return the same
                            // PersistentObject.
                            return gop.value_ptr.*;
                        }

                        if (comptime @hasDecl(ptr.child, "jsCallScopeEnd")) {
                            try self.call_scope_end_callbacks.append(scope_arena, CallScopeEndCallback.init(value));
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
                            v8.FunctionTemplate => js_obj_or_template.getInstanceTemplate().initInstance(context),
                            else => @compileError("mapZigInstanceToJs requires a v8.Object (constructors) or v8.FunctionTemplate, got: " ++ @typeName(@TypeOf(js_obj_or_template))),
                        };

                        const isolate = self.isolate;

                        if (isEmpty(ptr.child) == false) {
                            // The TAO contains the pointer ot our Zig instance as
                            // well as any meta data we'll need to use it later.
                            // See the TaggedAnyOpaque struct for more details.
                            const tao = try scope_arena.create(TaggedAnyOpaque);
                            const meta = @field(TYPE_LOOKUP, @typeName(ptr.child));
                            tao.* = .{
                                .ptr = value,
                                .index = meta.index,
                                .subtype = meta.subtype,
                                .offset = if (@typeInfo(ptr.child) != .@"opaque" and @hasField(ptr.child, "proto")) @offsetOf(ptr.child, "proto") else -1,
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
                            const obj_wrap = JsThis{ .obj = .{ .js_obj = js_obj, .scope = self } };
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

            // Callback from V8, asking us to load a module. The "specifier" is
            // the src of the module to load.
            fn resolveModuleCallback(
                c_context: ?*const v8.C_Context,
                c_specifier: ?*const v8.C_String,
                import_attributes: ?*const v8.C_FixedArray,
                referrer: ?*const v8.C_Module,
            ) callconv(.C) ?*const v8.C_Module {
                _ = import_attributes;
                _ = referrer;

                std.debug.assert(c_context != null);
                const context = v8.Context{ .handle = c_context.? };

                const self: *Scope = @ptrFromInt(context.getEmbedderData(1).castTo(v8.BigInt).getUint64());

                var buf: [1024]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&buf);

                // build the specifier value.
                const specifier = valueToString(
                    fba.allocator(),
                    .{ .handle = c_specifier.? },
                    self.isolate,
                    context,
                ) catch |e| {
                    log.err("resolveModuleCallback: get ref str: {any}", .{e});
                    return null;
                };

                // not currently needed
                // const referrer_module = if (referrer) |ref| v8.Module{ .handle = ref } else null;
                const module_loader = self.module_loader;
                const source = module_loader.func(module_loader.ptr, specifier) catch |err| {
                    log.err("fetchModuleSource for '{s}' fetch error: {}", .{ specifier, err });
                    return null;
                };

                const m = compileModule(self.isolate, source, specifier) catch |err| {
                    log.err("fetchModuleSource for '{s}' compile error: {}", .{ specifier, err });
                    return null;
                };
                return m.handle;
            }
        };

        pub const Callback = struct {
            id: usize,
            scope: *Scope,
            this: ?v8.Object = null,
            func: PersistentFunction,

            // We use this when mapping a JS value to a Zig object. We can't
            // Say we have a Zig function that takes a Callback, we can't just
            // check param.type == Callback, because Callback is a generic.
            // So, as a quick hack, we can determine if the Zig type is a
            // callback by checking @hasDecl(T, "_CALLBACK_ID_KLUDGE")
            const _CALLBACK_ID_KLUDGE = true;

            pub const Result = struct {
                stack: ?[]const u8,
                exception: []const u8,
            };

            pub fn withThis(self: *const Callback, value: anytype) !Callback {
                return .{
                    .id = self.id,
                    .func = self.func,
                    .scope = self.scope,
                    .this = try self.scope.valueToExistingObject(value),
                };
            }

            pub fn call(self: *const Callback, args: anytype) !void {
                return self.callWithThis(self.getThis(), args);
            }

            pub fn tryCall(self: *const Callback, args: anytype, result: *Result) !void {
                return self.tryCallWithThis(self.getThis(), args, result);
            }

            pub fn tryCallWithThis(self: *const Callback, this: anytype, args: anytype, result: *Result) !void {
                var try_catch: TryCatch = undefined;
                try_catch.init(self.scope);
                defer try_catch.deinit();

                self.callWithThis(this, args) catch |err| {
                    if (try_catch.hasCaught()) {
                        const allocator = self.scope.call_arena;
                        result.stack = try_catch.stack(allocator) catch null;
                        result.exception = (try_catch.exception(allocator) catch @errorName(err)) orelse @errorName(err);
                    } else {
                        result.stack = null;
                        result.exception = @errorName(err);
                    }
                    return err;
                };
            }

            pub fn callWithThis(self: *const Callback, this: anytype, args: anytype) !void {
                const scope = self.scope;

                const js_this = try scope.valueToExistingObject(this);

                const aargs = if (comptime @typeInfo(@TypeOf(args)) == .null) struct {}{} else args;
                const fields = @typeInfo(@TypeOf(aargs)).@"struct".fields;
                var js_args: [fields.len]v8.Value = undefined;
                inline for (fields, 0..) |f, i| {
                    js_args[i] = try scope.zigValueToJs(@field(aargs, f.name));
                }

                const result = self.func.castToFunction().call(scope.context, js_this, &js_args);
                if (result == null) {
                    return error.JSExecCallback;
                }
            }

            fn getThis(self: *const Callback) v8.Object {
                return self.this orelse self.scope.context.getGlobal();
            }

            // debug/helper to print the source of the JS callback
            fn printFunc(self: Callback) !void {
                const scope = self.scope;
                const value = self.func.castToFunction().toValue();
                const src = try valueToString(scope.call_arena, value, scope.isolate, scope.context);
                std.debug.print("{s}\n", .{src});
            }
        };

        pub const JsObject = struct {
            scope: *Scope,
            js_obj: v8.Object,

            // If a Zig struct wants the Object parameter, it'll declare a
            // function like:
            //    fn _length(self: *const NodeList, js_obj: Env.Object) usize
            //
            // When we're trying to call this function, we can't just do
            //    if (params[i].type.? == Object)
            // Because there is _no_ object, there's only an Env.Object, where
            // Env is a generic.
            // We could probably figure out a way to do this, but simply checking
            // for this declaration is _a lot_ easier.
            const _JSOBJECT_ID_KLUDGE = true;

            pub fn setIndex(self: JsObject, index: usize, value: anytype) !void {
                const key = switch (index) {
                    inline 0...1000 => |i| std.fmt.comptimePrint("{d}", .{i}),
                    else => try std.fmt.allocPrint(self.scope.scope_arena, "{d}", .{index}),
                };
                return self.set(key, value);
            }

            pub fn set(self: JsObject, key: []const u8, value: anytype) !void {
                const scope = self.scope;

                const js_key = v8.String.initUtf8(scope.isolate, key);
                const js_value = try scope.zigValueToJs(value);
                if (!self.js_obj.setValue(scope.context, js_key, js_value)) {
                    return error.FailedToSet;
                }
            }

            pub fn isTruthy(self: JsObject) bool {
                const js_value = self.js_obj.toValue();
                return js_value.toBool(self.scope.isolate);
            }

            pub fn toString(self: JsObject) ![]const u8 {
                const scope = self.scope;
                const js_value = self.js_obj.toValue();
                return valueToString(scope.call_arena, js_value, scope.isolate, scope.context);
            }

            pub fn format(self: JsObject, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                return writer.writeAll(try self.toString());
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

            pub fn setIndex(self: JsThis, index: usize, value: anytype) !void {
                return self.obj.setIndex(index, value);
            }

            pub fn set(self: JsThis, key: []const u8, value: anytype) !void {
                return self.obj.set(key, value);
            }
        };

        pub const TryCatch = struct {
            inner: v8.TryCatch,
            scope: *const Scope,

            pub fn init(self: *TryCatch, scope: *const Scope) void {
                self.scope = scope;
                self.inner.init(scope.isolate);
            }

            pub fn hasCaught(self: TryCatch) bool {
                return self.inner.hasCaught();
            }

            // the caller needs to deinit the string returned
            pub fn exception(self: TryCatch, allocator: Allocator) !?[]const u8 {
                const msg = self.inner.getException() orelse return null;
                const scope = self.scope;
                return try valueToString(allocator, msg, scope.isolate, scope.context);
            }

            // the caller needs to deinit the string returned
            pub fn stack(self: TryCatch, allocator: Allocator) !?[]const u8 {
                const scope = self.scope;
                const s = self.inner.getStackTrace(scope.context) orelse return null;
                return try valueToString(allocator, s, scope.isolate, scope.context);
            }

            // a shorthand method to return either the entire stack message
            // or just the exception message
            // - in Debug mode return the stack if available
            // - otherwhise return the exception if available
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
                const safe_context: *anyopaque = if (ContextT == void) @constCast(@ptrCast(&{})) else ctx;

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
                self.session.dispatchProtocolMessage(self.isolate, msg);
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
                scope: *const Scope,
                name: []const u8,
                origin: []const u8,
                aux_data: ?[]const u8,
                is_default_context: bool,
            ) void {
                self.inner.contextCreated(scope.context, name, origin, aux_data, is_default_context);
            }

            // Retrieves the RemoteObject for a given value.
            // The value is loaded through the Executor's mapZigInstanceToJs function,
            // just like a method return value. Therefore, if we've mapped this
            // value before, we'll get the existing JS PersistedObject and if not
            // we'll create it and track it for cleanup when the scope ends.
            pub fn getRemoteObject(
                self: *const Inspector,
                scope: *const Scope,
                group: []const u8,
                value: anytype,
            ) !RemoteObject {
                const js_value = try zigValueToJs(
                    scope.templates,
                    scope.isolate,
                    scope.context,
                    value,
                );

                // We do not want to expose this as a parameter for now
                const generate_preview = false;
                return self.session.wrapObject(
                    scope.isolate,
                    scope.context,
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

        pub const Value = struct {
            value: v8.Value,
            scope: *const Scope,

            // the caller needs to deinit the string returned
            pub fn toString(self: Value, allocator: Allocator) ![]const u8 {
                const scope = self.scope;
                return valueToString(allocator, self.value, scope.isolate, scope.context);
            }
        };

        fn compileModule(isolate: v8.Isolate, src: []const u8, name: []const u8) !v8.Module {
            // compile
            const script_name = v8.String.initUtf8(isolate, name);
            const script_source = v8.String.initUtf8(isolate, src);

            const origin = v8.ScriptOrigin.init(
                isolate,
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
        // FunctionTemplate of the isolate (in startScope)
        fn attachClass(comptime Struct: type, isolate: v8.Isolate, template: v8.FunctionTemplate) void {
            const template_proto = template.getPrototypeTemplate();
            inline for (@typeInfo(Struct).@"struct".decls) |declaration| {
                const name = declaration.name;
                if (comptime name[0] == '_') {
                    switch (@typeInfo(@TypeOf(@field(Struct, name)))) {
                        .@"fn" => generateMethod(Struct, name, isolate, template_proto),
                        else => generateAttribute(Struct, name, isolate, template, template_proto),
                    }
                } else if (comptime std.mem.startsWith(u8, name, "get_")) {
                    generateProperty(Struct, name[4..], isolate, template_proto);
                }
            }

            if (@hasDecl(Struct, "get_symbol_toStringTag") == false) {
                // If this WAS defined, then we would have created it in generateProperty.
                // But if it isn't, we create a default one
                const key = v8.Symbol.getToStringTag(isolate).toName();
                template_proto.setGetter(key, struct {
                    fn stringTag(_: ?*const v8.C_Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) void {
                        const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                        const class_name = v8.String.initUtf8(info.getIsolate(), comptime classNameForStruct(Struct));
                        info.getReturnValue().set(class_name);
                    }
                }.stringTag);
            }

            generateIndexer(Struct, template_proto);
            generateNamedIndexer(Struct, template_proto);
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
                    var caller = Caller(Self).init(info);
                    defer caller.deinit();

                    // See comment above. We generateConstructor on all types
                    // in order to create the FunctionTemplate, but there might
                    // not be an actual "constructor" function. So if someone
                    // does `new ClassName()` where ClassName doesn't have
                    // a constructor function, we'll return an error.
                    if (@hasDecl(Struct, "constructor") == false) {
                        const iso = caller.isolate;
                        const js_exception = iso.throwException(createException(iso, "illegal constructor"));
                        info.getReturnValue().set(js_exception);
                        return;
                    }

                    // Safe to call now, because if Struct.constructor didn't
                    // exist, the above if block would have returned.
                    const named_function = NamedFunction(Struct, Struct.constructor, "constructor"){};
                    caller.constructor(named_function, info) catch |err| {
                        caller.handleError(named_function, err, info);
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
                    var caller = Caller(Self).init(info);
                    defer caller.deinit();

                    const named_function = NamedFunction(Struct, @field(Struct, name), name){};
                    caller.method(named_function, info) catch |err| {
                        caller.handleError(named_function, err, info);
                    };
                }
            }.callback);
            template_proto.set(js_name, function_template, v8.PropertyAttribute.None);
        }

        fn generateAttribute(comptime Struct: type, comptime name: []const u8, isolate: v8.Isolate, template: v8.FunctionTemplate, template_proto: v8.ObjectTemplate) void {
            const zig_value = @field(Struct, name);
            const js_value = simpleZigValueToJs(isolate, zig_value, true);

            const js_name = v8.String.initUtf8(isolate, name[1..]).toName();

            // apply it both to the type itself
            template.set(js_name, js_value, v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);

            // andto instances of the type
            template_proto.set(js_name, js_value, v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);
        }

        fn generateProperty(comptime Struct: type, comptime name: []const u8, isolate: v8.Isolate, template_proto: v8.ObjectTemplate) void {
            const getter = @field(Struct, "get_" ++ name);
            const param_count = @typeInfo(@TypeOf(getter)).@"fn".params.len;

            var js_name: v8.Name = undefined;
            if (comptime std.mem.eql(u8, name, "symbol_toStringTag")) {
                if (param_count != 0) {
                    @compileError(@typeName(Struct) ++ ".get_symbol_toStringTag() cannot take any parameters");
                }
                js_name = v8.Symbol.getToStringTag(isolate).toName();
            } else {
                js_name = v8.String.initUtf8(isolate, name).toName();
            }

            const getter_callback = struct {
                fn callback(_: ?*const v8.C_Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) void {
                    const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                    var caller = Caller(Self).init(info);
                    defer caller.deinit();

                    const named_function = NamedFunction(Struct, getter, "get_" ++ name){};
                    caller.getter(named_function, info) catch |err| {
                        caller.handleError(named_function, err, info);
                    };
                }
            }.callback;

            const setter_name = "set_" ++ name;
            if (@hasDecl(Struct, setter_name) == false) {
                template_proto.setGetter(js_name, getter_callback);
                return;
            }

            const setter = @field(Struct, setter_name);
            const setter_callback = struct {
                fn callback(_: ?*const v8.C_Name, raw_value: ?*const v8.C_Value, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) void {
                    const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                    var caller = Caller(Self).init(info);
                    defer caller.deinit();

                    const js_value = v8.Value{ .handle = raw_value.? };
                    const named_function = NamedFunction(Struct, setter, "set_" ++ name){};
                    caller.setter(named_function, js_value, info) catch |err| {
                        caller.handleError(named_function, err, info);
                    };
                }
            }.callback;
            template_proto.setGetterAndSetter(js_name, getter_callback, setter_callback);
        }

        fn generateIndexer(comptime Struct: type, template_proto: v8.ObjectTemplate) void {
            if (@hasDecl(Struct, "indexed_get") == false) {
                return;
            }
            const configuration = v8.IndexedPropertyHandlerConfiguration{
                .getter = struct {
                    fn callback(idx: u32, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) void {
                        const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                        var caller = Caller(Self).init(info);
                        defer caller.deinit();

                        const named_function = NamedFunction(Struct, Struct.indexed_get, "indexed_get"){};
                        caller.getIndex(named_function, idx, info) catch |err| {
                            caller.handleError(named_function, err, info);
                        };
                    }
                }.callback,
            };

            // If you're trying to implement setter, read:
            // https://groups.google.com/g/v8-users/c/8tahYBsHpgY/m/IteS7Wn2AAAJ
            // The issue I had was
            // (a) where to attache it: does it go ont he instance_template
            //     instead of the prototype?
            // (b) defining the getter or query to respond with the
            //     PropertyAttribute to indicate if the property can be set
            template_proto.setIndexedProperty(configuration, null);
        }

        fn generateNamedIndexer(comptime Struct: type, template_proto: v8.ObjectTemplate) void {
            if (@hasDecl(Struct, "named_get") == false) {
                return;
            }
            const configuration = v8.NamedPropertyHandlerConfiguration{
                .getter = struct {
                    fn callback(c_name: ?*const v8.C_Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) void {
                        const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                        var caller = Caller(Self).init(info);
                        defer caller.deinit();

                        const named_function = NamedFunction(Struct, Struct.named_get, "named_get"){};
                        caller.getNamedIndex(named_function, .{ .handle = c_name.? }, info) catch |err| {
                            caller.handleError(named_function, err, info);
                        };
                    }
                }.callback,

                // This is really cool. Without this, we'd intercept _all_ properties
                // even those explicitly set. So, node.length for example would get routed
                // to our `named_get`, rather than a `get_length`. This might be
                // useful if we run into a type that we can't model properly in Zig.
                .flags = v8.PropertyHandlerFlags.OnlyInterceptStrings | v8.PropertyHandlerFlags.NonMasking,
            };

            // If you're trying to implement setter, read:
            // https://groups.google.com/g/v8-users/c/8tahYBsHpgY/m/IteS7Wn2AAAJ
            // The issue I had was
            // (a) where to attache it: does it go ont he instance_template
            //     instead of the prototype?
            // (b) defining the getter or query to respond with the
            //     PropertyAttribute to indicate if the property can be set
            template_proto.setNamedProperty(configuration, null);
        }

        // Turns a Zig value into a JS one.
        fn zigValueToJs(
            templates: []v8.FunctionTemplate,
            isolate: v8.Isolate,
            context: v8.Context,
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
                .void, .bool, .int, .comptime_int, .float, .comptime_float => {
                    // Need to do this to keep the compiler happy
                    // simpleZigValueToJs handles all of these cases.
                    unreachable;
                },
                .array => {
                    var js_arr = v8.Array.init(isolate, value.len);
                    var js_obj = js_arr.castTo(v8.Object);
                    for (value, 0..) |v, i| {
                        const js_val = try zigValueToJs(templates, isolate, context, v);
                        if (js_obj.setValueAtIndex(context, @intCast(i), js_val) == false) {
                            return error.FailedToCreateArray;
                        }
                    }
                    return js_obj.toValue();
                },
                .pointer => |ptr| switch (ptr.size) {
                    .one => {
                        const type_name = @typeName(ptr.child);
                        if (@hasField(TypeLookup, type_name)) {
                            const template = templates[@field(TYPE_LOOKUP, type_name).index];
                            const js_obj = try Scope.mapZigInstanceToJs(context, template, value);
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
                            const js_val = try zigValueToJs(templates, isolate, context, v);
                            if (js_obj.setValueAtIndex(context, @intCast(i), js_val) == false) {
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
                        const template = templates[@field(TYPE_LOOKUP, type_name).index];
                        const js_obj = try Scope.mapZigInstanceToJs(context, template, value);
                        return js_obj.toValue();
                    }

                    if (T == Callback) {
                        // we're returnig a callback
                        return value.func.toValue();
                    }

                    if (s.is_tuple) {
                        // return the tuple struct as an array
                        var js_arr = v8.Array.init(isolate, @intCast(s.fields.len));
                        var js_obj = js_arr.castTo(v8.Object);
                        inline for (s.fields, 0..) |f, i| {
                            const js_val = try zigValueToJs(templates, isolate, context, @field(value, f.name));
                            if (js_obj.setValueAtIndex(context, @intCast(i), js_val) == false) {
                                return error.FailedToCreateArray;
                            }
                        }
                        return js_obj.toValue();
                    }

                    // return the struct as a JS object
                    const js_obj = v8.Object.init(isolate);
                    inline for (s.fields) |f| {
                        const js_val = try zigValueToJs(templates, isolate, context, @field(value, f.name));
                        const key = v8.String.initUtf8(isolate, f.name);
                        if (!js_obj.setValue(context, key, js_val)) {
                            return error.CreateObjectFailure;
                        }
                    }
                    return js_obj.toValue();
                },
                .@"union" => |un| {
                    if (T == std.json.Value) {
                        return zigJsonToJs(isolate, context, value);
                    }
                    if (un.tag_type) |UnionTagType| {
                        inline for (un.fields) |field| {
                            if (value == @field(UnionTagType, field.name)) {
                                return zigValueToJs(templates, isolate, context, @field(value, field.name));
                            }
                        }
                        unreachable;
                    }
                    @compileError("Cannot use untagged union: " ++ @typeName(T));
                },
                .optional => {
                    if (value) |v| {
                        return zigValueToJs(templates, isolate, context, v);
                    }
                    return v8.initNull(isolate).toValue();
                },
                .error_union => return zigValueToJs(templates, isolate, context, value catch |err| return err),
                else => {},
            }
            @compileLog(@typeInfo(T));
            @compileError("A function returns an unsupported type: " ++ @typeName(T));
        }
        // Reverses the mapZigInstanceToJs, making sure that our TaggedAnyOpaque
        // contains a ptr to the correct type.
        fn typeTaggedAnyOpaque(comptime named_function: anytype, comptime R: type, js_obj: v8.Object) !R {
            const ti = @typeInfo(R);
            if (ti != .pointer) {
                @compileError(std.fmt.comptimePrint(
                    "{s} has a non-pointer Zig parameter type: {s}",
                    .{ named_function.full_name, @typeName(R) },
                ));
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
                @compileError(std.fmt.comptimePrint(
                    "{s} has an unknown Zig type: {s}",
                    .{ named_function.full_name, @typeName(R) },
                ));
            }

            const op = js_obj.getInternalField(0).castTo(v8.External).get();
            const toa: *TaggedAnyOpaque = @alignCast(@ptrCast(op));
            const expected_type_index = @field(TYPE_LOOKUP, type_name).index;

            var type_index = toa.index;
            if (type_index == expected_type_index) {
                return @alignCast(@ptrCast(toa.ptr));
            }

            // search through the prototype tree
            while (true) {
                const prototype_index = PROTOTYPE_TABLE[type_index];
                if (prototype_index == expected_type_index) {
                    // -1 is a sentinel value used for non-composition prototype
                    // This is used with netsurf and we just unsafely cast one
                    // type to another
                    const offset = toa.offset;
                    if (offset == -1) {
                        return @alignCast(@ptrCast(toa.ptr));
                    }

                    // A non-negative offset means we're using composition prototype
                    // (i.e. our struct has a "proto" field). the offset
                    // reresents the byte offset of the field. We can use that
                    // + the toa.ptr to get the field
                    return @ptrFromInt(@intFromPtr(toa.ptr) + @as(usize, @intCast(offset)));
                }
                if (prototype_index == type_index) {
                    return error.InvalidArgument;
                }
                type_index = prototype_index;
            }
        }

        // An interface for types that want to their jsScopeEnd function to be
        // called when the call scope ends
        const CallScopeEndCallback = struct {
            ptr: *anyopaque,
            callScopeEndFn: *const fn (ptr: *anyopaque, scope: *Scope) void,

            fn init(ptr: anytype) CallScopeEndCallback {
                const T = @TypeOf(ptr);
                const ptr_info = @typeInfo(T);

                const gen = struct {
                    pub fn callScopeEnd(pointer: *anyopaque, scope: *Scope) void {
                        const self: T = @ptrCast(@alignCast(pointer));
                        return ptr_info.pointer.child.jsCallScopeEnd(self, scope);
                    }
                };

                return .{
                    .ptr = ptr,
                    .callScopeEndFn = gen.callScopeEnd,
                };
            }

            pub fn callScopeEnd(self: CallScopeEndCallback, scope: *Scope) void {
                self.callScopeEndFn(self.ptr, scope);
            }
        };
    };
}

// We'll create a struct with all the types we want to bind to JavaScript. The
// fields for this struct will be the type names. The values, will be an
// instance of this struct.
// const TypeLookup = struct {
//     comptime cat: usize = TypeMeta{.index = 0, subtype = null},
//     comptime owner: usize = TypeMeta{.index = 1, subtype = .array}.
//     ...
// }
// This is essentially meta data for each type.
const TypeMeta = struct {
    // Every type is given a unique index. That index is used to lookup various
    // things, i.e. the prototype chain.
    index: usize,

    // We store the type's subtype here, so that when we create an instance of
    // the type, and bind it to JavaScript, we can store the subtype along with
    // the created TaggedAnyOpaque.s
    subtype: ?SubType,
};

fn isEmpty(comptime T: type) bool {
    return @typeInfo(T) != .@"opaque" and @sizeOf(T) == 0;
}

// Responsible for calling Zig functions from JS invokations. This could
// probably just contained in Executor, but having this specific logic, which
// is somewhat repetitive between constructors, functions, getters, etc contained
// here does feel like it makes it clenaer.
fn Caller(comptime E: type) type {
    const State = E.State;
    const TYPE_LOOKUP = E.TYPE_LOOKUP;
    const TypeLookup = @TypeOf(TYPE_LOOKUP);

    return struct {
        scope: *E.Scope,
        context: v8.Context,
        isolate: v8.Isolate,
        call_arena: Allocator,

        const Self = @This();

        // info is a v8.PropertyCallbackInfo or a v8.FunctionCallback
        // All we really want from it is the isolate.
        // executor = Isolate -> getCurrentContext -> getEmbedderData()
        fn init(info: anytype) Self {
            const isolate = info.getIsolate();
            const context = isolate.getCurrentContext();
            const scope: *E.Scope = @ptrFromInt(context.getEmbedderData(1).castTo(v8.BigInt).getUint64());

            scope.call_depth += 1;
            return .{
                .scope = scope,
                .isolate = isolate,
                .context = context,
                .call_arena = scope.call_arena,
            };
        }

        fn deinit(self: *Self) void {
            const scope = self.scope;
            const call_depth = scope.call_depth - 1;

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
                for (scope.call_scope_end_callbacks.items) |cb| {
                    cb.callScopeEnd(scope);
                }

                const arena: *ArenaAllocator = @alignCast(@ptrCast(scope.call_arena.ptr));
                _ = arena.reset(.{ .retain_with_limit = CALL_ARENA_RETAIN });
            }

            // Set this _after_ we've executed the above code, so that if the
            // above code executes any callbacks, they aren't being executed
            // at scope 0, which would be wrong.
            scope.call_depth = call_depth;
        }

        fn constructor(self: *Self, comptime named_function: anytype, info: v8.FunctionCallbackInfo) !void {
            const S = named_function.S;
            const args = try self.getArgs(named_function, 0, info);
            const res = @call(.auto, S.constructor, args);

            const ReturnType = @typeInfo(@TypeOf(S.constructor)).@"fn".return_type orelse {
                @compileError(@typeName(S) ++ " has a constructor without a return type");
            };

            const this = info.getThis();
            if (@typeInfo(ReturnType) == .error_union) {
                const non_error_res = res catch |err| return err;
                _ = try E.Scope.mapZigInstanceToJs(self.context, this, non_error_res);
            } else {
                _ = try E.Scope.mapZigInstanceToJs(self.context, this, res);
            }
            info.getReturnValue().set(this);
        }

        fn method(self: *Self, comptime named_function: anytype, info: v8.FunctionCallbackInfo) !void {
            const S = named_function.S;
            comptime assertSelfReceiver(named_function);

            var args = try self.getArgs(named_function, 1, info);
            const zig_instance = try E.typeTaggedAnyOpaque(named_function, *Receiver(S), info.getThis());

            // inject 'self' as the first parameter
            @field(args, "0") = zig_instance;

            const res = @call(.auto, named_function.func, args);
            info.getReturnValue().set(try self.zigValueToJs(res));
        }

        fn getter(self: *Self, comptime named_function: anytype, info: v8.PropertyCallbackInfo) !void {
            const S = named_function.S;
            const Getter = @TypeOf(named_function.func);
            if (@typeInfo(Getter).@"fn".return_type == null) {
                @compileError(@typeName(S) ++ " has a getter without a return type: " ++ @typeName(Getter));
            }

            var args: ParamterTypes(Getter) = undefined;
            const arg_fields = @typeInfo(@TypeOf(args)).@"struct".fields;
            switch (arg_fields.len) {
                0 => {}, // getters _can_ be parameterless
                1, 2 => {
                    const zig_instance = try E.typeTaggedAnyOpaque(named_function, *Receiver(S), info.getThis());
                    comptime assertSelfReceiver(named_function);
                    @field(args, "0") = zig_instance;
                    if (comptime arg_fields.len == 2) {
                        comptime assertIsStateArg(named_function, 1);
                        @field(args, "1") = self.scope.state;
                    }
                },
                else => @compileError(named_function.full_name + " has too many parmaters: " ++ @typeName(named_function.func)),
            }
            const res = @call(.auto, named_function.func, args);
            info.getReturnValue().set(try self.zigValueToJs(res));
        }

        fn setter(self: *Self, comptime named_function: anytype, js_value: v8.Value, info: v8.PropertyCallbackInfo) !void {
            const S = named_function.S;
            comptime assertSelfReceiver(named_function);

            const zig_instance = try E.typeTaggedAnyOpaque(named_function, *Receiver(S), info.getThis());

            const Setter = @TypeOf(named_function.func);
            var args: ParamterTypes(Setter) = undefined;
            const arg_fields = @typeInfo(@TypeOf(args)).@"struct".fields;
            switch (arg_fields.len) {
                0 => unreachable, // assertSelfReceiver make sure of this
                1 => @compileError(named_function.full_name ++ " only has 1 parameter"),
                2, 3 => {
                    @field(args, "0") = zig_instance;
                    @field(args, "1") = try self.jsValueToZig(named_function, arg_fields[1].type, js_value);
                    if (comptime arg_fields.len == 3) {
                        comptime assertIsStateArg(named_function, 2);
                        @field(args, "2") = self.scope.state;
                    }
                },
                else => @compileError(named_function.full_name ++ " setter with more than 3 parameters, why?"),
            }

            if (@typeInfo(Setter).@"fn".return_type) |return_type| {
                if (@typeInfo(return_type) == .error_union) {
                    _ = try @call(.auto, named_function.func, args);
                    return;
                }
            }
            _ = @call(.auto, named_function.func, args);
        }

        fn getIndex(self: *Self, comptime named_function: anytype, idx: u32, info: v8.PropertyCallbackInfo) !void {
            const S = named_function.S;
            const IndexedGet = @TypeOf(named_function.func);
            if (@typeInfo(IndexedGet).@"fn".return_type == null) {
                @compileError(named_function.full_name ++ " must have a return type");
            }

            var has_value = true;

            var args: ParamterTypes(IndexedGet) = undefined;
            const arg_fields = @typeInfo(@TypeOf(args)).@"struct".fields;
            switch (arg_fields.len) {
                0, 1, 2 => @compileError(named_function.full_name ++ " must take at least a u32 and *bool parameter"),
                3, 4 => {
                    const zig_instance = try E.typeTaggedAnyOpaque(named_function, *Receiver(S), info.getThis());
                    comptime assertSelfReceiver(named_function);
                    @field(args, "0") = zig_instance;
                    @field(args, "1") = idx;
                    @field(args, "2") = &has_value;
                    if (comptime arg_fields.len == 4) {
                        comptime assertIsStateArg(named_function, 3);
                        @field(args, "3") = self.scope.state;
                    }
                },
                else => @compileError(named_function.full_name ++ " has too many parmaters"),
            }

            const res = @call(.auto, S.indexed_get, args);
            if (has_value == false) {
                // for an indexed parameter, say nodes[10000], we should return
                // undefined, not null, if the index is out of rante
                info.getReturnValue().set(try self.zigValueToJs({}));
            } else {
                info.getReturnValue().set(try self.zigValueToJs(res));
            }
        }

        fn getNamedIndex(self: *Self, comptime named_function: anytype, name: v8.Name, info: v8.PropertyCallbackInfo) !void {
            const S = named_function.S;
            const NamedGet = @TypeOf(named_function.func);
            if (@typeInfo(NamedGet).@"fn".return_type == null) {
                @compileError(named_function.full_name ++ " must have a return type");
            }

            var has_value = true;
            var args: ParamterTypes(NamedGet) = undefined;
            const arg_fields = @typeInfo(@TypeOf(args)).@"struct".fields;
            switch (arg_fields.len) {
                0, 1, 2 => @compileError(named_function.full_name ++ " must take at least a u32 and *bool parameter"),
                3, 4 => {
                    const zig_instance = try E.typeTaggedAnyOpaque(named_function, *Receiver(S), info.getThis());
                    comptime assertSelfReceiver(named_function);
                    @field(args, "0") = zig_instance;
                    @field(args, "1") = try self.nameToString(name);
                    @field(args, "2") = &has_value;
                    if (comptime arg_fields.len == 4) {
                        comptime assertIsStateArg(named_function, 3);
                        @field(args, "3") = self.scope.state;
                    }
                },
                else => @compileError(named_function.full_name ++ " has too many parmaters"),
            }

            const res = @call(.auto, S.named_get, args);
            if (has_value == false) {
                // for an indexed parameter, say nodes[10000], we should return
                // undefined, not null, if the index is out of rante
                info.getReturnValue().set(try self.zigValueToJs({}));
            } else {
                info.getReturnValue().set(try self.zigValueToJs(res));
            }
        }

        fn nameToString(self: *Self, name: v8.Name) ![]const u8 {
            return valueToString(self.call_arena, .{ .handle = name.handle }, self.isolate, self.context);
        }

        fn assertSelfReceiver(comptime named_function: anytype) void {
            const params = @typeInfo(@TypeOf(named_function.func)).@"fn".params;
            if (params.len == 0) {
                @compileError(named_function.full_name ++ " must have a self parameter");
            }
            const R = Receiver(named_function.S);

            const first_param = params[0].type.?;
            if (first_param != *R and first_param != *const R) {
                @compileError(std.fmt.comptimePrint("The first parameter to {s} must be a *{s} or *const {s}. Got: {s}", .{ named_function.full_name, @typeName(R), @typeName(R), @typeName(first_param) }));
            }
        }

        fn assertIsStateArg(comptime named_function: anytype, index: comptime_int) void {
            const F = @TypeOf(named_function.func);
            const params = @typeInfo(F).@"fn".params;

            const param = params[index].type.?;
            if (param != State) {
                @compileError(std.fmt.comptimePrint("The {d} parameter to {s} must be a {s}. Got: {s}", .{ index, named_function.full_name, @typeName(State), @typeName(param) }));
            }
        }

        fn handleError(self: *Self, comptime named_function: anytype, err: anyerror, info: anytype) void {
            const isolate = self.isolate;
            var js_err: ?v8.Value = switch (err) {
                error.InvalidArgument => createTypeException(isolate, "invalid argument"),
                error.OutOfMemory => createException(isolate, "out of memory"),
                else => blk: {
                    const return_type = @typeInfo(@TypeOf(named_function.func)).@"fn".return_type orelse {
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

                    const Exception = comptime getCustomException(named_function.S) orelse break :blk null;
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
                        break :blk self.zigValueToJs(custom_exception) catch createException(isolate, "internal error");
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
        fn getArgs(self: *const Self, comptime named_function: anytype, comptime offset: usize, info: anytype) !ParamterTypes(@TypeOf(named_function.func)) {
            const F = @TypeOf(named_function.func);
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
                    @field(args, std.fmt.comptimePrint("{d}", .{params.len - 1 + offset})) = self.scope.state;
                    break :blk params[0 .. params.len - 1];
                }

                // If the last parameter is a special JsThis, set it, and exclude it
                // from our params slice, because we don't want to bind it to
                // a JS argument
                if (comptime isJsThis(params[params.len - 1].type.?)) {
                    @field(args, std.fmt.comptimePrint("{d}", .{params.len - 1 + offset})) = .{ .obj = .{
                        .js_obj = info.getThis(),
                        .executor = self.executor,
                    } };

                    // AND the 2nd last parameter is state
                    if (params.len > 1 and comptime isState(params[params.len - 2].type.?)) {
                        @field(args, std.fmt.comptimePrint("{d}", .{params.len - 2 + offset})) = self.scope.state;
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
                // This is going to get complicated. If the last Zig paremeter
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
                                a.* = try self.jsValueToZig(named_function, slice_type, js_value);
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
                    @field(args, tupleFieldName(field_index)) = self.jsValueToZig(named_function, param.type.?, js_value) catch {
                        return error.InvalidArgument;
                    };
                }
            }

            return args;
        }

        fn jsValueToZig(self: *const Self, comptime named_function: anytype, comptime T: type, js_value: v8.Value) !T {
            switch (@typeInfo(T)) {
                .optional => |o| {
                    if (js_value.isNullOrUndefined()) {
                        return null;
                    }
                    return try self.jsValueToZig(named_function, o.child, js_value);
                },
                .float => |f| switch (f.bits) {
                    0...32 => return js_value.toF32(self.context),
                    33...64 => return js_value.toF64(self.context),
                    else => {},
                },
                .int => return jsIntToZig(T, js_value, self.context),
                .bool => return js_value.toBool(self.isolate),
                .pointer => |ptr| switch (ptr.size) {
                    .one => {
                        if (!js_value.isObject()) {
                            return error.InvalidArgument;
                        }
                        if (@hasField(TypeLookup, @typeName(ptr.child))) {
                            const js_obj = js_value.castTo(v8.Object);
                            return E.typeTaggedAnyOpaque(named_function, *Receiver(ptr.child), js_obj);
                        }
                    },
                    .slice => {
                        if (js_value.isTypedArray()) {
                            const buffer_view = js_value.castTo(v8.ArrayBufferView);
                            const buffer = buffer_view.getBuffer();
                            const backing_store = v8.BackingStore.sharedPtrGet(&buffer.getBackingStore());
                            const data = backing_store.getData();
                            const byte_len = backing_store.getByteLength();

                            switch (ptr.child) {
                                u8 => {
                                    // need this sentinel check to keep the compiler happy
                                    if (ptr.sentinel() == null) {
                                        if (js_value.isUint8Array() or js_value.isUint8ClampedArray()) {
                                            const arr_ptr = @as([*]u8, @alignCast(@ptrCast(data)));
                                            return arr_ptr[0..byte_len];
                                        }
                                    }
                                },
                                i8 => {
                                    if (js_value.isInt8Array()) {
                                        const arr_ptr = @as([*]i8, @alignCast(@ptrCast(data)));
                                        return arr_ptr[0..byte_len];
                                    }
                                },
                                u16 => {
                                    if (js_value.isUint16Array()) {
                                        const arr_ptr = @as([*]u16, @alignCast(@ptrCast(data)));
                                        return arr_ptr[0 .. byte_len / 2];
                                    }
                                },
                                i16 => {
                                    if (js_value.isInt16Array()) {
                                        const arr_ptr = @as([*]i16, @alignCast(@ptrCast(data)));
                                        return arr_ptr[0 .. byte_len / 2];
                                    }
                                },
                                u32 => {
                                    if (js_value.isUint32Array()) {
                                        const arr_ptr = @as([*]u32, @alignCast(@ptrCast(data)));
                                        return arr_ptr[0 .. byte_len / 4];
                                    }
                                },
                                i32 => {
                                    if (js_value.isInt32Array()) {
                                        const arr_ptr = @as([*]i32, @alignCast(@ptrCast(data)));
                                        return arr_ptr[0 .. byte_len / 4];
                                    }
                                },
                                u64 => {
                                    if (js_value.isBigUint64Array()) {
                                        const arr_ptr = @as([*]u64, @alignCast(@ptrCast(data)));
                                        return arr_ptr[0 .. byte_len / 8];
                                    }
                                },
                                i64 => {
                                    if (js_value.isBigInt64Array()) {
                                        const arr_ptr = @as([*]i64, @alignCast(@ptrCast(data)));
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
                                    return valueToStringZ(self.call_arena, js_value, self.isolate, self.context);
                                }
                            } else {
                                return valueToString(self.call_arena, js_value, self.isolate, self.context);
                            }
                        }

                        if (!js_value.isArray()) {
                            return error.InvalidArgument;
                        }

                        const context = self.context;
                        const js_arr = js_value.castTo(v8.Array);
                        const js_obj = js_arr.castTo(v8.Object);

                        // Newer version of V8 appear to have an optimized way
                        // to do this (V8::Array has an iterate method on it)
                        const arr = try self.call_arena.alloc(ptr.child, js_arr.length());
                        for (arr, 0..) |*a, i| {
                            a.* = try self.jsValueToZig(named_function, ptr.child, try js_obj.getAtIndex(context, @intCast(i)));
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

                    // the first field that we find which the js_Value is
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
                else => {},
            }

            @compileError(named_function.full_name ++ " has an unsupported parameter type: " ++ @typeName(T));
        }

        fn jsIntToZig(comptime T: type, js_value: v8.Value, context: v8.Context) !T {
            const n = @typeInfo(T).int;
            switch (n.signedness) {
                .signed => switch (n.bits) {
                    8 => return jsSignedIntToZig(i8, -128, 127, try js_value.toI32(context)),
                    16 => return jsSignedIntToZig(i16, -32_768, 32_767, try js_value.toI32(context)),
                    32 => return jsSignedIntToZig(i32, -2_147_483_648, 2_147_483_647, try js_value.toI32(context)),
                    64 => {
                        if (js_value.isBigInt()) {
                            const v = js_value.castTo(v8.BigInt);
                            return v.getInt64();
                        }
                        return jsSignedIntToZig(i64, -2_147_483_648, 2_147_483_647, try js_value.toI32(context));
                    },
                    else => {},
                },
                .unsigned => switch (n.bits) {
                    8 => return jsUnsignedIntToZig(u8, 255, try js_value.toU32(context)),
                    16 => return jsUnsignedIntToZig(u16, 65_535, try js_value.toU32(context)),
                    32 => return jsUnsignedIntToZig(u32, 4_294_967_295, try js_value.toU32(context)),
                    64 => {
                        if (js_value.isBigInt()) {
                            const v = js_value.castTo(v8.BigInt);
                            return v.getUint64();
                        }
                        return jsUnsignedIntToZig(u64, 4_294_967_295, try js_value.toU32(context));
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

        // Extracted so that it can be used in both jsValueToZig and in
        // probeJsValueToZig. Avoids having to duplicate this logic when probing.
        fn jsValueToStruct(self: *const Self, comptime named_function: anytype, comptime T: type, js_value: v8.Value) !?T {
            if (@hasDecl(T, "_CALLBACK_ID_KLUDGE")) {
                if (!js_value.isFunction()) {
                    return error.InvalidArgument;
                }

                const func = v8.Persistent(v8.Function).init(self.isolate, js_value.castTo(v8.Function));
                const scope = self.scope;
                try scope.trackCallback(func);

                return .{
                    .func = func,
                    .scope = scope,
                    .id = js_value.castTo(v8.Object).getIdentityHash(),
                };
            }

            const js_obj = js_value.castTo(v8.Object);

            if (comptime isJsObject(T)) {
                // Caller wants an opaque JsObject. Probably a parameter
                // that it needs to pass back into a callback
                return E.JsObject{
                    .js_obj = js_obj,
                    .scope = self.scope,
                };
            }

            if (!js_value.isObject()) {
                return null;
            }

            const context = self.context;
            const isolate = self.isolate;

            var value: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const name = field.name;
                const key = v8.String.initUtf8(isolate, name);
                if (js_obj.has(context, key.toValue())) {
                    @field(value, name) = try self.jsValueToZig(named_function, field.type, try js_obj.getValue(context, key));
                } else if (@typeInfo(field.type) == .optional) {
                    @field(value, name) = null;
                } else {
                    const dflt = field.defaultValue() orelse return null;
                    @field(value, name) = dflt;
                }
            }
            return value;
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
        fn probeJsValueToZig(self: *const Self, comptime named_function: anytype, comptime T: type, js_value: v8.Value) !ProbeResult(T) {
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
                            const attempt = E.typeTaggedAnyOpaque(named_function, *Receiver(ptr.child), js_obj);
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
                            return error.InvalidArgument;
                        }

                        // This can get tricky.
                        const js_arr = js_value.castTo(v8.Array);

                        if (js_arr.length() == 0) {
                            // not so tricky in this case.
                            return .{ .value = &.{} };
                        }

                        // We settle for just probing the first value. Ok, actually
                        // not tricky in this case either.
                        const context = self.contxt;
                        const js_obj = js_arr.castTo(v8.Object);
                        return self.probeJsValueToZig(named_function, ptr.child, try js_obj.getAtIndex(context, 0));
                    },
                    else => {},
                },
                .@"struct" => {
                    // We don't want to duplicate the code for this, so we call
                    // the actual coversion function.
                    const value = (try self.jsValueToStruct(named_function, T, js_value)) orelse {
                        return .{ .invalid = {} };
                    };
                    return .{ .value = value };
                },
                else => {},
            }

            return .{ .invalid = {} };
        }

        fn zigValueToJs(self: *const Self, value: anytype) !v8.Value {
            return self.scope.zigValueToJs(value);
        }

        fn isState(comptime T: type) bool {
            const ti = @typeInfo(State);
            const Const_State = if (ti == .pointer) *const ti.pointer.child else State;
            return T == State or T == Const_State;
        }

        fn isJsObject(comptime T: type) bool {
            return @typeInfo(T) == .@"struct" and @hasDecl(T, "_JSOBJECT_ID_KLUDGE");
        }

        fn isJsThis(comptime T: type) bool {
            return @typeInfo(T) == .@"struct" and @hasDecl(T, "_JSTHIS_ID_KLUDGE");
        }
    };
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
        .@"union" => return simpleZigValueToJs(isolate, std.meta.activeTag(value), fail),
        else => {},
    }
    if (fail) {
        @compileError("Unsupported Zig type " ++ @typeName(@TypeOf(value)));
    }
    return null;
}

pub fn zigJsonToJs(isolate: v8.Isolate, context: v8.Context, value: std.json.Value) !v8.Value {
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
                const js_val = try zigJsonToJs(isolate, context, array_value);
                if (!obj.setValueAtIndex(context, @intCast(i), js_val)) {
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
                const js_val = try zigJsonToJs(isolate, context, kv.value_ptr.*);
                if (!obj.setValue(context, js_key, js_val)) {
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
    return std.fmt.comptimePrint("{d}", .{i});
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

    // If this type has composition-based prototype, represents the byte-offset
    // from ptr where the `proto` field is located. The value -1 represents
    // unsafe prototype where we can just cast ptr to the destination type
    // (this is used extensively with netsurf)
    offset: i32,

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

fn valueToString(allocator: Allocator, value: v8.Value, isolate: v8.Isolate, context: v8.Context) ![]u8 {
    const str = try value.toString(context);
    const len = str.lenUtf8(isolate);
    const buf = try allocator.alloc(u8, len);
    const n = str.writeUtf8(isolate, buf);
    std.debug.assert(n == len);
    return buf;
}

fn valueToStringZ(allocator: Allocator, value: v8.Value, isolate: v8.Isolate, context: v8.Context) ![:0]u8 {
    const str = try value.toString(context);
    const len = str.lenUtf8(isolate);
    const buf = try allocator.allocSentinel(u8, len, 0);
    const n = str.writeUtf8(isolate, buf);
    std.debug.assert(n == len);
    return buf;
}

const NoopInspector = struct {
    pub fn onInspectorResponse(_: *anyopaque, _: u32, _: []const u8) void {}
    pub fn onInspectorEvent(_: *anyopaque, _: []const u8) void {}
};

const ErrorModuleLoader = struct {
    pub fn fetchModuleSource(_: *anyopaque, _: []const u8) ![]const u8 {
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
fn Receiver(comptime S: type) type {
    return if (@hasDecl(S, "Self")) S.Self else S;
}

// We want the function name, or more precisely, the "Struct.function" for
// displaying helpful @compileError.
// However, there's no way to get the name from a std.Builtin.Fn,
// so we capture it early and mostly pass around this NamedFunction instance
// whenever we're trying to bind a function/getter/setter/etc so that we always
// have the main data (struct + function) along with the meta data for displaying
// better errors.
fn NamedFunction(comptime S: type, comptime function: anytype, comptime name: []const u8) type {
    const full_name = @typeName(S) ++ "." ++ name;
    const js_name = if (name[0] == '_') name[1..] else name;
    return struct {
        S: type = S,
        full_name: []const u8 = full_name,
        func: @TypeOf(function) = function,
        js_name: []const u8 = js_name,
    };
}

// This is called from V8. Whenever the v8 inspector has to describe a value
// it'll call this function to gets its [optional] subtype - which, from V8's
// point of view, is an arbitrary string.
pub export fn v8_inspector__Client__IMPL__valueSubtype(
    _: *v8.c.InspectorClientImpl,
    c_value: *const v8.C_Value,
) callconv(.C) [*c]const u8 {
    const external_entry = getTaggedAnyOpaque(.{ .handle = c_value }) orelse return null;
    return if (external_entry.subtype) |st| @tagName(st) else null;
}

// Same as valueSubType above, but for the optional description field.
// From what I can tell, some drivers _need_ the description field to be
// present, even if it's empty. So if we have a subType for the value, we'll
// put an empty description.
pub export fn v8_inspector__Client__IMPL__descriptionForValueSubtype(
    _: *v8.c.InspectorClientImpl,
    context: *const v8.C_Context,
    c_value: *const v8.C_Value,
) callconv(.C) [*c]const u8 {
    _ = context;

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
    return @alignCast(@ptrCast(external_data));
}

test {
    std.testing.refAllDecls(@import("test_primitive_types.zig"));
    std.testing.refAllDecls(@import("test_complex_types.zig"));
    std.testing.refAllDecls(@import("test_object_types.zig"));
}
