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

const std = @import("std");
const lp = @import("lightpanda");

const CDP = @import("../CDP.zig");

const Node = @import("../Node.zig");
const DOMNode = @import("../../browser/webapi/Node.zig");

const markdown = lp.markdown;
const SemanticTree = lp.SemanticTree;
const interactive = lp.interactive;
const structured_data = lp.structured_data;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        getMarkdown,
        getSemanticTree,
        getInteractiveElements,
        getNodeDetails,
        getStructuredData,
        detectForms,
        clickNode,
        fillNode,
        scrollNode,
        waitForSelector,
        handleJavaScriptDialog,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .getMarkdown => return getMarkdown(cmd),
        .getSemanticTree => return getSemanticTree(cmd),
        .getInteractiveElements => return getInteractiveElements(cmd),
        .getNodeDetails => return getNodeDetails(cmd),
        .getStructuredData => return getStructuredData(cmd),
        .detectForms => return detectForms(cmd),
        .clickNode => return clickNode(cmd),
        .fillNode => return fillNode(cmd),
        .scrollNode => return scrollNode(cmd),
        .waitForSelector => return waitForSelector(cmd),
        .handleJavaScriptDialog => return handleJavaScriptDialog(cmd),
    }
}

fn getSemanticTree(cmd: anytype) !void {
    const Params = struct {
        format: ?enum { text } = null,
        prune: ?bool = null,
        interactiveOnly: ?bool = null,
        backendNodeId: ?Node.Id = null,
        maxDepth: ?u32 = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const dom_node = if (params.backendNodeId) |nodeId|
        (bc.node_registry.lookup_by_id.get(nodeId) orelse return error.InvalidNodeId).dom
    else
        frame.document.asNode();

    var st = SemanticTree{
        .dom_node = dom_node,
        .registry = &bc.node_registry,
        .frame = frame,
        .arena = cmd.arena,
        .prune = params.prune orelse true,
        .interactive_only = params.interactiveOnly orelse false,
        .max_depth = params.maxDepth orelse std.math.maxInt(u32) - 1,
    };

    if (params.format) |format| {
        if (format == .text) {
            var aw: std.Io.Writer.Allocating = .init(cmd.arena);
            defer aw.deinit();
            try st.textStringify(&aw.writer);

            return cmd.sendResult(.{
                .semanticTree = aw.written(),
            }, .{});
        }
    }

    return cmd.sendResult(.{
        .semanticTree = st,
    }, .{});
}

fn getMarkdown(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const dom_node = if (params.nodeId) |nodeId|
        (bc.node_registry.lookup_by_id.get(nodeId) orelse return error.InvalidNodeId).dom
    else
        frame.document.asNode();

    var aw: std.Io.Writer.Allocating = .init(cmd.arena);
    defer aw.deinit();
    try markdown.dump(dom_node, .{}, &aw.writer, frame);

    return cmd.sendResult(.{
        .markdown = aw.written(),
    }, .{});
}

fn getInteractiveElements(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const root = if (params.nodeId) |nodeId|
        (bc.node_registry.lookup_by_id.get(nodeId) orelse return error.InvalidNodeId).dom
    else
        frame.document.asNode();

    const elements = try interactive.collectInteractiveElements(root, cmd.arena, frame);
    try interactive.registerNodes(elements, &bc.node_registry);

    return cmd.sendResult(.{
        .elements = elements,
    }, .{});
}

fn getNodeDetails(cmd: anytype) !void {
    const Params = struct {
        backendNodeId: Node.Id,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParam;

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const node = (bc.node_registry.lookup_by_id.get(params.backendNodeId) orelse return error.InvalidNodeId).dom;

    const details = SemanticTree.getNodeDetails(cmd.arena, node, &bc.node_registry, frame) catch return error.InternalError;

    return cmd.sendResult(.{
        .nodeDetails = details,
    }, .{});
}

fn getStructuredData(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const data = try structured_data.collectStructuredData(
        frame.document.asNode(),
        cmd.arena,
        frame,
    );

    return cmd.sendResult(.{
        .structuredData = data,
    }, .{});
}

fn detectForms(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const forms_data = try lp.forms.collectForms(
        cmd.arena,
        frame.document.asNode(),
        frame,
    );

    try lp.forms.registerNodes(forms_data, &bc.node_registry);

    return cmd.sendResult(.{
        .forms = forms_data,
    }, .{});
}

fn clickNode(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?Node.Id = null,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParam;

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const node_id = params.nodeId orelse params.backendNodeId orelse return error.InvalidParam;
    const node = bc.node_registry.lookup_by_id.get(node_id) orelse return error.InvalidNodeId;

    lp.actions.click(node.dom, frame) catch |err| {
        if (err == error.InvalidNodeType) return error.InvalidParam;
        return error.InternalError;
    };

    return cmd.sendResult(.{}, .{});
}

fn fillNode(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?Node.Id = null,
        text: []const u8,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParam;

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const node_id = params.nodeId orelse params.backendNodeId orelse return error.InvalidParam;
    const node = bc.node_registry.lookup_by_id.get(node_id) orelse return error.InvalidNodeId;

    lp.actions.fill(node.dom, params.text, frame) catch |err| {
        if (err == error.InvalidNodeType) return error.InvalidParam;
        return error.InternalError;
    };

    return cmd.sendResult(.{}, .{});
}

fn scrollNode(cmd: anytype) !void {
    const Params = struct {
        nodeId: ?Node.Id = null,
        backendNodeId: ?Node.Id = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParam;

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const maybe_node_id = params.nodeId orelse params.backendNodeId;

    var target_node: ?*DOMNode = null;
    if (maybe_node_id) |node_id| {
        const node = bc.node_registry.lookup_by_id.get(node_id) orelse return error.InvalidNodeId;
        target_node = node.dom;
    }

    lp.actions.scroll(target_node, params.x, params.y, frame) catch |err| {
        if (err == error.InvalidNodeType) return error.InvalidParam;
        return error.InternalError;
    };

    return cmd.sendResult(.{}, .{});
}

fn waitForSelector(cmd: anytype) !void {
    const Params = struct {
        selector: []const u8,
        timeout: ?u32 = null,
    };
    const params = (try cmd.params(Params)) orelse return error.InvalidParam;

    const bc = cmd.browser_context orelse return error.NoBrowserContext;
    _ = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const timeout_ms = params.timeout orelse 5000;
    const selector_z = try cmd.arena.dupeZ(u8, params.selector);

    const node = lp.actions.waitForSelector(selector_z, timeout_ms, bc.session) catch |err| {
        if (err == error.InvalidSelector) return error.InvalidParam;
        if (err == error.Timeout) return error.InternalError;
        return error.InternalError;
    };

    const registered = try bc.node_registry.register(node);
    return cmd.sendResult(.{
        .backendNodeId = registered.id,
    }, .{});
}

// Lightpanda-namespaced pre-arm for window.alert/confirm/prompt return values.
//
// Standard CDP drivers send Page.handleJavaScriptDialog *reactively* in
// response to a Page.javascriptDialogOpening event — the dialog suspends
// JS, the client picks accept/dismiss, the runtime resumes. Lightpanda's
// dialogs auto-dismiss in headless mode (window.alert/confirm/prompt
// return immediately rather than blocking V8), so by the time the event
// reaches the client, JS has already returned. A reactive call has
// nothing left to influence — full Chrome-faithful behavior would
// require V8 suspension, which #2082 / PR #2085 deferred.
//
// LP.handleJavaScriptDialog gives Lightpanda-aware clients a *proactive*
// opt-in: the client sets {accept, promptText} *before* triggering the JS
// that opens the dialog. The handler stashes the response on the
// BrowserContext; when the next dialog dispatches the
// `javascript_dialog_opening` notification, the listener in page.zig
// pops the stash and fills it into the dispatch's response output param.
// window.alert/confirm/prompt then return that value.
//
// Page.handleJavaScriptDialog continues to return -32000 "No dialog is
// showing" so reactive Chrome-style drivers see no semantic change.
//
// Without a pre-armed response, behavior is unchanged from PR #2085:
// confirm→false, prompt→null, alert→void.
fn handleJavaScriptDialog(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        accept: bool,
        promptText: ?[]const u8 = null,
    })) orelse return error.InvalidParam;

    const bc = cmd.browser_context orelse return error.NoBrowserContext;

    // Duplicate promptText into the BrowserContext arena so it outlives the
    // CDP command's own message arena (the dialog may fire on a later command).
    const prompt_text: ?[]const u8 = if (params.promptText) |t|
        try bc.arena.dupe(u8, t)
    else
        null;

    bc.pending_dialog_response = .{
        .accept = params.accept,
        .prompt_text = prompt_text,
    };

    return cmd.sendResult(null, .{});
}

