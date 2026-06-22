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

// The Env maps to a JSRuntime. Where the v8 backend restores contexts from
// a snapshot, here classes are registered once on the runtime and each
// context gets its prototypes/constructors built at creation time.
const std = @import("std");
const lp = @import("lightpanda");
const builtin = @import("builtin");

const js = @import("js.zig");
const bridge = @import("bridge.zig");
const Caller = @import("Caller.zig");
const Context = @import("Context.zig");
const registry = @import("../registry.zig");

const App = @import("../../../App.zig");
const Frame = @import("../../Frame.zig");
const Window = @import("../../webapi/Window.zig");
const WorkerGlobalScope = @import("../../webapi/WorkerGlobalScope.zig");

const q = js.q;
const log = lp.log;
const JsApis = registry.JsApis;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

const MAX_CONTEXTS = if (lp.build_config.wpt_extensions) 8192 else 128;

const Env = @This();

app: *App,

allocator: Allocator,

rt: *q.JSRuntime,

contexts: std.ArrayList(*Context),

context_id: usize,

// Monotonic key generator for PersistentHandles (see js.PersistentHandle).
persist_key: usize = 0,

// quickjs does not copy JSClassDef / JSClassExoticMethods - they must
// outlive the runtime.
definitions: []q.JSClassDef,
exotics: []q.JSClassExoticMethods,

// Class used to smuggle a raw Zig pointer through a JSValue (the
// equivalent of a v8::External). Used by Local.newCallback.
external_class_id: q.JSClassID = 0,

// The (contiguous) range of class ids registered for our JsApi types.
// Lets TaggedOpaque.fromJS reject opaques on foreign classes (quickjs
// built-ins also use the opaque slot for their own purposes).
first_js_class_id: q.JSClassID = 0,
last_js_class_id: q.JSClassID = 0,

// Heap-allocated so its address is stable even though Env is moved by
// value after init (the interrupt handler captures it).
terminate_requested: *std.atomic.Value(bool),

// Engine-neutral call sites (e.g. Page passing env.isolate to Origin.init)
// need this field to exist; quickjs has no isolate concept.
isolate: Isolate = .{},

pub const Isolate = struct {};

pub const InitOpts = struct {
    with_inspector: bool = false,
};

