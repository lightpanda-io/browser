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
const cdp = @import("cdp.zig");

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        runIfWaitingForDebugger,
        evaluate,
        addBinding,
        callFunctionOn,
        releaseObject,
    }, cmd.action) orelse return error.UnknownMethod;

    switch (action) {
        .runIfWaitingForDebugger => return cmd.sendResult(null, .{}),
        else => return sendInspector(cmd, action),
    }
}

fn sendInspector(cmd: anytype, action: anytype) !void {
    // save script in file at debug mode
    if (std.log.defaultLogEnabled(.debug)) {
        try logInspector(cmd, action);
    }

    if (cmd.session_id) |s| {
        cmd.cdp.session_id = try cdp.SessionID.parse(s);
    }

    // remove awaitPromise true params
    // TODO: delete when Promise are correctly handled by zig-js-runtime
    if (action == .callFunctionOn or action == .evaluate) {
        const json = cmd.json;
        if (std.mem.indexOf(u8, json, "\"awaitPromise\":true")) |_| {
            // +1 because we'll be turning a true -> false
            const buf = try cmd.arena.alloc(u8, json.len + 1);
            _ = std.mem.replace(u8, json, "\"awaitPromise\":true", "\"awaitPromise\":false", buf);
            cmd.session.callInspector(buf);
            return;
        }
    }

    cmd.session.callInspector(cmd.json);

    if (cmd.id != null) {
        return cmd.sendResult(null, .{});
    }
}

pub const ExecutionContextCreated = struct {
    id: u64,
    origin: []const u8,
    name: []const u8,
    uniqueId: []const u8,
    auxData: ?AuxData = null,

    pub const AuxData = struct {
        isDefault: bool = true,
        type: []const u8 = "default",
        frameId: []const u8 = cdp.FRAME_ID,
    };
};

fn logInspector(cmd: anytype, action: anytype) !void {
    const script = switch (action) {
        .evaluate => blk: {
            const params = (try cmd.params(struct {
                expression: []const u8,
                // contextId: ?u8 = null,
                // returnByValue: ?bool = null,
                // awaitPromise: ?bool = null,
                // userGesture: ?bool = null,
            })) orelse return error.InvalidParams;

            break :blk params.expression;
        },
        .callFunctionOn => blk: {
            const params = (try cmd.params(struct {
                functionDeclaration: []const u8,
                // objectId: ?[]const u8 = null,
                // executionContextId: ?u8 = null,
                // arguments: ?[]struct {
                //     value: ?[]const u8 = null,
                //     objectId: ?[]const u8 = null,
                // } = null,
                // returnByValue: ?bool = null,
                // awaitPromise: ?bool = null,
                // userGesture: ?bool = null,
            })) orelse return error.InvalidParams;

            break :blk params.functionDeclaration;
        },
        else => return,
    };
    const id = cmd.id orelse return error.RequiredId;
    const name = try std.fmt.allocPrint(cmd.arena, "id_{d}.js", .{id});

    var dir = try std.fs.cwd().makeOpenPath("zig-cache/tmp", .{});
    defer dir.close();

    const f = try dir.createFile(name, .{});
    defer f.close();
    try f.writeAll(script);
}