const testing = @import("../testing.zig");
test "cdp.lp: getMarkdown" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.getMarkdown",
    });

    const result = (try ctx.getSentMessage(0)).?.object.get("result").?.object;
    try testing.expect(result.get("markdown") != null);
}

test "cdp.lp: getInteractiveElements" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.getInteractiveElements",
    });

    const result = (try ctx.getSentMessage(0)).?.object.get("result").?.object;
    try testing.expect(result.get("elements") != null);
}

test "cdp.lp: getStructuredData" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.getStructuredData",
    });

    const result = (try ctx.getSentMessage(0)).?.object.get("result").?.object;
    try testing.expect(result.get("structuredData") != null);
}

test "cdp.lp: action tools" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const frame = try bc.session.createPage();
    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    var runner = try bc.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });

    // Test Click
    const btn = frame.document.getElementById("btn", frame).?.asNode();
    const btn_id = (try bc.node_registry.register(btn)).id;
    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.clickNode",
        .params = .{ .backendNodeId = btn_id },
    });

    // Test Fill Input
    const inp = frame.document.getElementById("inp", frame).?.asNode();
    const inp_id = (try bc.node_registry.register(inp)).id;
    try ctx.processMessage(.{
        .id = 2,
        .method = "LP.fillNode",
        .params = .{ .backendNodeId = inp_id, .text = "hello" },
    });

    // Test Fill Select
    const sel = frame.document.getElementById("sel", frame).?.asNode();
    const sel_id = (try bc.node_registry.register(sel)).id;
    try ctx.processMessage(.{
        .id = 3,
        .method = "LP.fillNode",
        .params = .{ .backendNodeId = sel_id, .text = "opt2" },
    });

    // Test Scroll
    const scrollbox = frame.document.getElementById("scrollbox", frame).?.asNode();
    const scrollbox_id = (try bc.node_registry.register(scrollbox)).id;
    try ctx.processMessage(.{
        .id = 4,
        .method = "LP.scrollNode",
        .params = .{ .backendNodeId = scrollbox_id, .y = 50 },
    });

    // Evaluate assertions
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const result = try ls.local.compileAndRun("window.clicked === true && window.inputVal === 'hello' && window.changed === true && window.selChanged === 'opt2' && window.scrolled === true", null);

    try testing.expect(result.isTrue());
}

