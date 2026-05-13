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

// CDP WebMCP domain.
// https://chromedevtools.github.io/devtools-protocol/tot/WebMCP/
const std = @import("std");
const lp = @import("lightpanda");

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");

const ModelContext = @import("../../browser/webapi/ModelContext.zig");
const Frame = @import("../../browser/Frame.zig");
const Notification = @import("../../Notification.zig");
const js = @import("../../browser/js/js.zig");
const ModelContextClient = ModelContext.ModelContextClient;

const log = lp.log;
const Allocator = std.mem.Allocator;

pub const Invocation = struct {
    id: u32,
    bc: *CDP.BrowserContext,
    frame_id: u32,
    name: []const u8,
    canceled: bool = false,
};

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        invokeTool,
        cancelInvocation,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .invokeTool => return invokeTool(cmd),
        .cancelInvocation => return cancelInvocation(cmd),
    }
}

fn enable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.webmcpEnable();

    // Replay any tools registered before enable. We walk the current
    // frame only; subframes will be added when they register.
    if (bc.session.currentFrame()) |frame| {
        const mc = frame.window.getModelContext();
        const tools = mc.tools(frame);
        if (tools.len > 0) {
            try sendToolsAdded(cmd.cdp, bc, frame, tools);
        }
    }

    return cmd.sendResult(null, .{});
}

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.webmcpDisable();
    return cmd.sendResult(null, .{});
}

const InvokeToolParams = struct {
    frameId: []const u8,
    toolName: []const u8,
    input: std.json.Value = .null,
};

fn invokeTool(cmd: *CDP.Command) !void {
    const params = (try cmd.params(InvokeToolParams)) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const frame_id = try id.parseFrameId(params.frameId);
    const frame = bc.session.findFrameByFrameId(frame_id) orelse return error.FrameNotFound;
    const mc = frame.window.getModelContext();
    const tool = mc.findTool(frame, params.toolName) orelse return error.NotFound;

    // Stringify the input once. We send it back to the client via
    // `toolInvoked.input` and pass the parsed form into the JS callback.
    const input_str = try std.json.Stringify.valueAlloc(cmd.arena, params.input, .{});

    const inv_id = bc.invocation_id_gen.incr();
    const inv_id_str = &id.toInvocationId(inv_id);

    const invocation = try bc.arena.create(Invocation);
    invocation.* = .{
        .id = inv_id,
        .bc = bc,
        .frame_id = frame_id,
        .name = try bc.arena.dupe(u8, tool.name),
    };
    try bc.webmcp_invocations.put(bc.arena, inv_id, invocation);

    // Send toolInvoked event before we run the JS, so the client sees
    // them in order even if the tool resolves synchronously.
    const session_id = bc.session_id;
    const frame_id_str = id.toFrameId(frame_id);
    try cmd.sendEvent("WebMCP.toolInvoked", .{
        .toolName = tool.name,
        .frameId = &frame_id_str,
        .invocationId = inv_id_str,
        .input = input_str,
    }, .{ .session_id = session_id });

    // Enter the frame's V8 context to invoke the stored callback.
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const local = &ls.local;

    const input_value = local.parseJSON(input_str) catch {
        try respondError(cmd.cdp, bc, invocation, "failed to parse input JSON");
        return cmd.sendResult(.{ .invocationId = inv_id_str }, .{});
    };

    const callback = local.toLocal(tool.execute);

    // ModelContextClient has no per-instance state today (see
    // ModelContext.zig). We still build a fresh wrapper so the page-side
    // signature `execute(input, client)` works as documented.
    var client_inst = ModelContextClient{};
    const client_value = try local.zigValueToJs(&client_inst, .{});

    var caught: js.TryCatch.Caught = undefined;
    const result = callback.tryCall(js.Value, .{ input_value, client_value }, &caught) catch {
        const msg = caught.exception orelse "tool threw";
        try respondError(cmd.cdp, bc, invocation, msg);
        return cmd.sendResult(.{ .invocationId = inv_id_str }, .{});
    };

    // If the tool returned a non-promise value, settle immediately.
    if (!result.isPromise()) {
        try respondCompleted(cmd.cdp, bc, invocation, result);
        return cmd.sendResult(.{ .invocationId = inv_id_str }, .{});
    }

    const promise = js.Promise{ .local = local, .handle = @ptrCast(result.handle) };
    const on_fulfilled = local.newCallback(onPromiseFulfilled, invocation);
    const on_rejected = local.newCallback(onPromiseRejected, invocation);
    _ = promise.thenAndCatch(on_fulfilled, on_rejected) catch {
        // If we couldn't chain, settle as error. Map entry will be
        // cleaned up below.
        try respondError(cmd.cdp, bc, invocation, "promise chain failed");
        return cmd.sendResult(.{ .invocationId = inv_id_str }, .{});
    };

    return cmd.sendResult(.{ .invocationId = inv_id_str }, .{});
}

