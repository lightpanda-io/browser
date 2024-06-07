const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getMsg = cdp.getMsg;
const stringify = cdp.stringify;
const sendEvent = cdp.sendEvent;

const Runtime = @import("runtime.zig");

const PageMethods = enum {
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
    const method = std.meta.stringToEnum(PageMethods, action) orelse
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

fn createIsolatedWorld(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const msg = try getMsg(alloc, void, scanner);

    // output
    const Resp = struct {
        executionContextId: u8 = 2,
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
    ctx.state.loaderID = "AF8667A203C5392DBE9AC290044AA4C2";

    var life_event = LifecycleEvent{
        .frameId = ctx.state.frameID,
        .loaderId = ctx.state.loaderID,
    };
    var ts_event: cdp.TimestampEvent = undefined;

    // frameStartedLoading event
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
    std.log.debug("res {s}", .{res});
    try server.sendSync(ctx, res);

    // Runtime.executionContextsCleared event
    try sendEvent(alloc, ctx, "Runtime.executionContextsCleared", void, {}, msg.sessionID);

    // launch navigate
    var p = try ctx.browser.currentSession().createPage();
    _ = try p.navigate(params.url);

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

    try Runtime.executionContextCreated(
        alloc,
        ctx,
        3,
        "http://127.0.0.1:1234",
        "",
        "7102379147004877974.3265385113993241162",
        .{ .frameId = ctx.state.frameID },
        msg.sessionID,
    );

    try Runtime.executionContextCreated(
        alloc,
        ctx,
        4,
        "://",
        "__playwright_utility_world__",
        "-4572718120346458707.6016875269626438350",
        .{ .isDefault = false, .type = "isolated", .frameId = ctx.state.frameID },
        msg.sessionID,
    );

    // domContentEventFired event
    ts_event = .{ .timestamp = 343721.803338 };
    try sendEvent(
        alloc,
        ctx,
        "Page.domContentEventFired",
        cdp.TimestampEvent,
        ts_event,
        msg.sessionID,
    );
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
    ts_event = .{ .timestamp = 343721.824655 };
    try sendEvent(
        alloc,
        ctx,
        "Page.loadEventFired",
        cdp.TimestampEvent,
        ts_event,
        msg.sessionID,
    );
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
