const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getMsg = cdp.getMsg;

const Methods = enum {
    getVersion,
    setDownloadBehavior,
    getWindowForTarget,
    setWindowBounds,
};

pub fn browser(
    alloc: std.mem.Allocator,
    id: ?u16,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .getVersion => getVersion(alloc, id, scanner, ctx),
        .setDownloadBehavior => setDownloadBehavior(alloc, id, scanner, ctx),
        .getWindowForTarget => getWindowForTarget(alloc, id, scanner, ctx),
        .setWindowBounds => setWindowBounds(alloc, id, scanner, ctx),
    };
}

const ProtocolVersion = "1.3";
const Product = "Chrome/124.0.6367.29";
const Revision = "@9e6ded5ac1ff5e38d930ae52bd9aec09bd1a68e4";
const UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const JsVersion = "12.4.254.8";

fn getVersion(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const msg = try getMsg(alloc, void, scanner);

    const Res = struct {
        protocolVersion: []const u8,
        product: []const u8,
        revision: []const u8,
        userAgent: []const u8,
        jsVersion: []const u8,
    };

    const res = Res{
        .protocolVersion = ProtocolVersion,
        .product = Product,
        .revision = Revision,
        .userAgent = UserAgent,
        .jsVersion = JsVersion,
    };
    return result(alloc, id orelse msg.id.?, Res, res, null);
}

fn setDownloadBehavior(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const Params = struct {
        behavior: []const u8,
        browserContextId: ?[]const u8 = null,
        downloadPath: ?[]const u8 = null,
        eventsEnabled: ?bool = null,
    };
    const msg = try getMsg(alloc, Params, scanner);
    return result(alloc, id orelse msg.id.?, null, null, null);
}

const DevToolsWindowID = 1923710101;

fn getWindowForTarget(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        targetId: ?[]const u8 = null,
    };
    const msg = try cdp.getMsg(alloc, ?Params, scanner);
    std.debug.assert(msg.sessionID != null);

    // output
    const Resp = struct {
        windowId: u64 = DevToolsWindowID,
        bounds: struct {
            left: ?u64 = null,
            top: ?u64 = null,
            width: ?u64 = null,
            height: ?u64 = null,
            windowState: []const u8 = "normal",
        } = .{},
    };
    return result(alloc, id orelse msg.id.?, Resp, Resp{}, msg.sessionID.?);
}

fn setWindowBounds(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    // NOTE: noop
    const msg = try cdp.getMsg(alloc, void, scanner);
    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
}
