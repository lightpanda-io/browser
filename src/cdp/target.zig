const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.CmdContext;
const SendFn = server.SendFn;
const result = @import("cdp.zig").result;
const getParams = @import("cdp.zig").getParams;

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
    comptime sendFn: SendFn,
) ![]const u8 {
    const method = std.meta.stringToEnum(TargetMethods, action) orelse
        return error.UnknownTargetMethod;
    return switch (method) {
        .setAutoAttach => tagetSetAutoAttach(alloc, id, scanner, ctx, sendFn),
        // .getTargetInfo => tagetGetTargetInfo(alloc, id, scanner),
    };
}

fn tagetSetAutoAttach(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
    comptime _: SendFn,
) ![]const u8 {
    const Params = struct {
        autoAttach: bool,
        waitForDebuggerOnStart: bool,
        flatten: ?bool = null,
    };
    const params = try getParams(alloc, Params, scanner);
    std.log.debug("params {any}", .{params});
    return result(alloc, id, null, null);
}

const TargetID = "CFCD6EC01573CF29BB638E9DC0F52DDC";

fn tagetGetTargetInfo(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
    comptime _: SendFn,
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
