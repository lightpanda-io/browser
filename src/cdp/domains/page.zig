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
const runtime = @import("runtime.zig");
const URL = @import("../../url.zig").URL;
const Notification = @import("../../notification.zig").Notification;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getFrameTree,
        setLifecycleEventsEnabled,
        addScriptToEvaluateOnNewDocument,
        createIsolatedWorld,
        navigate,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getFrameTree => return getFrameTree(cmd),
        .setLifecycleEventsEnabled => return setLifecycleEventsEnabled(cmd),
        .addScriptToEvaluateOnNewDocument => return addScriptToEvaluateOnNewDocument(cmd),
        .createIsolatedWorld => return createIsolatedWorld(cmd),
        .navigate => return navigate(cmd),
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
    // const params = (try cmd.params(struct {
    //     enabled: bool,
    // })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.page_life_cycle_events = true;
    return cmd.sendResult(null, .{});
}

// TODO: hard coded method
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

// TODO: hard coded method
/// @isolated_world The current understanding is that an isolated world should be a separate isolate and context
/// that would live in the BrowserContext. We think Puppetee creates this to be able to create variables
/// that are not interfering with the normal namespace of he webpage.
/// Similar to the main context we need to pretend to recreate it after a executionContextsCleared event
/// which happens when navigating to a new page.
/// Since we do not actually create an isolated context operations on this context are still performed
/// in the main context, we suspect this may lead to unexpected variables and value overwrites.
fn createIsolatedWorld(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        frameId: []const u8,
        worldName: []const u8,
        grantUniveralAccess: bool,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const session_id = cmd.input.session_id orelse return error.SessionIdRequired;

    const name_copy = try bc.session.arena.allocator().dupe(u8, params.worldName);
    const frame_id_copy = try bc.session.arena.allocator().dupe(u8, params.frameId);
    const fake_id = 0;

    bc.fake_isolatedworld = .{
        .id = fake_id,
        .origin = "", // The 2nd time chrome sends this it is "://"
        .name = name_copy,
        // TODO: hard coded ID, should change when context is recreated
        .uniqueId = "7102379147004877974.3265385113993241162",
        .auxData = .{
            .isDefault = false,
            .type = "isolated",
            .frameId = frame_id_copy,
        },
    };

    // Inform the client of the creation of the isolated world and its ID.
    // Note: Puppeteer uses the ID from this event and actually ignores the executionContextId return value
    try cmd.sendEvent("Runtime.executionContextCreated", .{ .context = bc.fake_isolatedworld }, .{ .session_id = session_id });

    try cmd.sendResult(.{
        .executionContextId = fake_id,
    }, .{});
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
    const target_id = bc.target_id orelse return error.TargetIdNotLoaded;

    // didn't attach?
    if (bc.session_id == null) {
        return error.SessionIdNotLoaded;
    }

    const url = try URL.parse(params.url, "https");

    const aux_data = try std.fmt.allocPrint(
        cmd.arena,
        // NOTE: we assume this is the default web page
        "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}",
        .{target_id},
    );

    var page = bc.session.currentPage().?;
    bc.loader_id = bc.cdp.loader_id_gen.next();
    try cmd.sendResult(.{
        .frameId = target_id,
        .loaderId = bc.loader_id,
    }, .{});

    try page.navigate(url, aux_data);
}

pub fn pageNavigate(bc: anytype, event: *const Notification.PageEvent) !void {
    // I don't think it's possible that we get these notifications and don't
    // have these things setup.
    std.debug.assert(bc.session.page != null);

    var cdp = bc.cdp;
    const loader_id = bc.loader_id;
    const target_id = bc.target_id orelse unreachable;
    const session_id = bc.session_id orelse unreachable;

    bc.reset();

    // frameStartedNavigating event
    try cdp.sendEvent("Page.frameStartedNavigating", .{
        .frameId = target_id,
        .url = event.url.raw,
        .loaderId = loader_id,
        .navigationType = "differentDocument",
    }, .{ .session_id = session_id });

    // frameStartedLoading event
    try cdp.sendEvent("Page.frameStartedLoading", .{
        .frameId = target_id,
    }, .{ .session_id = session_id });

    if (bc.page_life_cycle_events) {
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .name = "init",
            .frameId = target_id,
            .loaderId = loader_id,
            .timestamp = event.timestamp,
        }, .{ .session_id = session_id });
    }

    // TODO: noop event, we have no env context at this point, is it necesarry?
    // Sending this events will tell make the client drop its contexts and wait for new ones to be created.
    try cdp.sendEvent("Runtime.executionContextsCleared", null, .{ .session_id = session_id });

    // When the execution contexts are cleared the client expect us to send executionContextCreated events with the new ID for each context.
    // Since we do not actually maintain an isolated context we just send the same message as we did initially.
    // The contextCreated message is send for the main context by the session by calling the inspector.contextCreated when navigating.
    if (bc.fake_isolatedworld) |isolatedworld| try cdp.sendEvent("Runtime.executionContextCreated", .{ .context = isolatedworld }, .{ .session_id = session_id });
}

pub fn pageNavigated(bc: anytype, event: *const Notification.PageEvent) !void {
    // I don't think it's possible that we get these notifications and don't
    // have these things setup.
    std.debug.assert(bc.session.page != null);

    var cdp = bc.cdp;
    const timestamp = event.timestamp;
    const loader_id = bc.loader_id;
    const target_id = bc.target_id orelse unreachable;
    const session_id = bc.session_id orelse unreachable;

    try cdp.sendEvent("DOM.documentUpdated", null, .{ .session_id = session_id });

    // frameNavigated event
    try cdp.sendEvent("Page.frameNavigated", .{
        .type = "Navigation",
        .frame = Frame{
            .id = target_id,
            .url = event.url.raw,
            .loaderId = bc.loader_id,
            .securityOrigin = bc.security_origin,
            .secureContextType = bc.secure_context_type,
        },
    }, .{ .session_id = session_id });

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
