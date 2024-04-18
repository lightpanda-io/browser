const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getParams = cdp.getParams;
const stringify = cdp.stringify;

const PageMethods = enum {
    enable,
    getFrameTree,
    setLifecycleEventsEnabled,
    addScriptToEvaluateOnNewDocument,
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
        .addScriptToEvaluateOnNewDocument => addScriptToEvaluateOnNewDocument(alloc, id, scanner, ctx),
    };
}

fn enable(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const sessionID = try cdp.getSessionID(scanner);
    return result(alloc, id, null, null, sessionID);
}

const FrameTreeID = "90D14BBD8AED408A0467AC93100BCDBE";
const LoaderID = "CFC8BED824DD2FD56CF1EF33C965C79C";
const URLBase = "chrome://newtab/";

fn getFrameTree(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const sessionID = try cdp.getSessionID(scanner);
    const FrameTree = struct {
        frameTree: struct {
            frame: struct {
                id: []const u8 = FrameTreeID,
                loaderId: []const u8 = LoaderID,
                url: []const u8 = URLBase,
                domainAndRegistry: []const u8 = "",
                securityOrigin: []const u8 = URLBase,
                mimeType: []const u8 = "mimeType",
                adFrameStatus: struct {
                    adFrameType: []const u8 = "none",
                } = .{},
                secureContextType: []const u8 = "Secure",
                crossOriginIsolatedContextType: []const u8 = "NotIsolated",
                gatedAPIFeatures: [][]const u8 = &[0][]const u8{},
            } = .{},
        } = .{},
        childFrames: ?[]@This() = null,
    };
    return result(alloc, id, FrameTree, FrameTree{}, sessionID);
}

fn setLifecycleEventsEnabled(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        enabled: bool,
    };
    _ = try getParams(alloc, Params, scanner);
    const sessionID = try cdp.getSessionID(scanner);

    // output
    // TODO: dummy
    return result(alloc, id, null, null, sessionID);
}

fn addScriptToEvaluateOnNewDocument(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        source: []const u8,
        worldName: ?[]const u8 = null,
    };
    _ = try getParams(alloc, Params, scanner);
    const sessionID = try cdp.getSessionID(scanner);

    // output
    const Res = struct {
        identifier: []const u8 = "1",
    };
    return result(alloc, id, Res, Res{}, sessionID);
}
