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

const server = @import("../server.zig");
const Ctx = server.Ctx;
const cdp = @import("cdp.zig");
const result = cdp.result;
const IncomingMessage = @import("msg.zig").IncomingMessage;

const log = std.log.scoped(.cdp);

const Methods = enum {
    getVersion,
    setDownloadBehavior,
    getWindowForTarget,
    setWindowBounds,
};

pub fn browser(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    action: []const u8,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .getVersion => getVersion(alloc, msg, ctx),
        .setDownloadBehavior => setDownloadBehavior(alloc, msg, ctx),
        .getWindowForTarget => getWindowForTarget(alloc, msg, ctx),
        .setWindowBounds => setWindowBounds(alloc, msg, ctx),
    };
}

// TODO: hard coded data
const ProtocolVersion = "1.3";
const Product = "Chrome/124.0.6367.29";
const Revision = "@9e6ded5ac1ff5e38d930ae52bd9aec09bd1a68e4";
const UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const JsVersion = "12.4.254.8";

fn getVersion(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {
    // input
    const input = try msg.getInput(alloc, void);
    log.debug("Req > id {d}, method {s}", .{ input.id, "browser.getVersion" });

    // ouput
    const Res = struct {
        protocolVersion: []const u8 = ProtocolVersion,
        product: []const u8 = Product,
        revision: []const u8 = Revision,
        userAgent: []const u8 = UserAgent,
        jsVersion: []const u8 = JsVersion,
    };
    return result(alloc, input.id, Res, .{}, null);
}

// TODO: noop method
fn setDownloadBehavior(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {
    // input
    const Params = struct {
        behavior: []const u8,
        browserContextId: ?[]const u8 = null,
        downloadPath: ?[]const u8 = null,
        eventsEnabled: ?bool = null,
    };
    const input = try msg.getInput(alloc, Params);
    log.debug("REQ > id {d}, method {s}", .{ input.id, "browser.setDownloadBehavior" });

    // output
    return result(alloc, input.id, null, null, null);
}

// TODO: hard coded ID
const DevToolsWindowID = 1923710101;

fn getWindowForTarget(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        targetId: ?[]const u8 = null,
    };
    const input = try msg.getInput(alloc, Params);
    std.debug.assert(input.sessionId != null);
    log.debug("Req > id {d}, method {s}", .{ input.id, "browser.getWindowForTarget" });

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
    return result(alloc, input.id, Resp, Resp{}, input.sessionId);
}

// TODO: noop method
fn setWindowBounds(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {
    const input = try msg.getInput(alloc, void);

    // input
    log.debug("Req > id {d}, method {s}", .{ input.id, "browser.setWindowBounds" });

    // output
    return result(alloc, input.id, null, null, input.sessionId);
}
