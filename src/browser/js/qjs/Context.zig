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
const lp = @import("lightpanda");

const js = @import("js.zig");
const Env = @import("Env.zig");
const Origin = @import("Origin.zig");
const Scheduler = @import("../Scheduler.zig");
const Execution = @import("../Execution.zig");

const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");
const ScriptManagerBase = @import("../../ScriptManagerBase.zig");
const WorkerGlobalScope = @import("../../webapi/WorkerGlobalScope.zig");

const q = js.q;
const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

// Loosely maps to a Browser Page or Worker. Wraps a JSContext.
const Context = @This();

pub const GlobalScope = union(enum) {
    frame: *Frame,
    worker: *WorkerGlobalScope,

    pub fn base(self: GlobalScope) [:0]const u8 {
        return switch (self) {
            .frame => |frame| frame.base(),
            .worker => |worker| worker.base(),
        };
    }

    pub fn getJs(self: GlobalScope) *Context {
        return switch (self) {
            .frame => |frame| frame.js,
            .worker => |worker| worker.js,
        };
    }

    pub fn setJs(self: GlobalScope, ctx: *Context) void {
        switch (self) {
            .frame => |frame| frame.js = ctx,
            .worker => |worker| worker.js = ctx,
        }
    }
};

id: usize,
env: *Env,
global: GlobalScope,

// See v8/Context.zig for the Page vs Context relationship.
page: *Page,

ctx: *q.JSContext,

// Arena for the lifetime of the context
arena: Allocator,

// The call_arena for this context (frame.call_arena).
call_arena: Allocator,

// Calls can be nested (a function calling a callback); the call_arena is
// only reset when call_depth drops back to 0.
call_depth: usize = 0,

// When a Caller is active (JS->Zig callback), this points to its Local.
// When null, Zig->JS calls must create a js.Local.Scope via localScope.
local: ?*const js.Local = null,

origin: *Origin,

// Identity tracking. With quickjs there's only ever the main world, so
// this always points at the Page's Identity.
identity: *js.Identity,
identity_arena: Allocator,

// Emulates v8's HandleScope: every JSValue our conversion layer creates is
// pushed here, and Caller/Local.Scope free everything above their entry
// watermark on exit. Values that must outlive the scope are persisted
// (dup'd) instead.
handles: std.ArrayList(q.JSValue) = .empty,

// Top-level modules we've loaded, so a second <script type=module> with
// the same src doesn't re-evaluate. quickjs itself dedupes nested static
// imports per-context via the module loader.
module_cache: std.StringHashMapUnmanaged(void) = .empty,

// Module-loading plumbing.
script_manager: *ScriptManagerBase,

// Our macrotasks
scheduler: Scheduler,

// Execution context for worker-compatible APIs.
execution: Execution,

pub fn fromQ(qctx: ?*q.JSContext) *Context {
    return @ptrCast(@alignCast(q.JS_GetContextOpaque(qctx).?));
}

pub fn deinit(self: *Context) void {
    const env = self.env;
    defer env.app.arena_pool.release(self.arena);

    {
        const entered = self.enter({});
        defer entered.exit();

        // this can release objects
        self.scheduler.deinit();
    }

    self.page.releaseOrigin(self.origin);

    // Free anything still on the handle stack (e.g. values created during
    // scheduler teardown above).
    self.freeHandles(0);

    // Clear the opaque so a stale pointer can't be followed.
    q.JS_SetContextOpaque(self.ctx, null);
    q.JS_FreeContext(self.ctx);
    q.JS_RunGC(env.rt);
}

// Mint a PersistentHandle from an owned JSValue reference (the caller's
// ref is transferred to the handle). The slot lives on the page arena -
// handles never outlive the Page.
pub fn persist(self: *Context, value: q.JSValue) js.PersistentHandle {
    const env = self.env;
    env.persist_key += 1;
    const slot = self.page.frame_arena.create(js.PersistentSlot) catch |err| {
        // arena OOM is fatal anyway
        log.fatal(.js, "persist handle", .{ .err = err });
        unreachable;
    };
    slot.* = .{
        .value = value,
        .rt = env.rt,
        .key = env.persist_key,
    };
    return slot;
}

