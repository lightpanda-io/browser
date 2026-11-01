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

// WebMCP — https://webmachinelearning.github.io/webmcp/
//
// Only the calling document's tools are visible: `exposedTo` and
// `fromOrigins` are ignored, and tools aren't shared across frames yet.
const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Notification = @import("../../Notification.zig");

const Event = @import("Event.zig");
const Window = @import("Window.zig");
const EventTarget = @import("EventTarget.zig");
const AbortSignal = @import("AbortSignal.zig");
const DOMException = @import("DOMException.zig");
const ToolActivatedEvent = @import("event/ToolEvent.zig").ToolActivatedEvent;
const ToolCancelEvent = @import("event/ToolEvent.zig").ToolCancelEvent;

const log = lp.log;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ ModelContext, ModelContextClient };
}

const ModelContext = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_window: *Window,
_exec: *Execution,
_tools: std.ArrayList(*Tool) = .empty,

pub fn init(window: *Window) !*ModelContext {
    const frame = window._frame;
    return frame._factory.eventTarget(ModelContext{
        ._proto = undefined,
        ._window = window,
        ._exec = &frame.js.execution,
    });
}

pub fn asEventTarget(self: *ModelContext) *EventTarget {
    return self._proto;
}

pub const Annotations = struct {
    consequentialHint: bool = false,
    debugging: bool = false,
    readOnlyHint: bool = false,
    untrustedContentHint: bool = false,
};

pub const Tool = struct {
    ctx: *ModelContext,
    name: []const u8,
    title: ?[]const u8,
    description: []const u8,
    // JSON, serialized at registration like Chrome does, so later changes to
    // the page's object don't show through.
    input_schema: ?[]const u8,
    execute: js.Function.Global,
    annotations: ?Annotations,
    // registerTool's promise, until toolchange has fired.
    registration: ?js.PromiseResolver.Global,

    /// Calls `execute` in `local`'s context with `input_json` parsed as its
    /// input and `signal` as its options' signal. The result may be a promise.
    /// On `error.ToolThrew`, `caught` holds the exception.
    pub fn invoke(
        self: *const Tool,
        exec: *const Execution,
        local: *const js.Local,
        input_json: []const u8,
        signal: *AbortSignal,
        caught: *js.TryCatch.Caught,
    ) error{ OutOfMemory, InvalidInput, ToolThrew }!js.Value {
        const input = local.parseJSON(input_json) catch return error.InvalidInput;
        const client = try exec.page_arena.create(ModelContextClient);
        client.* = .{ ._signal = signal };
        const callback = local.toLocal(self.execute);
        return callback.tryCall(js.Value, .{ input, client }, caught) catch error.ToolThrew;
    }

    /// Unregisters the tool once the signal it was registered with aborts.
    pub fn onAbort(self: *Tool, reason: AbortSignal.Reason, exec: *const Execution) void {
        self.ctx.unregister(self, reason, exec) catch |err| {
            log.debug(.js, "unregister tool", .{ .err = err });
        };
    }

    fn lessThan(_: void, a: *const Tool, b: *const Tool) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }

    fn toRegisteredTool(self: *const Tool, local: *const js.Local) !js.Object {
        const window = self.ctx._window;
        const obj = local.newObject();
        _ = try obj.set("name", self.name, .{});
        _ = try obj.set("title", self.title orelse "", .{});
        _ = try obj.set("description", self.description, .{});
        if (self.input_schema) |schema| {
            _ = try obj.set("inputSchema", try local.parseJSON(schema), .{});
        }
        _ = try obj.set("window", window, .{});
        _ = try obj.set("origin", window.getOrigin(), .{});
        if (self.annotations) |annotations| {
            _ = try obj.set("annotations", annotations, .{});
        }
        return obj;
    }

    fn takeRegistration(self: *Tool) ?js.PromiseResolver.Global {
        defer self.registration = null;
        return self.registration;
    }

    fn resolveRegistration(ctx: *anyopaque) anyerror!?u32 {
        const self: *Tool = @ptrCast(@alignCast(ctx));
        const mc = self.ctx;
        mc.dispatchToolChange() catch |err| {
            log.debug(.js, "toolchange dispatch", .{ .err = err });
        };

        const registration = self.takeRegistration() orelse return null;
        defer registration.release();

        var ls: js.Local.Scope = undefined;
        mc._exec.js.localScope(&ls);
        defer ls.deinit();
        registration.local(&ls.local).resolve("ModelContext.registerTool", {});
        return null;
    }

    fn registrationCancelled(ctx: *anyopaque) void {
        const self: *Tool = @ptrCast(@alignCast(ctx));
        if (self.takeRegistration()) |registration| {
            registration.release();
        }
    }
};

