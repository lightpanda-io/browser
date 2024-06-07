const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getMsg = cdp.getMsg;
const stringify = cdp.stringify;

const EmulationMethods = enum {
    setEmulatedMedia,
    setFocusEmulationEnabled,
    setDeviceMetricsOverride,
};

pub fn emulation(
    alloc: std.mem.Allocator,
    id: ?u16,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(EmulationMethods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .setEmulatedMedia => setEmulatedMedia(alloc, id, scanner, ctx),
        .setFocusEmulationEnabled => setFocusEmulationEnabled(alloc, id, scanner, ctx),
        .setDeviceMetricsOverride => setDeviceMetricsOverride(alloc, id, scanner, ctx),
    };
}

const MediaFeature = struct {
    name: []const u8,
    value: []const u8,
};

fn setEmulatedMedia(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        media: ?[]const u8 = null,
        features: ?[]MediaFeature = null,
    };
    const msg = try getMsg(alloc, Params, scanner);

    // output
    // TODO: dummy
    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
}

fn setFocusEmulationEnabled(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        enabled: bool,
    };
    const msg = try getMsg(alloc, Params, scanner);

    // output
    // TODO: dummy
    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
}

fn setDeviceMetricsOverride(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const msg = try cdp.getMsg(alloc, void, scanner);

    // output
    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
}
