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
const Config = @import("../../Config.zig");

const log = lp.log;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        setEmulatedMedia,
        setFocusEmulationEnabled,
        setDeviceMetricsOverride,
        clearDeviceMetricsOverride,
        setTouchEmulationEnabled,
        setUserAgentOverride,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .setEmulatedMedia => return setEmulatedMedia(cmd),
        .setFocusEmulationEnabled => return setFocusEmulationEnabled(cmd),
        .setDeviceMetricsOverride => return setDeviceMetricsOverride(cmd),
        .clearDeviceMetricsOverride => return clearDeviceMetricsOverride(cmd),
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

fn setDeviceMetricsOverride(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        width: u32,
        height: u32,
        deviceScaleFactor: ?f64 = null,
        mobile: ?bool = null,
        scale: ?f64 = null,
        screenWidth: ?u32 = null,
        screenHeight: ?u32 = null,
    })) orelse return error.InvalidParams;

    // Not-yet-emulated parameters: accept them but warn so the caller knows
    // they are ignored.
    if (params.deviceScaleFactor) |v| {
        if (v != 0) log.warn(.not_implemented, "setDeviceMetricsOverride", .{
            .cdp_cmd = "Emulation.setDeviceMetricsOverride",
            .param = "deviceScaleFactor",
            .value = v,
        });
    }
    if (params.mobile) |v| {
        if (v) log.warn(.not_implemented, "setDeviceMetricsOverride", .{
            .cdp_cmd = "Emulation.setDeviceMetricsOverride",
            .param = "mobile",
            .value = v,
        });
    }
    if (params.scale) |v| {
        if (v != 0) log.warn(.not_implemented, "setDeviceMetricsOverride", .{
            .cdp_cmd = "Emulation.setDeviceMetricsOverride",
            .param = "scale",
            .value = v,
        });
    }
    if (params.screenWidth) |v| {
        if (v != 0) log.warn(.not_implemented, "setDeviceMetricsOverride", .{
            .cdp_cmd = "Emulation.setDeviceMetricsOverride",
            .param = "screenWidth",
            .value = v,
        });
    }
    if (params.screenHeight) |v| {
        if (v != 0) log.warn(.not_implemented, "setDeviceMetricsOverride", .{
            .cdp_cmd = "Emulation.setDeviceMetricsOverride",
            .param = "screenHeight",
            .value = v,
        });
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.FrameNotLoaded;

    // CDP convention: a 0 width/height means "don't override that dimension",
    // so keep the current value for any dimension passed as 0.
    const current = page.getViewport();
    page.viewport_override = .{
        .width = if (params.width > 0) params.width else current.width,
        .height = if (params.height > 0) params.height else current.height,
    };

    return cmd.sendResult(null, .{});
}

fn clearDeviceMetricsOverride(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const page = bc.session.currentPage() orelse return error.FrameNotLoaded;
    page.viewport_override = null;
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
    Config.validateUserAgent(ua) catch |err| switch (err) {
        error.NonPrintable => return cmd.sendError(-32602, "User agent contains non-printable characters", .{}),
        error.Reserved => {
            log.warn(.not_implemented, "Emulation.setUserAgentOverride", .{ .param = "userAgent", .value = ua, .info = "User agent must not contain Mozilla" });
            return cmd.sendResult(null, .{});
        },
    };

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const http_client = &cmd.cdp.browser.http_client;
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

test "cdp.Emulation: setUserAgentOverride ignores mozilla" {
    const filter: testing.LogFilter = .init(&.{.not_implemented});
    defer filter.deinit();

    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA2" });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Emulation.setUserAgentOverride",
        .params = .{ .userAgent = "Mozilla/5.0 (Windows NT 10.0)" },
    });

    try ctx.expectSentResult(null, .{});
    try testing.expectEqual(false, ctx.cdp().browser_context.?.user_agent_changed);
}

test "cdp.Emulation: setUserAgentOverride ignores mozilla case insensitive" {
    const filter: testing.LogFilter = .init(&.{.not_implemented});
    defer filter.deinit();

    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-UA3" });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Emulation.setUserAgentOverride",
        .params = .{ .userAgent = "MOZILLA/5.0 test" },
    });

    try ctx.expectSentResult(null, .{});
    try testing.expectEqual(false, ctx.cdp().browser_context.?.user_agent_changed);
}

test "cdp.Emulation: setUserAgentOverride rejects non-printable characters" {
    const filter: testing.LogFilter = .init(&.{.not_implemented});
    defer filter.deinit();

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
    const filter: testing.LogFilter = .init(&.{.not_implemented});
    defer filter.deinit();

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

test "cdp.Emulation: setDeviceMetricsOverride and clear" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-DM1" });
    _ = try bc.session.createPage();
    const page = bc.session.currentPage().?;

    // Defaults to the compile-time viewport before any override.
    try testing.expectEqual(1920, page.getViewport().width);
    try testing.expectEqual(1080, page.getViewport().height);

    try ctx.processMessage(.{
        .id = 8,
        .method = "Emulation.setDeviceMetricsOverride",
        .params = .{ .width = 375, .height = 812 },
    });

    try ctx.expectSentResult(null, .{ .id = 8 });
    try testing.expectEqual(375, page.getViewport().width);
    try testing.expectEqual(812, page.getViewport().height);

    try ctx.processMessage(.{
        .id = 9,
        .method = "Emulation.clearDeviceMetricsOverride",
    });

    try ctx.expectSentResult(null, .{ .id = 9 });
    try testing.expectEqual(1920, page.getViewport().width);
    try testing.expectEqual(1080, page.getViewport().height);
}
