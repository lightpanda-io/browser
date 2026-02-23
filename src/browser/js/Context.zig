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
const lp = @import("lightpanda");
const log = @import("../../log.zig");

const js = @import("js.zig");
const Env = @import("Env.zig");
const bridge = @import("bridge.zig");
const Scheduler = @import("Scheduler.zig");

const Page = @import("../Page.zig");
const ScriptManager = @import("../ScriptManager.zig");

const v8 = js.v8;
const Caller = js.Caller;

const Allocator = std.mem.Allocator;

const IS_DEBUG = @import("builtin").mode == .Debug;

// Loosely maps to a Browser Page.
const Context = @This();

id: usize,
env: *Env,
page: *Page,
isolate: js.Isolate,

// Per-context microtask queue for isolation between contexts
microtask_queue: *v8.MicrotaskQueue,

// The v8::Global<v8::Context>. When necessary, we can create a v8::Local<<v8::Context>>
// from this, and we can free it when the context is done.
handle: v8.Global,

cpu_profiler: ?*v8.CpuProfiler = null,

heap_profiler: ?*v8.HeapProfiler = null,

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

// When a Caller is active (V8->Zig callback), this points to its Local.
// When null, Zig->V8 calls must create a js.Local.Scope and initialize via
// context.localScope
local: ?*const js.Local = null,

// Serves two purposes. Like `global_objects`, this is used to free
// every Global(Object) we've created during the lifetime of the context.
// More importantly, it serves as an identity map - for a given Zig
// instance, we map it to the same Global(Object).
// The key is the @intFromPtr of the Zig value
identity_map: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,

// Any type that is stored in the identity_map which has a finalizer declared
// will have its finalizer stored here. This is only used when shutting down
// if v8 hasn't called the finalizer directly itself.
finalizer_callbacks: std.AutoHashMapUnmanaged(usize, *FinalizerCallback) = .empty,
finalizer_callback_pool: std.heap.MemoryPool(FinalizerCallback),

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

// Temp variants stored in HashMaps for O(1) early cleanup.
// Key is global.data_ptr.
global_values_temp: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,
global_promises_temp: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,
global_functions_temp: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,

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

// Our macrotasks
scheduler: Scheduler,

unknown_properties: (if (IS_DEBUG) std.StringHashMapUnmanaged(UnknownPropertyStat) else void) = if (IS_DEBUG) .{} else {},

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
    return @ptrCast(@alignCast(v8.v8__Context__GetAlignedPointerFromEmbedderData(c_context, 1)));
}

pub fn fromIsolate(isolate: js.Isolate) *Context {
    return fromC(v8.v8__Isolate__GetCurrentContext(isolate.handle).?);
}

