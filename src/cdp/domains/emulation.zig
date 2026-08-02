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
const Browser = @import("../../browser/Browser.zig");
const Viewport = @import("../../browser/Viewport.zig");

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
        screenOrientation: ?struct {
            type: []const u8,
            angle: i32,
        } = null,
    })) orelse return error.InvalidParams;

    const max_dimension = 10_000_000;
    const screen_width = params.screenWidth orelse 0;
    const screen_height = params.screenHeight orelse 0;
    const device_scale_factor = params.deviceScaleFactor orelse 0;
    if (params.width > max_dimension or
        params.height > max_dimension or
        screen_width > max_dimension or
        screen_height > max_dimension or
        device_scale_factor < 0)
    {
        return error.InvalidParams;
    }

    var screen_orientation: Browser.ScreenOrientation = .{};
    if (params.screenOrientation) |orientation| {
        if (orientation.angle < 0 or orientation.angle > 359) {
            return error.InvalidParams;
        }
        screen_orientation = .{
            .type = if (std.mem.eql(u8, orientation.type, "portraitPrimary"))
                .portrait_primary
            else if (std.mem.eql(u8, orientation.type, "portraitSecondary"))
                .portrait_secondary
            else if (std.mem.eql(u8, orientation.type, "landscapePrimary"))
                .landscape_primary
            else if (std.mem.eql(u8, orientation.type, "landscapeSecondary"))
                .landscape_secondary
            else
                return error.InvalidParams,
            .angle = orientation.angle,
        };
    }

    const viewport_override: ?Viewport = if (params.width == 0 and params.height == 0)
        null
    else
        .{
            .width = if (params.width > 0) params.width else Viewport.default.width,
            .height = if (params.height > 0) params.height else Viewport.default.height,
        };
    const screen_override: ?Viewport = if (screen_width > 0 and screen_height > 0)
        .{ .width = screen_width, .height = screen_height }
    else
        null;

    // Not-yet-emulated parameters: accept them but warn so the caller knows
    // they are ignored.
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
    // The override is stored on the Browser so it persists across page
    // navigations in the current session.
    const browser = &cmd.cdp.browser;
    browser.viewport_override = viewport_override;
    browser.screen_override = screen_override;
    browser.screen_orientation = screen_orientation;
    browser.device_scale_factor = if (device_scale_factor > 0) device_scale_factor else 1;

    return cmd.sendResult(null, .{});
}

fn clearDeviceMetricsOverride(cmd: *CDP.Command) !void {
    cmd.cdp.browser.resetDeviceMetrics();
    return cmd.sendResult(null, .{});
}

fn setTouchEmulationEnabled(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        enabled: bool,
        maxTouchPoints: u32 = 1,
    })) orelse return error.InvalidParams;

    if (params.maxTouchPoints < 1 or params.maxTouchPoints > 16) {
        return error.InvalidParams;
    }
    cmd.cdp.browser.max_touch_points = if (params.enabled) params.maxTouchPoints else 0;
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
    testing.silenceLog(&.{.not_implemented});

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
    testing.silenceLog(&.{.not_implemented});

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
    testing.silenceLog(&.{.not_implemented});

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
    testing.silenceLog(&.{.not_implemented});

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
    const page = bc.mainPage().?;
    const frame = bc.mainFrame() orelse unreachable;

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // Defaults to the compile-time viewport before any override.
    try testing.expectEqual(1920, page.getViewport().width);
    try testing.expectEqual(1080, page.getViewport().height);

    try ctx.processMessage(.{
        .id = 8,
        .method = "Emulation.setDeviceMetricsOverride",
        .params = .{
            .width = 375,
            .height = 812,
            .deviceScaleFactor = 3,
            .screenWidth = 430,
            .screenHeight = 932,
            .screenOrientation = .{
                .type = "portraitPrimary",
                .angle = 0,
            },
        },
    });

    try ctx.expectSentResult(null, .{ .id = 8 });
    try testing.expectEqual(375, page.getViewport().width);
    try testing.expectEqual(812, page.getViewport().height);
    try testing.expectEqual(430, bc.session.browser.getScreen().width);
    try testing.expectEqual(932, bc.session.browser.getScreen().height);
    try testing.expectEqual(3, bc.session.browser.device_scale_factor);
    try testing.expect((try ls.local.exec(
        \\innerWidth === 375 &&
        \\innerHeight === 812 &&
        \\screen.width === 430 &&
        \\screen.height === 932 &&
        \\screen.availWidth === 430 &&
        \\screen.availHeight === 932 &&
        \\screen.orientation.type === "portrait-primary" &&
        \\devicePixelRatio === 3
    , null)).isTrue());

    try ctx.processMessage(.{
        .id = 13,
        .method = "Emulation.setDeviceMetricsOverride",
        .params = .{
            .width = 800,
            .height = 600,
            .deviceScaleFactor = 2,
            .screenOrientation = .{
                .type = "sideways",
                .angle = 0,
            },
        },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 13 });
    try testing.expectEqual(375, page.getViewport().width);
    try testing.expectEqual(812, page.getViewport().height);
    try testing.expectEqual(430, bc.session.browser.getScreen().width);
    try testing.expectEqual(932, bc.session.browser.getScreen().height);
    try testing.expectEqual(3, bc.session.browser.device_scale_factor);

    // The override lives on the Browser, so it persists across page
    // navigations rather than being lost with the page.
    try testing.expectEqual(375, bc.session.browser.getViewport().width);
    try testing.expectEqual(812, bc.session.browser.getViewport().height);

    try ctx.processMessage(.{
        .id = 9,
        .method = "Emulation.clearDeviceMetricsOverride",
    });

    try ctx.expectSentResult(null, .{ .id = 9 });
    try testing.expectEqual(1920, page.getViewport().width);
    try testing.expectEqual(1080, page.getViewport().height);
    try testing.expectEqual(1920, bc.session.browser.getScreen().width);
    try testing.expectEqual(1080, bc.session.browser.getScreen().height);
    try testing.expectEqual(1, bc.session.browser.device_scale_factor);
    try testing.expect((try ls.local.exec(
        \\innerWidth === 1920 &&
        \\innerHeight === 1080 &&
        \\screen.width === 1920 &&
        \\screen.height === 1080 &&
        \\screen.orientation.type === "landscape-primary" &&
        \\devicePixelRatio === 1
    , null)).isTrue());

    try ctx.processMessage(.{
        .id = 12,
        .method = "Emulation.setDeviceMetricsOverride",
        .params = .{
            .width = 0,
            .height = 900,
            .deviceScaleFactor = 0,
        },
    });
    try ctx.expectSentResult(null, .{ .id = 12 });
    try testing.expectEqual(1920, page.getViewport().width);
    try testing.expectEqual(900, page.getViewport().height);
    try testing.expectEqual(1920, bc.session.browser.getScreen().width);
    try testing.expectEqual(1080, bc.session.browser.getScreen().height);
    try testing.expectEqual(1, bc.session.browser.device_scale_factor);
}

