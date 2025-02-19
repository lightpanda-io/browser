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

// TODO: hard coded data
const PROTOCOL_VERSION = "1.3";
const PRODUCT = "Chrome/124.0.6367.29";
const REVISION = "@9e6ded5ac1ff5e38d930ae52bd9aec09bd1a68e4";
const USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const JS_VERSION = "12.4.254.8";
const DEV_TOOLS_WINDOW_ID = 1923710101;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        getVersion,
        setDownloadBehavior,
        getWindowForTarget,
        setWindowBounds,
    }, cmd.action) orelse return error.UnknownMethod;

    switch (action) {
        .getVersion => return getVersion(cmd),
        .setDownloadBehavior => return setDownloadBehavior(cmd),
        .getWindowForTarget => return getWindowForTarget(cmd),
        .setWindowBounds => return setWindowBounds(cmd),
    }
}

fn getVersion(cmd: anytype) !void {
    // TODO: pre-serialize?
    return cmd.sendResult(.{
        .protocolVersion = PROTOCOL_VERSION,
        .product = PRODUCT,
        .revision = REVISION,
        .userAgent = USER_AGENT,
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
