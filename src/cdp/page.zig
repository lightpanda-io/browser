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
const cdp = @import("cdp.zig");
const runtime = @import("runtime.zig");

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
                .url = bc.url,
                .id = target_id,
                .loaderId = bc.loader_id,
                .securityOrigin = bc.security_origin,
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
fn createIsolatedWorld(cmd: anytype) !void {
    _ = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const session_id = cmd.input.session_id orelse return error.SessionIdRequired;

    const params = (try cmd.params(struct {
        frameId: []const u8,
        worldName: []const u8,
        grantUniveralAccess: bool,
    })) orelse return error.InvalidParams;

    // noop executionContextCreated event
    try cmd.sendEvent("Runtime.executionContextCreated", .{
        .context = runtime.ExecutionContextCreated{
            .id = 0,
            .origin = "",
            .name = params.worldName,
            // TODO: hard coded ID
            .uniqueId = "7102379147004877974.3265385113993241162",
            .auxData = .{
                .isDefault = false,
                .type = "isolated",
                .frameId = params.frameId,
            },
        },
    }, .{ .session_id = session_id });

    return cmd.sendResult(.{
        .executionContextId = 0,
    }, .{});
}

fn navigate(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // didn't create?
    const target_id = bc.target_id orelse return error.TargetIdNotLoaded;

    // didn't attach?
    const session_id = bc.session_id orelse return error.SessionIdNotLoaded;

    // if we have a target_id we have to have a page;
    std.debug.assert(bc.session.page != null);

    const params = (try cmd.params(struct {
        url: []const u8,
        referrer: ?[]const u8 = null,
        transitionType: ?[]const u8 = null, // TODO: enum
        frameId: ?[]const u8 = null,
        referrerPolicy: ?[]const u8 = null, // TODO: enum
    })) orelse return error.InvalidParams;

    // change state
    bc.reset();
    bc.url = params.url;

    // TODO: hard coded ID
    bc.loader_id = "AF8667A203C5392DBE9AC290044AA4C2";

    const LifecycleEvent = struct {
        frameId: []const u8,
        loaderId: ?[]const u8,
        name: []const u8,
        timestamp: f32,
    };

    var life_event = LifecycleEvent{
        .frameId = target_id,
        .loaderId = bc.loader_id,
        .name = "init",
        .timestamp = 343721.796037,
    };

    // frameStartedLoading event
    // TODO: event partially hard coded
    try cmd.sendEvent("Page.frameStartedLoading", .{
        .frameId = target_id,
    }, .{ .session_id = session_id });

    if (bc.page_life_cycle_events) {
        try cmd.sendEvent("Page.lifecycleEvent", life_event, .{ .session_id = session_id });
    }

    // output
    try cmd.sendResult(.{
        .frameId = target_id,
        .loaderId = bc.loader_id,
    }, .{});

    // TODO: at this point do we need async the following actions to be async?

    // Send Runtime.executionContextsCleared event
    // TODO: noop event, we have no env context at this point, is it necesarry?
    try cmd.sendEvent("Runtime.executionContextsCleared", null, .{ .session_id = session_id });

    const aux_data = try std.fmt.allocPrint(
        cmd.arena,
        // NOTE: we assume this is the default web page
        "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}",
        .{target_id},
    );

    var page = bc.session.currentPage().?;
    try page.navigate(params.url, aux_data);

    // Events

    // lifecycle init event
    // TODO: partially hard coded
    if (bc.page_life_cycle_events) {
        life_event.name = "init";
        life_event.timestamp = 343721.796037;
        try cmd.sendEvent("Page.lifecycleEvent", life_event, .{ .session_id = session_id });
    }

    try cmd.sendEvent("DOM.documentUpdated", null, .{ .session_id = session_id });

    // frameNavigated event
    try cmd.sendEvent("Page.frameNavigated", .{
        .type = "Navigation",
        .frame = Frame{
            .id = target_id,
            .url = bc.url,
            .securityOrigin = bc.security_origin,
            .secureContextType = bc.secure_context_type,
            .loaderId = bc.loader_id,
        },
    }, .{ .session_id = session_id });

    // domContentEventFired event
    // TODO: partially hard coded
    try cmd.sendEvent(
        "Page.domContentEventFired",
        cdp.TimestampEvent{ .timestamp = 343721.803338 },
        .{ .session_id = session_id },
    );

    // lifecycle DOMContentLoaded event
    // TODO: partially hard coded
    if (bc.page_life_cycle_events) {
        life_event.name = "DOMContentLoaded";
        life_event.timestamp = 343721.803338;
        try cmd.sendEvent("Page.lifecycleEvent", life_event, .{ .session_id = session_id });
    }

    // loadEventFired event
    // TODO: partially hard coded
    try cmd.sendEvent(
        "Page.loadEventFired",
        cdp.TimestampEvent{ .timestamp = 343721.824655 },
        .{ .session_id = session_id },
    );

    // lifecycle DOMContentLoaded event
    // TODO: partially hard coded
    if (bc.page_life_cycle_events) {
        life_event.name = "load";
        life_event.timestamp = 343721.824655;
        try cmd.sendEvent("Page.lifecycleEvent", life_event, .{ .session_id = session_id });
    }

    // frameStoppedLoading
    return cmd.sendEvent("Page.frameStoppedLoading", .{
        .frameId = target_id,
    }, .{ .session_id = session_id });
}

const testing = @import("testing.zig");
test "cdp.page: getFrameTree" {
    var ctx = testing.context();
    defer ctx.deinit();

    {
        try testing.expectError(error.BrowserContextNotLoaded, ctx.processMessage(.{ .id = 10, .method = "Page.getFrameTree", .params = .{ .targetId = "X" } }));
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 11, .method = "Page.getFrameTree" });
        try ctx.expectSentResult(.{
            .frameTree = .{
                .frame = .{
                    .id = bc.frame_id,
                    .loaderId = bc.loader_id,
                    .url = bc.url,
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
