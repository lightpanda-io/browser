const std = @import("std");

const jsruntime = @import("jsruntime");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getParams = cdp.getParams;
const stringify = cdp.stringify;

const RuntimeMethods = enum {
    enable,
    runIfWaitingForDebugger,
    evaluate,
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
        .evaluate => evaluate(alloc, id, scanner, ctx),
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

fn evaluate(
    alloc: std.mem.Allocator,
    id: u64,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // ensure a page has been previously created
    if (ctx.browser.currentSession().page == null) return error.CDPNoPage;

    // input
    const Params = struct {
        expression: []const u8,
        contextId: ?u8,
    };

    const input = try cdp.getContent(alloc, Params, scanner);
    const sessionID = input.sessionID;
    std.debug.assert(sessionID != null);

    // save script in file at debug mode
    std.log.debug("script {d} length: {d}", .{ id, input.params.expression.len });
    if (std.log.defaultLogEnabled(.debug)) {
        const name = try std.fmt.allocPrint(alloc, "id_{d}.js", .{id});
        defer alloc.free(name);
        const dir = try std.fs.cwd().makeOpenPath("zig-cache/tmp", .{});
        const f = try dir.createFile(name, .{});
        defer f.close();
        const nb = try f.write(input.params.expression);
        std.debug.assert(nb == input.params.expression.len);
        const p = try dir.realpathAlloc(alloc, name);
        defer alloc.free(p);
        std.log.debug("Script {d} saved at {s}", .{ id, p });
    }

    // evaluate the script in the context of the current page
    // TODO: should we use instead the allocator of the page?
    // the following code does not work
    // const page_alloc = ctx.browser.currentSession().page.?.arena.allocator();
    const session_alloc = ctx.browser.currentSession().alloc;
    var res = jsruntime.JSResult{};
    try ctx.browser.currentSession().env.run(session_alloc, input.params.expression, "cdp", &res, null);
    defer res.deinit(session_alloc);

    if (!res.success) {
        std.log.err("script {d} result: {s}", .{ id, res.result });
        if (res.stack) |stack| {
            std.log.err("script {d} stack: {s}", .{ id, stack });
        }
        return error.CDPRuntimeEvaluate;
    }
    std.log.debug("script {d} result: {s}", .{ id, res.result });

    // TODO: Resp should depends on JS result returned by the JS engine
    const Resp = struct {
        type: []const u8 = "object",
        className: []const u8 = "UtilityScript",
        description: []const u8 = "UtilityScript",
        objectId: []const u8 = "7481631759780215274.3.2",
    };
    return result(alloc, id, Resp, Resp{}, sessionID);
}
