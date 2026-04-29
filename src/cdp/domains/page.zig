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
const lp = @import("lightpanda");

const screenshot_png = @embedFile("screenshot.png");
const screenshot_pdf = @embedFile("screenshot.pdf");

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");

const js = @import("../../browser/js/js.zig");
const URL = @import("../../browser/URL.zig");
const Frame = @import("../../browser/Frame.zig");
const timestampF = @import("../../datetime.zig").timestamp;
const Notification = @import("../../Notification.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getFrameTree,
        setLifecycleEventsEnabled,
        addScriptToEvaluateOnNewDocument,
        removeScriptToEvaluateOnNewDocument,
        createIsolatedWorld,
        navigate,
        reload,
        stopLoading,
        close,
        captureScreenshot,
        printToPDF,
        getLayoutMetrics,
        handleJavaScriptDialog,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getFrameTree => return getFrameTree(cmd),
        .setLifecycleEventsEnabled => return setLifecycleEventsEnabled(cmd),
        .addScriptToEvaluateOnNewDocument => return addScriptToEvaluateOnNewDocument(cmd),
        .removeScriptToEvaluateOnNewDocument => return removeScriptToEvaluateOnNewDocument(cmd),
        .createIsolatedWorld => return createIsolatedWorld(cmd),
        .navigate => return navigate(cmd),
        .reload => return doReload(cmd),
        .stopLoading => return cmd.sendResult(null, .{}),
        .close => return close(cmd),
        .captureScreenshot => return captureScreenshot(cmd),
        .printToPDF => return printToPDF(cmd),
        .getLayoutMetrics => return getLayoutMetrics(cmd),
        .handleJavaScriptDialog => return handleJavaScriptDialog(cmd),
    }
}

const CDPFrame = struct {
    id: []const u8,
    loaderId: []const u8,
    url: []const u8,
    domainAndRegistry: []const u8 = "",
    securityOrigin: []const u8,
    mimeType: []const u8 = "text/html",
    adFrameStatus: struct {
        adFrameType: []const u8 = "none",
    } = .{},
    secureContextType: []const u8,
    crossOriginIsolatedContextType: []const u8 = "NotIsolated",
    gatedAPIFeatures: [][]const u8 = &[0][]const u8{},
};

fn getFrameTree(cmd: *CDP.Command) !void {
    // Stagehand parses the response and error if we don't return a
    // correct one for this call when browser context or target id are missing.
    const startup = .{
        .frameTree = .{
            .frame = .{
                .id = "TID-STARTUP",
                .loaderId = "LID-STARTUP",
                .securityOrigin = @import("../CDP.zig").URL_BASE,
                .url = "about:blank",
                .secureContextType = "Secure",
            },
        },
    };
    const bc = cmd.browser_context orelse return cmd.sendResult(startup, .{});
    const target_id = bc.target_id orelse return cmd.sendResult(startup, .{});

    return cmd.sendResult(.{
        .frameTree = .{
            .frame = CDPFrame{
                .id = &target_id,
                .securityOrigin = bc.security_origin,
                .loaderId = "LID-0000000001",
                .url = bc.getURL() orelse "about:blank",
                .secureContextType = bc.secure_context_type,
            },
        },
    }, .{});
}

fn setLifecycleEventsEnabled(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        enabled: bool,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    if (params.enabled == false) {
        bc.lifecycleEventsDisable();
        return cmd.sendResult(null, .{});
    }

    // Enable lifecycle events.
    try bc.lifecycleEventsEnable();

    // When we enable lifecycle events, we must dispatch events for all
    // attached targets.
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    if (frame._load_state == .complete) {
        const frame_id = &id.toFrameId(frame._frame_id);
        const loader_id = &id.toLoaderId(frame._loader_id);

        const now = timestampF(.monotonic);
        try sendPageLifecycle(bc, "DOMContentLoaded", now, frame_id, loader_id);
        try sendPageLifecycle(bc, "load", now, frame_id, loader_id);

        const http_client = frame._session.browser.http_client;
        const http_active = http_client.http_active;
        const total_network_activity = http_active + http_client.interception_layer.intercepted;
        if (frame._notified_network_almost_idle.check(total_network_activity <= 2)) {
            try sendPageLifecycle(bc, "networkAlmostIdle", now, frame_id, loader_id);
        }
        if (frame._notified_network_idle.check(total_network_activity == 0)) {
            try sendPageLifecycle(bc, "networkIdle", now, frame_id, loader_id);
        }
    }

    return cmd.sendResult(null, .{});
}

fn addScriptToEvaluateOnNewDocument(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        source: []const u8,
        worldName: ?[]const u8 = null,
        includeCommandLineAPI: bool = false,
        runImmediately: bool = false,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    if (params.runImmediately) {
        log.warn(.not_implemented, "addScriptOnNewDocument", .{ .param = "runImmediately" });
    }

    const script_id = bc.next_script_id;
    bc.next_script_id += 1;

    const source_dupe = try bc.arena.dupe(u8, params.source);
    try bc.scripts_on_new_document.append(bc.arena, .{
        .identifier = script_id,
        .source = source_dupe,
    });

    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{script_id}) catch "1";
    return cmd.sendResult(.{
        .identifier = id_str,
    }, .{});
}