test "cdp.Emulation: overrides reset with the browser context" {
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-RESET-1" });
    try ctx.processMessage(.{
        .id = 14,
        .method = "Emulation.setDeviceMetricsOverride",
        .params = .{
            .width = 800,
            .height = 600,
            .deviceScaleFactor = 2,
            .screenWidth = 1024,
            .screenHeight = 768,
        },
    });
    try ctx.expectSentResult(null, .{ .id = 14 });
    try ctx.processMessage(.{
        .id = 15,
        .method = "Emulation.setTouchEmulationEnabled",
        .params = .{ .enabled = true, .maxTouchPoints = 5 },
    });
    try ctx.expectSentResult(null, .{ .id = 15 });

    try testing.expectEqual(800, bc.session.browser.getViewport().width);
    try testing.expectEqual(5, bc.session.browser.max_touch_points);

    bc = try ctx.loadBrowserContext(.{ .id = "BID-RESET-2" });
    try testing.expectEqual(1920, bc.session.browser.getViewport().width);
    try testing.expectEqual(1080, bc.session.browser.getViewport().height);
    try testing.expectEqual(1920, bc.session.browser.getScreen().width);
    try testing.expectEqual(1080, bc.session.browser.getScreen().height);
    try testing.expectEqual(1, bc.session.browser.device_scale_factor);
    try testing.expectEqual(0, bc.session.browser.max_touch_points);
}

test "cdp.Emulation: setTouchEmulationEnabled updates navigator" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-TOUCH" });
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    try ctx.processMessage(.{
        .id = 10,
        .method = "Emulation.setTouchEmulationEnabled",
        .params = .{ .enabled = true, .maxTouchPoints = 5 },
    });
    try ctx.expectSentResult(null, .{ .id = 10 });
    try testing.expectEqual(5, bc.session.browser.max_touch_points);
    try testing.expect((try ls.local.exec("navigator.maxTouchPoints === 5", null)).isTrue());

    try ctx.processMessage(.{
        .id = 12,
        .method = "Emulation.setTouchEmulationEnabled",
        .params = .{ .enabled = true, .maxTouchPoints = 0 },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 12 });
    try testing.expectEqual(5, bc.session.browser.max_touch_points);

    try ctx.processMessage(.{
        .id = 13,
        .method = "Emulation.setTouchEmulationEnabled",
        .params = .{ .enabled = false, .maxTouchPoints = 17 },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 13 });
    try testing.expectEqual(5, bc.session.browser.max_touch_points);

    try ctx.processMessage(.{
        .id = 11,
        .method = "Emulation.setTouchEmulationEnabled",
        .params = .{ .enabled = false },
    });
    try ctx.expectSentResult(null, .{ .id = 11 });
    try testing.expectEqual(0, bc.session.browser.max_touch_points);
    try testing.expect((try ls.local.exec("navigator.maxTouchPoints === 0", null)).isTrue());
}