pub fn init(app: *App, opts: InitOpts) !Env {
    // CDP (and thus the inspector) is not supported with the quickjs engine.
    std.debug.assert(opts.with_inspector == false);

    const allocator = app.allocator;

    const rt = q.JS_NewRuntime() orelse return error.FailedToCreateRuntime;
    errdefer q.JS_FreeRuntime(rt);

    // This MUST stay safely below the OS thread stack of whatever thread runs
    // JS (fetchThread, serve connections, etc.), which is std.Thread's default
    // of 16MiB. QuickJS only trips its (catchable) stack-overflow guard once
    // usage exceeds this limit; if the limit is larger than the real OS stack,
    // the thread stack is exhausted first and the process dies with a bus
    // error instead. 8MiB leaves a generous margin for the native C frames
    // between guard checks.
    // TODO: configurable / derive from the actual thread stack size.
    q.JS_SetMaxStackSize(rt, 8 * 1024 * 1024);

    if (comptime IS_DEBUG) {
        q.JS_SetDumpFlags(rt, q.JS_DUMP_LEAKS | q.JS_DUMP_ATOM_LEAKS);
    }

    const definitions = try allocator.alloc(q.JSClassDef, JsApis.len + 1);
    errdefer allocator.free(definitions);

    var exotics = try allocator.alloc(q.JSClassExoticMethods, comptime countExotics());
    errdefer allocator.free(exotics);

    var first_js_class_id: q.JSClassID = 0;
    var last_js_class_id: q.JSClassID = 0;
    var exotic_index: usize = 0;
    inline for (JsApis, 0..) |JsApi, i| {
        @setEvalBranchQuota(10_000);
        JsApi.Meta.class_id = 0;
        _ = q.JS_NewClassID(rt, &JsApi.Meta.class_id);
        if (i == 0) {
            first_js_class_id = JsApi.Meta.class_id;
        }
        last_js_class_id = JsApi.Meta.class_id;

        const exotic: ?*q.JSClassExoticMethods = blk: {
            if (comptime hasExotics(JsApi)) {
                defer exotic_index += 1;
                exotics[exotic_index] = bridge.buildExotic(JsApi);
                break :blk &exotics[exotic_index];
            }
            break :blk null;
        };

        definitions[i] = .{
            .class_name = if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi),
            .finalizer = null,
            .gc_mark = null,
            .call = comptime callHandler(JsApi),
            .exotic = exotic,
        };
        if (q.JS_NewClass(rt, JsApi.Meta.class_id, &definitions[i]) != 0) {
            return error.FailedToCreateClass;
        }
    }

    var external_class_id: q.JSClassID = 0;
    _ = q.JS_NewClassID(rt, &external_class_id);
    definitions[JsApis.len] = .{
        .class_name = "LightpandaExternal",
        .finalizer = null,
        .gc_mark = null,
        .call = null,
        .exotic = null,
    };
    if (q.JS_NewClass(rt, external_class_id, &definitions[JsApis.len]) != 0) {
        return error.FailedToCreateClass;
    }

    q.JS_SetModuleLoaderFunc(rt, Context.moduleNormalize, Context.moduleLoad, null);
    q.JS_SetHostPromiseRejectionTracker(rt, Context.promiseRejectionTracker, null);

    const terminate_requested = try allocator.create(std.atomic.Value(bool));
    errdefer allocator.destroy(terminate_requested);
    terminate_requested.* = .init(false);

    q.JS_SetInterruptHandler(rt, struct {
        fn handler(_: ?*q.JSRuntime, opq: ?*anyopaque) callconv(.c) c_int {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(opq.?));
            return @intFromBool(flag.load(.acquire));
        }
    }.handler, terminate_requested);

    return .{
        .app = app,
        .rt = rt,
        .context_id = 0,
        .allocator = allocator,
        .contexts = .empty,
        .definitions = definitions,
        .exotics = exotics,
        .external_class_id = external_class_id,
        .first_js_class_id = first_js_class_id,
        .last_js_class_id = last_js_class_id,
        .terminate_requested = terminate_requested,
    };
}

pub fn deinit(self: *Env) void {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.contexts.items.len == 0);
    }
    for (self.contexts.items) |ctx| {
        ctx.deinit();
    }
    self.contexts.deinit(self.allocator);

    q.JS_FreeRuntime(self.rt);
    self.allocator.free(self.definitions);
    self.allocator.free(self.exotics);
    self.allocator.destroy(self.terminate_requested);
}

pub const ContextParams = struct {
    identity: *js.Identity,
    identity_arena: Allocator,
    call_arena: Allocator,
    debug_name: []const u8 = "Context",
};

pub fn createContext(self: *Env, frame: *Frame, params: ContextParams) !*Context {
    return self._createContext(frame, params);
}

pub fn createWorkerContext(self: *Env, worker: *WorkerGlobalScope, params: ContextParams) !*Context {
    return self._createContext(worker, params);
}