fn removeScriptToEvaluateOnNewDocument(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        identifier: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const target_id = std.fmt.parseInt(u32, params.identifier, 10) catch
        return cmd.sendResult(null, .{});

    for (bc.scripts_on_new_document.items, 0..) |script, i| {
        if (script.identifier == target_id) {
            _ = bc.scripts_on_new_document.orderedRemove(i);
            break;
        }
    }
    return cmd.sendResult(null, .{});
}

fn close(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const target_id = bc.target_id orelse return error.TargetNotLoaded;

    // can't be null if we have a target_id
    lp.assert(bc.session.page != null, "CDP.frame.close null frame", .{});

    try cmd.sendResult(.{}, .{});

    // Following code is similar to target.closeTarget
    //
    // could be null, created but never attached
    if (bc.session_id) |session_id| {
        // Inspector.detached event
        try cmd.sendEvent("Inspector.detached", .{
            .reason = "Render process gone.",
        }, .{ .session_id = session_id });

        // detachedFromTarget event
        try cmd.sendEvent("Target.detachedFromTarget", .{
            .targetId = target_id,
            .sessionId = session_id,
            .reason = "Render process gone.",
        }, .{});

        bc.session_id = null;
    }

    bc.session.removePage();
    for (bc.isolated_worlds.items) |world| {
        world.deinit();
    }
    bc.isolated_worlds.clearRetainingCapacity();
    bc.target_id = null;
}

fn createIsolatedWorld(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        frameId: []const u8,
        worldName: []const u8,
        grantUniveralAccess: bool = false,
    })) orelse return error.InvalidParams;
    if (!params.grantUniveralAccess) {
        log.warn(.not_implemented, "Page.createIsolatedWorld", .{ .param = "grantUniveralAccess" });
        // When grantUniveralAccess == false and the client attempts to resolve
        // or otherwise access a DOM or other JS Object from another context that should fail.
    }
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const world = try bc.createIsolatedWorld(params.worldName, params.grantUniveralAccess);
    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    const js_context = try world.createContext(frame);
    const aux_data = try std.fmt.allocPrint(cmd.arena, "{{\"isDefault\":false,\"type\":\"isolated\",\"frameId\":\"{s}\"}}", .{params.frameId});

    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();

    bc.inspector_session.inspector.contextCreated(
        &ls.local,
        params.worldName,
        frame.origin orelse "",
        aux_data,
        false,
    );

    const context_id = bc.inspector_session.inspector.getContextId(&ls.local);
    return cmd.sendResult(.{ .executionContextId = context_id }, .{});
}

fn navigate(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        url: [:0]const u8,
        // referrer: ?[]const u8 = null,
        // transitionType: ?[]const u8 = null, // TODO: enum
        // frameId: ?[]const u8 = null,
        // referrerPolicy: ?[]const u8 = null, // TODO: enum
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // didn't create?
    // const target_id = bc.target_id orelse return error.TargetIdNotLoaded;

    // didn't attach?
    if (bc.session_id == null) {
        return error.SessionIdNotLoaded;
    }

    const session = bc.session;
    var frame = session.currentFrame() orelse return error.FrameNotLoaded;

    if (frame._load_state != .waiting) {
        // Reset isolated world identities to disable V8 weak callbacks before
        // resetPageResources releases refs. Prevents double-release crashes.
        for (bc.isolated_worlds.items) |isolated_world| {
            isolated_world.identity.deinit();
            isolated_world.identity = .{};
        }
        frame = try session.replacePage();
    }

    const encoded_url = try URL.ensureEncoded(frame.call_arena, params.url, "UTF-8");
    try frame.navigate(encoded_url, .{
        .reason = .address_bar,
        .cdp_id = cmd.input.id,
        .kind = .{ .push = null },
    });
}

