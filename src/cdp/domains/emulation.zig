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
const CDP = @import("../CDP.zig");
const log = @import("../../log.zig");

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        setEmulatedMedia,
        setFocusEmulationEnabled,
        setDeviceMetricsOverride,
        setTouchEmulationEnabled,
        setUserAgentOverride,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .setEmulatedMedia => return setEmulatedMedia(cmd),
        .setFocusEmulationEnabled => return setFocusEmulationEnabled(cmd),
        .setDeviceMetricsOverride => return setDeviceMetricsOverride(cmd),
        .setTouchEmulationEnabled => return setTouchEmulationEnabled(cmd),
        .setUserAgentOverride => return setUserAgentOverride(cmd),
    }
}

// TODO: noop method
fn setEmulatedMedia(cmd: *CDP.Command) !void {
    // const input = (try const incoming.params(struct {
    //     media: ?[]const u8 = null,
    //     features: ?[]struct{
    //         name: []const u8,
    //         value: [] const u8
    //     } = null,
    // })) orelse return error.InvalidParams;

    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn setFocusEmulationEnabled(cmd: *CDP.Command) !void {
    // const input = (try const incoming.params(struct {
    //     enabled: bool,
    // })) orelse return error.InvalidParams;
    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn setDeviceMetricsOverride(cmd: *CDP.Command) !void {
    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn setTouchEmulationEnabled(cmd: *CDP.Command) !void {
    return cmd.sendResult(null, .{});
}

// Emulation.setUserAgentOverride is also called by Network.setUserAgentOverride
pub fn setUserAgentOverride(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        userAgent: []const u8,
        acceptLanguage: ?[]const u8 = null,
        platform: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.acceptLanguage) |v| {
        log.warn(.not_implemented, "Emulation.setUserAgentOverride", .{ .param = "acceptLanguage", .value = v });
    }
    if (params.platform) |v| {
        log.warn(.not_implemented, "Emulation.setUserAgentOverride", .{ .param = "platform", .value = v });
    }

    const ua = params.userAgent;

    // Validate: all characters must be printable ASCII
    for (ua) |c| {
        if (!std.ascii.isPrint(c)) {
            return cmd.sendError(-32602, "User agent contains non-printable characters", .{});
        }
    }

    // Reject user agents containing "mozilla" (case-insensitive)
    if (std.ascii.indexOfIgnoreCase(ua, "mozilla") != null) {
        return cmd.sendError(-32602, "User agent must not contain Mozilla", .{});
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const http_client = cmd.cdp.browser.http_client;
    try http_client.setUserAgentOverride(ua);
    bc.user_agent_changed = true;

    return cmd.sendResult(null, .{});
}

const testing = @import("../testing.zig");

test "cdp.Emulation: setUserAgentOverride with valid user agent" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA1" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Emulation.setUserAgentOverride",
        .params = .{ .userAgent = "CustomBot/1.0" },
    });

    try ctx.expectSentResult(null, .{ .id = 1 });
}

test "cdp.Emulation: setUserAgentOverride rejects mozilla" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA2" });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Emulation.setUserAgentOverride",
        .params = .{ .userAgent = "Mozilla/5.0 (Windows NT 10.0)" },
    });

    try ctx.expectSentError(-32602, "User agent must not contain Mozilla", .{ .id = 2 });
}

test "cdp.Emulation: setUserAgentOverride rejects mozilla case insensitive" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA3" });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Emulation.setUserAgentOverride",
        .params = .{ .userAgent = "MOZILLA/5.0 test" },
    });

    try ctx.expectSentError(-32602, "User agent must not contain Mozilla", .{ .id = 3 });
}

test "cdp.Emulation: setUserAgentOverride rejects non-printable characters" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA4" });

    try ctx.processMessage(.{
        .id = 4,
        .method = "Emulation.setUserAgentOverride",
        .params = .{ .userAgent = "Bot/1.0\x01hidden" },
    });

    try ctx.expectSentError(-32602, "User agent contains non-printable characters", .{ .id = 4 });
}

test "cdp.Emulation: setUserAgentOverride with optional params" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA5" });

    try ctx.processMessage(.{
        .id = 5,
        .method = "Emulation.setUserAgentOverride",
        .params = .{
            .userAgent = "CustomBot/2.0",
            .acceptLanguage = "en-US",
            .platform = "Linux",
        },
    });

    try ctx.expectSentResult(null, .{ .id = 5 });
}

test "cdp.Emulation: setUserAgentOverride can be called multiple times" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA6" });

    try ctx.processMessage(.{
        .id = 6,
        .method = "Emulation.setUserAgentOverride",
        .params = .{ .userAgent = "FirstBot/1.0" },
    });

    try ctx.expectSentResult(null, .{ .id = 6 });

    try ctx.processMessage(.{
        .id = 7,
        .method = "Emulation.setUserAgentOverride",
        .params = .{ .userAgent = "SecondBot/2.0" },
    });

    try ctx.expectSentResult(null, .{ .id = 7 });
}