const ToolDict = struct {
    annotations: ?Annotations = null,
    description: []const u8,
    execute: js.Function.Global,
    inputSchema: ?js.Value = null,
    name: []const u8,
    title: ?[]const u8 = null,
};

const SignalOptions = struct {
    signal: ?*AbortSignal = null,
};

pub fn registerTool(
    self: *ModelContext,
    tool: ToolDict,
    options_: ?SignalOptions,
    exec: *const Execution,
) !js.Promise {
    if (self.findTool(tool.name) != null) {
        return error.InvalidStateError;
    }
    try validateName(tool.name);
    if (tool.description.len == 0) {
        return error.InvalidStateError;
    }

    const arena = exec.page_arena;
    const input_schema = if (definedValue(tool.inputSchema)) |schema| try stringifyObject(arena, schema) else null;

    const local = exec.js.local.?;
    const resolver = local.createPromiseResolver();
    const promise = resolver.promise();

    const options = options_ orelse SignalOptions{};
    if (options.signal) |signal| {
        if (signal._aborted) {
            AbortSignal.rejectWithReason(resolver, "ModelContext.registerTool", signal._reason);
            return promise;
        }
    }

    const entry = try arena.create(Tool);
    entry.* = .{
        .ctx = self,
        .name = try arena.dupe(u8, tool.name),
        .title = if (tool.title) |t| try arena.dupe(u8, t) else null,
        .description = try arena.dupe(u8, tool.description),
        .input_schema = input_schema,
        .execute = tool.execute,
        .annotations = tool.annotations,
        .registration = try resolver.persist(),
    };

    if (options.signal) |signal| {
        try signal._dependents.append(arena, .{ .model_context_tool = entry });
    }
    try self._tools.append(arena, entry);

    // Fire `model_context_tool_added` so observers (CDP `WebMCP` domain,
    // native MCP forwarder) can surface the new tool.
    const event: Notification.ModelContextToolEvent = .{ .exec = exec, .tool = entry };
    exec.session.notification.dispatch(.model_context_tool_added, &event);

    // Like Chrome, toolchange fires and the promise resolves in a later task,
    // so aborting the signal right after registering still rejects it.
    try exec.js.scheduler.add(entry, Tool.resolveRegistration, 0, .{
        .name = "ModelContext.registerTool",
        .finalizer = Tool.registrationCancelled,
    });
    return promise;
}

fn unregister(self: *ModelContext, tool: *Tool, reason: AbortSignal.Reason, exec: *const Execution) !void {
    const index = std.mem.indexOfScalar(*Tool, self._tools.items, tool) orelse return;
    _ = self._tools.orderedRemove(index);

    const event: Notification.ModelContextToolEvent = .{ .exec = exec, .tool = tool };
    exec.session.notification.dispatch(.model_context_tool_removed, &event);

    // Running calls already looked the tool up, so nothing calls it again.
    tool.execute.release();

    if (tool.takeRegistration()) |registration| {
        defer registration.release();

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();
        AbortSignal.rejectWithReason(registration.local(&ls.local), "ModelContext.registerTool", reason);
    }

    try exec.js.scheduler.add(self, runToolChange, 0, .{
        .name = "ModelContext.toolchange",
    });
}