pub fn deinit(self: *Context) void {
    if (comptime IS_DEBUG) {
        var it = self.unknown_properties.iterator();
        while (it.next()) |kv| {
            log.debug(.unknown_prop, "unknown property", .{
                .property = kv.key_ptr.*,
                .occurrences = kv.value_ptr.count,
                .first_stack = kv.value_ptr.first_stack,
            });
        }
    }

    const env = self.env;
    defer env.app.arena_pool.release(self.arena);

    var hs: js.HandleScope = undefined;
    const entered = self.enter(&hs);
    defer entered.exit();

    // this can release objects
    self.scheduler.deinit();

    {
        var it = self.identity_map.valueIterator();
        while (it.next()) |global| {
            v8.v8__Global__Reset(global);
        }
    }
    {
        var it = self.finalizer_callbacks.valueIterator();
        while (it.next()) |finalizer| {
            finalizer.*.deinit();
        }
        self.finalizer_callback_pool.deinit();
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

    {
        var it = self.global_values_temp.valueIterator();
        while (it.next()) |global| {
            v8.v8__Global__Reset(global);
        }
    }

    {
        var it = self.global_promises_temp.valueIterator();
        while (it.next()) |global| {
            v8.v8__Global__Reset(global);
        }
    }

    {
        var it = self.global_functions_temp.valueIterator();
        while (it.next()) |global| {
            v8.v8__Global__Reset(global);
        }
    }

    v8.v8__Global__Reset(&self.handle);
    env.isolate.notifyContextDisposed();
    // There can be other tasks associated with this context that we need to
    // purge while the context is still alive.
    env.pumpMessageLoop();
    v8.v8__MicrotaskQueue__DELETE(self.microtask_queue);
}

pub fn weakRef(self: *Context, obj: anytype) void {
    const fc = self.finalizer_callbacks.get(@intFromPtr(obj)) orelse {
        if (comptime IS_DEBUG) {
            // should not be possible
            std.debug.assert(false);
        }
        return;
    };
    v8.v8__Global__SetWeakFinalizer(&fc.global, fc, bridge.Struct(@TypeOf(obj)).JsApi.Meta.finalizer.from_v8, v8.kParameter);
}

pub fn safeWeakRef(self: *Context, obj: anytype) void {
    const fc = self.finalizer_callbacks.get(@intFromPtr(obj)) orelse {
        if (comptime IS_DEBUG) {
            // should not be possible
            std.debug.assert(false);
        }
        return;
    };
    v8.v8__Global__ClearWeak(&fc.global);
    v8.v8__Global__SetWeakFinalizer(&fc.global, fc, bridge.Struct(@TypeOf(obj)).JsApi.Meta.finalizer.from_v8, v8.kParameter);
}

pub fn strongRef(self: *Context, obj: anytype) void {
    const fc = self.finalizer_callbacks.get(@intFromPtr(obj)) orelse {
        if (comptime IS_DEBUG) {
            // should not be possible
            std.debug.assert(false);
        }
        return;
    };
    v8.v8__Global__ClearWeak(&fc.global);
}

pub fn release(self: *Context, item: anytype) void {
    if (@TypeOf(item) == *anyopaque) {
        // Existing *anyopaque path for identity_map. Called internally from
        // finalizers
        var global = self.identity_map.fetchRemove(@intFromPtr(item)) orelse {
            if (comptime IS_DEBUG) {
                // should not be possible
                std.debug.assert(false);
            }
            return;
        };
        v8.v8__Global__Reset(&global.value);

        // The item has been fianalized, remove it for the finalizer callback so that
        // we don't try to call it again on shutdown.
        const fc = self.finalizer_callbacks.fetchRemove(@intFromPtr(item)) orelse {
            if (comptime IS_DEBUG) {
                // should not be possible
                std.debug.assert(false);
            }
            return;
        };
        self.finalizer_callback_pool.destroy(fc.value);
        return;
    }

    var map = switch (@TypeOf(item)) {
        js.Value.Temp => &self.global_values_temp,
        js.Promise.Temp => &self.global_promises_temp,
        js.Function.Temp => &self.global_functions_temp,
        else => |T| @compileError("Context.release cannot be called with a " ++ @typeName(T)),
    };

    if (map.fetchRemove(item.handle.data_ptr)) |kv| {
        var global = kv.value;
        v8.v8__Global__Reset(&global);
    }
}

// Any operation on the context have to be made from a local.
pub fn localScope(self: *Context, ls: *js.Local.Scope) void {
    const isolate = self.isolate;
    js.HandleScope.init(&ls.handle_scope, isolate);

    const local_v8_context: *const v8.Context = @ptrCast(v8.v8__Global__Get(&self.handle, isolate.handle));
    v8.v8__Context__Enter(local_v8_context);

    // TODO: add and init ls.hs  for the handlescope
    ls.local = .{
        .ctx = self,
        .isolate = isolate,
        .handle = local_v8_context,
        .call_arena = self.call_arena,
    };
}

pub fn toLocal(self: *Context, global: anytype) js.Local.ToLocalReturnType(@TypeOf(global)) {
    const l = self.local orelse @panic("toLocal called without active Caller context");
    return l.toLocal(global);
}

// This isn't expected to be called often. It's for converting attributes into
// function calls, e.g. <body onload="doSomething"> will turn that "doSomething"
// string into a js.Function which looks like: function(e) { doSomething(e) }
// There might be more efficient ways to do this, but doing it this way means
// our code only has to worry about js.Funtion, not some union of a js.Function
// or a string.
pub fn stringToPersistedFunction(self: *Context, str: []const u8) !js.Function.Global {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    var extra: []const u8 = "";
    const normalized = std.mem.trim(u8, str, &std.ascii.whitespace);
    if (normalized.len > 0 and normalized[normalized.len - 1] != ')') {
        extra = "(e)";
    }
    const full = try std.fmt.allocPrintSentinel(self.call_arena, "(function(e) {{ {s}{s} }})", .{ normalized, extra }, 0);
    const js_val = try ls.local.compileAndRun(full, null);
    if (!js_val.isFunction()) {
        return error.StringFunctionError;
    }
    return try (js.Function{ .local = &ls.local, .handle = @ptrCast(js_val.handle) }).persist();
}

pub fn module(self: *Context, comptime want_result: bool, local: *const js.Local, src: []const u8, url: []const u8, cacheable: bool) !(if (want_result) ModuleEntry else void) {
    const mod, const owned_url = blk: {
        const arena = self.arena;

        // gop will _always_ initiated if cacheable == true
        var gop: std.StringHashMapUnmanaged(ModuleEntry).GetOrPutResult = undefined;
        if (cacheable) {
            gop = try self.module_cache.getOrPut(arena, url);
            if (gop.found_existing) {
                if (gop.value_ptr.module) |cache_mod| {
                    if (gop.value_ptr.module_promise == null) {
                        // This an usual case, but it can happen if a module is
                        // first asynchronously requested and then synchronously
                        // requested as a child of some root import. In that case,
                        // the module may not be instantiated yet (so we have to
                        // do that). It might not be evaluated yet. So we have
                        // to do that too. Evaluation is particularly important
                        // as it sets up our cache entry's module_promise.
                        // It appears that v8 handles potential double-instantiated
                        // and double-evaluated modules safely. The 2nd instantiation
                        // is a no-op, and the second evaluation returns the same
                        // promise.
                        const mod = local.toLocal(cache_mod);
                        if (mod.getStatus() == .kUninstantiated and try mod.instantiate(resolveModuleCallback) == false) {
                            return error.ModuleInstantiationError;
                        }
                        return self.evaluateModule(want_result, mod, url, true);
                    }
                    return if (comptime want_result) gop.value_ptr.* else {};
                }
            } else {
                // first time seeing this
                gop.value_ptr.* = .{};
            }
        }

        const owned_url = try arena.dupeZ(u8, url);
        const m = try compileModule(local, src, owned_url);

        if (cacheable) {
            // compileModule is synchronous - nothing can modify the cache during compilation
            lp.assert(gop.value_ptr.module == null, "Context.module has module", .{});
            gop.value_ptr.module = try m.persist();
            if (!gop.found_existing) {
                gop.key_ptr.* = owned_url;
            }
        }

        break :blk .{ m, owned_url };
    };

    try self.postCompileModule(mod, owned_url, local);

    if (try mod.instantiate(resolveModuleCallback) == false) {
        return error.ModuleInstantiationError;
    }

    return self.evaluateModule(want_result, mod, owned_url, cacheable);
}

fn evaluateModule(self: *Context, comptime want_result: bool, mod: js.Module, url: []const u8, cacheable: bool) !(if (want_result) ModuleEntry else void) {
    const evaluated = mod.evaluate() catch {
        if (comptime IS_DEBUG) {
            std.debug.assert(mod.getStatus() == .kErrored);
        }

        // Some module-loading errors aren't handled by TryCatch. We need to
        // get the error from the module itself.
        const message = blk: {
            const e = mod.getException().toString() catch break :blk "???";
            break :blk e.toSlice() catch "???";
        };
        log.warn(.js, "evaluate module", .{
            .message = message,
            .specifier = url,
        });
        return error.EvaluationError;
    };

    // https://v8.github.io/api/head/classv8_1_1Module.html#a1f1758265a4082595757c3251bb40e0f
    // Must be a promise that gets returned here.
    lp.assert(evaluated.isPromise(), "Context.module non-promise", .{});

    if (!cacheable) {
        switch (comptime want_result) {
            false => return,
            true => unreachable,
        }
    }

    // entry has to have been created atop this function
    const entry = self.module_cache.getPtr(url).?;

    // and the module must have been set after we compiled it
    lp.assert(entry.module != null, "Context.module with module", .{});
    if (entry.module_promise != null) {
        // While loading this script, it's possible that it was dynamically
        // included (either the module dynamically loaded itself (unlikely) or
        // it included a script which dynamically imported it). If it was, then
        // the module_promise would already be setup, and we don't need to do
        // anything
    } else {
        // The *much* more likely case where the module we're trying to load
        // didn't [directly or indirectly] dynamically load itself.
        entry.module_promise = try evaluated.toPromise().persist();
    }
    return if (comptime want_result) entry.* else {};
}

fn compileModule(local: *const js.Local, src: []const u8, name: []const u8) !js.Module {
    var origin_handle: v8.ScriptOrigin = undefined;
    v8.v8__ScriptOrigin__CONSTRUCT2(
        &origin_handle,
        local.isolate.initStringHandle(name),
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
        local.isolate.initStringHandle(src),
        &origin_handle,
        null, // cached data
        &source_handle,
    );

    defer v8.v8__ScriptCompiler__Source__DESTRUCT(&source_handle);

    const module_handle = v8.v8__ScriptCompiler__CompileModule(
        local.isolate.handle,
        &source_handle,
        v8.kNoCompileOptions,
        v8.kNoCacheNoReason,
    ) orelse {
        return error.JsException;
    };

    return .{
        .local = local,
        .handle = module_handle,
    };
}

// After we compile a module, whether it's a top-level one, or a nested one,
// we always want to track its identity (so that, if this module imports other
// modules, we can resolve the full URL), and preload any dependent modules.
fn postCompileModule(self: *Context, mod: js.Module, url: [:0]const u8, local: *const js.Local) !void {
    try self.module_identifier.putNoClobber(self.arena, mod.getIdentityHash(), url);

    // Non-async modules are blocking. We can download them in parallel, but
    // they need to be processed serially. So we want to get the list of
    // dependent modules this module has and start downloading them asap.
    const requests = mod.getModuleRequests();
    const request_len = requests.len();
    const script_manager = self.script_manager.?;
    for (0..request_len) |i| {
        const specifier = requests.get(i).specifier(local);
        const normalized_specifier = try script_manager.resolveSpecifier(
            self.call_arena,
            url,
            try specifier.toSliceZ(),
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

fn newFunctionWithData(local: *const js.Local, comptime callback: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void, data: *anyopaque) js.Function {
    const external = local.isolate.createExternal(data);
    const handle = v8.v8__Function__New__DEFAULT2(local.handle, callback, @ptrCast(external)).?;
    return .{
        .local = local,
        .handle = handle,
    };
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
    const local = js.Local{
        .ctx = self,
        .handle = c_context.?,
        .isolate = self.isolate,
        .call_arena = self.call_arena,
    };

    const specifier = js.String.toSliceZ(.{ .local = &local, .handle = c_specifier.? }) catch |err| {
        log.err(.js, "resolve module", .{ .err = err });
        return null;
    };
    const referrer = js.Module{ .local = &local, .handle = c_referrer.? };

    return self._resolveModuleCallback(referrer, specifier, &local) catch |err| {
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
    const local = js.Local{
        .ctx = self,
        .handle = c_context.?,
        .call_arena = self.call_arena,
        .isolate = self.isolate,
    };

    const resource = js.String.toSliceZ(.{ .local = &local, .handle = resource_name.? }) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback1" });
        return @constCast((local.rejectPromise("Out of memory") catch return null).handle);
    };

    const specifier = js.String.toSliceZ(.{ .local = &local, .handle = v8_specifier.? }) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback2" });
        return @constCast((local.rejectPromise("Out of memory") catch return null).handle);
    };

    const normalized_specifier = self.script_manager.?.resolveSpecifier(
        self.arena, // might need to survive until the module is loaded
        resource,
        specifier,
    ) catch |err| {
        log.err(.app, "OOM", .{ .err = err, .src = "dynamicModuleCallback3" });
        return @constCast((local.rejectPromise("Out of memory") catch return null).handle);
    };

    const promise = self._dynamicModuleCallback(normalized_specifier, resource, &local) catch |err| blk: {
        log.err(.js, "dynamic module callback", .{
            .err = err,
        });
        break :blk local.rejectPromise("Failed to load module") catch return null;
    };
    return @constCast(promise.handle);
}

pub fn metaObjectCallback(c_context: ?*v8.Context, c_module: ?*v8.Module, c_meta: ?*v8.Value) callconv(.c) void {
    // @HandleScope  implement this without a fat context/local..
    const self = fromC(c_context.?);
    var local = js.Local{
        .ctx = self,
        .handle = c_context.?,
        .isolate = self.isolate,
        .call_arena = self.call_arena,
    };

    const m = js.Module{ .local = &local, .handle = c_module.? };
    const meta = js.Object{ .local = &local, .handle = @ptrCast(c_meta.?) };

    const url = self.module_identifier.get(m.getIdentityHash()) orelse {
        // Shouldn't be possible.
        log.err(.js, "import meta", .{ .err = error.UnknownModuleReferrer });
        return;
    };

    const js_value = local.zigValueToJs(url, .{}) catch {
        log.err(.js, "import meta", .{ .err = error.FailedToConvertUrl });
        return;
    };
    const res = meta.defineOwnProperty("url", js_value, 0) orelse false;
    if (!res) {
        log.err(.js, "import meta", .{ .err = error.FailedToSet });
    }
}

fn _resolveModuleCallback(self: *Context, referrer: js.Module, specifier: [:0]const u8, local: *const js.Local) !?*const v8.Module {
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
        return local.toLocal(m).handle;
    }

    var source = try self.script_manager.?.waitForImport(normalized_specifier);
    defer source.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const mod = try compileModule(local, source.src(), normalized_specifier);
    try self.postCompileModule(mod, normalized_specifier, local);
    entry.module = try mod.persist();
    // Note: We don't instantiate/evaluate here - V8 will handle instantiation
    // as part of the parent module's dependency chain. If there's a resolver
    // waiting, it will be handled when the module is eventually evaluated
    // (either as a top-level module or when accessed via dynamic import)
    return mod.handle;
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

fn _dynamicModuleCallback(self: *Context, specifier: [:0]const u8, referrer: []const u8, local: *const js.Local) !js.Promise {
    const gop = try self.module_cache.getOrPut(self.arena, specifier);
    if (gop.found_existing) {
        if (gop.value_ptr.resolver_promise) |rp| {
            return local.toLocal(rp);
        }
    }

    const resolver = local.createPromiseResolver();
    const state = try self.arena.create(DynamicModuleResolveState);

    state.* = .{
        .module = null,
        .context = self,
        .specifier = specifier,
        .context_id = self.id,
        .resolver = try resolver.persist(),
    };

    const promise = resolver.promise();

    if (!gop.found_existing or gop.value_ptr.module == null) {
        // Either this is a completely new module, or it's an entry that was
        // created (e.g., in postCompileModule) but not yet loaded
        // this module hasn't been seen before. This is the most
        // complicated path.

        // First, we'll setup a bare entry into our cache. This will
        // prevent anyone one else from trying to asynchronously load
        // it. Instead, they can just return our promise.
        gop.value_ptr.* = ModuleEntry{
            .module = null,
            .module_promise = null,
            .resolver_promise = try promise.persist(),
        };

        // Next, we need to actually load it.
        self.script_manager.?.getAsyncImport(specifier, dynamicModuleSourceCallback, state, referrer) catch |err| {
            const error_msg = local.newString(@errorName(err));
            _ = resolver.reject("dynamic module get async", error_msg);
        };

        // For now, we're done. but this will be continued in
        // `dynamicModuleSourceCallback`, once the source for the module is loaded.
        return promise;
    }

    // we might update the map, so we might need to re-fetch this.
    var entry = gop.value_ptr;

    // So we have a module, but no async resolver. This can only
    // happen if the module was first synchronously loaded (Does that
    // ever even happen?!) You'd think we can just return the module
    // but no, we need to resolve the module namespace, and the
    // module could still be loading!
    // We need to do part of what the first case is going to do in
    // `dynamicModuleSourceCallback`, but we can skip some steps
    // since the module is already loaded,
    lp.assert(gop.value_ptr.module != null, "Context._dynamicModuleCallback has module", .{});

    // If the module hasn't been evaluated yet (it was only instantiated
    // as a static import dependency), we need to evaluate it now.
    if (entry.module_promise == null) {
        const mod = local.toLocal(gop.value_ptr.module.?);
        const status = mod.getStatus();
        if (status == .kEvaluated or status == .kEvaluating) {
            // Module was already evaluated (shouldn't normally happen, but handle it).
            // Create a pre-resolved promise with the module namespace.
            const module_resolver = local.createPromiseResolver();
            module_resolver.resolve("resolve module", mod.getModuleNamespace());
            _ = try module_resolver.persist();
            entry.module_promise = try module_resolver.promise().persist();
        } else {
            // the module was loaded, but not evaluated, we _have_ to evaluate it now
            const evaluated = mod.evaluate() catch {
                if (comptime IS_DEBUG) {
                    std.debug.assert(status == .kErrored);
                }
                _ = resolver.reject("module evaluation", local.newString("Module evaluation failed"));
                return promise;
            };
            lp.assert(evaluated.isPromise(), "Context._dynamicModuleCallback non-promise", .{});
            // mod.evaluate can invalidate or gop
            entry = self.module_cache.getPtr(specifier).?;
            entry.module_promise = try evaluated.toPromise().persist();
        }
    }

    // like before, we want to set this up so that if anything else
    // tries to load this module, it can just return our promise
    // since we're going to be doing all the work.
    entry.resolver_promise = try promise.persist();

    // But we can skip direclty to `resolveDynamicModule` which is
    // what the above callback will eventually do.
    self.resolveDynamicModule(state, entry.*, local);
    return promise;
}

fn dynamicModuleSourceCallback(ctx: *anyopaque, module_source_: anyerror!ScriptManager.ModuleSource) void {
    const state: *DynamicModuleResolveState = @ptrCast(@alignCast(ctx));
    var self = state.context;

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const local = &ls.local;

    var ms = module_source_ catch |err| {
        _ = local.toLocal(state.resolver).reject("dynamic module source", local.newString(@errorName(err)));
        return;
    };

    const module_entry = blk: {
        defer ms.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        break :blk self.module(true, local, ms.src(), state.specifier, true) catch |err| {
            const caught = try_catch.caughtOrError(self.call_arena, err);
            log.err(.js, "module compilation failed", .{
                .caught = caught,
                .specifier = state.specifier,
            });
            _ = local.toLocal(state.resolver).reject("dynamic compilation failure", local.newString(caught.exception orelse ""));
            return;
        };
    };

    self.resolveDynamicModule(state, module_entry, local);
}

fn resolveDynamicModule(self: *Context, state: *DynamicModuleResolveState, module_entry: ModuleEntry, local: *const js.Local) void {
    defer local.runMicrotasks();

    // we can only be here if the module has been evaluated and if
    // we have a resolve loading this asynchronously.
    lp.assert(module_entry.module_promise != null, "Context.resolveDynamicModule has module_promise", .{});
    lp.assert(module_entry.resolver_promise != null, "Context.resolveDynamicModule has resolver_promise", .{});
    if (comptime IS_DEBUG) {
        std.debug.assert(self.module_cache.contains(state.specifier));
    }
    state.module = module_entry.module.?;

    // We've gotten the source for the module and are evaluating it.
    // You might think we're done, but the module evaluation is
    // itself asynchronous. We need to chain to the module's own
    // promise. When the module is evaluated, it resolves to the
    // last value of the module. But, for module loading, we need to
    // resolve to the module's namespace.

    const then_callback = newFunctionWithData(local, struct {
        pub fn callback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(callback_handle).?;
            var c: Caller = undefined;
            c.init(isolate);
            defer c.deinit();

            const info_data = v8.v8__FunctionCallbackInfo__Data(callback_handle).?;
            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(v8.v8__External__Value(@ptrCast(info_data))));

            if (s.context_id != c.local.ctx.id) {
                // The microtask is tied to the isolate, not the context
                // it can be resolved while another context is active
                // (Which seems crazy to me). If that happens, then
                // another page was loaded and we MUST ignore this
                // (most of the fields in state are not valid)
                return;
            }
            const l = c.local;
            defer l.runMicrotasks();
            const namespace = l.toLocal(s.module.?).getModuleNamespace();
            _ = l.toLocal(s.resolver).resolve("resolve namespace", namespace);
        }
    }.callback, @ptrCast(state));

    const catch_callback = newFunctionWithData(local, struct {
        pub fn callback(callback_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(callback_handle).?;
            var c: Caller = undefined;
            c.init(isolate);
            defer c.deinit();

            const info_data = v8.v8__FunctionCallbackInfo__Data(callback_handle).?;
            const s: *DynamicModuleResolveState = @ptrCast(@alignCast(v8.v8__External__Value(@ptrCast(info_data))));

            const l = &c.local;
            const ctx = l.ctx;
            if (s.context_id != ctx.id) {
                return;
            }

            defer l.runMicrotasks();
            _ = l.toLocal(s.resolver).reject("catch callback", js.Value{
                .local = l,
                .handle = v8.v8__FunctionCallbackInfo__Data(callback_handle).?,
            });
        }
    }.callback, @ptrCast(state));

    _ = local.toLocal(module_entry.module_promise.?).thenAndCatch(then_callback, catch_callback) catch |err| {
        log.err(.js, "module evaluation is promise", .{
            .err = err,
            .specifier = state.specifier,
        });
        _ = local.toLocal(state.resolver).reject("module promise", local.newString("Failed to evaluate promise"));
    };
}

// Used to make temporarily enter and exit a context, updating and restoring
// page.js:
//    var hs: js.HandleScope = undefined;
//    const entered = ctx.enter(&hs);
//    defer entered.exit();
pub fn enter(self: *Context, hs: *js.HandleScope) Entered {
    const isolate = self.isolate;
    js.HandleScope.init(hs, isolate);

    const page = self.page;
    const original = page.js;
    page.js = self;

    const handle: *const v8.Context = @ptrCast(v8.v8__Global__Get(&self.handle, isolate.handle));
    v8.v8__Context__Enter(handle);
    return .{ .original = original, .handle = handle, .handle_scope = hs };
}

const Entered = struct {
    // the context we should restore on the page
    original: *Context,

    // the handle of the entered context
    handle: *const v8.Context,

    handle_scope: *js.HandleScope,

    pub fn exit(self: Entered) void {
        self.original.page.js = self.original;
        v8.v8__Context__Exit(self.handle);
        self.handle_scope.deinit();
    }
};

pub fn queueMutationDelivery(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            ctx.page.deliverMutations();
        }
    }.run);
}

