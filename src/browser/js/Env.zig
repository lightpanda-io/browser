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
const builtin = @import("builtin");

const v8 = js.v8;

const App = @import("../../App.zig");
const log = @import("../../log.zig");

const bridge = @import("bridge.zig");
const Context = @import("Context.zig");
const Isolate = @import("Isolate.zig");
const Platform = @import("Platform.zig");
const Snapshot = @import("Snapshot.zig");
const Inspector = @import("Inspector.zig");

const Page = @import("../Page.zig");
const Window = @import("../webapi/Window.zig");

const JsApis = bridge.JsApis;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

fn initClassIds() void {
    inline for (JsApis, 0..) |JsApi, i| {
        JsApi.Meta.class_id = i;
    }
}

var class_id_once = std.once(initClassIds);

// The Env maps to a V8 isolate, which represents a isolated sandbox for
// executing JavaScript. The Env is where we'll define our V8 <-> Zig bindings,
// and it's where we'll start ExecutionWorlds, which actually execute JavaScript.
// The `S` parameter is arbitrary state. When we start an ExecutionWorld, an instance
// of S must be given. This instance is available to any Zig binding.
// The `types` parameter is a tuple of Zig structures we want to bind to V8.
const Env = @This();

app: *App,

platform: *const Platform,

// the global isolate
isolate: js.Isolate,

contexts: [64]*Context,
context_count: usize,

// just kept around because we need to free it on deinit
isolate_params: *v8.CreateParams,

context_id: usize,

// Global handles that need to be freed on deinit
eternal_function_templates: []v8.Eternal,

// Dynamic slice to avoid circular dependency on JsApis.len at comptime
templates: []*const v8.FunctionTemplate,

// Global template created once per isolate and reused across all contexts
global_template: v8.Eternal,

// Inspector associated with the Isolate. Exists when CDP is being used.
inspector: ?*Inspector,

// We can store data in a v8::Object's Private data bag. The keys are v8::Private
// which an be created once per isolaet.
private_symbols: PrivateSymbols,

microtask_queues_are_running: bool,

pub const InitOpts = struct {
    with_inspector: bool = false,
};

