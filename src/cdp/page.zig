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
    createIsolatedWorld,
    navigate,
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
        .createIsolatedWorld => createIsolatedWorld(alloc, id, scanner, ctx),
        .navigate => navigate(alloc, id, scanner, ctx),
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

fn getFrameTree(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const sessionID = try cdp.getSessionID(scanner);
    const FrameTree = struct {
        frameTree: struct {
            frame: struct {
                id: []const u8,
                loaderId: []const u8,
                url: []const u8,
                domainAndRegistry: []const u8 = "",
                securityOrigin: []const u8,
                mimeType: []const u8 = "text/html",
                adFrameStatus: struct {
                    adFrameType: []const u8 = "none",
                } = .{},
                secureContextType: []const u8,
                crossOriginIsolatedContextType: []const u8 = "NotIsolated",
                gatedAPIFeatures: [][]const u8 = &[0][]const u8{},
            },
        },
        childFrames: ?[]@This() = null,
    };
    const frameTree = FrameTree{
        .frameTree = .{
            .frame = .{
                .id = ctx.state.frameID,
                .url = ctx.state.url,
                .securityOrigin = ctx.state.securityOrigin,
                .secureContextType = ctx.state.secureContextType,
                .loaderId = ctx.state.loaderID,
            },
        },
    };
    return result(alloc, id, FrameTree, frameTree, sessionID);
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
        includeCommandLineAPI: bool = false,
        runImmediately: bool = false,
    };
    _ = try getParams(alloc, Params, scanner);
    const sessionID = try cdp.getSessionID(scanner);

    // output
    const Res = struct {
        identifier: []const u8 = "1",
    };
    return result(alloc, id, Res, Res{}, sessionID);
}

fn createIsolatedWorld(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const content = try cdp.getContent(alloc, void, scanner);

    // output
    const Resp = struct {
        executionContextId: u8 = 2,
    };

    return result(alloc, id, Resp, .{}, content.sessionID);
}

fn navigate(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        url: []const u8,
        referrer: ?[]const u8 = null,
        transitionType: ?[]const u8 = null, // TODO: enum
        frameId: ?[]const u8 = null,
        referrerPolicy: ?[]const u8 = null, // TODO: enum
    };
    const content = try cdp.getContent(alloc, Params, scanner);
    std.debug.assert(content.sessionID != null);

    // change state
    ctx.state.url = content.params.url;
    ctx.state.loaderID = "AF8667A203C5392DBE9AC290044AA4C2";

    // output
    const Resp = struct {
        frameId: []const u8,
        loaderId: ?[]const u8,
        errorText: ?[]const u8 = null,
    };
    const resp = Resp{
        .frameId = ctx.state.frameID,
        .loaderId = ctx.state.loaderID,
    };
    return result(alloc, id, Resp, resp, content.sessionID);
}