fn cancelInvocation(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        invocationId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const inv_id = CDP.InvocationIdGen.parse(params.invocationId) catch return error.InvalidParams;
    const entry = bc.webmcp_invocations.fetchRemove(inv_id) orelse return error.NotFound;
    entry.value.canceled = true;

    try cmd.cdp.sendEvent("WebMCP.toolResponded", .{
        .invocationId = &id.toInvocationId(inv_id),
        .status = "Canceled",
    }, .{ .session_id = bc.session_id });

    return cmd.sendResult(null, .{});
}

fn onPromiseFulfilled(invocation: *Invocation, value: js.Value) anyerror!void {
    // The map is the source of truth for "still active". cancelInvocation
    // removes it from the map and sends Canceled; we drop the late result.
    if (invocation.bc.webmcp_invocations.fetchRemove(invocation.id) == null) return;
    respondCompleted(invocation.bc.cdp, invocation.bc, invocation, value) catch |err| {
        log.err(.cdp, "WebMCP fulfilled", .{ .err = err });
    };
}

fn onPromiseRejected(invocation: *Invocation, reason: js.Value) anyerror!void {
    if (invocation.bc.webmcp_invocations.fetchRemove(invocation.id) == null) return;
    const msg = reason.toStringSliceWithAlloc(invocation.bc.notification_arena) catch "tool rejected";
    respondError(invocation.bc.cdp, invocation.bc, invocation, msg) catch |err| {
        log.err(.cdp, "WebMCP rejected", .{ .err = err });
    };
}

fn respondCompleted(
    cdp: *CDP,
    bc: *CDP.BrowserContext,
    invocation: *Invocation,
    value: js.Value,
) !void {
    const arena = bc.notification_arena;
    const output_json = value.toJson(arena) catch "null";
    try cdp.sendEvent("WebMCP.toolResponded", .{
        .invocationId = &id.toInvocationId(invocation.id),
        .status = "Completed",
        .output = RawJson{ .raw = output_json },
    }, .{ .session_id = bc.session_id });
    _ = bc.webmcp_invocations.remove(invocation.id);
}

// Embeds a pre-stringified JSON value into the outer payload.
const RawJson = struct {
    raw: []const u8,

    pub fn jsonStringify(self: RawJson, w: anytype) !void {
        try w.print("{s}", .{self.raw});
    }
};

fn respondError(
    cdp: *CDP,
    bc: *CDP.BrowserContext,
    invocation: *Invocation,
    err_text: []const u8,
) !void {
    try cdp.sendEvent("WebMCP.toolResponded", .{
        .invocationId = &id.toInvocationId(invocation.id),
        .status = "Error",
        .errorText = err_text,
    }, .{ .session_id = bc.session_id });
    _ = bc.webmcp_invocations.remove(invocation.id);
}

pub fn onToolAdded(
    arena: Allocator,
    bc: *CDP.BrowserContext,
    event: *const Notification.ModelContextToolEvent,
) !void {
    var ls: js.Local.Scope = undefined;
    event.frame.js.localScope(&ls);
    defer ls.deinit();

    const writer = ToolWriter{
        .frame_id = id.toFrameId(event.frame._frame_id),
        .tools = &.{event.tool},
        .local = &ls.local,
        .arena = arena,
    };
    try bc.cdp.sendEvent("WebMCP.toolsAdded", .{
        .tools = writer,
    }, .{ .session_id = bc.session_id });
}

