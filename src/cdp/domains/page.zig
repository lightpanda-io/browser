// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const URL = @import("../../url.zig").URL;
const Page = @import("../../browser/page.zig").Page;
const Notification = @import("../../notification.zig").Notification;

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getFrameTree,
        setLifecycleEventsEnabled,
        addScriptToEvaluateOnNewDocument,
        createIsolatedWorld,
        navigate,
        stopLoading,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getFrameTree => return getFrameTree(cmd),
        .setLifecycleEventsEnabled => return setLifecycleEventsEnabled(cmd),
        .addScriptToEvaluateOnNewDocument => return addScriptToEvaluateOnNewDocument(cmd),
        .createIsolatedWorld => return createIsolatedWorld(cmd),
        .navigate => return navigate(cmd),
        .stopLoading => return cmd.sendResult(null, .{}),
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
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const target_id = bc.target_id orelse return error.TargetNotLoaded;

    return cmd.sendResult(.{
        .frameTree = .{
            .frame = Frame{
                .id = target_id,
                .loaderId = bc.loader_id,
                .securityOrigin = bc.security_origin,
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
    if (params.enabled) {
        try bc.lifecycleEventsEnable();
    } else {
        bc.lifecycleEventsDisable();
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

fn createIsolatedWorld(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        frameId: []const u8,
        worldName: []const u8,
        grantUniveralAccess: bool,
    })) orelse return error.InvalidParams;
    if (!params.grantUniveralAccess) {
        std.debug.print("grantUniveralAccess == false is not yet implemented", .{});
        // When grantUniveralAccess == false and the client attempts to resolve
        // or otherwise access a DOM or other JS Object from another context that should fail.
    }
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const world = try bc.createIsolatedWorld(params.worldName, params.grantUniveralAccess);
    const page = bc.session.currentPage() orelse return error.PageNotLoaded;
    try pageCreated(bc, page);
    const js_context = &world.executor.js_context.?;

    // Create the auxdata json for the contextCreated event
    // Calling contextCreated will assign a Id to the context and send the contextCreated event
    const aux_data = try std.fmt.allocPrint(cmd.arena, "{{\"isDefault\":false,\"type\":\"isolated\",\"frameId\":\"{s}\"}}", .{params.frameId});
    bc.inspector.contextCreated(js_context, world.name, "", aux_data, false);

    return cmd.sendResult(.{ .executionContextId = js_context.v8_context.debugContextId() }, .{});
}

fn navigate(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        url: []const u8,
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

    var page = bc.session.currentPage() orelse return error.PageNotLoaded;
    bc.loader_id = bc.cdp.loader_id_gen.next();

    try page.navigate(params.url, .{
        .reason = .address_bar,
        .cdp_id = cmd.input.id,
    });
}

pub fn pageNavigate(arena: Allocator, bc: anytype, event: *const Notification.PageNavigate) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    bc.loader_id = bc.cdp.loader_id_gen.next();
    const loader_id = bc.loader_id;
    const target_id = bc.target_id orelse unreachable;

    bc.reset();

    var cdp = bc.cdp;
    const reason_: ?[]const u8 = switch (event.opts.reason) {
        .anchor => "anchorClick",
        .script => "scriptInitiated",
        .form => switch (event.opts.method) {
            .GET => "formSubmissionGet",
            .POST => "formSubmissionPost",
            else => unreachable,
        },
        .address_bar => null,
    };
    if (reason_) |reason| {
        try cdp.sendEvent("Page.frameScheduledNavigation", .{
            .frameId = target_id,
            .delay = 0,
            .reason = reason,
            .url = event.url,
        }, .{ .session_id = session_id });

        try cdp.sendEvent("Page.frameRequestedNavigation", .{
            .frameId = target_id,
            .reason = reason,
            .url = event.url,
            .disposition = "currentTab",
        }, .{ .session_id = session_id });
    }

    // frameStartedNavigating event
    try cdp.sendEvent("Page.frameStartedNavigating", .{
        .frameId = target_id,
        .url = event.url,
        .loaderId = loader_id,
        .navigationType = "differentDocument",
    }, .{ .session_id = session_id });

    // frameStartedLoading event
    try cdp.sendEvent("Page.frameStartedLoading", .{
        .frameId = target_id,
    }, .{ .session_id = session_id });

    // Drivers are sensitive to the order of events. Some more than others.
    // The result for the Page.navigate seems like it _must_ come after
    // the frameStartedLoading, but before any lifecycleEvent. So we
    // unfortunately have to put the input_id ito the NavigateOpts which gets
    // passed back into the notification.
    if (event.opts.cdp_id) |input_id| {
        try cdp.sendJSON(.{
            .id = input_id,
            .result = .{
                .frameId = target_id,
                .loaderId = loader_id,
            },
            .sessionId = session_id,
        });
    }

    if (bc.page_life_cycle_events) {
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .name = "init",
            .frameId = target_id,
            .loaderId = loader_id,
            .timestamp = event.timestamp,
        }, .{ .session_id = session_id });
    }

    if (reason_ != null) {
        try cdp.sendEvent("Page.frameClearedScheduledNavigation", .{
            .frameId = target_id,
        }, .{ .session_id = session_id });
    }

    // When we actually recreated the context we should have the inspector send this event, see: resetContextGroup
    // Sending this event will tell the client that the context ids they had are invalid and the context shouls be dropped
    // The client will expect us to send new contextCreated events, such that the client has new id's for the active contexts.
    try cdp.sendEvent("Runtime.executionContextsCleared", null, .{ .session_id = session_id });

    {
        const page = bc.session.currentPage() orelse return error.PageNotLoaded;
        const aux_data = try std.fmt.allocPrint(arena, "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}", .{target_id});
        bc.inspector.contextCreated(
            page.main_context,
            "",
            try page.origin(arena),
            aux_data,
            true,
        );
    }
    if (bc.isolated_world) |*isolated_world| {
        const aux_json = try std.fmt.allocPrint(arena, "{{\"isDefault\":false,\"type\":\"isolated\",\"frameId\":\"{s}\"}}", .{target_id});
        // Calling contextCreated will assign a new Id to the context and send the contextCreated event
        bc.inspector.contextCreated(
            &isolated_world.executor.js_context.?,
            isolated_world.name,
            "://",
            aux_json,
            false,
        );
    }
}

