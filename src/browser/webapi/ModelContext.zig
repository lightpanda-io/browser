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
const std = @import("std");

const js = @import("../js/js.zig");
const Notification = @import("../../Notification.zig");

const AbortSignal = @import("AbortSignal.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ ModelContext, ModelContextClient };
}

const ModelContext = @This();

_tools: std.ArrayList(*Tool) = .{},

pub const init: ModelContext = .{};

pub const Annotations = struct {
    readOnlyHint: bool = false,
    untrustedContentHint: bool = false,
    // Not in the W3C spec yet. The CDP `WebMCP.Annotation` type has an
    // `autosubmit` field; storing it here means the CDP follow-up won't have
    // to re-shape this struct.
    autoSubmitHint: bool = false,
};

pub const Tool = struct {
    ctx: *ModelContext,
    name: []const u8,
    title: ?[]const u8,
    description: []const u8,
    input_schema: ?js.Object.Global,
    execute: js.Function.Global,
    annotations: Annotations,
    signal: ?*AbortSignal,

    pub fn markAborted(self: *Tool, exec: *const Execution) !void {
        try self.ctx.markAborted(self, exec);
    }
};

const ToolDict = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: []const u8,
    inputSchema: ?js.Object.Global = null,
    execute: js.Function.Global,
    annotations: ?Annotations = null,
};

const RegisterToolOptions = struct {
    signal: ?*AbortSignal = null,
};

pub fn registerTool(
    self: *ModelContext,
    tool: ToolDict,
    options_: ?RegisterToolOptions,
    exec: *const Execution,
) !void {
    try validateName(tool.name);
    if (tool.description.len == 0) {
        return error.InvalidStateError;
    }

    const options = options_ orelse RegisterToolOptions{};

    // Per spec: a pre-aborted signal makes registration a silent no-op.
    if (options.signal) |signal| {
        if (signal._aborted) {
            return;
        }
    }

    // Reject duplicate names. The spec says `InvalidStateError`.
    for (self._tools.items) |existing| {
        if (std.mem.eql(u8, existing.name, tool.name)) {
            return error.InvalidStateError;
        }
    }

    const arena = exec.arena;
    const entry = try arena.create(Tool);
    entry.* = .{
        .ctx = self,
        .name = try arena.dupe(u8, tool.name),
        .title = if (tool.title) |t| try arena.dupe(u8, t) else null,
        .description = try arena.dupe(u8, tool.description),
        .input_schema = tool.inputSchema,
        .execute = tool.execute,
        .annotations = tool.annotations orelse .{},
        .signal = options.signal,
    };

    if (entry.signal) |s| {
        try s._dependents.append(arena, .{ .model_context_tool = entry });
    }
    try self._tools.append(arena, entry);

    // Fire `model_context_tool_added` so observers (CDP `WebMCP` domain,
    // native MCP forwarder) can surface the new tool.
    const event: Notification.ModelContextToolEvent = .{ .exec = exec, .tool = entry };

    const session = switch (exec.context.global) {
        inline else => |g| g._session,
    };

    session.notification.dispatch(.model_context_tool_added, &event);
}

/// Snapshot of currently-registered tools.
/// Used by the CDP `WebMCP.enable` replay and the native MCP forwarder.
pub fn tools(self: *ModelContext) []const *Tool {
    return self._tools.items;
}

/// Look up a tool by name. Returns null if not found or if its signal has
/// fired. Used by CDP `WebMCP.invokeTool`.
pub fn findTool(self: *ModelContext, name: []const u8) ?*Tool {
    for (self._tools.items) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Walk the tool list and remove any whose `AbortSignal` has fired,
/// dispatching `model_context_tool_removed` for each. Cheap when no
/// signals fired (which is the common case).
fn markAborted(self: *ModelContext, tool: *Tool, exec: *const Execution) !void {
    const session = switch (exec.context.global) {
        inline else => |g| g._session,
    };

    var i: usize = 0;
    while (i < self._tools.items.len) {
        const t = self._tools.items[i];
        if (t == tool) {
            _ = self._tools.swapRemove(i);
            const event: Notification.ModelContextToolEvent = .{ .exec = exec, .tool = t };
            session.notification.dispatch(.model_context_tool_removed, &event);
            return;
        }
        i += 1;
    }
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

// ModelContextClient — passed as the second argument to an `execute`
// callback. Today its only method is `requestUserInteraction`, which the
// spec leaves implementation-defined; for a headless browser, the closest
// faithful behaviour is to run the user-supplied callback directly and
// resolve with its return value.
pub const ModelContextClient = struct {
    _pad: bool = false,

    pub fn requestUserInteraction(
        _: *ModelContextClient,
        callback: js.Function,
        exec: *const Execution,
    ) !js.Promise {
        var ls: js.Local.Scope = undefined;
        exec.context.global.getJs().localScope(&ls);
        defer ls.deinit();
        const resolver = ls.local.createPromiseResolver();

        var caught: js.TryCatch.Caught = undefined;
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
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

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
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const registerTool = bridge.function(
        ModelContext.registerTool,
        .{ .dom_exception = true },
    );
};

const testing = @import("../../testing.zig");
test "WebApi: ModelContext" {
    try testing.htmlRunner("webmcp/model_context.html", .{});
}
