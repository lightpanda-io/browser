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

const server = @import("../server.zig");
const Ctx = server.Ctx;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getMsg = cdp.getMsg;
const stringify = cdp.stringify;
const sendEvent = cdp.sendEvent;

const Runtime = @import("runtime.zig");

const Methods = enum {
    enable,
    getFrameTree,
    setLifecycleEventsEnabled,
    addScriptToEvaluateOnNewDocument,
    createIsolatedWorld,
    navigate,
};

pub fn page(
    alloc: std.mem.Allocator,
    id: ?u16,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .enable => enable(alloc, id, scanner, ctx),
        .getFrameTree => getFrameTree(alloc, id, scanner, ctx),
        .setLifecycleEventsEnabled => setLifecycleEventsEnabled(alloc, id, scanner, ctx),
        .addScriptToEvaluateOnNewDocument => addScriptToEvaluateOnNewDocument(alloc, id, scanner, ctx),
        .createIsolatedWorld => createIsolatedWorld(alloc, id, scanner, ctx),
        .navigate => navigate(alloc, id, scanner, ctx),
    };
}

fn enable(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const msg = try getMsg(alloc, void, scanner);
    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
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

fn getFrameTree(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const msg = try cdp.getMsg(alloc, void, scanner);

    const FrameTree = struct {
        frameTree: struct {
            frame: Frame,
        },
        childFrames: ?[]@This() = null,
    };
    const frameTree = FrameTree{
        .frameTree = .{
            .frame = .{
                .id = ctx.state.frameID,
                .url = ctx.state.url,
                .securityOrigin = ctx.state.securityOrigin,
                .secureContextType = ctx.state.secureContextType,
                .loaderId = ctx.state.loaderID,
            },
        },
    };
    return result(alloc, id orelse msg.id.?, FrameTree, frameTree, msg.sessionID);
}

fn setLifecycleEventsEnabled(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        enabled: bool,
    };
    const msg = try getMsg(alloc, Params, scanner);

    ctx.state.page_life_cycle_events = true;

    // output
    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
}

const LifecycleEvent = struct {
    frameId: []const u8,
    loaderId: ?[]const u8,
    name: []const u8 = undefined,
    timestamp: f32 = undefined,
};

// TODO: hard coded method
fn addScriptToEvaluateOnNewDocument(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        source: []const u8,
        worldName: ?[]const u8 = null,
        includeCommandLineAPI: bool = false,
        runImmediately: bool = false,
    };
    const msg = try getMsg(alloc, Params, scanner);

    // output
    const Res = struct {
        identifier: []const u8 = "1",
    };
    return result(alloc, id orelse msg.id.?, Res, Res{}, msg.sessionID);
}

// TODO: hard coded method
fn createIsolatedWorld(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        frameId: []const u8,
        worldName: []const u8,
        grantUniveralAccess: bool,
    };
    const msg = try getMsg(alloc, Params, scanner);
    std.debug.assert(msg.sessionID != null);
    const params = msg.params.?;

    // noop executionContextCreated event
    try Runtime.executionContextCreated(
        alloc,
        ctx,
        0,
        "",
        params.worldName,
        // TODO: hard coded ID
        "7102379147004877974.3265385113993241162",
        .{
            .isDefault = false,
            .type = "isolated",
            .frameId = params.frameId,
        },
        msg.sessionID,
    );

    // output
    const Resp = struct {
        executionContextId: u8 = 0,
    };

    return result(alloc, id orelse msg.id.?, Resp, .{}, msg.sessionID);
}

