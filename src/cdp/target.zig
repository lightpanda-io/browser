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
    };
}

const PageTargetID = "CFCD6EC01573CF29BB638E9DC0F52DDC";
const BrowserTargetID = "2d2bdef9-1c95-416f-8c0e-83f3ab73a30c";
const BrowserContextID = "65618675CB7D3585A95049E9DFE95EA9";

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
        const AttachToTarget = struct {
            sessionId: []const u8 = cdp.SessionID,
            targetInfo: struct {
                targetId: []const u8 = PageTargetID,
                type: []const u8 = "page",
                title: []const u8 = "New Incognito tab",
                url: []const u8 = cdp.URLBase,
                attached: bool = true,
                canAccessOpener: bool = false,
                browserContextId: []const u8 = BrowserContextID,
            } = .{},
            waitingForDebugger: bool = false,
        };
        const attached = try cdp.method(alloc, "Target.attachedToTarget", AttachToTarget, .{}, null);
        std.log.debug("res {s}", .{attached});
        try server.sendSync(ctx, attached);
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