pub fn init(app: *App, opts: InitOpts) !Env {
    if (comptime IS_DEBUG) {
        comptime {
            // V8 requirement for any data using SetAlignedPointerInInternalField
            const a = @alignOf(@import("TaggedOpaque.zig"));
            std.debug.assert(a >= 2 and a % 2 == 0);
        }
    }

    // Initialize class IDs once before any V8 work
    class_id_once.call();

    const allocator = app.allocator;
    const snapshot = &app.snapshot;

    var params = try allocator.create(v8.CreateParams);
    errdefer allocator.destroy(params);
    v8.v8__Isolate__CreateParams__CONSTRUCT(params);
    params.snapshot_blob = @ptrCast(&snapshot.startup_data);

    params.array_buffer_allocator = v8.v8__ArrayBuffer__Allocator__NewDefaultAllocator().?;
    errdefer v8.v8__ArrayBuffer__Allocator__DELETE(params.array_buffer_allocator.?);

    params.external_references = &snapshot.external_references;

    var isolate = js.Isolate.init(params);
    errdefer isolate.deinit();
    const isolate_handle = isolate.handle;

    v8.v8__Isolate__SetHostImportModuleDynamicallyCallback(isolate_handle, Context.dynamicModuleCallback);
    v8.v8__Isolate__SetPromiseRejectCallback(isolate_handle, promiseRejectCallback);
    v8.v8__Isolate__SetMicrotasksPolicy(isolate_handle, v8.kExplicit);
    v8.v8__Isolate__SetFatalErrorHandler(isolate_handle, fatalCallback);
    v8.v8__Isolate__SetOOMErrorHandler(isolate_handle, oomCallback);

    isolate.enter();
    errdefer isolate.exit();

    v8.v8__Isolate__SetHostInitializeImportMetaObjectCallback(isolate_handle, Context.metaObjectCallback);

    // Allocate arrays dynamically to avoid comptime dependency on JsApis.len
    const eternal_function_templates = try allocator.alloc(v8.Eternal, JsApis.len);
    errdefer allocator.free(eternal_function_templates);

    const templates = try allocator.alloc(*const v8.FunctionTemplate, JsApis.len);
    errdefer allocator.free(templates);

    var global_eternal: v8.Eternal = undefined;
    var private_symbols: PrivateSymbols = undefined;
    {
        var temp_scope: js.HandleScope = undefined;
        temp_scope.init(isolate);
        defer temp_scope.deinit();

        inline for (JsApis, 0..) |_, i| {
            const data = v8.v8__Isolate__GetDataFromSnapshotOnce(isolate_handle, snapshot.data_start + i);
            const function_handle: *const v8.FunctionTemplate = @ptrCast(data);
            // Make function template eternal
            v8.v8__Eternal__New(isolate_handle, @ptrCast(function_handle), &eternal_function_templates[i]);

            // Extract the local handle from the global for easy access
            const eternal_ptr = v8.v8__Eternal__Get(&eternal_function_templates[i], isolate_handle);
            templates[i] = @ptrCast(@alignCast(eternal_ptr.?));
        }

        // Create global template once per isolate
        const js_global = v8.v8__FunctionTemplate__New__DEFAULT(isolate_handle);
        const window_name = v8.v8__String__NewFromUtf8(isolate_handle, "Window", v8.kNormal, 6);
        v8.v8__FunctionTemplate__SetClassName(js_global, window_name);

        // Find Window in JsApis by name (avoids circular import)
        const window_index = comptime bridge.JsApiLookup.getId(Window.JsApi);
        v8.v8__FunctionTemplate__Inherit(js_global, templates[window_index]);

        const global_template_local = v8.v8__FunctionTemplate__InstanceTemplate(js_global).?;
        v8.v8__ObjectTemplate__SetNamedHandler(global_template_local, &.{
            .getter = bridge.unknownWindowPropertyCallback,
            .setter = null,
            .query = null,
            .deleter = null,
            .enumerator = null,
            .definer = null,
            .descriptor = null,
            .data = null,
            .flags = v8.kOnlyInterceptStrings | v8.kNonMasking,
        });
        // I don't 100% understand this. We actually set this up in the snapshot,
        // but for the global instance, it doesn't work. SetIndexedHandler and
        // SetNamedHandler are set on the Instance template, and that's the key
        // difference. The context has its own global instance, so we need to set
        // these back up directly on it. There might be a better way to do this.
        v8.v8__ObjectTemplate__SetIndexedHandler(global_template_local, &.{
            .getter = Window.JsApi.index.getter,
            .setter = null,
            .query = null,
            .deleter = null,
            .enumerator = null,
            .definer = null,
            .descriptor = null,
            .data = null,
            .flags = 0,
        });
        v8.v8__Eternal__New(isolate_handle, @ptrCast(global_template_local), &global_eternal);
        private_symbols = PrivateSymbols.init(isolate_handle);
    }

    var inspector: ?*js.Inspector = null;
    if (opts.with_inspector) {
        inspector = try Inspector.init(allocator, isolate_handle);
    }

    return .{
        .app = app,
        .context_id = 0,
        .contexts = undefined,
        .context_count = 0,
        .isolate = isolate,
        .platform = &app.platform,
        .templates = templates,
        .isolate_params = params,
        .inspector = inspector,
        .global_template = global_eternal,
        .private_symbols = private_symbols,
        .microtask_queues_are_running = false,
        .eternal_function_templates = eternal_function_templates,
    };
}

pub fn deinit(self: *Env) void {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.context_count == 0);
    }
    for (self.contexts[0..self.context_count]) |ctx| {
        ctx.deinit();
    }

    const allocator = self.app.allocator;
    if (self.inspector) |i| {
        i.deinit(allocator);
    }

    allocator.free(self.templates);
    allocator.free(self.eternal_function_templates);
    self.private_symbols.deinit();

    self.isolate.exit();
    self.isolate.deinit();
    v8.v8__ArrayBuffer__Allocator__DELETE(self.isolate_params.array_buffer_allocator.?);
    allocator.destroy(self.isolate_params);
}