fn navigate(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        url: []const u8,
        referrer: ?[]const u8 = null,
        transitionType: ?[]const u8 = null, // TODO: enum
        frameId: ?[]const u8 = null,
        referrerPolicy: ?[]const u8 = null, // TODO: enum
    };
    const msg = try getMsg(alloc, Params, scanner);
    std.debug.assert(msg.sessionID != null);
    const params = msg.params.?;

    // change state
    ctx.state.url = params.url;
    // TODO: hard coded ID
    ctx.state.loaderID = "AF8667A203C5392DBE9AC290044AA4C2";

    var life_event = LifecycleEvent{
        .frameId = ctx.state.frameID,
        .loaderId = ctx.state.loaderID,
    };
    var ts_event: cdp.TimestampEvent = undefined;

    // frameStartedLoading event
    // TODO: event partially hard coded
    const FrameStartedLoading = struct {
        frameId: []const u8,
    };
    const frame_started_loading = FrameStartedLoading{ .frameId = ctx.state.frameID };
    try sendEvent(
        alloc,
        ctx,
        "Page.frameStartedLoading",
        FrameStartedLoading,
        frame_started_loading,
        msg.sessionID,
    );
    if (ctx.state.page_life_cycle_events) {
        life_event.name = "init";
        life_event.timestamp = 343721.796037;
        try sendEvent(
            alloc,
            ctx,
            "Page.lifecycleEvent",
            LifecycleEvent,
            life_event,
            msg.sessionID,
        );
    }

    // output
    const Resp = struct {
        frameId: []const u8,
        loaderId: ?[]const u8,
        errorText: ?[]const u8 = null,
    };
    const resp = Resp{
        .frameId = ctx.state.frameID,
        .loaderId = ctx.state.loaderID,
    };
    const res = try result(alloc, id orelse msg.id.?, Resp, resp, msg.sessionID);
    defer alloc.free(res);
    std.log.debug("res {s}", .{res});
    try server.sendSync(ctx, res);

    // TODO: at this point do we need async the following actions to be async?

    // Send Runtime.executionContextsCleared event
    // TODO: noop event, we have no env context at this point, is it necesarry?
    try sendEvent(alloc, ctx, "Runtime.executionContextsCleared", void, {}, msg.sessionID);

    // Launch navigate
    try ctx.browser.session.createPage();
    ctx.state.executionContextId += 1;
    const auxData = try std.fmt.allocPrint(
        alloc,
        // NOTE: we assume this is the default web page
        "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}",
        .{ctx.state.frameID},
    );
    defer alloc.free(auxData);
    try ctx.browser.session.page().navigate(params.url, auxData);

    // Events

    // lifecycle init event
    // TODO: partially hard coded
    if (ctx.state.page_life_cycle_events) {
        life_event.name = "init";
        life_event.timestamp = 343721.796037;
        try sendEvent(
            alloc,
            ctx,
            "Page.lifecycleEvent",
            LifecycleEvent,
            life_event,
            msg.sessionID,
        );
    }

    // frameNavigated event
    const FrameNavigated = struct {
        frame: Frame,
        type: []const u8 = "Navigation",
    };
    const frame_navigated = FrameNavigated{
        .frame = .{
            .id = ctx.state.frameID,
            .url = ctx.state.url,
            .securityOrigin = ctx.state.securityOrigin,
            .secureContextType = ctx.state.secureContextType,
            .loaderId = ctx.state.loaderID,
        },
    };
    try sendEvent(
        alloc,
        ctx,
        "Page.frameNavigated",
        FrameNavigated,
        frame_navigated,
        msg.sessionID,
    );

    // domContentEventFired event
    // TODO: partially hard coded
    ts_event = .{ .timestamp = 343721.803338 };
    try sendEvent(
        alloc,
        ctx,
        "Page.domContentEventFired",
        cdp.TimestampEvent,
        ts_event,
        msg.sessionID,
    );

    // lifecycle DOMContentLoaded event
    // TODO: partially hard coded
    if (ctx.state.page_life_cycle_events) {
        life_event.name = "DOMContentLoaded";
        life_event.timestamp = 343721.803338;
        try sendEvent(
            alloc,
            ctx,
            "Page.lifecycleEvent",
            LifecycleEvent,
            life_event,
            msg.sessionID,
        );
    }

    // loadEventFired event
    // TODO: partially hard coded
    ts_event = .{ .timestamp = 343721.824655 };
    try sendEvent(
        alloc,
        ctx,
        "Page.loadEventFired",
        cdp.TimestampEvent,
        ts_event,
        msg.sessionID,
    );

    // lifecycle DOMContentLoaded event
    // TODO: partially hard coded
    if (ctx.state.page_life_cycle_events) {
        life_event.name = "load";
        life_event.timestamp = 343721.824655;
        try sendEvent(
            alloc,
            ctx,
            "Page.lifecycleEvent",
            LifecycleEvent,
            life_event,
            msg.sessionID,
        );
    }

    // frameStoppedLoading
    const FrameStoppedLoading = struct { frameId: []const u8 };
    try sendEvent(
        alloc,
        ctx,
        "Page.frameStoppedLoading",
        FrameStoppedLoading,
        .{ .frameId = ctx.state.frameID },
        msg.sessionID,
    );

    return "";
}
