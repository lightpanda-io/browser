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

const id = @import("../id.zig");
const log = @import("../../log.zig");
const js = @import("../../browser/js/js.zig");
const URL = @import("../../browser/URL.zig");
const Page = @import("../../browser/Page.zig");
const timestampF = @import("../../datetime.zig").timestamp;
const Notification = @import("../../Notification.zig");

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getFrameTree,
        setLifecycleEventsEnabled,
        addScriptToEvaluateOnNewDocument,
        createIsolatedWorld,
        navigate,
        reload,
        stopLoading,
        close,
        captureScreenshot,
        getLayoutMetrics,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getFrameTree => return getFrameTree(cmd),
        .setLifecycleEventsEnabled => return setLifecycleEventsEnabled(cmd),
        .addScriptToEvaluateOnNewDocument => return addScriptToEvaluateOnNewDocument(cmd),
        .createIsolatedWorld => return createIsolatedWorld(cmd),
        .navigate => return navigate(cmd),
        .reload => return doReload(cmd),
        .stopLoading => return cmd.sendResult(null, .{}),
        .close => return close(cmd),
        .captureScreenshot => return captureScreenshot(cmd),
        .getLayoutMetrics => return getLayoutMetrics(cmd),
    }
}

const Frame = struct {
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

fn getFrameTree(cmd: anytype) !void {
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
            .frame = Frame{
                .id = &target_id,
                .securityOrigin = bc.security_origin,
                .loaderId = "LID-0000000001",
                .url = bc.getURL() orelse "about:blank",
                .secureContextType = bc.secure_context_type,
            },
        },
    }, .{});
}

fn setLifecycleEventsEnabled(cmd: anytype) !void {
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
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    if (page._load_state == .complete) {
        const frame_id = &id.toFrameId(page._frame_id);
        const loader_id = &id.toLoaderId(page._req_id);

        const now = timestampF(.monotonic);
        try sendPageLifecycle(bc, "DOMContentLoaded", now, frame_id, loader_id);
        try sendPageLifecycle(bc, "load", now, frame_id, loader_id);

        const http_client = page._session.browser.http_client;
        const http_active = http_client.active;
        const total_network_activity = http_active + http_client.intercepted;
        if (page._notified_network_almost_idle.check(total_network_activity <= 2)) {
            try sendPageLifecycle(bc, "networkAlmostIdle", now, frame_id, loader_id);
        }
        if (page._notified_network_idle.check(total_network_activity == 0)) {
            try sendPageLifecycle(bc, "networkIdle", now, frame_id, loader_id);
        }
    }

    return cmd.sendResult(null, .{});
}

// TODO: hard coded method
// With the command we receive a script we need to store and run for each new document.
// Note that the worldName refers to the name given to the isolated world.
fn addScriptToEvaluateOnNewDocument(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     source: []const u8,
    //     worldName: ?[]const u8 = null,
    //     includeCommandLineAPI: bool = false,
    //     runImmediately: bool = false,
    // })) orelse return error.InvalidParams;

    return cmd.sendResult(.{
        .identifier = "1",
    }, .{});
}

fn close(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const target_id = bc.target_id orelse return error.TargetNotLoaded;

    // can't be null if we have a target_id
    lp.assert(bc.session.page != null, "CDP.page.close null page", .{});

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

fn createIsolatedWorld(cmd: anytype) !void {
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
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    const js_context = try world.createContext(page);
    return cmd.sendResult(.{ .executionContextId = js_context.id }, .{});
}

fn navigate(cmd: anytype) !void {
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
    var page = session.currentPage() orelse return error.PageNotLoaded;

    if (page._load_state != .waiting) {
        page = try session.replacePage();
    }

    const encoded_url = try URL.ensureEncoded(page.call_arena, params.url);
    try page.navigate(encoded_url, .{
        .reason = .address_bar,
        .cdp_id = cmd.input.id,
        .kind = .{ .push = null },
    });
}

fn doReload(cmd: anytype) !void {
    const params = try cmd.params(struct {
        ignoreCache: ?bool = null,
        scriptToEvaluateOnLoad: ?[]const u8 = null,
    });

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    if (bc.session_id == null) {
        return error.SessionIdNotLoaded;
    }

    const session = bc.session;
    var page = session.currentPage() orelse return error.PageNotLoaded;

    // Dupe URL before replacePage() frees the old page's arena.
    const reload_url = try cmd.arena.dupeZ(u8, page.url);

    if (page._load_state != .waiting) {
        page = try session.replacePage();
    }

    try page.navigate(reload_url, .{
        .reason = .address_bar,
        .cdp_id = cmd.input.id,
        .kind = .reload,
        .force = if (params) |p| p.ignoreCache orelse false else false,
    });
}

pub fn pageNavigate(bc: anytype, event: *const Notification.PageNavigate) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;
    bc.reset();

    const frame_id = &id.toFrameId(event.frame_id);
    const loader_id = &id.toLoaderId(event.req_id);

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

pub fn pageRemove(bc: anytype) !void {
    // Clear all remote object mappings to prevent stale objectIds from being used
    // after the context is destroy
    bc.inspector_session.inspector.resetContextGroup();

    // The main page is going to be removed, we need to remove contexts from other worlds first.
    for (bc.isolated_worlds.items) |isolated_world| {
        try isolated_world.removeContext();
    }
}

pub fn pageCreated(bc: anytype, page: *Page) !void {
    _ = bc.cdp.page_arena.reset(.{ .retain_with_limit = 1024 * 512 });

    for (bc.isolated_worlds.items) |isolated_world| {
        _ = try isolated_world.createContext(page);
    }
    // Only retain captured responses until a navigation event. In CDP term,
    // this is called a "renderer" and the cache-duration can be controlled via
    // the Network.configureDurableMessages message (which we don't support)
    bc.captured_responses = .empty;
}

pub fn pageFrameCreated(bc: anytype, event: *const Notification.PageFrameCreated) !void {
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
            .loaderId = &id.toLoaderId(event.frame_id),
            .timestamp = event.timestamp,
        }, .{ .session_id = session_id });
    }
}