fn doReload(cmd: *CDP.Command) !void {
    const params = try cmd.params(struct {
        ignoreCache: ?bool = null,
        scriptToEvaluateOnLoad: ?[]const u8 = null,
    });

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    if (bc.session_id == null) {
        return error.SessionIdNotLoaded;
    }

    const session = bc.session;
    var frame = session.currentFrame() orelse return error.FrameNotLoaded;

    // Capture URL plus the prior navigation's method/body/header before
    // replacePage() frees the old frame's arena. Replaying the same HTTP
    // method on reload matches Chrome's F5 behavior — POST navigations
    // re-submit, GET navigations re-fetch.
    const reload_url = try cmd.arena.dupeZ(u8, frame.url);
    const prev_nav = frame._navigated_options;
    const prev_body: ?[]const u8, const prev_header: ?[:0]const u8 = blk: {
        const p = prev_nav orelse break :blk .{ null, null };
        break :blk .{
            if (p.body) |b| try cmd.arena.dupe(u8, b) else null,
            if (p.header) |h| try cmd.arena.dupeZ(u8, h) else null,
        };
    };

    if (frame._load_state != .waiting) {
        // Reset isolated world identities to disable V8 weak callbacks before
        // resetPageResources releases refs. Prevents double-release crashes.
        for (bc.isolated_worlds.items) |isolated_world| {
            isolated_world.identity.deinit();
            isolated_world.identity = .{};
        }
        frame = try session.replacePage();
    }

    try frame.navigate(reload_url, .{
        .reason = .address_bar,
        .cdp_id = cmd.input.id,
        .kind = .reload,
        .force = if (params) |p| p.ignoreCache orelse false else false,
        .method = if (prev_nav) |p| p.method else .GET,
        .body = prev_body,
        .header = prev_header,
    });
}

pub fn frameNavigate(bc: *CDP.BrowserContext, event: *const Notification.FrameNavigate) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;
    bc.reset();

    const frame_id = &id.toFrameId(event.frame_id);
    const loader_id = &id.toLoaderId(event.loader_id);

    var cdp = bc.cdp;
    const reason_: ?[]const u8 = switch (event.opts.reason) {
        .anchor => "anchorClick",
        .script, .history, .navigation => "scriptInitiated",
        .form => switch (event.opts.method) {
            .GET => "formSubmissionGet",
            .POST => "formSubmissionPost",
            else => unreachable,
        },
        .address_bar => null,
        .initialFrameNavigation => "initialFrameNavigation",
    };
    if (reason_) |reason| {
        if (event.opts.reason != .initialFrameNavigation) {
            try cdp.sendEvent("Page.frameScheduledNavigation", .{
                .frameId = frame_id,
                .delay = 0,
                .reason = reason,
                .url = event.url,
            }, .{ .session_id = session_id });
        }
        try cdp.sendEvent("Page.frameRequestedNavigation", .{
            .frameId = frame_id,
            .reason = reason,
            .url = event.url,
            .disposition = "currentTab",
        }, .{ .session_id = session_id });
    }

    // frameStartedNavigating event
    try cdp.sendEvent("Page.frameStartedNavigating", .{
        .frameId = frame_id,
        .url = event.url,
        .loaderId = loader_id,
        .navigationType = "differentDocument",
    }, .{ .session_id = session_id });

    // frameStartedLoading event
    try cdp.sendEvent("Page.frameStartedLoading", .{
        .frameId = frame_id,
    }, .{ .session_id = session_id });
}

pub fn frameRemove(bc: *CDP.BrowserContext) void {
    // Clear all remote object mappings to prevent stale objectIds from being used
    // after the context is destroy
    bc.inspector_session.inspector.resetContextGroup();

    // The main frame is going to be removed, we need to remove contexts from other worlds first.
    for (bc.isolated_worlds.items) |isolated_world| {
        isolated_world.removeContext();
    }
}

pub fn frameCreated(bc: *CDP.BrowserContext, frame: *Frame) !void {
    _ = bc.cdp.frame_arena.reset(.{ .retain_with_limit = 1024 * 512 });

    for (bc.isolated_worlds.items) |isolated_world| {
        _ = try isolated_world.createContext(frame);
    }
    // Only retain captured responses until a navigation event. In CDP term,
    // this is called a "renderer" and the cache-duration can be controlled via
    // the Network.configureDurableMessages message (which we don't support)
    bc.captured_responses = .empty;
}

pub fn frameChildFrameCreated(bc: *CDP.BrowserContext, event: *const Notification.FrameChildFrameCreated) !void {
    const session_id = bc.session_id orelse return;

    const cdp = bc.cdp;
    const frame_id = &id.toFrameId(event.frame_id);

    try cdp.sendEvent("Page.frameAttached", .{ .params = .{
        .frameId = frame_id,
        .parentFrameId = &id.toFrameId(event.parent_id),
    } }, .{ .session_id = session_id });

    if (bc.page_life_cycle_events) {
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .name = "init",
            .frameId = frame_id,
            .loaderId = &id.toLoaderId(event.loader_id),
            .timestamp = event.timestamp,
        }, .{ .session_id = session_id });
    }
}