pub fn onToolRemoved(
    arena: Allocator,
    bc: *CDP.BrowserContext,
    event: *const Notification.ModelContextToolEvent,
) !void {
    _ = arena;
    const frame_id_str = id.toFrameId(event.frame._frame_id);
    try bc.cdp.sendEvent("WebMCP.toolsRemoved", .{
        .tools = &.{
            .{ .name = event.tool.name, .frameId = &frame_id_str },
        },
    }, .{ .session_id = bc.session_id });
}

fn sendToolsAdded(
    cdp: *CDP,
    bc: *CDP.BrowserContext,
    frame: *Frame,
    tools: []const *const ModelContext.Tool,
) !void {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const writer = ToolWriter{
        .frame_id = id.toFrameId(frame._frame_id),
        .tools = tools,
        .local = &ls.local,
        .arena = bc.notification_arena,
    };
    try cdp.sendEvent("WebMCP.toolsAdded", .{ .tools = writer }, .{ .session_id = bc.session_id });
}

const testing = @import("../testing.zig");

test "cdp.WebMCP: enable replays existing tools" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-M",
        .session_id = "SID-M",
        .target_id = "TID-000000000M".*,
        .url = "cdp/webmcp_fixture.html",
    });
    _ = bc;

    try ctx.processMessage(.{
        .id = 1,
        .method = "WebMCP.enable",
        .session_id = "SID-M",
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    // The fixture registered `greet` before enable — should be replayed.
    try ctx.expectSentEvent("WebMCP.toolsAdded", .{
        .tools = &.{
            .{
                .name = "greet",
                .description = "Returns a greeting for the given person",
                .annotations = .{
                    .readOnly = true,
                    .untrustedContent = false,
                    .autosubmit = false,
                },
            },
        },
    }, .{ .session_id = "SID-M" });
}

test "cdp.WebMCP: register fires toolsAdded after enable" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-M",
        .session_id = "SID-M",
        .target_id = "TID-000000000M".*,
        .url = "cdp/webmcp_fixture.html",
    });

    try ctx.processMessage(.{ .id = 1, .method = "WebMCP.enable", .session_id = "SID-M" });
    try ctx.expectSentResult(null, .{ .id = 1 });

    // Drain the initial replay.
    try ctx.expectSentEvent("WebMCP.toolsAdded", .{
        .tools = &.{.{ .name = "greet" }},
    }, .{ .session_id = "SID-M" });

    // Register a fresh tool from JS, expect a new toolsAdded event.
    var ls: @import("../../browser/js/js.zig").Local.Scope = undefined;
    bc.session.currentFrame().?.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec(
        \\navigator.modelContext.registerTool({
        \\  name: 'echo',
        \\  description: 'echo input back',
        \\  execute: async (input) => input,
        \\});
    , "register-echo");

    try ctx.expectSentEvent("WebMCP.toolsAdded", .{
        .tools = &.{.{ .name = "echo", .description = "echo input back" }},
    }, .{ .session_id = "SID-M" });
}

test "cdp.WebMCP: invokeTool fires toolInvoked + toolResponded" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-M",
        .session_id = "SID-M",
        .target_id = "TID-000000000M".*,
        .url = "cdp/webmcp_fixture.html",
    });
    const frame_id = id.toFrameId(bc.session.currentFrame().?._frame_id);

    try ctx.processMessage(.{ .id = 1, .method = "WebMCP.enable", .session_id = "SID-M" });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try ctx.expectSentEvent("WebMCP.toolsAdded", null, .{ .session_id = "SID-M" });

    try ctx.processMessage(.{
        .id = 2,
        .method = "WebMCP.invokeTool",
        .session_id = "SID-M",
        .params = .{
            .frameId = &frame_id,
            .toolName = "greet",
            .input = .{ .who = "world" },
        },
    });
    try ctx.expectSentResult(.{ .invocationId = "INV-0000000001" }, .{ .id = 2 });

    try ctx.expectSentEvent("WebMCP.toolInvoked", .{
        .toolName = "greet",
        .frameId = &frame_id,
        .invocationId = "INV-0000000001",
    }, .{ .session_id = "SID-M" });

    try ctx.expectSentEvent("WebMCP.toolResponded", .{
        .invocationId = "INV-0000000001",
        .status = "Completed",
    }, .{ .session_id = "SID-M" });
}

