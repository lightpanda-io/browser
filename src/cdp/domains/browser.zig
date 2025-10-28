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

// TODO: hard coded data
const PROTOCOL_VERSION = "1.3";
const REVISION = "@9e6ded5ac1ff5e38d930ae52bd9aec09bd1a68e4";

// CDP_USER_AGENT const is used by the CDP server only to identify itself to
// the CDP clients.
// Many clients check the CDP server is a Chrome browser.
//
// CDP_USER_AGENT const is not used by the browser for the HTTP client (see
// src/http/client.zig) nor exposed to the JS (see
// src/browser/html/navigator.zig).
const CDP_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const PRODUCT = "Chrome/124.0.6367.29";

const JS_VERSION = "12.4.254.8";
const DEV_TOOLS_WINDOW_ID = 1923710101;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        getVersion,
        setPermission,
        setWindowBounds,
        resetPermissions,
        grantPermissions,
        getWindowForTarget,
        setDownloadBehavior,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .getVersion => return getVersion(cmd),
        .setPermission => return setPermission(cmd),
        .setWindowBounds => return setWindowBounds(cmd),
        .resetPermissions => return resetPermissions(cmd),
        .grantPermissions => return grantPermissions(cmd),
        .getWindowForTarget => return getWindowForTarget(cmd),
        .setDownloadBehavior => return setDownloadBehavior(cmd),
    }
}

fn getVersion(cmd: anytype) !void {
    // TODO: pre-serialize?
    return cmd.sendResult(.{
        .protocolVersion = PROTOCOL_VERSION,
        .product = PRODUCT,
        .revision = REVISION,
        .userAgent = CDP_USER_AGENT,
        .jsVersion = JS_VERSION,
    }, .{ .include_session_id = false });
}

// TODO: noop method
fn setDownloadBehavior(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     behavior: []const u8,
    //     browserContextId: ?[]const u8 = null,
    //     downloadPath: ?[]const u8 = null,
    //     eventsEnabled: ?bool = null,
    // })) orelse return error.InvalidParams;

    return cmd.sendResult(null, .{ .include_session_id = false });
}

fn getWindowForTarget(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     targetId: ?[]const u8 = null,
    // })) orelse return error.InvalidParams;

    return cmd.sendResult(.{ .windowId = DEV_TOOLS_WINDOW_ID, .bounds = .{
        .windowState = "normal",
    } }, .{});
}

// TODO: noop method
fn setWindowBounds(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn grantPermissions(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn setPermission(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn resetPermissions(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

const testing = @import("../testing.zig");
test "cdp.browser: getVersion" {
    var ctx = testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{
        .id = 32,
        .method = "Browser.getVersion",
    });

    try ctx.expectSentCount(1);
    try ctx.expectSentResult(.{
        .protocolVersion = PROTOCOL_VERSION,
        .product = PRODUCT,
        .revision = REVISION,
        .userAgent = CDP_USER_AGENT,
        .jsVersion = JS_VERSION,
    }, .{ .id = 32, .index = 0, .session_id = null });
}

test "cdp.browser: getWindowForTarget" {
    var ctx = testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{
        .id = 33,
        .method = "Browser.getWindowForTarget",
    });

    try ctx.expectSentCount(1);
    try ctx.expectSentResult(.{
        .windowId = DEV_TOOLS_WINDOW_ID,
        .bounds = .{ .windowState = "normal" },
    }, .{ .id = 33, .index = 0, .session_id = null });
}