pub fn pageRemove(bc: anytype) !void {
    // The main page is going to be removed, we need to remove contexts from other worlds first.
    if (bc.isolated_world) |*isolated_world| {
        try isolated_world.removeContext();
    }
}

pub fn pageCreated(bc: anytype, page: *Page) !void {
    if (bc.isolated_world) |*isolated_world| {
        // We need to recreate the isolated world context
        try isolated_world.createContext(page);

        const polyfill = @import("../../browser/polyfill/polyfill.zig");
        try polyfill.preload(bc.arena, &isolated_world.executor.js_context.?);
    }
}

pub fn pageNavigated(bc: anytype, event: *const Notification.PageNavigated) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;
    const loader_id = bc.loader_id;
    const target_id = bc.target_id orelse unreachable;
    const timestamp = event.timestamp;

    var cdp = bc.cdp;
    // frameNavigated event
    try cdp.sendEvent("Page.frameNavigated", .{
        .type = "Navigation",
        .frame = Frame{
            .id = target_id,
            .url = event.url,
            .loaderId = bc.loader_id,
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
            .frameId = target_id,
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
            .frameId = target_id,
            .loaderId = loader_id,
        }, .{ .session_id = session_id });
    }

    // frameStoppedLoading
    return cdp.sendEvent("Page.frameStoppedLoading", .{
        .frameId = target_id,
    }, .{ .session_id = session_id });
}

pub fn pageNetworkIdle(bc: anytype, event: *const Notification.PageNetworkIdle) !void {
    return sendPageLifecycle(bc, "networkIdle", event.timestamp);
}

pub fn pageNetworkAlmostIdle(bc: anytype, event: *const Notification.PageNetworkAlmostIdle) !void {
    return sendPageLifecycle(bc, "networkAlmostIdle", event.timestamp);
}

fn sendPageLifecycle(bc: anytype, name: []const u8, timestamp: u32) !void {
    // detachTarget could be called, in which case, we still have a page doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const loader_id = bc.loader_id;
    const target_id = bc.target_id orelse unreachable;
    return bc.cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
        .name = name,
        .frameId = target_id,
        .loaderId = loader_id,
        .timestamp = timestamp,
    }, .{ .session_id = session_id });
}

const LifecycleEvent = struct {
    frameId: []const u8,
    loaderId: ?[]const u8,
    name: []const u8,
    timestamp: u32,
};

const testing = @import("../testing.zig");
test "cdp.page: getFrameTree" {
    var ctx = testing.context();
    defer ctx.deinit();

    {
        try testing.expectError(error.BrowserContextNotLoaded, ctx.processMessage(.{ .id = 10, .method = "Page.getFrameTree", .params = .{ .targetId = "X" } }));
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .target_id = "TID-3" });
    {
        try ctx.processMessage(.{ .id = 11, .method = "Page.getFrameTree" });
        try ctx.expectSentResult(.{
            .frameTree = .{
                .frame = .{
                    .id = "TID-3",
                    .loaderId = bc.loader_id,
                    .url = "about:blank",
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
}