pub fn queueIntersectionChecks(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            ctx.page.performScheduledIntersectionChecks();
        }
    }.run);
}

pub fn queueIntersectionDelivery(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            ctx.page.deliverIntersections();
        }
    }.run);
}

pub fn queueSlotchangeDelivery(self: *Context) !void {
    self.enqueueMicrotask(struct {
        fn run(ctx: *Context) void {
            ctx.page.deliverSlotchangeEvents();
        }
    }.run);
}

// Helper for executing a Microtask on this Context. In V8, microtasks aren't
// associated to a Context - they are just functions to execute in an Isolate.
// But for these Context microtasks, we want to (a) make sure the context isn't
// being shut down and (b) that it's entered.
fn enqueueMicrotask(self: *Context, callback: anytype) void {
    // Use context-specific microtask queue instead of isolate queue
    v8.v8__MicrotaskQueue__EnqueueMicrotask(self.microtask_queue, self.isolate.handle, struct {
        fn run(data: ?*anyopaque) callconv(.c) void {
            const ctx: *Context = @ptrCast(@alignCast(data.?));
            var hs: js.HandleScope = undefined;
            const entered = ctx.enter(&hs);
            defer entered.exit();
            callback(ctx);
        }
    }.run, self);
}

pub fn queueMicrotaskFunc(self: *Context, cb: js.Function) void {
    // Use context-specific microtask queue instead of isolate queue
    v8.v8__MicrotaskQueue__EnqueueMicrotaskFunc(self.microtask_queue, self.isolate.handle, cb.handle);
}

