const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getParams = cdp.getParams;
const stringify = cdp.stringify;

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
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    _ = ctx;

    // input
    const sessionID = try cdp.getSessionID(scanner);

    // output
    // const uniqueID = "1367118932354479079.-1471398151593995849";
    // const mainCtx = try executionContextCreated(
    //     alloc,
    //     1,
    //     cdp.URLBase,
    //     "",
    //     uniqueID,
    //     .{},
    //     sessionID,
    // );
    // std.log.debug("res {s}", .{mainCtx});
    // try server.sendAsync(ctx, mainCtx);

    return result(alloc, id, null, null, sessionID);
}

pub const AuxData = struct {
    isDefault: bool = true,
    type: []const u8 = "default",
    frameId: []const u8 = cdp.FrameID,
};

const ExecutionContextDescription = struct {
    id: u64,
    origin: []const u8,
    name: []const u8,
    uniqueId: []const u8,
    auxData: ?AuxData = null,
};

pub fn executionContextCreated(
    alloc: std.mem.Allocator,
    ctx: *Ctx,
    id: u64,
    origin: []const u8,
    name: []const u8,
    uniqueID: []const u8,
    auxData: ?AuxData,
    sessionID: ?[]const u8,
) !void {
    const Params = struct {
        context: ExecutionContextDescription,
    };
    const params = Params{
        .context = .{
            .id = id,
            .origin = origin,
            .name = name,
            .uniqueId = uniqueID,
            .auxData = auxData,
        },
    };
    try cdp.sendEvent(alloc, ctx, "Runtime.executionContextCreated", Params, params, sessionID);
}

fn runIfWaitingForDebugger(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const sessionID = try cdp.getSessionID(scanner);
    return result(alloc, id, null, null, sessionID);
}