fn _createContext(self: *Env, global: anytype, params: ContextParams) !*Context {
    const T = @TypeOf(global);
    const is_frame = T == *Frame;
    const realm: bridge.Realm = if (comptime is_frame) .window else .worker;
    const GlobalScopeApi = if (comptime is_frame) Window.JsApi else WorkerGlobalScope.JsApi;

    const context_arena = try self.app.arena_pool.acquire(.medium, params.debug_name);
    errdefer self.app.arena_pool.release(context_arena);

    const qctx = q.JS_NewContext(self.rt) orelse return error.OutOfMemory;
    errdefer q.JS_FreeContext(qctx);

    const js_global = q.JS_GetGlobalObject(qctx);
    defer q.JS_FreeValue(qctx, js_global);

    // Build every class' prototype and (for this realm's APIs) expose the
    // constructor on the global.
    var js_protos: [JsApis.len]q.JSValue = undefined;
    inline for (JsApis, 0..) |JsApi, i| {
        @setEvalBranchQuota(10_000);
        const proto = q.JS_NewObject(qctx);
        js_protos[i] = proto;

        const constructor = try bridge.attachClass(JsApi, realm, qctx, proto, false);

        // JS_SetClassProto takes ownership; the local stays valid for the
        // prototype-chain wiring below because the class holds a ref.
        q.JS_SetClassProto(qctx, JsApi.Meta.class_id, proto);

        if (comptime !@hasDecl(JsApi.Meta, "name")) {
            if (constructor) |ctor| {
                q.JS_FreeValue(qctx, ctor);
            }
        } else if (constructor) |ctor| {
            if (comptime inRealm(JsApi, realm)) {
                const ctor_name = comptime if (@hasDecl(JsApi.Meta, "constructor_alias"))
                    JsApi.Meta.constructor_alias
                else
                    JsApi.Meta.name;

                // Web IDL: interface objects on the global are non-enumerable
                // by default. Opt back in via JsApi.Meta.enumerable = true.
                var flags: c_int = q.JS_PROP_WRITABLE | q.JS_PROP_CONFIGURABLE;
                if (@hasDecl(JsApi.Meta, "enumerable") and JsApi.Meta.enumerable == true) {
                    flags |= q.JS_PROP_ENUMERABLE;
                }
                if (@hasDecl(JsApi.Meta, "constructor_alias")) {
                    _ = q.JS_DefinePropertyValueStr(qctx, js_global, JsApi.Meta.name, q.JS_DupValue(qctx, ctor), flags);
                }
                _ = q.JS_DefinePropertyValueStr(qctx, js_global, ctor_name, ctor, flags);
            } else {
                q.JS_FreeValue(qctx, ctor);
            }
        }
    }

    // Prototype chains (both the instance prototypes and, implicitly via
    // JS_SetConstructor, constructor.prototype links).
    inline for (JsApis, 0..) |JsApi, i| {
        if (comptime protoIndexLookup(JsApi)) |proto_index| {
            const ret = q.JS_SetPrototype(qctx, js_protos[i], js_protos[proto_index]);
            std.debug.assert(ret == 1);
        }
    }

    // [Global] flattening: define the global scope chain's members (e.g.
    // Window, EventTarget) directly on the global object, in addition to
    // the prototype chain. This makes `var navigator = ...` style shadowing
    // behave like real browsers (see the v8 Snapshot for details).
    inline for (comptime globalScopeChain(GlobalScopeApi)) |ScopeApi| {
        _ = try bridge.attachClass(ScopeApi, realm, qctx, js_global, true);
    }
    {
        const global_scope_index = comptime registry.JsApiLookup.getId(GlobalScopeApi);
        const ret = q.JS_SetPrototype(qctx, js_global, js_protos[global_scope_index]);
        std.debug.assert(ret == 1);
    }

    const context_id = self.context_id;
    self.context_id = context_id + 1;

    const page = global._page;
    const origin = try page.getOrCreateOrigin(null);
    errdefer page.releaseOrigin(origin);

    const context = try context_arena.create(Context);
    context.* = .{
        .env = self,
        .global = if (comptime is_frame) .{ .frame = global } else .{ .worker = global },
        .origin = origin,
        .id = context_id,
        .page = page,
        .ctx = qctx,
        .arena = context_arena,
        .call_arena = params.call_arena,
        .script_manager = if (comptime is_frame) &global._script_manager.base else &global._script_manager,
        .scheduler = .init(context_arena),
        .identity = params.identity,
        .identity_arena = params.identity_arena,
        .execution = undefined,
    };

    context.execution = .{
        .js = context,
        .url = &global.url,
        .buf = &global.buf,
        .charset = &global.charset,
        .arena = global.arena,
        .page = context.page,
        .session = page.session,
        .call_arena = params.call_arena,
        ._factory = global._factory,
        ._scheduler = &context.scheduler,
    };

    q.JS_SetContextOpaque(qctx, context);

    // Register the global object in the identity map so that returning the
    // window (or worker scope) from Zig yields the global object.
    const identity_ptr = if (comptime is_frame) @intFromPtr(global.window) else @intFromPtr(global);
    const gop = try params.identity.identity_map.getOrPut(params.identity_arena, identity_ptr);
    if (gop.found_existing == false) {
        gop.value_ptr.* = context.persist(q.JS_DupValue(qctx, js_global));
    }

    {
        // DOMException must inherit from Error for `instanceof Error` and
        // stack traces to behave.
        const src = "DOMException.prototype.__proto__ = Error.prototype";
        const v = q.JS_Eval(qctx, src, src.len, "<init>", q.JS_EVAL_TYPE_GLOBAL);
        std.debug.assert(!q.JS_IsException(v));
        q.JS_FreeValue(qctx, v);
    }

    if (self.contexts.items.len >= MAX_CONTEXTS) {
        return error.TooManyContexts;
    }
    try self.contexts.append(self.allocator, context);

    return context;
}