pub fn createFinalizerCallback(self: *Context, global: v8.Global, ptr: *anyopaque, finalizerFn: *const fn (ptr: *anyopaque, page: *Page) void) !*FinalizerCallback {
    const fc = try self.finalizer_callback_pool.create();
    fc.* = .{
        .ctx = self,
        .ptr = ptr,
        .global = global,
        .finalizerFn = finalizerFn,
    };
    return fc;
}

// == Misc ==
// A type that has a finalizer can have its finalizer called one of two ways.
// The first is from V8 via the WeakCallback we give to weakRef. But that isn't
// guaranteed to fire, so we track this in ctx._finalizers and call them on
// context shutdown.
pub const FinalizerCallback = struct {
    ctx: *Context,
    ptr: *anyopaque,
    global: v8.Global,
    finalizerFn: *const fn (ptr: *anyopaque, page: *Page) void,

    pub fn deinit(self: *FinalizerCallback) void {
        self.finalizerFn(self.ptr, self.ctx.page);
        self.ctx.finalizer_callback_pool.destroy(self);
    }
};

// == Profiler ==
pub fn startCpuProfiler(self: *Context) void {
    if (comptime !IS_DEBUG) {
        // Still testing this out, don't have it properly exposed, so add this
        // guard for the time being to prevent any accidental/weird prod issues.
        @compileError("CPU Profiling is only available in debug builds");
    }

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    std.debug.assert(self.cpu_profiler == null);
    v8.v8__CpuProfiler__UseDetailedSourcePositionsForProfiling(self.isolate.handle);

    const cpu_profiler = v8.v8__CpuProfiler__Get(self.isolate.handle).?;
    const title = self.isolate.initStringHandle("v8_cpu_profile");
    v8.v8__CpuProfiler__StartProfiling(cpu_profiler, title);
    self.cpu_profiler = cpu_profiler;
}

