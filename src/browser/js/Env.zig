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
isolate: v8.Isolate,

// just kept around because we need to free it on deinit
isolate_params: *v8.CreateParams,

context_id: usize,

// Dynamic slice to avoid circular dependency on JsApis.len at comptime
templates: []v8.FunctionTemplate,

pub fn init(allocator: Allocator, platform: *const Platform, snapshot: *Snapshot) !Env {
    var params = try allocator.create(v8.CreateParams);
    errdefer allocator.destroy(params);
    v8.c.v8__Isolate__CreateParams__CONSTRUCT(params);
    params.snapshot_blob = @ptrCast(&snapshot.startup_data);

    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    errdefer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);

    params.external_references = &snapshot.external_references;

    var isolate = v8.Isolate.init(params);
    errdefer isolate.deinit();

    // This is the callback that runs whenever a module is dynamically imported.
    isolate.setHostImportModuleDynamicallyCallback(Context.dynamicModuleCallback);
    isolate.setPromiseRejectCallback(promiseRejectCallback);
    isolate.setMicrotasksPolicy(v8.c.kExplicit);

    isolate.enter();
    errdefer isolate.exit();

    isolate.setHostInitializeImportMetaObjectCallback(Context.metaObjectCallback);

    // Allocate templates array dynamically to avoid comptime dependency on JsApis.len
    const templates = try allocator.alloc(v8.FunctionTemplate, JsApis.len);
    errdefer allocator.free(templates);

    {
        var temp_scope: v8.HandleScope = undefined;
        v8.HandleScope.init(&temp_scope, isolate);
        defer temp_scope.deinit();
        const context = v8.Context.init(isolate, null, null);

        context.enter();
        defer context.exit();

        inline for (JsApis, 0..) |JsApi, i| {
            JsApi.Meta.class_id = i;
            const data = context.getDataFromSnapshotOnce(snapshot.data_start + i);
            const function = v8.FunctionTemplate{ .handle = @ptrCast(data) };
            templates[i] = v8.Persistent(v8.FunctionTemplate).init(isolate, function).castToFunctionTemplate();
        }
    }

    return .{
        .context_id = 0,
        .isolate = isolate,
        .platform = platform,
        .allocator = allocator,
        .templates = templates,
        .isolate_params = params,
    };
}

pub fn deinit(self: *Env) void {
    self.isolate.exit();
    self.isolate.deinit();
    v8.destroyArrayBufferAllocator(self.isolate_params.array_buffer_allocator.?);
    self.allocator.destroy(self.isolate_params);
    self.allocator.free(self.templates);
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
        if (msg.getValue()) |v8_value|
            context.valueToString(v8_value, .{}) catch |err| @errorName(err)
        else
            "no value";

    log.debug(.js, "unhandled rejection", .{
        .value = value,
        .stack = context.stackTrace() catch |err| @errorName(err) orelse "???",
        .note = "This should be updated to call window.unhandledrejection",
    });
}