pub fn createContext(self: *Env, page: *Page) !*Context {
    const context_arena = try self.app.arena_pool.acquire();
    errdefer self.app.arena_pool.release(context_arena);

    const isolate = self.isolate;
    var hs: js.HandleScope = undefined;
    hs.init(isolate);
    defer hs.deinit();

    // Create a per-context microtask queue for isolation
    const microtask_queue = v8.v8__MicrotaskQueue__New(isolate.handle, v8.kExplicit).?;
    errdefer v8.v8__MicrotaskQueue__DELETE(microtask_queue);

    // Get the global template that was created once per isolate
    const global_template: *const v8.ObjectTemplate = @ptrCast(@alignCast(v8.v8__Eternal__Get(&self.global_template, isolate.handle).?));
    v8.v8__ObjectTemplate__SetInternalFieldCount(global_template, comptime Snapshot.countInternalFields(Window.JsApi));

    const v8_context = v8.v8__Context__New__Config(isolate.handle, &.{
        .global_template = global_template,
        .global_object = null,
        .microtask_queue = microtask_queue,
    }).?;

    // Create the v8::Context and wrap it in a v8::Global
    var context_global: v8.Global = undefined;
    v8.v8__Global__New(isolate.handle, v8_context, &context_global);

    // get the global object for the context, this maps to our Window
    const global_obj = v8.v8__Context__Global(v8_context).?;
    {
        // Store our TAO inside the internal field of the global object. This
        // maps the v8::Object -> Zig instance. Almost all objects have this, and
        // it gets setup automatically as objects are created, but the Window
        // object already exists in v8 (it's the global) so we manually create
        // the mapping here.
        const tao = try context_arena.create(@import("TaggedOpaque.zig"));
        tao.* = .{
            .value = @ptrCast(page.window),
            .prototype_chain = (&Window.JsApi.Meta.prototype_chain).ptr,
            .prototype_len = @intCast(Window.JsApi.Meta.prototype_chain.len),
            .subtype = .node, // this probably isn't right, but it's what we've been doing all along
        };
        v8.v8__Object__SetAlignedPointerInInternalField(global_obj, 0, tao);
    }
    // our window wrapped in a v8::Global
    var global_global: v8.Global = undefined;
    v8.v8__Global__New(isolate.handle, global_obj, &global_global);

    const context_id = self.context_id;
    self.context_id = context_id + 1;

    const context = try context_arena.create(Context);
    context.* = .{
        .env = self,
        .page = page,
        .id = context_id,
        .isolate = isolate,
        .arena = context_arena,
        .handle = context_global,
        .templates = self.templates,
        .call_arena = page.call_arena,
        .microtask_queue = microtask_queue,
        .script_manager = &page._script_manager,
        .scheduler = .init(context_arena),
        .finalizer_callback_pool = std.heap.MemoryPool(Context.FinalizerCallback).init(self.app.allocator),
    };
    try context.identity_map.putNoClobber(context_arena, @intFromPtr(page.window), global_global);

    // Store a pointer to our context inside the v8 context so that, given
    // a v8 context, we can get our context out
    v8.v8__Context__SetAlignedPointerInEmbedderData(v8_context, 1, @ptrCast(context));

    const count = self.context_count;
    if (count >= self.contexts.len) {
        return error.TooManyContexts;
    }
    self.contexts[count] = context;
    self.context_count = count + 1;

    return context;
}

pub fn destroyContext(self: *Env, context: *Context) void {
    for (self.contexts[0..self.context_count], 0..) |ctx, i| {
        if (ctx == context) {
            // Swap with last element and decrement count
            self.context_count -= 1;
            self.contexts[i] = self.contexts[self.context_count];
            break;
        }
    } else {
        if (comptime IS_DEBUG) {
            @panic("Tried to remove unknown context");
        }
    }

    const isolate = self.isolate;
    if (self.inspector) |inspector| {
        var hs: js.HandleScope = undefined;
        hs.init(isolate);
        defer hs.deinit();
        inspector.contextDestroyed(@ptrCast(v8.v8__Global__Get(&context.handle, isolate.handle)));
    }

    context.deinit();
}

pub fn runMicrotasks(self: *Env) void {
    if (self.microtask_queues_are_running == false) {
        const v8_isolate = self.isolate.handle;

        self.microtask_queues_are_running = true;
        defer self.microtask_queues_are_running = false;

        var i: usize = 0;
        while (i < self.context_count) : (i += 1) {
            const ctx = self.contexts[i];
            v8.v8__MicrotaskQueue__PerformCheckpoint(ctx.microtask_queue, v8_isolate);
        }
    }
}

pub fn runMacrotasks(self: *Env) !?u64 {
    var ms_to_next_task: ?u64 = null;
    for (self.contexts[0..self.context_count]) |ctx| {
        if (comptime builtin.is_test == false) {
            // I hate this comptime check as much as you do. But we have tests
            // which rely on short execution before shutdown. In real world, it's
            // underterministic whether a timer will or won't run before the
            // page shutsdown. But for tests, we need to run them to their end.
            if (ctx.scheduler.hasReadyTasks() == false) {
                continue;
            }
        }

        var hs: js.HandleScope = undefined;
        const entered = ctx.enter(&hs);
        defer entered.exit();

        const ms = (try ctx.scheduler.run()) orelse continue;
        if (ms_to_next_task == null or ms < ms_to_next_task.?) {
            ms_to_next_task = ms;
        }
    }
    return ms_to_next_task;
}