pub fn frameNavigated(arena: Allocator, bc: *CDP.BrowserContext, event: *const Notification.FrameNavigated) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const frame_id = &id.toFrameId(event.frame_id);
    const loader_id = &id.toLoaderId(event.loader_id);

    var cdp = bc.cdp;

    // Drivers are sensitive to the order of events. Some more than others.
    // The result for the Page.navigate seems like it _must_ come after
    // the frameStartedLoading, but before any lifecycleEvent. So we
    // unfortunately have to put the input_id ito the NavigateOpts which gets
    // passed back into the notification.
    if (event.opts.cdp_id) |input_id| {
        try cdp.sendJSON(.{
            .id = input_id,
            .result = .{
                .frameId = frame_id,
                .loaderId = loader_id,
            },
            .sessionId = session_id,
        });
    }

    if (bc.page_life_cycle_events) {
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .name = "init",
            .frameId = frame_id,
            .loaderId = loader_id,
            .timestamp = event.timestamp,
        }, .{ .session_id = session_id });
    }

    const reason_: ?[]const u8 = switch (event.opts.reason) {
        .anchor => "anchorClick",
        .script, .history, .navigation => "scriptInitiated",
        .form => switch (event.opts.method) {
            .GET => "formSubmissionGet",
            .POST => "formSubmissionPost",
            else => unreachable,
        },
        .address_bar => null,
        .initialFrameNavigation => "initialFrameNavigation",
    };

    if (reason_ != null) {
        try cdp.sendEvent("Page.frameClearedScheduledNavigation", .{
            .frameId = frame_id,
        }, .{ .session_id = session_id });
    }

    const frame = bc.session.currentFrame() orelse return error.FrameNotLoaded;

    // When we actually recreated the context we should have the inspector send
    // this event, see: resetContextGroup. Sending this event will tell the
    // client that the context ids they had are invalid and the context should
    // be dropped. The client will expect us to send new contextCreated events,
    // such that the client has new id's for the active contexts.
    // Only send executionContextsCleared for main frame navigations. For child
    // frames (iframes), clearing all contexts would destroy the main frame's
    // context, causing Puppeteer's frame.evaluate()/frame.content() to hang
    // forever.
    if (event.frame_id == frame._frame_id) {
        try cdp.sendEvent("Runtime.executionContextsCleared", null, .{ .session_id = session_id });
    }

    // frameNavigated event
    try cdp.sendEvent("Page.frameNavigated", .{
        .type = "Navigation",
        .frame = CDPFrame{
            .id = frame_id,
            .url = event.url,
            .loaderId = loader_id,
            .securityOrigin = bc.security_origin,
            .secureContextType = bc.secure_context_type,
        },
    }, .{ .session_id = session_id });

    {
        const aux_data = try std.fmt.allocPrint(arena, "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\",\"loaderId\":\"{s}\"}}", .{ frame_id, loader_id });

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        bc.inspector_session.inspector.contextCreated(
            &ls.local,
            "",
            frame.origin orelse "",
            aux_data,
            true,
        );
    }
    for (bc.isolated_worlds.items) |isolated_world| {
        const aux_json = try std.fmt.allocPrint(arena, "{{\"isDefault\":false,\"type\":\"isolated\",\"frameId\":\"{s}\",\"loaderId\":\"{s}\"}}", .{ frame_id, loader_id });

        // Calling contextCreated will assign a new Id to the context and send the contextCreated event

        var ls: js.Local.Scope = undefined;
        (isolated_world.context orelse continue).localScope(&ls);
        defer ls.deinit();

        bc.inspector_session.inspector.contextCreated(
            &ls.local,
            isolated_world.name,
            "://",
            aux_json,
            false,
        );
    }

    // Evaluate scripts registered via Page.addScriptToEvaluateOnNewDocument.
    // Must run after the execution context is created but before the client
    // receives frameNavigated/loadEventFired so polyfills are available for
    // subsequent CDP commands.
    if (bc.scripts_on_new_document.items.len > 0) {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        for (bc.scripts_on_new_document.items) |script| {
            var try_catch: lp.js.TryCatch = undefined;
            try_catch.init(&ls.local);
            defer try_catch.deinit();

            ls.local.eval(script.source, null) catch |err| {
                const caught = try_catch.caughtOrError(arena, err);
                log.warn(.cdp, "script on new doc", .{ .caught = caught });
            };
        }
    }

    // frameNavigated event
    try cdp.sendEvent("Page.frameNavigated", .{
        .type = "Navigation",
        .frame = CDPFrame{
            .id = frame_id,
            .url = event.url,
            .loaderId = loader_id,
            .securityOrigin = bc.security_origin,
            .secureContextType = bc.secure_context_type,
        },
    }, .{ .session_id = session_id });

    // The DOM.documentUpdated event must be send after the frameNavigated one.
    // chromedp client expects to receive the events is this order.
    // see https://github.com/chromedp/chromedp/issues/1558
    try cdp.sendEvent("DOM.documentUpdated", null, .{ .session_id = session_id });
}

pub fn frameDOMContentLoaded(bc: anytype, event: *const Notification.FrameDOMContentLoaded) !void {
    const session_id = bc.session_id orelse return;
    const timestamp = event.timestamp;
    var cdp = bc.cdp;

    try cdp.sendEvent(
        "Page.domContentEventFired",
        .{ .timestamp = timestamp },
        .{ .session_id = session_id },
    );

    if (bc.page_life_cycle_events) {
        const frame_id = &id.toFrameId(event.frame_id);
        const loader_id = &id.toLoaderId(event.loader_id);
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .timestamp = timestamp,
            .name = "DOMContentLoaded",
            .frameId = frame_id,
            .loaderId = loader_id,
        }, .{ .session_id = session_id });
    }
}

