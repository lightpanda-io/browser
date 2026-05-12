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
// Exposes `navigator.modelContext`, the page-side surface for declaring MCP
// tools to a browser agent. Lightpanda doesn't ship an agent yet; the
// follow-ups will wire the registered tools through:
//   1. CDP `WebMCP` domain (https://chromedevtools.github.io/devtools-protocol/tot/WebMCP/)
//   2. Lightpanda's own MCP server forwarding tools to an external LLM.
//
// Both consumers reach into `tools()` / `findTool()` from Zig; the JS-side
// surface (`registerTool`, `requestUserInteraction`) is the only part shipped
// today.

const std = @import("std");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const AbortSignal = @import("AbortSignal.zig");

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
    name: []const u8,
    title: ?[]const u8,
    description: []const u8,
    input_schema: ?js.Object.Global,
    execute: js.Function.Global,
    annotations: Annotations,
    // When present, the tool is considered unregistered once the signal
    // fires. Checked lazily on each `tools()` / `findTool()` call — fine
    // for headless usage where there's no synchronous observer to notify.
    signal: ?*AbortSignal,
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
    frame: *Frame,
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

    // Reject duplicate names. The spec says `InvalidStateError`. We compact
    // the list lazily here so a tool whose signal already aborted doesn't
    // block re-registering under the same name.
    self.compactAborted();
    for (self._tools.items) |existing| {
        if (std.mem.eql(u8, existing.name, tool.name)) {
            return error.InvalidStateError;
        }
    }

    const arena = frame.arena;
    const entry = try arena.create(Tool);
    entry.* = .{
        .name = try arena.dupe(u8, tool.name),
        .title = if (tool.title) |t| try arena.dupe(u8, t) else null,
        .description = try arena.dupe(u8, tool.description),
        .input_schema = tool.inputSchema,
        .execute = tool.execute,
        .annotations = tool.annotations orelse .{},
        .signal = options.signal,
    };

    try self._tools.append(arena, entry);
}

/// Snapshot of currently-registered tools, with aborted entries filtered.
/// Used by the (not-yet-implemented) CDP `WebMCP.enable` replay and the
/// native MCP forwarder.
pub fn tools(self: *ModelContext) []const *Tool {
    self.compactAborted();
    return self._tools.items;
}

/// Look up a tool by name. Returns null if not found or if its signal has
/// fired. Used by the (not-yet-implemented) CDP `WebMCP.invokeTool`.
pub fn findTool(self: *ModelContext, name: []const u8) ?*Tool {
    self.compactAborted();
    for (self._tools.items) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn compactAborted(self: *ModelContext) void {
    var i: usize = 0;
    while (i < self._tools.items.len) {
        const t = self._tools.items[i];
        if (t.signal) |signal| {
            if (signal._aborted) {
                _ = self._tools.swapRemove(i);
                continue;
            }
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
        frame: *Frame,
    ) !js.Promise {
        const local = frame.js.local.?;
        const resolver = local.createPromiseResolver();

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