test "cdp.lp: waitForSelector" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const frame = try bc.session.createPage();
    const url = "http://localhost:9582/src/browser/tests/mcp_wait_for_selector.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    var runner = try bc.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });

    // 1. Existing element
    try ctx.processMessage(.{
        .id = 1,
        .method = "LP.waitForSelector",
        .params = .{ .selector = "#existing", .timeout = 2000 },
    });
    var result = (try ctx.getSentMessage(0)).?.object.get("result").?.object;
    try testing.expect(result.get("backendNodeId") != null);

    // 2. Delayed element
    try ctx.processMessage(.{
        .id = 2,
        .method = "LP.waitForSelector",
        .params = .{ .selector = "#delayed", .timeout = 5000 },
    });
    result = (try ctx.getSentMessage(1)).?.object.get("result").?.object;
    try testing.expect(result.get("backendNodeId") != null);

    // 3. Timeout error
    try ctx.processMessage(.{
        .id = 3,
        .method = "LP.waitForSelector",
        .params = .{ .selector = "#nonexistent", .timeout = 100 },
    });
    const err_obj = (try ctx.getSentMessage(2)).?.object.get("error").?.object;
    try testing.expect(err_obj.get("code") != null);
}

test "cdp.lp: handleJavaScriptDialog accepts/dismisses without an open dialog" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // Without a BrowserContext: error (matches other LP handlers' shape).
        try ctx.processMessage(.{ .id = 1, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = true } });
        try ctx.expectSentError(-31998, "NoBrowserContext", .{ .id = 1 });
    }

    _ = try ctx.loadBrowserContext(.{ .id = "BID-D1", .url = "cdp/dialog.html", .target_id = "FID-000000000X".* });

    {
        // Pre-arming with accept=true succeeds. Headless browsers auto-dismiss,
        // so the CDP client sends LP.handleJavaScriptDialog *before* the JS
        // that opens the dialog — handler stashes the response on the
        // BrowserContext.
        try ctx.processMessage(.{ .id = 2, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = true } });
        try ctx.expectSentResult(null, .{ .id = 2 });
    }

    {
        // Pre-arming with accept=false also succeeds.
        try ctx.processMessage(.{ .id = 3, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = false } });
        try ctx.expectSentResult(null, .{ .id = 3 });
    }

    {
        // Pre-arming with a promptText also succeeds. The string is dup'd into
        // the BrowserContext arena so it survives until the dialog dispatches.
        try ctx.processMessage(.{ .id = 4, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = true, .promptText = "hello" } });
        try ctx.expectSentResult(null, .{ .id = 4 });
    }
}