pub fn destroyContext(self: *Env, context: *Context) void {
    for (self.contexts.items, 0..) |ctx, i| {
        if (ctx == context) {
            _ = self.contexts.swapRemove(i);
            break;
        }
    } else {
        if (comptime IS_DEBUG) {
            @panic("Tried to remove unknown context");
        }
    }
    context.deinit();
}

pub fn runMicrotasks(self: *Env) void {
    var qctx: ?*q.JSContext = null;
    while (true) {
        const res = q.JS_ExecutePendingJob(self.rt, &qctx);
        if (res == 0) {
            return;
        }
        if (res < 0) {
            @branchHint(.unlikely);
            const ctx = qctx orelse return;
            const exception = q.JS_GetException(ctx);
            defer q.JS_FreeValue(ctx, exception);
            logException(ctx, "pending job", exception);
        }
    }
}

pub fn runMacrotasks(self: *Env) !void {
    // Re-read len/items each iteration: scheduler.run() can create a new
    // context (e.g. an iframe), appending to (and reallocating) the list.
    var i: usize = 0;
    while (i < self.contexts.items.len) : (i += 1) {
        const ctx = self.contexts.items[i];
        if (comptime builtin.is_test == false) {
            // See v8/Env.zig for why tests always run their schedulers.
            if (ctx.scheduler.hasReadyTasks() == false) {
                continue;
            }
        }

        const entered = ctx.enter({});
        defer entered.exit();
        try ctx.scheduler.run();
    }
}

pub fn msToNextMacrotask(self: *Env) ?u64 {
    var next_task: u64 = std.math.maxInt(u64);
    for (self.contexts.items) |ctx| {
        const candidate = ctx.scheduler.msToNextHigh() orelse continue;
        next_task = @min(candidate, next_task);
    }
    return if (next_task == std.math.maxInt(u64)) null else next_task;
}

// v8's platform has a background task queue; quickjs has nothing comparable.
pub fn pumpMessageLoop(self: *const Env) void {
    _ = self;
}

pub fn hasBackgroundTasks(self: *const Env) bool {
    _ = self;
    return false;
}

pub fn waitForBackgroundTasks(self: *Env) void {
    self.runMicrotasks();
}

pub fn runIdleTasks(self: *const Env) void {
    _ = self;
}

pub fn lowMemoryNotification(self: *Env) void {
    q.JS_RunGC(self.rt);
}

pub const MemoryPressureLevel = enum(u32) {
    none = 0,
    moderate = 1,
    critical = 2,
};

