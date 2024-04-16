const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const result = @import("cdp.zig").result;
const getParams = @import("cdp.zig").getParams;
const stringify = @import("cdp.zig").stringify;

const EmulationMethods = enum {
    setEmulatedMedia,
    setFocusEmulationEnabled,
};

pub fn emulation(
    alloc: std.mem.Allocator,
    id: u64,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(EmulationMethods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .setEmulatedMedia => setEmulatedMedia(alloc, id, scanner, ctx),
        .setFocusEmulationEnabled => setFocusEmulationEnabled(alloc, id, scanner, ctx),
    };
}

fn setEmulatedMedia(
    alloc: std.mem.Allocator,
    id: u64,
    _: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    return result(alloc, id, null, null);
}

fn setFocusEmulationEnabled(
    alloc: std.mem.Allocator,
    id: u64,
    _: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    return result(alloc, id, null, null);
}
