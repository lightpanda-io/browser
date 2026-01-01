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
const Context = @import("Context.zig");
const Platform = @import("Platform.zig");
const Snapshot = @import("Snapshot.zig");
const Inspector = @import("Inspector.zig");
const ExecutionWorld = @import("ExecutionWorld.zig");

const JsApis = bridge.JsApis;
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
isolate: js.Isolate,

// just kept around because we need to free it on deinit
isolate_params: *v8.c.CreateParams,

context_id: usize,

// Global handles that need to be freed on deinit
globals: []v8.c.Global,

// Dynamic slice to avoid circular dependency on JsApis.len at comptime
templates: []*const v8.c.FunctionTemplate,

pub fn init(allocator: Allocator, platform: *const Platform, snapshot: *Snapshot) !Env {
    var params = try allocator.create(v8.c.CreateParams);
    errdefer allocator.destroy(params);
    v8.c.v8__Isolate__CreateParams__CONSTRUCT(params);
    params.snapshot_blob = @ptrCast(&snapshot.startup_data);

    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    errdefer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);

    params.external_references = &snapshot.external_references;

    var isolate = js.Isolate.init(params);
    errdefer isolate.deinit();

    v8.c.v8__Isolate__SetHostImportModuleDynamicallyCallback(isolate.handle, Context.dynamicModuleCallback);
    v8.c.v8__Isolate__SetPromiseRejectCallback(isolate.handle, promiseRejectCallback);
    v8.c.v8__Isolate__SetMicrotasksPolicy(isolate.handle, v8.c.kExplicit);

    isolate.enter();
    errdefer isolate.exit();

    v8.c.v8__Isolate__SetHostInitializeImportMetaObjectCallback(isolate.handle, Context.metaObjectCallback);

    // Allocate arrays dynamically to avoid comptime dependency on JsApis.len
    const globals = try allocator.alloc(v8.c.Global, JsApis.len);
    errdefer allocator.free(globals);

    const templates = try allocator.alloc(*const v8.c.FunctionTemplate, JsApis.len);
    errdefer allocator.free(templates);

    {
        var temp_scope: js.HandleScope = undefined;
        temp_scope.init(isolate);
        defer temp_scope.deinit();
        const context_handle = isolate.createContextHandle(null, null);

        v8.c.v8__Context__Enter(context_handle);
        defer v8.c.v8__Context__Exit(context_handle);

        inline for (JsApis, 0..) |JsApi, i| {
            JsApi.Meta.class_id = i;
            const data = v8.c.v8__Context__GetDataFromSnapshotOnce(context_handle, snapshot.data_start + i);
            const function_handle: *const v8.c.FunctionTemplate = @ptrCast(data);
            // Make function template global/persistent
            v8.c.v8__Global__New(isolate.handle, @ptrCast(function_handle), &globals[i]);
            // Extract the local handle from the global for easy access
            templates[i] = @ptrCast(@alignCast(@as(*const anyopaque, @ptrFromInt(globals[i].data_ptr))));
        }
    }

    return .{
        .context_id = 0,
        .isolate = isolate,
        .platform = platform,
        .allocator = allocator,
        .globals = globals,
        .templates = templates,
        .isolate_params = params,
    };
}

pub fn deinit(self: *Env) void {
    // Free global handles before destroying the isolate
    for (self.globals) |*global| {
        v8.c.v8__Global__Reset(global);
    }
    self.allocator.free(self.globals);
    self.allocator.free(self.templates);

    self.isolate.exit();
    self.isolate.deinit();
    v8.destroyArrayBufferAllocator(self.isolate_params.array_buffer_allocator.?);
    self.allocator.destroy(self.isolate_params);
}

pub fn newInspector(self: *Env, arena: Allocator, ctx: anytype) !*Inspector {
    const inspector = try arena.create(Inspector);
    try Inspector.init(inspector, self.isolate.handle, ctx);
    return inspector;
}

pub fn runMicrotasks(self: *const Env) void {
    self.isolate.performMicrotasksCheckpoint();
}

pub fn pumpMessageLoop(self: *const Env) bool {
    return v8.c.v8__Platform__PumpMessageLoop(self.platform.handle, self.isolate.handle, false);
}

pub fn runIdleTasks(self: *const Env) void {
    v8.c.v8__Platform__RunIdleTasks(self.platform.handle, self.isolate.handle, 1);
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
    var handle_scope: js.HandleScope = undefined;
    handle_scope.init(self.isolate);
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
    const isolate_handle = v8.c.v8__Object__GetIsolate(@ptrCast(msg.getPromise().handle)).?;
    const js_isolate = js.Isolate{ .handle = isolate_handle };
    const context = Context.fromIsolate(js_isolate);

    const value =
        if (msg.getValue()) |v8_value|
            context.valueToString(js.Value{ .ctx = context, .handle = v8_value.handle }, .{}) catch |err| @errorName(err)
        else
            "no value";

    log.debug(.js, "unhandled rejection", .{
        .value = value,
        .stack = context.stackTrace() catch |err| @errorName(err) orelse "???",
        .note = "This should be updated to call window.unhandledrejection",
    });
}
