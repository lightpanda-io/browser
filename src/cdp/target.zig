const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getParams = cdp.getParams;
const stringify = cdp.stringify;

const TargetMethods = enum {
    setAutoAttach,
    getTargetInfo,
    createBrowserContext,
    createTarget,
};

pub fn target(
    alloc: std.mem.Allocator,
    id: u64,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(TargetMethods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .setAutoAttach => tagetSetAutoAttach(alloc, id, scanner, ctx),
        .getTargetInfo => tagetGetTargetInfo(alloc, id, scanner, ctx),
        .createBrowserContext => createBrowserContext(alloc, id, scanner, ctx),
        .createTarget => createTarget(alloc, id, scanner, ctx),
    };
}

const PageTargetID = "CFCD6EC01573CF29BB638E9DC0F52DDC";
const BrowserTargetID = "2d2bdef9-1c95-416f-8c0e-83f3ab73a30c";
const BrowserContextID = "65618675CB7D3585A95049E9DFE95EA9";

const AttachToTarget = struct {
    sessionId: []const u8,
    targetInfo: struct {
        targetId: []const u8,
        type: []const u8 = "page",
        title: []const u8,
        url: []const u8,
        attached: bool = true,
        canAccessOpener: bool = false,
        browserContextId: []const u8,
    },
    waitingForDebugger: bool = false,
};

const TargetFilter = struct {
    type: []const u8,
    exclude: bool,
};

fn tagetSetAutoAttach(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const Params = struct {
        autoAttach: bool,
        waitForDebuggerOnStart: bool,
        flatten: bool = true,
        filter: ?[]TargetFilter = null,
    };
    const params = try getParams(alloc, Params, scanner);
    std.log.debug("params {any}", .{params});

    const sessionID = try cdp.getSessionID(scanner);

    if (sessionID == null) {
        const attached = AttachToTarget{
            .sessionId = cdp.SessionID,
            .targetInfo = .{
                .targetId = PageTargetID,
                .title = "New Incognito tab",
                .url = cdp.URLBase,
                .browserContextId = BrowserContextID,
            },
        };
        try cdp.sendEvent(alloc, ctx, "Target.attachedToTarget", AttachToTarget, attached, null);
    }

    return result(alloc, id, null, null, sessionID);
}

fn tagetGetTargetInfo(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        targetId: ?[]const u8 = null,
    };
    _ = try getParams(alloc, Params, scanner);

    // output
    const TargetInfo = struct {
        targetId: []const u8,
        type: []const u8,
        title: []const u8 = "",
        url: []const u8 = "",
        attached: bool = true,
        openerId: ?[]const u8 = null,
        canAccessOpener: bool = false,
        openerFrameId: ?[]const u8 = null,
        browserContextId: ?[]const u8 = null,
        subtype: ?[]const u8 = null,
    };
    const targetInfo = TargetInfo{
        .targetId = BrowserTargetID,
        .type = "browser",
    };
    return result(alloc, id, TargetInfo, targetInfo, null);
}

const ContextID = "22648B09EDCCDD11109E2D4FEFBE4F89";
const ContextSessionID = "4FDC2CB760A23A220497A05C95417CF4";

fn createBrowserContext(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        disposeOnDetach: bool = false,
        proxyServer: ?[]const u8 = null,
        proxyBypassList: ?[]const u8 = null,
        originsWithUniversalNetworkAccess: ?[][]const u8 = null,
    };
    _ = try getParams(alloc, Params, scanner);
    const sessionID = try cdp.getSessionID(scanner);

    // output
    const Resp = struct {
        browserContextId: []const u8 = ContextID,
    };
    return result(alloc, id, Resp, Resp{}, sessionID);
}

const TargetID = "57356548460A8F29706A2ADF14316298";

fn createTarget(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        url: []const u8,
        width: ?u64 = null,
        height: ?u64 = null,
        browserContextId: []const u8,
        enableBeginFrameControl: bool = false,
        newWindow: bool = false,
        background: bool = false,
        forTab: ?bool = null,
    };
    _ = try getParams(alloc, Params, scanner);
    const sessionID = try cdp.getSessionID(scanner);

    // change CDP state
    ctx.state.frameID = TargetID;
    ctx.state.url = "about:blank";
    ctx.state.securityOrigin = "://";
    ctx.state.secureContextType = "InsecureScheme";
    ctx.state.loaderID = "DD4A76F842AA389647D702B4D805F49A";

    // send attachToTarget event
    const attached = AttachToTarget{
        .sessionId = ContextSessionID,
        .targetInfo = .{
            .targetId = ctx.state.frameID,
            .title = "",
            .url = ctx.state.url,
            .browserContextId = ContextID,
        },
        .waitingForDebugger = true,
    };
    try cdp.sendEvent(alloc, ctx, "Target.attachedToTarget", AttachToTarget, attached, sessionID);

    // output
    const Resp = struct {
        targetId: []const u8 = TargetID,
    };
    return result(alloc, id, Resp, Resp{}, sessionID);
}
