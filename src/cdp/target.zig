const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.CmdContext;
const SendFn = server.SendFn;
const result = @import("cdp.zig").result;
const getParams = @import("cdp.zig").getParams;
const stringify = @import("cdp.zig").stringify;

const TargetMethods = enum {
    setAutoAttach,
    // attachedToTarget,
    // getTargetInfo,
};

pub fn target(
    alloc: std.mem.Allocator,
    id: u64,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(TargetMethods, action) orelse
        return error.UnknownTargetMethod;
    return switch (method) {
        .setAutoAttach => tagetSetAutoAttach(alloc, id, scanner, ctx),
        // .getTargetInfo => tagetGetTargetInfo(alloc, id, scanner),
    };
}

const SessionID = "9559320D92474062597D9875C664CAC0";
const TargetID = "CFCD6EC01573CF29BB638E9DC0F52DDC";
const BrowserContextID = "65618675CB7D3585A95049E9DFE95EA9";

fn tagetSetAutoAttach(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const Params = struct {
        autoAttach: bool,
        waitForDebuggerOnStart: bool,
        flatten: ?bool = null,
    };
    const params = try getParams(alloc, Params, scanner);
    std.log.debug("params {any}", .{params});

    const AttachToTarget = struct {
        method: []const u8 = "Target.attachedToTarget",
        params: struct {
            sessionId: []const u8 = SessionID,
            targetInfo: struct {
                targetId: []const u8 = TargetID,
                type: []const u8 = "page",
                title: []const u8 = "New Incognito tab",
                url: []const u8 = "chrome://newtab/",
                attached: bool = true,
                canAccessOpener: bool = false,
                browserContextId: []const u8 = BrowserContextID,
            } = .{},
            waitingForDebugger: bool = false,
        } = .{},
    };
    const attached = try stringify(alloc, AttachToTarget{});
    try server.sendLater(ctx, attached, 0);

    return result(alloc, id, null, null);
}

fn tagetGetTargetInfo(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    _ = scanner;

    const TargetInfo = struct {
        targetId: []const u8,
        type: []const u8,
        title: []const u8,
        url: []const u8,
        attached: bool,
        canAccessOpener: bool,

        browserContextId: ?[]const u8 = null,
    };
    const targetInfo = TargetInfo{
        .targetId = TargetID,
        .type = "page",
    };
    _ = targetInfo;
    return result(alloc, id, null, null);
}

// fn tagetGetTargetInfo(
//     alloc: std.mem.Allocator,
//     id: u64,
//     scanner: *std.json.Scanner,
// ) ![]const u8 {
//     _ = scanner;

//     const TargetInfo = struct {
//         targetId: []const u8,
//         type: []const u8,
//         title: []const u8,
//         url: []const u8,
//         attached: bool,
//         canAccessOpener: bool,

//         browserContextId: ?[]const u8 = null,
//     };
//     const targetInfo = TargetInfo{
//         .targetId = TargetID,
//         .type = "page",
//     };
//     _ = targetInfo;
//     return result(alloc, id, null, null);
// }