test "cdp.WebMCP: invokeTool unknown name" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-M",
        .session_id = "SID-M",
        .target_id = "TID-000000000M".*,
        .url = "cdp/webmcp_fixture.html",
    });
    const frame_id = id.toFrameId(bc.session.currentFrame().?._frame_id);

    try ctx.processMessage(.{ .id = 1, .method = "WebMCP.enable", .session_id = "SID-M" });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try ctx.expectSentEvent("WebMCP.toolsAdded", null, .{ .session_id = "SID-M" });

    try ctx.processMessage(.{
        .id = 2,
        .method = "WebMCP.invokeTool",
        .session_id = "SID-M",
        .params = .{
            .frameId = &frame_id,
            .toolName = "does_not_exist",
            .input = .{},
        },
    });
    try ctx.expectSentError(-31998, "NotFound", .{ .id = 2 });
}

test "cdp.WebMCP: cancelInvocation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-M",
        .session_id = "SID-M",
        .target_id = "TID-000000000M".*,
        .url = "cdp/webmcp_fixture.html",
    });

    try ctx.processMessage(.{ .id = 1, .method = "WebMCP.enable", .session_id = "SID-M" });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try ctx.expectSentEvent("WebMCP.toolsAdded", null, .{ .session_id = "SID-M" });

    // Register a never-settling tool so we have an invocation to cancel.
    var ls: @import("../../browser/js/js.zig").Local.Scope = undefined;
    bc.session.currentFrame().?.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec(
        \\navigator.modelContext.registerTool({
        \\  name: 'hang',
        \\  description: 'never settles',
        \\  execute: () => new Promise(() => {}),
        \\});
    , "register-hang");
    try ctx.expectSentEvent("WebMCP.toolsAdded", .{
        .tools = &.{.{ .name = "hang" }},
    }, .{ .session_id = "SID-M" });

    const frame_id = id.toFrameId(bc.session.currentFrame().?._frame_id);
    try ctx.processMessage(.{
        .id = 2,
        .method = "WebMCP.invokeTool",
        .session_id = "SID-M",
        .params = .{
            .frameId = &frame_id,
            .toolName = "hang",
            .input = .{},
        },
    });
    try ctx.expectSentResult(.{ .invocationId = "INV-0000000001" }, .{ .id = 2 });
    try ctx.expectSentEvent("WebMCP.toolInvoked", .{ .invocationId = "INV-0000000001" }, .{ .session_id = "SID-M" });

    try ctx.processMessage(.{
        .id = 3,
        .method = "WebMCP.cancelInvocation",
        .session_id = "SID-M",
        .params = .{ .invocationId = "INV-0000000001" },
    });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try ctx.expectSentEvent("WebMCP.toolResponded", .{
        .invocationId = "INV-0000000001",
        .status = "Canceled",
    }, .{ .session_id = "SID-M" });
}

// Serializes a slice of `*const ModelContext.Tool` as the
// `WebMCP.toolsAdded.params.tools` array. Each tool's `inputSchema` is
// an arbitrary JS object — we round-trip it through `JSON.stringify` and
// embed the raw JSON.
const ToolWriter = struct {
    frame_id: [14]u8,
    tools: []const *const ModelContext.Tool,
    local: *const js.Local,
    arena: Allocator,

    pub fn jsonStringify(self: *const ToolWriter, w: anytype) !void {
        try w.beginArray();
        for (self.tools) |t| {
            try w.beginObject();

            try w.objectField("name");
            try w.write(t.name);

            try w.objectField("description");
            try w.write(t.description);

            try w.objectField("inputSchema");
            if (t.input_schema) |schema_global| {
                const schema_obj = schema_global.local(self.local);
                const schema_json = schema_obj.toValue().toJson(self.arena) catch "{}";
                try w.print("{s}", .{schema_json});
            } else {
                try w.beginObject();
                try w.endObject();
            }

            try w.objectField("annotations");
            try w.beginObject();
            try w.objectField("readOnly");
            try w.write(t.annotations.readOnlyHint);
            try w.objectField("untrustedContent");
            try w.write(t.annotations.untrustedContentHint);
            try w.objectField("autosubmit");
            try w.write(t.annotations.autoSubmitHint);
            try w.endObject();

            try w.objectField("frameId");
            try w.write(&self.frame_id);

            try w.endObject();
        }
        try w.endArray();
    }
};
