const std = @import("std");
const builtin = @import("builtin");

const jsruntime = @import("jsruntime");

const server = @import("../server.zig");
const Ctx = server.Cmd;
const cdp = @import("cdp.zig");
const result = cdp.result;
const getMsg = cdp.getMsg;
const stringify = cdp.stringify;

const Methods = enum {
    enable,
    runIfWaitingForDebugger,
    evaluate,
    addBinding,
    callFunctionOn,
};

pub fn runtime(
    alloc: std.mem.Allocator,
    id: ?u16,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .enable => enable(alloc, id, scanner, ctx),
        .runIfWaitingForDebugger => runIfWaitingForDebugger(alloc, id, scanner, ctx),
        .evaluate => evaluate(alloc, id, scanner, ctx),
        .addBinding => addBinding(alloc, id, scanner, ctx),
        .callFunctionOn => callFunctionOn(alloc, id, scanner, ctx),
    };
}

fn enable(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const msg = try getMsg(alloc, void, scanner);

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

    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
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
    id: u16,
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
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const msg = try getMsg(alloc, void, scanner);

    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
}

fn evaluate(
    alloc: std.mem.Allocator,
    _id: ?u16,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // ensure a page has been previously created
    if (ctx.browser.currentSession().page == null) return error.CDPNoPage;

    // input
    const Params = struct {
        expression: []const u8,
        contextId: ?u8 = null,
        returnByValue: ?bool = null,
        awaitPromise: ?bool = null,
        userGesture: ?bool = null,
    };

    const msg = try getMsg(alloc, Params, scanner);
    std.debug.assert(msg.sessionID != null);
    const params = msg.params.?;
    const id = _id orelse msg.id.?;

    // save script in file at debug mode
    std.log.debug("script {d} length: {d}", .{ id, params.expression.len });
    if (std.log.defaultLogEnabled(.debug)) {
        try cdp.dumpFile(alloc, id, params.expression);
    }

    // evaluate the script in the context of the current page
    const session = ctx.browser.currentSession();
    // TODO: should we use instead the allocator of the page?
    // the following code does not work with session.page.?.arena.allocator() as alloc
    const res = try runtimeEvaluate(session.alloc, id, session.env, params.expression, "cdp");

    // check result
    const res_type = try res.typeOf(session.env);

    // TODO: Resp should depends on JS result returned by the JS engine
    const Resp = struct {
        result: struct {
            type: []const u8,
            subtype: ?[]const u8 = null,
            className: ?[]const u8 = null,
            description: ?[]const u8 = null,
            objectId: ?[]const u8 = null,
        },
    };
    var resp = Resp{
        .result = .{
            .type = @tagName(res_type),
        },
    };
    if (res_type == .object) {
        resp.result.className = "Object";
        resp.result.description = "Object";
        resp.result.objectId = "-9051357107442861868.3.2";
    }
    return result(alloc, id, Resp, resp, msg.sessionID);
}

fn addBinding(
    alloc: std.mem.Allocator,
    _id: ?u16,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        name: []const u8,
        executionContextId: ?u8 = null,
    };
    const msg = try getMsg(alloc, Params, scanner);
    const id = _id orelse msg.id.?;
    const params = msg.params.?;
    if (params.executionContextId) |contextId| {
        std.debug.assert(contextId == ctx.state.executionContextId);
    }

    const script = try std.fmt.allocPrint(alloc, "globalThis['{s}'] = {{}};", .{params.name});
    defer alloc.free(script);

    const session = ctx.browser.currentSession();
    _ = try runtimeEvaluate(session.alloc, id, session.env, script, "addBinding");

    return result(alloc, id, null, null, msg.sessionID);
}

fn callFunctionOn(
    alloc: std.mem.Allocator,
    _id: ?u16,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        functionDeclaration: []const u8,
        objectId: ?[]const u8 = null,
        executionContextId: ?u8 = null,
        arguments: ?[]struct {
            value: ?[]const u8 = null,
        } = null,
        returnByValue: ?bool = null,
        awaitPromise: ?bool = null,
        userGesture: ?bool = null,
    };
    const msg = try getMsg(alloc, Params, scanner);
    const id = _id orelse msg.id.?;
    const params = msg.params.?;
    std.debug.assert(params.objectId != null or params.executionContextId != null);
    if (params.executionContextId) |contextID| {
        std.debug.assert(contextID == ctx.state.executionContextId);
    }
    const name = "callFunctionOn";

    // save script in file at debug mode
    std.log.debug("{s} script id {d}, length: {d}", .{ name, id, params.functionDeclaration.len });
    if (std.log.defaultLogEnabled(.debug)) {
        try cdp.dumpFile(alloc, id, params.functionDeclaration);
    }

    // parse function
    if (!std.mem.startsWith(u8, params.functionDeclaration, "function ")) {
        return error.CDPRuntimeCallFunctionOnNotFunction;
    }
    const pos = std.mem.indexOfScalar(u8, params.functionDeclaration, '(');
    if (pos == null) return error.CDPRuntimeCallFunctionOnWrongFunction;
    var function = params.functionDeclaration[9..pos.?];
    function = try std.fmt.allocPrint(alloc, "{s}(", .{function});
    defer alloc.free(function);
    if (params.arguments) |args| {
        for (args, 0..) |arg, i| {
            if (i > 0) {
                function = try std.fmt.allocPrint(alloc, "{s}, ", .{function});
            }
            if (arg.value) |value| {
                function = try std.fmt.allocPrint(alloc, "{s}\"{s}\"", .{ function, value });
            } else {
                function = try std.fmt.allocPrint(alloc, "{s}undefined", .{function});
            }
        }
    }
    function = try std.fmt.allocPrint(alloc, "{s});", .{function});
    std.log.debug("{s} id {d}, function parsed: {s}", .{ name, id, function });

    const session = ctx.browser.currentSession();
    // TODO: should we use the page's allocator instead of the session's allocator?
    // the following code does not work with session.page.?.arena.allocator() as alloc

    // first evaluate the function declaration
    _ = try runtimeEvaluate(session.alloc, id, session.env, params.functionDeclaration, name);

    // then call the function on the arguments
    _ = try runtimeEvaluate(session.alloc, id, session.env, function, name);

    return result(alloc, id, null, "{\"type\":\"undefined\"}", msg.sessionID);
}

// caller is the owner of JSResult returned
fn runtimeEvaluate(
    alloc: std.mem.Allocator,
    id: u16,
    env: jsruntime.Env,
    script: []const u8,
    comptime name: []const u8,
) !jsruntime.JSValue {

    // try catch
    var try_catch: jsruntime.TryCatch = undefined;
    try_catch.init(env);
    defer try_catch.deinit();

    // script exec
    const res = env.execWait(script, name) catch {
        if (try try_catch.err(alloc, env)) |err_msg| {
            defer alloc.free(err_msg);
            std.log.err("'{s}' id {d}, result: {s}", .{ name, id, err_msg });
        }
        return error.CDPRuntimeEvaluate;
    };

    if (builtin.mode == .Debug) {
        const res_msg = try res.toString(alloc, env);
        defer alloc.free(res_msg);
        std.log.debug("'{s}' id {d}, result: {s}", .{ name, id, res_msg });
    }
    return res;
}
