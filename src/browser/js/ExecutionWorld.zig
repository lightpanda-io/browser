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

const log = @import("../../log.zig");

const js = @import("js.zig");
const v8 = js.v8;

const bridge = @import("bridge.zig");
const Env = @import("Env.zig");
const Context = @import("Context.zig");

const Page = @import("../Page.zig");
const ScriptManager = @import("../ScriptManager.zig");

const ArenaAllocator = std.heap.ArenaAllocator;

const CONTEXT_ARENA_RETAIN = 1024 * 64;

const JsApis = bridge.JsApis;

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
// A v8.HandleScope is like an arena. Once created, any "Local" that
// v8 creates will be released (or at least, releasable by the v8 GC)
// when the handle_scope is freed.
// We also maintain our own "context_arena" which allows us to have
// all page related memory easily managed.
pub fn createContext(self: *ExecutionWorld, page: *Page, enter: bool, global_callback: ?js.GlobalMissingCallback) !*Context {
    std.debug.assert(self.context == null);

    const env = self.env;
    const isolate = env.isolate;
    const templates = &self.env.templates;

    var v8_context: v8.Context = blk: {
        var temp_scope: v8.HandleScope = undefined;
        v8.HandleScope.init(&temp_scope, isolate);
        defer temp_scope.deinit();

        const js_global = v8.FunctionTemplate.initDefault(isolate);
        js_global.setClassName(v8.String.initUtf8(isolate, "Window"));
        Env.attachClass(@TypeOf(page.window.*).JsApi, isolate, js_global);

        const global_template = js_global.getInstanceTemplate();
        global_template.setInternalFieldCount(1);

        // Configure the missing property callback on the global
        // object.
        if (global_callback != null) {
            const configuration = v8.NamedPropertyHandlerConfiguration{
                .getter = struct {
                    fn callback(c_name: ?*const v8.C_Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8 {
                        const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                        const context = Context.fromIsolate(info.getIsolate());

                        const property = context.valueToString(.{ .handle = c_name.? }, .{}) catch "???";
                        if (context.global_callback.?.missing(property, context)) {
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
        inline for (JsApis, 0..) |JsApi, i| {
            if (@hasDecl(JsApi.Meta, "name")) {
                const class_name = v8.String.initUtf8(isolate, JsApi.Meta.name);
                global_template.set(class_name.toName(), templates[i], v8.PropertyAttribute.None);
            }
        }

        // The global object (Window) has already been hooked into the v8
        // engine when the Env was initialized - like every other type.
        // But the V8 global is its own FunctionTemplate instance so even
        // though it's also a Window, we need to set the prototype for this
        // specific instance of the the Window.
        {
            const proto_type = @typeInfo(@TypeOf(page.window._proto)).pointer.child;
            const proto_index = bridge.JsApiLookup.getId(proto_type.JsApi);
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
        inline for (JsApis, 0..) |JsApi, i| {
            if (comptime Env.protoIndexLookup(JsApi)) |proto_index| {
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
    const context_id = env.context_id;
    env.context_id = context_id + 1;

    self.context = Context{
        .page = page,
        .id = context_id,
        .isolate = isolate,
        .v8_context = v8_context,
        .templates = &env.templates,
        .handle_scope = handle_scope,
        .script_manager = &page._script_manager,
        .call_arena = page.call_arena,
        .arena = self.context_arena.allocator(),
        .global_callback = global_callback,
    };

    var context = &self.context.?;
    {
        // Store a pointer to our context inside the v8 context so that, given
        // a v8 context, we can get our context out
        const data = isolate.initBigIntU64(@intCast(@intFromPtr(context)));
        v8_context.setEmbedderData(1, data);
    }

    // @ZIGDOM
    // Custom exception
    // NOTE: there is no way in v8 to subclass the Error built-in type
    // TODO: this is an horrible hack
    // inline for (JsApi) |JsApi| {
    //     const Struct = s.defaultValue().?;
    //     if (@hasDecl(Struct, "ErrorSet")) {
    //         const script = comptime JsApi.Meta.name ++ ".prototype.__proto__ = Error.prototype";
    //         _ = try context.exec(script, "errorSubclass");
    //     }
    // }

    try context.setupGlobal();
    return context;
}

pub fn removeContext(self: *ExecutionWorld) void {
    // Force running the micro task to drain the queue before reseting the
    // context arena.
    // Tasks in the queue are relying to the arena memory could be present in
    // the queue. Running them later could lead to invalid memory accesses.
    self.env.runMicrotasks();

    self.context.?.deinit();
    self.context = null;
    _ = self.context_arena.reset(.{ .retain_with_limit = CONTEXT_ARENA_RETAIN });
}

pub fn terminateExecution(self: *const ExecutionWorld) void {
    self.env.isolate.terminateExecution();
}

pub fn resumeExecution(self: *const ExecutionWorld) void {
    self.env.isolate.cancelTerminateExecution();
}