pub fn frameLoaded(bc: anytype, event: *const Notification.FrameLoaded) !void {
    const session_id = bc.session_id orelse return;
    const timestamp = event.timestamp;
    var cdp = bc.cdp;

    const frame_id = &id.toFrameId(event.frame_id);

    try cdp.sendEvent(
        "Page.loadEventFired",
        .{ .timestamp = timestamp },
        .{ .session_id = session_id },
    );

    if (bc.page_life_cycle_events) {
        const loader_id = &id.toLoaderId(event.loader_id);
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .timestamp = timestamp,
            .name = "load",
            .frameId = frame_id,
            .loaderId = loader_id,
        }, .{ .session_id = session_id });
    }

    return cdp.sendEvent("Page.frameStoppedLoading", .{
        .frameId = frame_id,
    }, .{ .session_id = session_id });
}

pub fn frameNetworkIdle(bc: *CDP.BrowserContext, event: *const Notification.FrameNetworkIdle) !void {
    return sendPageLifecycle(bc, "networkIdle", event.timestamp, &id.toFrameId(event.frame_id), &id.toLoaderId(event.loader_id));
}

pub fn frameNetworkAlmostIdle(bc: *CDP.BrowserContext, event: *const Notification.FrameNetworkAlmostIdle) !void {
    return sendPageLifecycle(bc, "networkAlmostIdle", event.timestamp, &id.toFrameId(event.frame_id), &id.toLoaderId(event.loader_id));
}

fn sendPageLifecycle(bc: *CDP.BrowserContext, name: []const u8, timestamp: u64, frame_id: []const u8, loader_id: []const u8) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    return bc.cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
        .name = name,
        .frameId = frame_id,
        .loaderId = loader_id,
        .timestamp = timestamp,
    }, .{ .session_id = session_id });
}

// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-handleJavaScriptDialog
fn handleJavaScriptDialog(cmd: *CDP.Command) !void {
    // Dialogs auto-dismiss in headless mode. By the time the CDP client
    // sends this command, the dialog has already returned and there is
    // no pending dialog to accept or dismiss.
    //
    // Lightpanda-aware clients that want to control confirm/prompt return
    // values can pre-arm a response via LP.handleJavaScriptDialog instead
    // (see src/cdp/domains/lp.zig).
    _ = try cmd.params(struct {
        accept: bool,
        promptText: ?[]const u8 = null,
    });
    return cmd.sendError(-32000, "No dialog is showing", .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-javascriptDialogOpening
pub fn javascriptDialogOpening(bc: anytype, event: *const Notification.JavascriptDialogOpening) !void {
    // Pop any response pre-armed via LP.handleJavaScriptDialog onto the
    // dispatch's output param so the calling alert/confirm/prompt returns
    // the CDP client's choice. Cleared unconditionally — a stash applies
    // to exactly one dialog.
    if (bc.pending_dialog_response) |pending| {
        event.response.* = pending;
        bc.pending_dialog_response = null;
    }

    const session_id = bc.session_id orelse return;
    var cdp = bc.cdp;

    try cdp.sendEvent("Page.javascriptDialogOpening", .{
        .url = event.url,
        .message = event.message,
        .type = event.dialog_type,
        .hasBrowserHandler = false,
        .defaultPrompt = "",
    }, .{ .session_id = session_id });
}

const LifecycleEvent = struct {
    frameId: []const u8,
    loaderId: ?[]const u8,
    name: []const u8,
    timestamp: u64,
};

const Viewport = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    scale: f64,
};

fn base64Encode(comptime input: []const u8) [std.base64.standard.Encoder.calcSize(input.len)]u8 {
    const encoder = std.base64.standard.Encoder;
    var buf: [encoder.calcSize(input.len)]u8 = undefined;
    _ = encoder.encode(&buf, input);
    return buf;
}

// Return a fake screenshot
fn captureScreenshot(cmd: *CDP.Command) !void {
    const Params = struct {
        format: ?[]const u8 = "png",
        quality: ?u8 = null,
        clip: ?Viewport = null,
        fromSurface: ?bool = false,
        captureBeyondViewport: ?bool = false,
        optimizeForSpeed: ?bool = false,
    };
    const params = try cmd.params(Params) orelse Params{};

    const format = params.format orelse "png";

    if (!std.mem.eql(u8, format, "png")) {
        log.warn(.not_implemented, "Page.captureScreenshot params", .{ .format = format });
        return cmd.sendError(-32000, "unsupported screenshot format.", .{});
    }
    if (params.quality != null) {
        log.warn(.not_implemented, "Page.captureScreenshot params", .{ .quality = params.quality });
    }
    if (params.clip != null) {
        log.warn(.not_implemented, "Page.captureScreenshot params", .{ .clip = params.clip });
    }
    if (params.fromSurface orelse false or params.captureBeyondViewport orelse false or params.optimizeForSpeed orelse false) {
        log.warn(.not_implemented, "Page.captureScreenshot params", .{
            .fromSurface = params.fromSurface,
            .captureBeyondViewport = params.captureBeyondViewport,
            .optimizeForSpeed = params.optimizeForSpeed,
        });
    }

    return cmd.sendResult(.{
        .data = base64Encode(screenshot_png),
    }, .{});
}

// Return a fake pdf
fn printToPDF(cmd: *CDP.Command) !void {
    // Ignore all parameters.
    return cmd.sendResult(.{
        .data = base64Encode(screenshot_pdf),
    }, .{});
}

fn getLayoutMetrics(cmd: *CDP.Command) !void {
    const width = 1920;
    const height = 1080;

    return cmd.sendResult(.{
        .layoutViewport = .{
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
        },
        .visualViewport = .{
            .offsetX = 0,
            .offsetY = 0,
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
            .scale = 1,
            .zoom = 1,
        },
        .contentSize = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        },
        .cssLayoutViewport = .{
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
        },
        .cssVisualViewport = .{
            .offsetX = 0,
            .offsetY = 0,
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
            .scale = 1,
            .zoom = 1,
        },
        .cssContentSize = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        },
    }, .{});
}