pub fn memoryPressureNotification(self: *Env, level: MemoryPressureLevel) void {
    _ = level;
    q.JS_RunGC(self.rt);
}

pub fn isExecutionTerminating(self: *const Env) bool {
    return self.terminate_requested.load(.acquire);
}

pub fn terminatePending(self: *const Env) bool {
    return self.terminate_requested.load(.acquire);
}

pub fn terminate(self: *Env) void {
    self.terminate_requested.store(true, .release);
}

// Called from the network thread. The interrupt handler picks the flag up
// at the next JS interrupt check.
pub fn requestTerminate(self: *Env) void {
    self.terminate_requested.store(true, .release);
}

pub fn cancelTerminate(self: *Env) void {
    self.terminate_requested.store(false, .release);
}

pub fn dumpMemoryStats(self: *Env) void {
    var usage: q.JSMemoryUsage = undefined;
    q.JS_ComputeMemoryUsage(self.rt, &usage);
    std.debug.print(
        \\ Malloc Size: {d}
        \\ Malloc Count: {d}
        \\ Memory Used Size: {d}
        \\ Object Count: {d}
        \\
    , .{ usage.malloc_size, usage.malloc_count, usage.memory_used_size, usage.obj_count });
}

pub fn logException(qctx: *q.JSContext, comptime src: []const u8, exception: q.JSValueConst) void {
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const message = js.valueToString(fba.allocator(), qctx, exception) catch "???";
    log.warn(.js, src, .{ .message = message });
}

fn countExotics() usize {
    var count: usize = 0;
    for (JsApis) |JsApi| {
        if (hasExotics(JsApi)) {
            count += 1;
        }
    }
    return count;
}

fn hasExotics(comptime JsApi: type) bool {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(JsApi).@"struct".decls) |d| {
        const T = @TypeOf(@field(JsApi, d.name));
        if (T == bridge.Indexed or T == bridge.NamedIndexed) {
            return true;
        }
    }
    return false;
}

fn callHandler(comptime JsApi: type) @FieldType(q.JSClassDef, "call") {
    // document.all (htmldda) and callable collections both map to the
    // class' call handler. The undetectable part of htmldda has no quickjs
    // equivalent and is dropped.
    if (@hasDecl(JsApi.Meta, "htmldda")) {
        return JsApi.Meta.callable.func;
    }
    if (@hasDecl(JsApi, "callable")) {
        return JsApi.callable.func;
    }
    return null;
}

fn inRealm(comptime JsApi: type, comptime realm: bridge.Realm) bool {
    @setEvalBranchQuota(100_000);
    const list = switch (realm) {
        .window => &registry.PageJsApis,
        .worker => &registry.WorkerJsApis,
    };
    inline for (list) |Api| {
        if (Api == JsApi) return true;
    }
    return false;
}

fn protoIndexLookup(comptime JsApi: type) ?u16 {
    @setEvalBranchQuota(100_000);
    comptime {
        const T = JsApi.bridge.type;
        if (!@hasField(T, "_proto")) {
            return null;
        }
        const Ptr = std.meta.fieldInfo(T, ._proto).type;
        const F = @typeInfo(Ptr).pointer.child;
        for (JsApis, 0..) |Api, i| {
            if (Api == F.JsApi) {
                return i;
            }
        }
        @compileError("Prototype " ++ @typeName(F.JsApi) ++ " not found in API list");
    }
}

// The chain of interface types reachable from a [Global] interface via
// WebIDL inheritance, e.g. Window -> [Window.JsApi, EventTarget.JsApi].
fn globalScopeChain(comptime GlobalScopeApi: type) []const type {
    comptime {
        var chain: []const type = &[_]type{};
        var JsApi = GlobalScopeApi;
        while (true) {
            chain = chain ++ &[_]type{JsApi};
            const proto_index = protoIndexLookup(JsApi) orelse break;
            JsApi = JsApis[proto_index];
        }
        return chain;
    }
}
