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
persisted_context: ?js.Global(Context) = null,

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

    const persisted_context: js.Global(Context) = blk: {
        var temp_scope: js.HandleScope = undefined;
        temp_scope.init(isolate);
        defer temp_scope.deinit();


        // Getting this into the snapshot is tricky (anything involving the
        // global is tricky). Easier to do here
        const func_tmpl_handle = isolate.createFunctionTemplateHandle();
        const global_template = v8.v8__FunctionTemplate__InstanceTemplate(func_tmpl_handle).?;
        var configuration: v8.NamedPropertyHandlerConfiguration = .{
            .getter = unknownPropertyCallback,
            .setter = null,
            .query = null,
            .deleter = null,
            .enumerator = null,
            .definer = null,
            .descriptor = null,
            .data = null,
            .flags = v8.kOnlyInterceptStrings | v8.kNonMasking,
        };
        v8.v8__ObjectTemplate__SetNamedHandler(global_template, &configuration);

        const context_handle = isolate.createContextHandle(null, null);
        break :blk js.Global(Context).init(isolate.handle, context_handle);
    };

    // For a Page we only create one HandleScope, it is stored in the main World (enter==true). A page can have multple contexts, 1 for each World.
    // The main Context that enters and holds the HandleScope should therefore always be created first. Following other worlds for this page
    // like isolated Worlds, will thereby place their objects on the main page's HandleScope. Note: In the furure the number of context will multiply multiple frames support
    const v8_context = persisted_context.local();
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
        .handle = v8_context,
        .templates = env.templates,
        .handle_scope = handle_scope,
        .script_manager = &page._script_manager,
        .call_arena = page.call_arena,
        .arena = arena,
    };
    self.persisted_context = persisted_context;

    var context = &self.context.?;
    // Store a pointer to our context inside the v8 context so that, given
    // a v8 context, we can get our context out
    const data = isolate.initBigInt(@intFromPtr(context));
    v8.v8__Context__SetEmbedderData(context.handle, 1, @ptrCast(data.handle));

    try context.setupGlobal();
    return context;
}

pub fn removeContext(self: *ExecutionWorld) void {
    // Force running the micro task to drain the queue before reseting the
    // context arena.
    // Tasks in the queue are relying to the arena memory could be present in
    // the queue. Running them later could lead to invalid memory accesses.
    self.env.runMicrotasks();

    var context = &(self.context orelse return);
    context.deinit();
    self.context = null;

    self.persisted_context.?.deinit();
    self.persisted_context = null;

    _ = self.context_arena.reset(.{ .retain_with_limit = CONTEXT_ARENA_RETAIN });
}

pub fn terminateExecution(self: *const ExecutionWorld) void {
    self.env.isolate.terminateExecution();
}

pub fn resumeExecution(self: *const ExecutionWorld) void {
    self.env.isolate.cancelTerminateExecution();
}


pub fn unknownPropertyCallback(c_name: ?*const v8.Name, raw_info: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
    const isolate_handle = v8.v8__PropertyCallbackInfo__GetIsolate(raw_info).?;
    const context = Context.fromIsolate(.{ .handle = isolate_handle });

    const property: ?[]u8 = context.valueToString(.{ .ctx = context, .handle = c_name.? }, .{}) catch {
        return v8.Intercepted.No;
    };

    const ignored = std.StaticStringMap(void).initComptime(.{
        .{ "process", {} },
        .{ "ShadyDOM", {} },
        .{ "ShadyCSS", {} },

        .{ "litNonce", {} },
        .{ "litHtmlVersions", {} },
        .{ "litElementVersions", {} },
        .{ "litHtmlPolyfillSupport", {} },
        .{ "litElementHydrateSupport", {} },
        .{ "litElementPolyfillSupport", {} },
        .{ "reactiveElementVersions", {} },

        .{ "recaptcha", {} },
        .{ "grecaptcha", {} },
        .{ "___grecaptcha_cfg", {} },
        .{ "__recaptcha_api", {} },
        .{ "__google_recaptcha_client", {} },

        .{ "CLOSURE_FLAGS", {} },
    });

    if (!ignored.has(property)) {
        const page = context.page;
        const document = page.document;

        if (document.getElementById(property, page)) |el| {
            const js_value = context.zigValueToJs(el, .{}) catch {
                return v8.Intercepted.No;
            };

            info.getReturnValue().set(js_value);
            return v8.Intercepted.Yes;
        }

        if (comptime IS_DEBUG) {
            log.debug(.unknown_prop, "unknown global property", .{
                .info = "but the property can exist in pure JS",
                .stack = context.stackTrace() catch "???",
                .property = property,
            });
        }
    }

    // not intercepted
    return 0;
}