const testing = @import("../testing.zig");
test "cdp.frame: getFrameTree" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // no browser context - should return TID-STARTUP
        try ctx.processMessage(.{ .id = 1, .method = "Page.getFrameTree", .sessionId = "STARTUP" });
        try ctx.expectSentResult(.{
            .frameTree = .{
                .frame = .{
                    .id = "TID-STARTUP",
                    .loaderId = "LID-STARTUP",
                    .url = "about:blank",
                    .secureContextType = "Secure",
                },
            },
        }, .{ .id = 1, .session_id = "STARTUP" });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });
    {
        try ctx.processMessage(.{ .id = 11, .method = "Page.getFrameTree" });
        try ctx.expectSentResult(.{
            .frameTree = .{
                .frame = .{
                    .id = "FID-000000000X",
                    .loaderId = "LID-0000000001",
                    .url = "http://127.0.0.1:9582/src/browser/tests/hi.html",
                    .domainAndRegistry = "",
                    .securityOrigin = bc.security_origin,
                    .mimeType = "text/html",
                    .adFrameStatus = .{
                        .adFrameType = "none",
                    },
                    .secureContextType = bc.secure_context_type,
                    .crossOriginIsolatedContextType = "NotIsolated",
                    .gatedAPIFeatures = [_][]const u8{},
                },
            },
        }, .{ .id = 11 });
    }

    {
        // STARTUP session is handled when a broweser context and a target id exists.
        try ctx.processMessage(.{ .id = 12, .method = "Page.getFrameTree", .session_id = "STARTUP" });
        try ctx.expectSentResult(.{
            .frameTree = .{
                .frame = .{
                    .id = "FID-000000000X",
                    .loaderId = "LID-0000000001",
                    .url = "http://127.0.0.1:9582/src/browser/tests/hi.html",
                    .domainAndRegistry = "",
                    .securityOrigin = bc.security_origin,
                    .mimeType = "text/html",
                    .adFrameStatus = .{
                        .adFrameType = "none",
                    },
                    .secureContextType = bc.secure_context_type,
                    .crossOriginIsolatedContextType = "NotIsolated",
                    .gatedAPIFeatures = [_][]const u8{},
                },
            },
        }, .{ .id = 12 });
    }
}

test "cdp.frame: captureScreenshot" {
    const LogFilter = @import("../../testing.zig").LogFilter;
    const filter: LogFilter = .init(&.{.not_implemented});
    defer filter.deinit();

    var ctx = try testing.context();
    defer ctx.deinit();
    {
        try ctx.processMessage(.{ .id = 10, .method = "Page.captureScreenshot", .params = .{ .format = "jpg" } });
        try ctx.expectSentError(-32000, "unsupported screenshot format.", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 11, .method = "Page.captureScreenshot" });
        try ctx.expectSentResult(.{
            .data = base64Encode(screenshot_png),
        }, .{ .id = 11 });
    }
}

test "cdp.frame: printToPDF" {
    const LogFilter = @import("../../testing.zig").LogFilter;
    const filter: LogFilter = .init(&.{.not_implemented});
    defer filter.deinit();

    var ctx = try testing.context();
    defer ctx.deinit();
    {
        try ctx.processMessage(.{ .id = 10, .method = "Page.printToPDF", .params = .{ .landscape = true } });
        try ctx.expectSentResult(.{
            .data = base64Encode(screenshot_pdf),
        }, .{ .id = 10 });
    }
}

