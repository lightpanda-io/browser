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
const lp = @import("lightpanda");
const CDP = @import("../CDP.zig");

const log = lp.log;
const PermissionState = @import("../../browser/webapi/Permissions.zig").State;

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

pub fn processMessage(cmd: *CDP.Command) !void {
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

fn getVersion(cmd: *CDP.Command) !void {
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
fn setDownloadBehavior(cmd: *CDP.Command) !void {
    // const params = (try cmd.params(struct {
    //     behavior: []const u8,
    //     browserContextId: ?[]const u8 = null,
    //     downloadPath: ?[]const u8 = null,
    //     eventsEnabled: ?bool = null,
    // })) orelse return error.InvalidParams;

    return cmd.sendResult(null, .{ .include_session_id = false });
}

fn getWindowForTarget(cmd: *CDP.Command) !void {
    // const params = (try cmd.params(struct {
    //     targetId: ?[]const u8 = null,
    // })) orelse return error.InvalidParams;

    return cmd.sendResult(.{ .windowId = DEV_TOOLS_WINDOW_ID, .bounds = .{
        .windowState = "normal",
    } }, .{});
}

// TODO: noop method
fn setWindowBounds(cmd: *CDP.Command) !void {
    return cmd.sendResult(null, .{});
}

// Grant the listed permissions so navigator.permissions.query() reports them
// as "granted". State is stored on the Browser, so it persists across page
// navigations.
fn grantPermissions(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        permissions: []const []const u8,
        origin: ?[]const u8 = null,
        browserContextId: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.origin) |v| {
        log.warn(.not_implemented, "Browser.grantPermissions", .{ .param = "origin", .value = v });
    }
    if (params.browserContextId) |v| {
        log.warn(.not_implemented, "Browser.grantPermissions", .{ .param = "browserContextId", .value = v });
    }

    const browser = &cmd.cdp.browser;
    for (params.permissions) |name| {
        try browser.setPermission(name, .granted);
    }

    return cmd.sendResult(null, .{ .include_session_id = false });
}

// Set a single permission to an explicit state ("granted", "denied" or
// "prompt"), reflected by navigator.permissions.query().
fn setPermission(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        permission: struct { name: []const u8 },
        setting: []const u8,
        origin: ?[]const u8 = null,
        browserContextId: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.origin) |v| {
        log.warn(.not_implemented, "Browser.setPermission", .{ .param = "origin", .value = v });
    }
    if (params.browserContextId) |v| {
        log.warn(.not_implemented, "Browser.setPermission", .{ .param = "browserContextId", .value = v });
    }

    const state = std.meta.stringToEnum(PermissionState, params.setting) orelse {
        return error.InvalidPermissionSetting;
    };
    try cmd.cdp.browser.setPermission(params.permission.name, state);
    return cmd.sendResult(null, .{ .include_session_id = false });
}

// Clear all granted permissions; navigator.permissions.query() falls back to
// the default "prompt".
fn resetPermissions(cmd: *CDP.Command) !void {
    cmd.cdp.browser.clearPermissions();
    return cmd.sendResult(null, .{ .include_session_id = false });
}

const testing = @import("../testing.zig");
test "cdp.browser: getVersion" {
    var ctx = try testing.context();
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
    var ctx = try testing.context();
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

test "cdp.browser: grant/set/reset permissions reach navigator.permissions" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-PERM", .url = "cdp/dom1.html" });
    const browser = bc.session.browser;

    // grantPermissions: each listed permission becomes "granted". State lives
    // on the Browser, not the Page.
    try ctx.processMessage(.{
        .id = 40,
        .method = "Browser.grantPermissions",
        .params = .{ .permissions = &[_][]const u8{ "geolocation", "notifications" } },
    });
    try ctx.expectSentResult(null, .{ .id = 40, .session_id = null });
    // State lives on the Browser, not the Page, so it persists for the whole
    // CDP connection (across page navigations) rather than being lost when the
    // page is replaced.
    try testing.expectEqual(.granted, browser.permissions.get("geolocation").?);
    try testing.expectEqual(.granted, browser.permissions.get("notifications").?);

    // setPermission: override a single permission to an explicit state.
    try ctx.processMessage(.{
        .id = 41,
        .method = "Browser.setPermission",
        .params = .{ .permission = .{ .name = "geolocation" }, .setting = "denied" },
    });
    try ctx.expectSentResult(null, .{ .id = 41, .session_id = null });
    try testing.expectEqual(.denied, browser.permissions.get("geolocation").?);

    // resetPermissions: clears everything; query falls back to "prompt".
    try ctx.processMessage(.{
        .id = 42,
        .method = "Browser.resetPermissions",
    });
    try ctx.expectSentResult(null, .{ .id = 42, .session_id = null });
    try testing.expectEqual(@as(usize, 0), browser.permissions.count());
}
