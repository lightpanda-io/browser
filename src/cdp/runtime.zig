const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const result = @import("cdp.zig").result;
const getParams = @import("cdp.zig").getParams;
const stringify = @import("cdp.zig").stringify;

const RuntimeMethods = enum {
    enable,
    runIfWaitingForDebugger,
};

pub fn runtime(
    alloc: std.mem.Allocator,
    id: u64,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(RuntimeMethods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .enable => enable(alloc, id, scanner, ctx),
        .runIfWaitingForDebugger => runIfWaitingForDebugger(alloc, id, scanner, ctx),
    };
}

fn enable(
    alloc: std.mem.Allocator,
    id: u64,
    _: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    return result(alloc, id, null, null);
}

fn runIfWaitingForDebugger(
    alloc: std.mem.Allocator,
    id: u64,
    _: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    return result(alloc, id, null, null);
}