pub fn stopCpuProfiler(self: *Context) ![]const u8 {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const title = self.isolate.initStringHandle("v8_cpu_profile");
    const handle = v8.v8__CpuProfiler__StopProfiling(self.cpu_profiler.?, title) orelse return error.NoProfiles;
    const string_handle = v8.v8__CpuProfile__Serialize(handle, self.isolate.handle) orelse return error.NoProfile;
    return (js.String{ .local = &ls.local, .handle = string_handle }).toSlice();
}

pub fn startHeapProfiler(self: *Context) void {
    if (comptime !IS_DEBUG) {
        @compileError("Heap Profiling is only available in debug builds");
    }

    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    std.debug.assert(self.heap_profiler == null);
    const heap_profiler = v8.v8__HeapProfiler__Get(self.isolate.handle).?;

    // Sample every 32KB, stack depth 32
    v8.v8__HeapProfiler__StartSamplingHeapProfiler(heap_profiler, 32 * 1024, 32);
    v8.v8__HeapProfiler__StartTrackingHeapObjects(heap_profiler, true);

    self.heap_profiler = heap_profiler;
}

pub fn stopHeapProfiler(self: *Context) !struct { []const u8, []const u8 } {
    var ls: js.Local.Scope = undefined;
    self.localScope(&ls);
    defer ls.deinit();

    const allocating = blk: {
        const profile = v8.v8__HeapProfiler__GetAllocationProfile(self.heap_profiler.?);
        const string_handle = v8.v8__AllocationProfile__Serialize(profile, self.isolate.handle);
        v8.v8__HeapProfiler__StopSamplingHeapProfiler(self.heap_profiler.?);
        v8.v8__AllocationProfile__Delete(profile);
        break :blk try (js.String{ .local = &ls.local, .handle = string_handle.? }).toSlice();
    };

    const snapshot = blk: {
        const snapshot = v8.v8__HeapProfiler__TakeHeapSnapshot(self.heap_profiler.?, null) orelse return error.NoProfiles;
        const string_handle = v8.v8__HeapSnapshot__Serialize(snapshot, self.isolate.handle);
        v8.v8__HeapProfiler__StopTrackingHeapObjects(self.heap_profiler.?);
        v8.v8__HeapSnapshot__Delete(snapshot);
        break :blk try (js.String{ .local = &ls.local, .handle = string_handle.? }).toSlice();
    };

    return .{ allocating, snapshot };
}

const UnknownPropertyStat = struct {
    count: usize,
    first_stack: []const u8,
};
