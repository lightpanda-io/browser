// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const builtin = @import("builtin");

const jsruntime = @import("jsruntime");

const server = @import("../server.zig");
const Ctx = server.Ctx;
const cdp = @import("cdp.zig");
const result = cdp.result;
const IncomingMessage = @import("msg.zig").IncomingMessage;
const stringify = cdp.stringify;
const target = @import("target.zig");

const log = std.log.scoped(.cdp);

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
    msg: *IncomingMessage,
    action: []const u8,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        // NOTE: we could send it anyway to the JS runtime but it's good to check it
        return error.UnknownMethod;
    return switch (method) {
        .runIfWaitingForDebugger => runIfWaitingForDebugger(alloc, msg, ctx),
        else => sendInspector(alloc, method, msg, ctx),
    };
}

fn sendInspector(
    alloc: std.mem.Allocator,
    method: Methods,
    msg: *IncomingMessage,
    ctx: *Ctx,
) ![]const u8 {
    var sessionId: ?[]const u8 = null;

    // save script in file at debug mode
    if (std.log.defaultLogEnabled(.debug)) {

        // input
        var id: u16 = undefined;
        var script: ?[]const u8 = null;

        if (method == .evaluate) {
            const Params = struct {
                expression: []const u8,
                contextId: ?u8 = null,
                returnByValue: ?bool = null,
                awaitPromise: ?bool = null,
                userGesture: ?bool = null,
            };

            const input = try msg.getInput(alloc, Params);
            log.debug("Req > id {d}, method {s} (script saved on cache)", .{ input.id, "runtime.evaluate" });
            script = input.params.expression;
            id = input.id;
            sessionId = input.sessionId;
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

            const input = try msg.getInput(alloc, Params);
            log.debug("Req > id {d}, method {s} (script saved on cache)", .{ input.id, "runtime.callFunctionOn" });
            script = input.params.functionDeclaration;
            id = input.id;
            sessionId = input.sessionId;
        }

        if (script) |src| {
            try cdp.dumpFile(alloc, id, src);
        }
    } else {
        const input = try msg.getInput(alloc, void);
        sessionId = input.sessionId;
    }

    // remove awaitPromise true params
    // TODO: delete when Promise are correctly handled by zig-js-runtime
    if (method == .callFunctionOn or method == .evaluate) {
        const buf = try alloc.alloc(u8, msg.json.len + 1);
        defer alloc.free(buf);
        _ = std.mem.replace(u8, msg.json, "\"awaitPromise\":true", "\"awaitPromise\":false", buf);
        ctx.sendInspector(buf);
    } else {
        ctx.sendInspector(msg.json);
    }

    if (method == .enable) {
        try executionContextCreated(
            alloc,
            ctx,
            0,
            "://",
            "",
            // TODO: hard coded ID
            "7102379147004877974.3265385113993241162",
            .{
                .isDefault = true,
                .type = "default",
                // TODO: hard coded ID
                .frameId = cdp.FrameID,
            },
            // TODO: hard coded ID
            sessionId,
        );
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
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {
    const input = try msg.getInput(alloc, void);
    log.debug("Req > id {d}, method {s}", .{ input.id, "runtime.runIfWaitingForDebugger" });

    return result(alloc, input.id, null, null, input.sessionId);
}