pub fn pageNavigated(arena: Allocator, bc: anytype, event: *const Notification.PageNavigated) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const timestamp = event.timestamp;
    const frame_id = &id.toFrameId(event.frame_id);
    const loader_id = &id.toLoaderId(event.req_id);

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

    const page = bc.session.currentPage() orelse return error.PageNotLoaded;

    // When we actually recreated the context we should have the inspector send
    // this event, see: resetContextGroup Sending this event will tell the
    // client that the context ids they had are invalid and the context shouls
    // be dropped The client will expect us to send new contextCreated events,
    // such that the client has new id's for the active contexts.
    // Only send executionContextsCleared for main frame navigations. For child
    // frames (iframes), clearing all contexts would destroy the main frame's
    // context, causing Puppeteer's page.evaluate()/page.content() to hang
    // forever.
    if (event.frame_id == page._frame_id) {
        try cdp.sendEvent("Runtime.executionContextsCleared", null, .{ .session_id = session_id });
    }

    {
        const aux_data = try std.fmt.allocPrint(arena, "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\",\"loaderId\":\"{s}\"}}", .{ frame_id, loader_id });

        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        bc.inspector_session.inspector.contextCreated(
            &ls.local,
            "",
            page.origin orelse "",
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

    // frameNavigated event
    try cdp.sendEvent("Page.frameNavigated", .{
        .type = "Navigation",
        .frame = Frame{
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

    // domContentEventFired event
    // TODO: partially hard coded
    try cdp.sendEvent(
        "Page.domContentEventFired",
        .{ .timestamp = timestamp },
        .{ .session_id = session_id },
    );

    // lifecycle DOMContentLoaded event
    // TODO: partially hard coded
    if (bc.page_life_cycle_events) {
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .timestamp = timestamp,
            .name = "DOMContentLoaded",
            .frameId = frame_id,
            .loaderId = loader_id,
        }, .{ .session_id = session_id });
    }

    // loadEventFired event
    try cdp.sendEvent(
        "Page.loadEventFired",
        .{ .timestamp = timestamp },
        .{ .session_id = session_id },
    );

    // lifecycle DOMContentLoaded event
    if (bc.page_life_cycle_events) {
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .timestamp = timestamp,
            .name = "load",
            .frameId = frame_id,
            .loaderId = loader_id,
        }, .{ .session_id = session_id });
    }

    // frameStoppedLoading
    return cdp.sendEvent("Page.frameStoppedLoading", .{
        .frameId = frame_id,
    }, .{ .session_id = session_id });
}

pub fn pageNetworkIdle(bc: anytype, event: *const Notification.PageNetworkIdle) !void {
    return sendPageLifecycle(bc, "networkIdle", event.timestamp, &id.toFrameId(event.frame_id), &id.toLoaderId(event.req_id));
}

pub fn pageNetworkAlmostIdle(bc: anytype, event: *const Notification.PageNetworkAlmostIdle) !void {
    return sendPageLifecycle(bc, "networkAlmostIdle", event.timestamp, &id.toFrameId(event.frame_id), &id.toLoaderId(event.req_id));
}

fn sendPageLifecycle(bc: anytype, name: []const u8, timestamp: u64, frame_id: []const u8, loader_id: []const u8) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    return bc.cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
        .name = name,
        .frameId = frame_id,
        .loaderId = loader_id,
        .timestamp = timestamp,
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

fn captureScreenshot(cmd: anytype) !void {
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

fn getLayoutMetrics(cmd: anytype) !void {
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
test "cdp.page: getFrameTree" {
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
        // STARTUP sesion is handled when a broweser context and a target id exists.
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

test "cdp.page: captureScreenshot" {
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

test "cdp.page: getLayoutMetrics" {
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

test "cdp.page: reload" {
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
