const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const result = @import("cdp.zig").result;
const getParams = @import("cdp.zig").getParams;
const stringify = @import("cdp.zig").stringify;

const PageMethods = enum {
    enable,
    getFrameTree,
    setLifecycleEventsEnabled,
};

pub fn page(
    alloc: std.mem.Allocator,
    id: u64,
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

fn getFrameTree(
    alloc: std.mem.Allocator,
    id: u64,
    _: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    // TODO: dummy
    return result(alloc, id, null, null);
}

fn setLifecycleEventsEnabled(
    alloc: std.mem.Allocator,
    id: u64,
    _: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    // TODO: dummy
    return result(alloc, id, null, null);
}