test "cdp.frame: getLayoutMetrics" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    const width = 1920;
    const height = 1080;

    try ctx.processMessage(.{ .id = 12, .method = "Page.getLayoutMetrics" });
    try ctx.expectSentResult(.{
        .layoutViewport = .{
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
        },
        .visualViewport = .{
            .offsetX = 0,
            .offsetY = 0,
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
            .scale = 1,
            .zoom = 1,
        },
        .contentSize = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        },
        .cssLayoutViewport = .{
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
        },
        .cssVisualViewport = .{
            .offsetX = 0,
            .offsetY = 0,
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
            .scale = 1,
            .zoom = 1,
        },
        .cssContentSize = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        },
    }, .{ .id = 12 });
}

test "cdp.frame: reload" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // reload without browser context — should error
        try ctx.processMessage(.{ .id = 30, .method = "Page.reload" });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 30 });
    }

    _ = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    {
        // reload with no params — should not error (navigation is async,
        // so no result is sent synchronously; we just verify no error)
        try ctx.processMessage(.{ .id = 31, .method = "Page.reload" });
    }

    {
        // reload with ignoreCache param
        try ctx.processMessage(.{ .id = 32, .method = "Page.reload", .params = .{ .ignoreCache = true } });
    }
}

test "cdp.frame: reload replays POST navigation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    // Manually wire up the browser context: loadBrowserContext only does GET
    // navigations, but we need the first navigation to be POST.
    const cdp_inst = ctx.cdp();
    _ = try cdp_inst.createBrowserContext();
    var bc = &cdp_inst.browser_context.?;
    bc.id = "BID-A6";
    bc.session_id = "SID-X";
    bc.target_id = "TID-A6-0000000".*;

    // First navigation: POST a form-style payload to /echo_method.
    {
        const f = try bc.session.createPage();
        try f.navigate("http://127.0.0.1:9582/echo_method", .{
            .method = .POST,
            .body = "key=value",
            .header = "Content-Type: application/x-www-form-urlencoded",
        });
        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });
    }

    // Sanity: the body confirms a POST round-tripped.
    {
        const f = bc.session.currentFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('method=POST')", null);
        try testing.expect(v.toBool());
    }

    // Trigger a CDP reload. With the fix in place, doReload captures the
    // prior POST method/body/header and replays them. Without it (regression
    // guard), the second request would silently fall back to GET.
    try ctx.processMessage(.{ .id = 50, .method = "Page.reload" });

    {
        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });
    }

    {
        const f = bc.session.currentFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('method=POST')", null);
        try testing.expect(v.toBool());
    }
}

test "cdp.frame: reload after POST→redirect drops the POST" {
    // RFC 7231 §6.4.3 / §6.4.4: 302 and 303 responses to a POST cause the
    // user agent to convert the followup request to GET. The page that
    // actually loaded did so via GET, so a later Page.reload must NOT replay
    // the original POST body to the redirect target.
    var ctx = try testing.context();
    defer ctx.deinit();

    const cdp_inst = ctx.cdp();
    _ = try cdp_inst.createBrowserContext();
    var bc = &cdp_inst.browser_context.?;
    bc.id = "BID-A6R";
    bc.session_id = "SID-XR";
    bc.target_id = "TID-A6R-000000".*;

    // First navigation: POST /redirect_to_echo → 302 → GET /echo_method.
    {
        const f = try bc.session.createPage();
        try f.navigate("http://127.0.0.1:9582/redirect_to_echo", .{
            .method = .POST,
            .body = "key=value",
            .header = "Content-Type: application/x-www-form-urlencoded",
        });
        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });
    }

    // Sanity: after the redirect, the loaded page is /echo_method via GET.
    {
        const f = bc.session.currentFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('method=GET')", null);
        try testing.expect(v.toBool());
    }

    // Reload. The request that produced the current page was GET, so the
    // reload must also be GET — not a re-POST of the original form data.
    try ctx.processMessage(.{ .id = 60, .method = "Page.reload" });

    {
        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });
    }

    {
        const f = bc.session.currentFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('method=GET')", null);
        try testing.expect(v.toBool());
    }
}

test "cdp.frame: navigate inherits original fragment across redirect" {
    // RFC 7231 §7.1.2: when a 3xx Location header has no fragment, the redirect
    // inherits the fragment of the request URL.
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    {
        // Location: /redirect-target  (no fragment) — must inherit #myfrag.
        try ctx.processMessage(.{
            .id = 40,
            .method = "Page.navigate",
            .params = .{ .url = "http://127.0.0.1:9582/redirect-no-fragment#myfrag" },
        });

        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });

        const frame = bc.session.currentFrame() orelse unreachable;
        try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/redirect-target#myfrag", frame.url);
    }

    {
        // Location: /redirect-target#target_fragment — target's fragment wins.
        try ctx.processMessage(.{
            .id = 41,
            .method = "Page.navigate",
            .params = .{ .url = "http://127.0.0.1:9582/redirect-with-fragment#requested" },
        });

        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });

        const frame = bc.session.currentFrame() orelse unreachable;
        try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/redirect-target#target_fragment", frame.url);
    }

    {
        // No fragment on either side — final URL has no fragment.
        try ctx.processMessage(.{
            .id = 42,
            .method = "Page.navigate",
            .params = .{ .url = "http://127.0.0.1:9582/redirect-no-fragment" },
        });

        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });

        const frame = bc.session.currentFrame() orelse unreachable;
        try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/redirect-target", frame.url);
    }
}