fn runToolChange(ctx: *anyopaque) anyerror!?u32 {
    const self: *ModelContext = @ptrCast(@alignCast(ctx));
    try self.dispatchToolChange();
    return null;
}

fn dispatchToolChange(self: *ModelContext) !void {
    const exec = self._exec;
    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, "toolchange")) {
        return;
    }
    const event = try Event.initTrusted(comptime .wrap("toolchange"), .{}, exec.page);
    try exec.dispatch(target, event, .{ .context = "ModelContext.toolchange" });
}

/// Fires `toolactivated` or `toolcancel`.
fn dispatchToolEvent(self: *ModelContext, comptime E: type, tool_name: []const u8) !void {
    const exec = self._exec;
    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, E.event_type)) {
        return;
    }
    const event = try E.initTrusted(tool_name, exec.page);
    try exec.dispatch(target, event.asEvent(), .{ .context = "ModelContext." ++ E.event_type });
}

pub fn getTools(self: *ModelContext, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const sorted = try exec.call_arena.dupe(*Tool, self._tools.items);
    std.mem.sort(*Tool, sorted, {}, Tool.lessThan);

    const array = local.newArray(@intCast(sorted.len));
    for (sorted, 0..) |tool, i| {
        _ = try array.set(@intCast(i), try tool.toRegisteredTool(local), .{});
    }
    return local.resolvePromise(array);
}

// The members of a RegisteredTool that identify it.
const ToolRef = struct {
    name: []const u8,
    origin: []const u8,
    window: *Window,
};

pub fn executeTool(
    self: *ModelContext,
    ref: ToolRef,
    input_: ?js.Value,
    options_: ?SignalOptions,
    exec: *const Execution,
) !js.Promise {
    const arena = exec.page_arena;
    const input_json = if (definedValue(input_)) |input| try stringifyObject(exec.call_arena, input) else "{}";

    const local = exec.js.local.?;
    const resolver = local.createPromiseResolver();
    const promise = resolver.promise();

    const options = options_ orelse SignalOptions{};
    if (options.signal) |signal| {
        if (signal._aborted) {
            AbortSignal.rejectWithReason(resolver, "ModelContext.executeTool", signal._reason);
            return promise;
        }
    }

    // Tools in other windows aren't reachable yet.
    if (ref.window != self._window or !std.mem.eql(u8, ref.origin, self._window.getOrigin())) {
        resolver.reject("ModelContext.executeTool", try toolNotFound(arena, ref.name));
        return promise;
    }

    const input_arena = try exec.getArena(.tiny, "ModelContext.executeTool");
    errdefer input_arena.release();

    const call = try arena.create(ToolCall);
    call.* = .{
        .ctx = self,
        .name = try arena.dupe(u8, ref.name),
        .input_arena = input_arena,
        .input_json = try input_arena.allocator().dupe(u8, input_json),
        .resolver = try resolver.persist(),
        .caller_signal = options.signal,
        .signal = try AbortSignal.init(exec),
    };
    if (options.signal) |signal| {
        try signal._dependents.append(arena, .{ .model_context_call = call });
    }

    // Like Chrome, the tool runs in a later task, after executeTool returns.
    try exec.js.scheduler.add(call, ToolCall.run, 0, .{
        .name = "ModelContext.executeTool",
        .finalizer = ToolCall.dropped,
    });
    return promise;
}

fn toolNotFound(allocator: std.mem.Allocator, name: []const u8) !DOMException {
    return executionFailed(try std.fmt.allocPrint(allocator, "Tool not found: {s}", .{name}));
}