// == handle scope emulation ==
pub fn track(self: *Context, value: q.JSValue) void {
    if (!q.JS_VALUE_HAS_REF_COUNT(value)) {
        return;
    }
    self.handles.append(self.arena, value) catch |err| {
        // The arena allocator can only fail on OOM, which is fatal anyway.
        log.fatal(.js, "track handle", .{ .err = err });
    };
}

pub fn handleMark(self: *const Context) usize {
    return self.handles.items.len;
}

pub fn freeHandles(self: *Context, mark: usize) void {
    const items = self.handles.items;
    for (items[mark..]) |value| {
        q.JS_FreeValue(self.ctx, value);
    }
    self.handles.shrinkRetainingCapacity(mark);
}

pub fn setOrigin(self: *Context, key: ?[]const u8) !void {
    if (comptime IS_DEBUG) {
        lp.assert(self.origin.rc == 1, "Ref opaque origin", .{ .rc = self.origin.rc });
    }
    const origin = try self.page.getOrCreateOrigin(key);
    self.page.releaseOrigin(self.origin);
    self.origin = origin;
}

pub fn trackGlobal(self: *Context, handle: js.PersistentHandle) !void {
    return self.page.globals.append(self.page.frame_arena, handle);
}

pub fn trackTemp(self: *Context, handle: js.PersistentHandle) !void {
    return self.page.temps.put(self.page.frame_arena, handle.key, handle);
}

pub const IdentityResult = struct {
    value_ptr: *js.PersistentHandle,
    found_existing: bool,
};

pub fn addIdentity(self: *Context, ptr: usize) !IdentityResult {
    const gop = try self.identity.identity_map.getOrPut(self.identity_arena, ptr);
    return .{
        .value_ptr = gop.value_ptr,
        .found_existing = gop.found_existing,
    };
}

// Any operation on the context has to be made from a local.
pub fn localScope(self: *Context, ls: *js.Local.Scope) void {
    ls.* = .{
        .local = .{
            .ctx = self,
            .call_arena = self.call_arena,
        },
        .mark = self.handleMark(),
    };
}

pub fn toLocal(self: *Context, global: anytype) js.Local.ToLocalReturnType(@TypeOf(global)) {
    const l = self.local orelse @panic("toLocal called without active Caller context");
    return l.toLocal(global);
}

pub fn getIncumbent(self: *Context) *Frame {
    // quickjs has no incumbent-context tracking; the current context is the
    // best (and in a single-world engine, correct enough) answer.
    return switch (self.global) {
        .frame => |frame| frame,
        .worker => unreachable,
    };
}

pub fn stringToPersistedFunction(
    self: *Context,
    function_body: []const u8,
    comptime parameter_names: []const []const u8,
    extensions: anytype,
) !js.Function.Global {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const js_function = try ls.local.compileFunction(function_body, parameter_names, extensions);
    return js_function.persist();
}

// == modules ==
// Evaluates `src` as a module. Unlike the v8 backend, nested static
// imports and dynamic import() are driven by quickjs through the runtime
// module loader (moduleNormalize / moduleLoad below).
pub fn module(self: *Context, comptime want_result: bool, local: *const js.Local, src: []const u8, url: []const u8, cacheable: bool) !void {
    // The v8 backend returns its module-cache entry for dynamic imports;
    // with quickjs dynamic import is handled natively by the runtime's
    // module loader, so there's no result to return.
    comptime std.debug.assert(want_result == false);

    if (cacheable) {
        const gop = try self.module_cache.getOrPut(self.arena, url);
        if (gop.found_existing) {
            return;
        }
        gop.key_ptr.* = try self.arena.dupe(u8, url);
    }

    const qctx = self.ctx;
    const owned_url = try self.call_arena.dupeZ(u8, url);
    const source = try local.prepareSource(src);

    var eval_opts = q.JSEvalOptions{
        .version = q.JS_EVAL_OPTIONS_VERSION,
        .filename = owned_url.ptr,
        .line_num = 1,
        .eval_flags = q.JS_EVAL_TYPE_MODULE | q.JS_EVAL_FLAG_COMPILE_ONLY,
    };

    const js_func = q.JS_Eval2(qctx, source.ptr, source.len, &eval_opts);
    if (q.JS_IsException(js_func)) {
        q.JS_FreeValue(qctx, js_func);
        return error.JsException;
    }

    const js_mod: *q.JSModuleDef = @ptrCast(q.JS_VALUE_GET_PTR(js_func).?);
    self.setImportMeta(js_mod, owned_url);

    // JS_EvalFunction takes ownership of js_func.
    const js_promise = q.JS_EvalFunction(qctx, js_func);
    if (q.JS_IsException(js_promise)) {
        q.JS_FreeValue(qctx, js_promise);
        return error.JsException;
    }

    // Keep the evaluation promise alive for the page's lifetime, mirroring
    // the v8 backend's ModuleEntry.module_promise. A module suspended at a
    // top-level await is otherwise an unreachable cycle (suspended frame <->
    // promise graph) that cycle-GC collects MID-EXECUTION, detaching its
    // closures' var_refs over freed values.
    try self.trackGlobal(self.persist(js_promise));

    local.runMicrotasks();
}