test "cdp.frame: anchor click sends Referer matching the originating page" {
    // HTML Living Standard "navigate" algorithm + Fetch §4.5 "request's referrer":
    // when a navigation is initiated by a hyperlink click (or form submit, or
    // location.href assignment), the resulting request carries a Referer
    // header equal to the originating document's URL.
    var ctx = try testing.context();
    defer ctx.deinit();

    const cdp_inst = ctx.cdp();
    _ = try cdp_inst.createBrowserContext();
    var bc = &cdp_inst.browser_context.?;
    bc.id = "BID-A18";
    bc.session_id = "SID-A18";
    bc.target_id = "TID-A18-000000".*;

    // Initial navigation to the page hosting the anchor — driven directly via
    // Frame.navigate(.address_bar), so this request itself has no Referer.
    {
        const f = try bc.session.createPage();
        try f.navigate("http://127.0.0.1:9582/referer_link.html", .{});
        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });
    }

    // Click the anchor via JS. The click goes through Frame.scheduleNavigation
    // (.reason = .script), which must capture the originating frame's URL as
    // the Referer for the queued navigation.
    {
        const f = bc.session.currentFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec("document.getElementById('link').click()", null);
        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });
    }

    // After the click navigation completes, the loaded page is /echo_referer
    // and its body echoes the Referer header the server actually saw.
    {
        const f = bc.session.currentFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec(
            "document.body.innerText.includes('referer=http://127.0.0.1:9582/referer_link.html')",
            null,
        );
        try testing.expect(v.toBool());
    }
}

test "cdp.frame: address-bar Page.navigate sends no Referer" {
    // Regression guard: navigations initiated by the user agent itself (CDP
    // Page.navigate, address-bar typed URLs, Page.reload) must not leak the
    // previous page's URL as Referer. Matches Chrome.
    var ctx = try testing.context();
    defer ctx.deinit();

    const cdp_inst = ctx.cdp();
    _ = try cdp_inst.createBrowserContext();
    var bc = &cdp_inst.browser_context.?;
    bc.id = "BID-A18B";
    bc.session_id = "SID-A18B";
    bc.target_id = "TID-A18B-00000".*;

    {
        const f = try bc.session.createPage();
        try f.navigate("http://127.0.0.1:9582/echo_referer", .{});
        var runner = try bc.session.runner(.{});
        try runner.wait(.{ .ms = 2000 });
    }

    {
        const f = bc.session.currentFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('referer=NONE')", null);
        try testing.expect(v.toBool());
    }
}

test "cdp.frame: addScriptToEvaluateOnNewDocument" {
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    {
        // Register a script — should return unique identifier "1"
        try ctx.processMessage(.{ .id = 20, .method = "Page.addScriptToEvaluateOnNewDocument", .params = .{ .source = "window.__test = 1" } });
        try ctx.expectSentResult(.{
            .identifier = "1",
        }, .{ .id = 20 });
    }

    {
        // Register another script — should return identifier "2"
        try ctx.processMessage(.{ .id = 21, .method = "Page.addScriptToEvaluateOnNewDocument", .params = .{ .source = "window.__test2 = 2" } });
        try ctx.expectSentResult(.{
            .identifier = "2",
        }, .{ .id = 21 });
    }

    {
        // Remove the first script — should succeed
        try ctx.processMessage(.{ .id = 22, .method = "Page.removeScriptToEvaluateOnNewDocument", .params = .{ .identifier = "1" } });
        try ctx.expectSentResult(null, .{ .id = 22 });
    }

    {
        // Remove a non-existent identifier — should succeed silently
        try ctx.processMessage(.{ .id = 23, .method = "Page.removeScriptToEvaluateOnNewDocument", .params = .{ .identifier = "999" } });
        try ctx.expectSentResult(null, .{ .id = 23 });
    }

    {
        try ctx.processMessage(.{ .id = 34, .method = "Page.reload" });
        // wait for this event, which is sent after we've run the registered scripts
        try ctx.expectSentEvent("Page.frameNavigated", .{
            .frame = .{ .loaderId = "LID-0000000002" },
        }, .{});

        const frame = bc.session.currentFrame() orelse unreachable;

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const test_val = try ls.local.exec("window.__test2", null);
        try testing.expectEqual(2, try test_val.toI32());
    }
}
