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
const IS_DEBUG = @import("builtin").mode == .Debug;

const log = @import("../../log.zig");

const js = @import("js.zig");
const v8 = js.v8;

const Env = @import("Env.zig");
const bridge = @import("bridge.zig");
const Context = @import("Context.zig");

const Page = @import("../Page.zig");

const ArenaAllocator = std.heap.ArenaAllocator;

const CONTEXT_ARENA_RETAIN = 1024 * 64;

// ExecutionWorld closely models a JS World.
// https://chromium.googlesource.com/chromium/src/+/master/third_party/blink/renderer/bindings/core/v8/V8BindingDesign.md#World
// https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/scripting/ExecutionWorld
const ExecutionWorld = @This();

env: *Env,

// Arena whose lifetime is for a single page load. Where
// the call_arena lives for a single function call, the context_arena
// lives for the lifetime of the entire page. The allocator will be
// owned by the Context, but the arena itself is owned by the ExecutionWorld
// so that we can re-use it from context to context.
context_arena: ArenaAllocator,

// Currently a context maps to a Browser's Page. Here though, it's only a
// mechanism to organization page-specific memory. The ExecutionWorld
// does all the work, but having all page-specific data structures
// grouped together helps keep things clean.
context: ?Context = null,

// no init, must be initialized via env.newExecutionWorld()

pub fn deinit(self: *ExecutionWorld) void {
    if (self.context != null) {
        self.removeContext();
    }
    self.context_arena.deinit();
}

// Only the top Context in the Main ExecutionWorld should hold a handle_scope.
// A js.HandleScope is like an arena. Once created, any "Local" that
// v8 creates will be released (or at least, releasable by the v8 GC)
// when the handle_scope is freed.
// We also maintain our own "context_arena" which allows us to have
// all page related memory easily managed.
pub fn createContext(self: *ExecutionWorld, page: *Page, enter: bool) !*Context {
    std.debug.assert(self.context == null);

    const env = self.env;
    const isolate = env.isolate;
    const arena = self.context_arena.allocator();

    // our window wrapped in a v8::Global
    var global_global: v8.Global = undefined;

    // Create the v8::Context and wrap it in a v8::Global
    var context_global: v8.Global = undefined;
    const v8_context = blk: {
        var temp_scope: js.HandleScope = undefined;
        temp_scope.init(isolate);
        defer temp_scope.deinit();

        // Getting this into the snapshot is tricky (anything involving the
        // global is tricky). Easier to do here
        const global_template = @import("Snapshot.zig").createGlobalTemplate(isolate.handle, env.templates);
        v8.v8__ObjectTemplate__SetNamedHandler(global_template, &.{
            .getter = bridge.unknownPropertyCallback,
            .setter = null,
            .query = null,
            .deleter = null,
            .enumerator = null,
            .definer = null,
            .descriptor = null,
            .data = null,
            .flags = v8.kOnlyInterceptStrings | v8.kNonMasking,
        });

        const local_context = v8.v8__Context__New(isolate.handle, global_template, null).?;
        v8.v8__Global__New(isolate.handle, local_context, &context_global);

        const global_obj = v8.v8__Context__Global(local_context).?;
        v8.v8__Global__New(isolate.handle, global_obj, &global_global);

        break :blk local_context;
    };

    var handle_scope: ?js.HandleScope = null;
    if (enter) {
        handle_scope = @as(js.HandleScope, undefined);
        handle_scope.?.init(isolate);
        v8.v8__Context__Enter(v8_context);
    }
    errdefer if (enter) {
        v8.v8__Context__Exit(v8_context);
        handle_scope.?.deinit();
    };

    const context_id = env.context_id;
    env.context_id = context_id + 1;

    self.context = Context{
        .page = page,
        .id = context_id,
        .isolate = isolate,
        .handle = context_global,
        .global_global = global_global,
        .templates = env.templates,
        .handle_scope = handle_scope,
        .script_manager = &page._script_manager,
        .call_arena = page.call_arena,
        .arena = arena,
    };

    var context = &self.context.?;
    try context.identity_map.putNoClobber(arena, @intFromPtr(page.window), global_global);

    // Store a pointer to our context inside the v8 context so that, given
    // a v8 context, we can get our context out
    const data = isolate.initBigInt(@intFromPtr(&self.context.?));
    v8.v8__Context__SetEmbedderData(v8_context, 1, @ptrCast(data.handle));

    return &self.context.?;
}

pub fn removeContext(self: *ExecutionWorld) void {
    var context = &(self.context orelse return);
    context.deinit();
    self.context = null;

    self.env.isolate.notifyContextDisposed();
    _ = self.context_arena.reset(.{ .retain_with_limit = CONTEXT_ARENA_RETAIN });
}

pub fn terminateExecution(self: *const ExecutionWorld) void {
    self.env.isolate.terminateExecution();
}

pub fn resumeExecution(self: *const ExecutionWorld) void {
    self.env.isolate.cancelTerminateExecution();
}
