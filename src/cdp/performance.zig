const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getMsg = cdp.getMsg;

const PerformanceMethods = enum {
    enable,
};

pub fn performance(
    alloc: std.mem.Allocator,
    id: ?u16,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(PerformanceMethods, action) orelse
        return error.UnknownMethod;

    return switch (method) {
        .enable => performanceEnable(alloc, id, scanner, ctx),
    };
}

fn performanceEnable(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const msg = try getMsg(alloc, void, scanner);

    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
}