// An executeTool call waiting on its tool.
pub const ToolCall = struct {
    ctx: *ModelContext,
    name: []const u8,
    // Read once, when the tool runs.
    input_arena: *lp.Arena,
    input_json: []const u8,
    resolver: js.PromiseResolver.Global,
    caller_signal: ?*AbortSignal,
    // The signal passed to the tool, aborted when the caller cancels.
    signal: *AbortSignal,
    started: bool = false,
    settled: bool = false,

    fn run(ctx: *anyopaque) anyerror!?u32 {
        const self: *ToolCall = @ptrCast(@alignCast(ctx));
        defer self.input_arena.release();
        const mc = self.ctx;
        const exec = mc._exec;

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();
        const local = &ls.local;

        // A caller that already aborted still runs the tool: its cancel task,
        // queued behind this one, then aborts the tool's signal.
        const tool = mc.findTool(self.name) orelse {
            self.fail(local, try toolNotFound(exec.page_arena, self.name));
            return null;
        };
        self.started = true;

        var caught: js.TryCatch.Caught = .{};
        if (tool.invoke(exec, local, self.input_json, self.signal, &caught)) |result| {
            if (result.isPromise()) {
                const on_fulfilled = local.newCallback(onFulfilled, self);
                const on_rejected = local.newCallback(onRejected, self);
                _ = try result.toPromise().thenAndCatch(on_fulfilled, on_rejected);
            } else {
                self.succeed(local, result);
            }
        } else |err| switch (err) {
            error.ToolThrew => self.fail(local, executionFailed(caught.exception orelse "Unknown error")),
            // `input_json` was serialized from an object.
            error.InvalidInput => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        }

        try mc.dispatchToolEvent(ToolActivatedEvent, self.name);
        return null;
    }

    fn dropped(ctx: *anyopaque) void {
        const self: *ToolCall = @ptrCast(@alignCast(ctx));
        self.input_arena.release();
        if (self.settled) return;
        self.settled = true;
        self.resolver.release();
    }

    fn onFulfilled(self: *ToolCall, value: js.Value) void {
        self.succeed(value.local, value);
    }

    fn onRejected(self: *ToolCall, reason: js.Value) void {
        const message = reason.toStringSliceWithAlloc(self.ctx._exec.page_arena) catch "Unknown error";
        self.fail(reason.local, executionFailed(message));
    }

    fn succeed(self: *ToolCall, local: *const js.Local, value: js.Value) void {
        if (self.settled) return;

        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        // The promise copies the text, but a DOMException keeps its message.
        const text = resultText(local.call_arena, value) catch |err| {
            const message = if (try_catch.exceptionValue()) |exception|
                exception.toStringSliceWithAlloc(self.ctx._exec.page_arena) catch @errorName(err)
            else
                @errorName(err);
            return self.fail(local, executionFailed(message));
        };

        const resolver = self.settle(local) orelse return;
        defer self.resolver.release();
        resolver.resolve("ModelContext.executeTool", text);
    }

    fn fail(self: *ToolCall, local: *const js.Local, err: DOMException) void {
        const resolver = self.settle(local) orelse return;
        defer self.resolver.release();
        resolver.reject("ModelContext.executeTool", err);
    }

    fn settle(self: *ToolCall, local: *const js.Local) ?js.PromiseResolver {
        if (self.settled) return null;
        self.settled = true;
        if (self.caller_signal) |signal| {
            signal.removeDependent(.{ .model_context_call = self });
        }
        return self.resolver.local(local);
    }

    /// The caller aborted: reject right away, and cancel the tool in a later
    /// task, the way Chrome forwards the cancellation to the tool's frame.
    pub fn onAbort(self: *ToolCall, reason: AbortSignal.Reason, exec: *const Execution) void {
        if (self.settled) return;
        self.settled = true;

        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();
        AbortSignal.rejectWithReason(self.resolver.local(&ls.local), "ModelContext.executeTool", reason);
        self.resolver.release();

        exec.js.scheduler.add(self, cancel, 0, .{
            .name = "ModelContext.toolcancel",
        }) catch |err| {
            log.debug(.js, "schedule toolcancel", .{ .err = err });
        };
    }

    fn cancel(ctx: *anyopaque) anyerror!?u32 {
        const self: *ToolCall = @ptrCast(@alignCast(ctx));
        if (!self.started) return null;
        const mc = self.ctx;
        try self.signal.abort(null, mc._exec);
        try mc.dispatchToolEvent(ToolCancelEvent, self.name);
        return null;
    }
};