fn setImportMeta(self: *Context, js_mod: *q.JSModuleDef, url: [:0]const u8) void {
    const qctx = self.ctx;
    const meta = q.JS_GetImportMeta(qctx, js_mod);
    defer q.JS_FreeValue(qctx, meta);
    // The URL has to outlive this call; dupe onto the context arena.
    const owned = self.arena.dupeZ(u8, url) catch return;
    _ = q.JS_DefinePropertyValueStr(qctx, meta, "url", q.JS_NewString(qctx, owned.ptr), q.JS_PROP_C_W_E);
}

// Callback from quickjs: resolve a specifier relative to its importer.
pub fn moduleNormalize(qctx: ?*q.JSContext, base_name: [*c]const u8, name: [*c]const u8, _: ?*anyopaque) callconv(.c) [*c]u8 {
    const self = fromQ(qctx);
    const normalized = self.script_manager.resolveSpecifier(
        self.call_arena,
        std.mem.span(base_name),
        std.mem.span(name),
    ) catch |err| {
        log.warn(.js, "module normalize", .{
            .err = err,
            .base = std.mem.span(base_name),
            .name = std.mem.span(name),
        });
        return null;
    };
    // quickjs frees this, so it must be allocated with js_malloc.
    return q.js_strndup(qctx, normalized.ptr, normalized.len);
}

// Callback from quickjs: load (and compile) the module's source. This is
// synchronous - the script manager blocks on the fetch.
pub fn moduleLoad(qctx: ?*q.JSContext, name: [*c]const u8, _: ?*anyopaque) callconv(.c) ?*q.JSModuleDef {
    const self = fromQ(qctx);
    const zname = std.mem.span(name);

    var source = self.script_manager.waitForImport(sliceZ(zname)) catch |err| switch (err) {
        error.UnknownModule => blk: {
            // Nothing prefetched this module yet (quickjs resolves imports
            // lazily); start the fetch and wait for it.
            self.script_manager.preloadImport(sliceZ(zname), zname, .{}) catch |perr| {
                return throwModuleError(qctx.?, zname, perr);
            };
            break :blk self.script_manager.waitForImport(sliceZ(zname)) catch |werr| {
                return throwModuleError(qctx.?, zname, werr);
            };
        },
        else => return throwModuleError(qctx.?, zname, err),
    };
    defer source.deinit();

    const local = js.Local{ .ctx = self, .call_arena = self.call_arena };
    const src = local.prepareSource(source.src()) catch return null;
    var eval_opts = q.JSEvalOptions{
        .version = q.JS_EVAL_OPTIONS_VERSION,
        .filename = name,
        .line_num = 1,
        .eval_flags = q.JS_EVAL_TYPE_MODULE | q.JS_EVAL_FLAG_COMPILE_ONLY,
    };
    const js_func = q.JS_Eval2(qctx, src.ptr, src.len, &eval_opts);
    if (q.JS_IsException(js_func)) {
        q.JS_FreeValue(qctx.?, js_func);
        return null;
    }

    const js_mod: *q.JSModuleDef = @ptrCast(q.JS_VALUE_GET_PTR(js_func).?);
    self.setImportMeta(js_mod, sliceZ(zname));

    // The module definition survives; the wrapping value doesn't need to.
    q.JS_FreeValue(qctx.?, js_func);
    return js_mod;
}

fn sliceZ(s: []const u8) [:0]const u8 {
    // std.mem.span on a [*c] already guarantees the sentinel in memory.
    return s.ptr[0..s.len :0];
}

fn throwModuleError(qctx: *q.JSContext, name: []const u8, err: anyerror) ?*q.JSModuleDef {
    log.warn(.js, "module load", .{ .name = name, .err = err });
    const js_err = q.JS_ThrowTypeError(qctx, "Failed to load module: %s", @errorName(err).ptr);
    q.JS_FreeValue(qctx, js_err);
    return null;
}