pub fn pumpMessageLoop(self: *const Env) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate.handle);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    const isolate = self.isolate.handle;
    const platform = self.platform.handle;
    while (v8.v8__Platform__PumpMessageLoop(platform, isolate, false)) {}
}

pub fn hasBackgroundTasks(self: *const Env) bool {
    return v8.v8__Isolate__HasPendingBackgroundTasks(self.isolate.handle);
}

pub fn waitForBackgroundTasks(self: *Env) void {
    var hs: v8.HandleScope = undefined;
    v8.v8__HandleScope__CONSTRUCT(&hs, self.isolate.handle);
    defer v8.v8__HandleScope__DESTRUCT(&hs);

    const isolate = self.isolate.handle;
    const platform = self.platform.handle;
    while (v8.v8__Isolate__HasPendingBackgroundTasks(isolate)) {
        _ = v8.v8__Platform__PumpMessageLoop(platform, isolate, true);
        self.runMicrotasks();
    }
}

pub fn runIdleTasks(self: *const Env) void {
    v8.v8__Platform__RunIdleTasks(self.platform.handle, self.isolate.handle, 1);
}

// V8 doesn't immediately free memory associated with
// a Context, it's managed by the garbage collector. We use the
// `lowMemoryNotification` call on the isolate to encourage v8 to free
// any contexts which have been freed.
// This GC is very aggressive. Use memoryPressureNotification for less
// aggressive GC passes.
pub fn lowMemoryNotification(self: *Env) void {
    var handle_scope: js.HandleScope = undefined;
    handle_scope.init(self.isolate);
    defer handle_scope.deinit();
    self.isolate.lowMemoryNotification();
}

// V8 doesn't immediately free memory associated with
// a Context, it's managed by the garbage collector. We use the
// `memoryPressureNotification` call on the isolate to encourage v8 to free
// any contexts which have been freed.
// The level indicates the aggressivity of the GC required:
// moderate speeds up incremental GC
// critical runs one full GC
// For a more aggressive GC, use lowMemoryNotification.
pub fn memoryPressureNotification(self: *Env, level: Isolate.MemoryPressureLevel) void {
    var handle_scope: js.HandleScope = undefined;
    handle_scope.init(self.isolate);
    defer handle_scope.deinit();
    self.isolate.memoryPressureNotification(level);
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

pub fn terminate(self: *const Env) void {
    v8.v8__Isolate__TerminateExecution(self.isolate.handle);
}

fn promiseRejectCallback(message_handle: v8.PromiseRejectMessage) callconv(.c) void {
    const promise_handle = v8.v8__PromiseRejectMessage__GetPromise(&message_handle).?;
    const v8_isolate = v8.v8__Object__GetIsolate(@ptrCast(promise_handle)).?;
    const js_isolate = js.Isolate{ .handle = v8_isolate };
    const ctx = Context.fromIsolate(js_isolate);

    const local = js.Local{
        .ctx = ctx,
        .isolate = js_isolate,
        .handle = v8.v8__Isolate__GetCurrentContext(v8_isolate).?,
        .call_arena = ctx.call_arena,
    };

    const page = ctx.page;
    page.window.unhandledPromiseRejection(.{
        .local = &local,
        .handle = &message_handle,
    }, page) catch |err| {
        log.warn(.browser, "unhandled rejection handler", .{ .err = err });
    };
}

fn fatalCallback(c_location: [*c]const u8, c_message: [*c]const u8) callconv(.c) void {
    const location = std.mem.span(c_location);
    const message = std.mem.span(c_message);
    log.fatal(.app, "V8 fatal callback", .{ .location = location, .message = message });
    @import("../../crash_handler.zig").crash("Fatal V8 Error", .{ .location = location, .message = message }, @returnAddress());
}

fn oomCallback(c_location: [*c]const u8, details: ?*const v8.OOMDetails) callconv(.c) void {
    const location = std.mem.span(c_location);
    const detail = if (details) |d| std.mem.span(d.detail) else "";
    log.fatal(.app, "V8 OOM", .{ .location = location, .detail = detail });
    @import("../../crash_handler.zig").crash("V8 OOM", .{ .location = location, .detail = detail }, @returnAddress());
}

const PrivateSymbols = struct {
    const Private = @import("Private.zig");

    child_nodes: Private,

    fn init(isolate: *v8.Isolate) PrivateSymbols {
        return .{
            .child_nodes = Private.init(isolate, "child_nodes"),
        };
    }

    fn deinit(self: *PrivateSymbols) void {
        self.child_nodes.deinit();
    }
};