fn executionFailed(message: []const u8) DOMException {
    return DOMException.init(message, "UnknownError");
}

/// The string executeTool resolves with: objects as JSON, anything else as
/// its string form.
fn resultText(allocator: std.mem.Allocator, value: js.Value) ![]const u8 {
    const text = if (value.isObject())
        try value.toJson(allocator)
    else
        try value.toStringSliceWithAlloc(allocator);
    return if (text.len == 0) "Operation succeeded" else text;
}

/// Serializes a schema or tool input, which must be a JSON object. A throwing
/// toJSON or a cycle leaves its TypeError pending, which rejects the call.
fn stringifyObject(allocator: std.mem.Allocator, value: js.Value) ![]const u8 {
    if (!value.isObject()) {
        return error.TypeError;
    }
    const json = try value.toJson(allocator);
    if (std.mem.eql(u8, json, "undefined")) {
        return error.TypeError;
    }
    return json;
}

fn definedValue(value: ?js.Value) ?js.Value {
    const v = value orelse return null;
    return if (v.isUndefined()) null else v;
}

/// Snapshot of currently-registered tools.
/// Used by the CDP `WebMCP.enable` replay and the native MCP forwarder.
pub fn tools(self: *ModelContext) []const *Tool {
    return self._tools.items;
}

/// Look up a tool by name. Used by CDP `WebMCP.invokeTool`.
pub fn findTool(self: *ModelContext, name: []const u8) ?*Tool {
    for (self._tools.items) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 128) {
        return error.InvalidStateError;
    }
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.';
        if (!ok) return error.InvalidStateError;
    }
}

// ModelContextClient — the second argument to an `execute` callback. The
// spec makes it a `{signal}` dictionary; `requestUserInteraction` is kept for
// pages written against the earlier explainer, and runs the callback
// directly since a headless browser has no user to ask.
pub const ModelContextClient = struct {
    _signal: *AbortSignal,

    fn getSignal(self: *const ModelContextClient) *AbortSignal {
        return self._signal;
    }

    pub fn requestUserInteraction(
        _: *ModelContextClient,
        callback: js.Function,
        exec: *const Execution,
    ) !js.Promise {
        var ls: js.Local.Scope = undefined;
        exec.js.global.getJs().localScope(&ls);
        defer ls.deinit();
        const resolver = ls.local.createPromiseResolver();

        var caught: js.TryCatch.Caught = .{};
        if (callback.tryCall(js.Value, .{}, &caught)) |result| {
            // The callback may itself return a thenable; resolving with its
            // value lets V8's promise resolution machinery unwrap it.
            resolver.resolve("requestUserInteraction", result);
        } else |_| {
            const ex_msg = caught.exception orelse "requestUserInteraction callback threw";
            resolver.rejectError("requestUserInteraction", .{ .generic_error = ex_msg });
        }
        return resolver.promise();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ModelContextClient);

        pub const Meta = struct {
            pub const name = "ModelContextClient";
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const signal = bridge.accessor(ModelContextClient.getSignal, null, .{});
        pub const requestUserInteraction = bridge.function(
            ModelContextClient.requestUserInteraction,
            .{},
        );
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(ModelContext);

    pub const Meta = struct {
        pub const name = "ModelContext";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const registerTool = bridge.function(ModelContext.registerTool, .{});
    pub const getTools = bridge.function(ModelContext.getTools, .{});
    pub const executeTool = bridge.function(ModelContext.executeTool, .{});
    pub const ontoolchange = EventTarget.handlerAccessor(ModelContext, "toolchange");
    pub const ontoolactivated = EventTarget.handlerAccessor(ModelContext, "toolactivated");
    pub const ontoolcancel = EventTarget.handlerAccessor(ModelContext, "toolcancel");
};

const testing = @import("../../testing.zig");
test "WebApi: ModelContext" {
    try testing.htmlRunner("webmcp/model_context.html", .{});
    try testing.htmlRunner("webmcp/execute_tool.html", .{});
}