pub fn promiseRejectionTracker(
    qctx_: ?*q.JSContext,
    promise: q.JSValueConst,
    reason: q.JSValueConst,
    is_handled: bool,
    _: ?*anyopaque,
) callconv(.c) void {
    const qctx = qctx_.?;
    const self: *Context = @ptrCast(@alignCast(q.JS_GetContextOpaque(qctx) orelse return));

    const local = js.Local{
        .ctx = self,
        .call_arena = self.call_arena,
    };

    const rejection = js.PromiseRejection{
        .local = &local,
        .promise_handle = promise,
        .reason_handle = reason,
    };

    const no_handler = !is_handled;
    switch (self.global) {
        .frame => |frame| {
            frame.window.unhandledPromiseRejection(no_handler, rejection, frame) catch |err| {
                log.warn(.browser, "unhandled rejection handler", .{ .err = err, .target = "window" });
            };
        },
        .worker => |wsg| {
            wsg.unhandledPromiseRejection(no_handler, rejection) catch |err| {
                log.warn(.browser, "unhandled rejection handler", .{ .err = err, .target = "worker" });
            };
        },
    }
}

// Used to temporarily enter and exit a context, updating and restoring
// frame.js:
//    const entered = ctx.enter();
//    defer entered.exit();
pub fn enter(self: *Context, hs: anytype) Entered {
    _ = hs; // v8 needs a HandleScope here; quickjs has no equivalent
    const original = self.global.getJs();
    self.global.setJs(self);
    return .{
        .ctx = self,
        .original = original,
        .global = self.global,
        .mark = self.handleMark(),
    };
}

const Entered = struct {
    ctx: *Context,
    original: *Context,
    global: GlobalScope,
    mark: usize,

    pub fn exit(self: Entered) void {
        self.ctx.freeHandles(self.mark);
        self.global.setJs(self.original);
    }
};

pub fn queueMutationDelivery(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| Frame.observers.deliverMutations(frame),
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueIntersectionChecks(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| Frame.observers.performScheduledIntersectionChecks(frame),
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueIntersectionDelivery(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| Frame.observers.deliverIntersections(frame),
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueSlotchangeDelivery(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| frame.deliverSlotchangeEvents(),
                .worker => unreachable,
            }
        }
    }.run);
}

pub fn queueCustomElementBackupDrain(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            switch (ctx.global) {
                .frame => |frame| frame._ce_reactions.drainBackup(frame),
                .worker => unreachable,
            }
        }
    }.run);
}

fn enqueueMicrotask(self: *Context, comptime callback: anytype) void {
    const ret = q.JS_EnqueueJob(self.ctx, struct {
        fn run(qctx: ?*q.JSContext, _: c_int, _: [*c]q.JSValueConst) callconv(.c) q.JSValue {
            const ctx: *Context = @ptrCast(@alignCast(q.JS_GetContextOpaque(qctx) orelse return js.UNDEFINED));
            const entered = ctx.enter({});
            defer entered.exit();
            callback(ctx);
            return js.UNDEFINED;
        }
    }.run, 0, null);
    if (ret < 0) {
        // can only fail on OOM, which is fatal anyway
        log.fatal(.js, "enqueue microtask", .{});
    }
}

pub fn queueMicrotaskFunc(self: *Context, cb: js.Function) void {
    var args = [_]q.JSValue{cb.handle};
    const ret = q.JS_EnqueueJob(self.ctx, struct {
        fn run(qctx: ?*q.JSContext, argc: c_int, argv: [*c]q.JSValueConst) callconv(.c) q.JSValue {
            std.debug.assert(argc == 1);
            const ctx: *Context = @ptrCast(@alignCast(q.JS_GetContextOpaque(qctx) orelse return js.UNDEFINED));
            const entered = ctx.enter({});
            defer entered.exit();
            const ret = q.JS_Call(qctx, argv[0], js.UNDEFINED, 0, null);
            if (q.JS_IsException(ret)) {
                return ret;
            }
            q.JS_FreeValue(qctx, ret);
            return js.UNDEFINED;
        }
    }.run, args.len, &args);
    if (ret < 0) {
        log.err(.js, "queue microtask", .{});
    }
}
