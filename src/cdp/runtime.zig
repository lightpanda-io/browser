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
    releaseObject,
};

pub fn runtime(
    alloc: std.mem.Allocator,
    id: ?u16,
    action: []const u8,
    scanner: *std.json.Scanner,
    s: []const u8,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        // NOTE: we could send it anyway to the JS runtime but it's good to check it
        return error.UnknownMethod;
    return switch (method) {
        .runIfWaitingForDebugger => runIfWaitingForDebugger(alloc, id, scanner, ctx),
        else => sendInspector(alloc, method, id, s, scanner, ctx),
    };
}

fn sendInspector(
    alloc: std.mem.Allocator,
    method: Methods,
    _id: ?u16,
    s: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {

    // save script in file at debug mode
    if (std.log.defaultLogEnabled(.debug)) {

        // input
        var script: ?[]const u8 = null;
        var id: u16 = undefined;

        if (method == .evaluate) {
            const Params = struct {
                expression: []const u8,
                contextId: ?u8 = null,
                returnByValue: ?bool = null,
                awaitPromise: ?bool = null,
                userGesture: ?bool = null,
            };

            const msg = try getMsg(alloc, Params, scanner);
            const params = msg.params.?;
            script = params.expression;
            id = _id orelse msg.id.?;
        } else if (method == .callFunctionOn) {
            const Params = struct {
                functionDeclaration: []const u8,
                objectId: ?[]const u8 = null,
                executionContextId: ?u8 = null,
                arguments: ?[]struct {
                    value: ?[]const u8 = null,
                    objectId: ?[]const u8 = null,
                } = null,
                returnByValue: ?bool = null,
                awaitPromise: ?bool = null,
                userGesture: ?bool = null,
            };

            const msg = try getMsg(alloc, Params, scanner);
            const params = msg.params.?;
            script = params.functionDeclaration;
            id = _id orelse msg.id.?;
        }

        if (script) |src| {
            try cdp.dumpFile(alloc, id, src);
        }
    }

    // remove awaitPromise true params
    // TODO: delete when Promise are correctly handled by zig-js-runtime
    if (method == .callFunctionOn or method == .evaluate) {
        const buf = try alloc.alloc(u8, s.len + 1);
        defer alloc.free(buf);
        _ = std.mem.replace(u8, s, "\"awaitPromise\":true", "\"awaitPromise\":false", buf);
        ctx.sendInspector(buf);
    } else {
        ctx.sendInspector(s);
    }
    return "";
}

pub const AuxData = struct {
    isDefault: bool = true,
    type: []const u8 = "default",
    frameId: []const u8 = cdp.FrameID,
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
        context: struct {
            id: u64,
            origin: []const u8,
            name: []const u8,
            uniqueId: []const u8,
            auxData: ?AuxData = null,
        },
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

// TODO: noop method
// should we be passing this also to the JS Inspector?
fn runIfWaitingForDebugger(
    alloc: std.mem.Allocator,
    id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const msg = try getMsg(alloc, void, scanner);

    return result(alloc, id orelse msg.id.?, null, null, msg.sessionID);
}