test "cdp.lp: handleJavaScriptDialog controls confirm/prompt/alert return values" {
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-D2", .url = "cdp/dialog.html", .target_id = "FID-000000000X".* });

    const frame = bc.session.currentFrame() orelse unreachable;
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // ---- confirm: accept=true makes confirm() return true ----
    try ctx.processMessage(.{ .id = 1, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = true } });
    try ctx.expectSentResult(null, .{ .id = 1 });

    const c_accept = try ls.local.exec("confirm('proceed?')", null);
    try testing.expectEqual(true, c_accept.toBool());
    try ctx.expectSentEvent("Page.javascriptDialogOpening", .{
        .message = "proceed?",
        .type = "confirm",
        .hasBrowserHandler = false,
        .defaultPrompt = "",
    }, .{ .session_id = "SID-X" });

    // ---- confirm: accept=false makes confirm() return false ----
    try ctx.processMessage(.{ .id = 2, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = false } });
    try ctx.expectSentResult(null, .{ .id = 2 });

    const c_dismiss = try ls.local.exec("confirm('again?')", null);
    try testing.expectEqual(false, c_dismiss.toBool());

    // ---- confirm: no pre-arm preserves PR #2085 default (false) ----
    const c_default = try ls.local.exec("confirm('default?')", null);
    try testing.expectEqual(false, c_default.toBool());

    // ---- prompt: accept=true with promptText returns the text ----
    try ctx.processMessage(.{ .id = 3, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = true, .promptText = "hello" } });
    try ctx.expectSentResult(null, .{ .id = 3 });

    const p_text = try ls.local.exec("prompt('name?')", null);
    const p_text_str = try p_text.toStringSlice();
    try testing.expectEqualSlices(u8, "hello", p_text_str);

    // ---- prompt: accept=true without promptText AND no dialog defaultText returns "" ----
    try ctx.processMessage(.{ .id = 4, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = true } });
    try ctx.expectSentResult(null, .{ .id = 4 });

    const p_empty = try ls.local.exec("prompt('name?')", null);
    const p_empty_str = try p_empty.toStringSlice();
    try testing.expectEqualSlices(u8, "", p_empty_str);

    // ---- prompt: accept=true without promptText falls back to dialog defaultText ----
    // Mirrors Chrome's accept-without-typing behavior: with no client-supplied
    // promptText, the prompt's return value is the second arg to window.prompt.
    try ctx.processMessage(.{ .id = 5, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = true } });
    try ctx.expectSentResult(null, .{ .id = 5 });

    const p_default_text = try ls.local.exec("prompt('name?', 'John Smith')", null);
    const p_default_text_str = try p_default_text.toStringSlice();
    try testing.expectEqualSlices(u8, "John Smith", p_default_text_str);

    // ---- prompt: pre-armed promptText overrides the dialog defaultText ----
    try ctx.processMessage(.{ .id = 6, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = true, .promptText = "typed" } });
    try ctx.expectSentResult(null, .{ .id = 6 });

    const p_override = try ls.local.exec("prompt('name?', 'John Smith')", null);
    const p_override_str = try p_override.toStringSlice();
    try testing.expectEqualSlices(u8, "typed", p_override_str);

    // ---- prompt: accept=false returns null regardless of dialog defaultText ----
    try ctx.processMessage(.{ .id = 7, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = false } });
    try ctx.expectSentResult(null, .{ .id = 7 });

    const p_dismiss_with_default = try ls.local.exec("prompt('cancel?', 'John Smith')", null);
    try testing.expect(p_dismiss_with_default.isNull());

    // ---- prompt: accept=false makes prompt() return null ----
    try ctx.processMessage(.{ .id = 8, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = false } });
    try ctx.expectSentResult(null, .{ .id = 8 });

    const p_dismiss = try ls.local.exec("prompt('cancel?')", null);
    try testing.expect(p_dismiss.isNull());

    // ---- prompt: no pre-arm preserves PR #2085 default (null) ----
    const p_default = try ls.local.exec("prompt('default?')", null);
    try testing.expect(p_default.isNull());

    // ---- alert: dispatches the event but has no return value to override ----
    try ctx.processMessage(.{ .id = 9, .method = "LP.handleJavaScriptDialog", .params = .{ .accept = true } });
    try ctx.expectSentResult(null, .{ .id = 9 });
    _ = try ls.local.exec("alert('important')", null);
    try ctx.expectSentEvent("Page.javascriptDialogOpening", .{
        .message = "important",
        .type = "alert",
    }, .{ .session_id = "SID-X" });

    // ---- pending response is consumed by exactly one dialog ----
    // After the alert above pops the pre-arm, the next confirm sees no pending
    // and falls back to the default (false) — the alert MUST clear pending so
    // the response doesn't leak across dialogs.
    const c_after_alert = try ls.local.exec("confirm('leak?')", null);
    try testing.expectEqual(false, c_after_alert.toBool());
}
