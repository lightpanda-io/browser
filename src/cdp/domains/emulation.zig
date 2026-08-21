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
const js = @import("../../browser/js/js.zig");

const log = lp.log;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        setEmulatedMedia,
        setFocusEmulationEnabled,
        setDeviceMetricsOverride,
        clearDeviceMetricsOverride,
        setTouchEmulationEnabled,
        setUserAgentOverride,
        setGeolocationOverride,
        clearGeolocationOverride,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .setEmulatedMedia => return setEmulatedMedia(cmd),
        .setFocusEmulationEnabled => return setFocusEmulationEnabled(cmd),
        .setDeviceMetricsOverride => return setDeviceMetricsOverride(cmd),
        .clearDeviceMetricsOverride => return clearDeviceMetricsOverride(cmd),
        .setTouchEmulationEnabled => return setTouchEmulationEnabled(cmd),
        .setUserAgentOverride => return setUserAgentOverride(cmd),
        .setGeolocationOverride => return setGeolocationOverride(cmd),
        .clearGeolocationOverride => return clearGeolocationOverride(cmd),
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
        if (v != 0 and v != 1) log.warn(.not_implemented, "setDeviceMetricsOverride", .{
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

    // The override is stored on the Browser so it persists across page
    // navigations for the whole CDP connection.
    const browser = &cmd.cdp.browser;

    // CDP convention: a 0 width/height means "don't override that dimension",
    // so keep the current value for any dimension passed as 0.
    const current = browser.getViewport();
    browser.viewport_override = .{
        .width = if (params.width > 0) params.width else current.width,
        .height = if (params.height > 0) params.height else current.height,
    };

    return cmd.sendResult(null, .{});
}

fn clearDeviceMetricsOverride(cmd: *CDP.Command) !void {
    cmd.cdp.browser.viewport_override = null;
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

fn setGeolocationOverride(cmd: *CDP.Command) !void {
    const Params = struct {
        latitude: ?f64 = null,
        longitude: ?f64 = null,
        accuracy: ?f64 = null,
    };
    // Absent params emulates "position unavailable" (Chrome semantics), so fall
    // back to all-null defaults rather than erroring.
    const params = (try cmd.params(Params)) orelse Params{};

    const browser = &cmd.cdp.browser;
    if (params.latitude) |lat| {
        if (params.longitude) |lon| {
            browser.geolocation_override = .{
                .latitude = lat,
                .longitude = lon,
                .accuracy = params.accuracy orelse 0,
            };
            return cmd.sendResult(null, .{});
        }
    }
    browser.geolocation_override = null;
    return cmd.sendResult(null, .{});
}

fn clearGeolocationOverride(cmd: *CDP.Command) !void {
    cmd.cdp.browser.geolocation_override = null;
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
}

test "cdp.Emulation: setGeolocationOverride and clear" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-GEO", .url = "cdp/dom1.html" });
    const browser = bc.session.browser;

    try ctx.processMessage(.{
        .id = 1,
        .method = "Emulation.setGeolocationOverride",
        .params = .{ .latitude = 48.8584, .longitude = 2.2945, .accuracy = 10 },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try testing.expectEqual(48.8584, browser.geolocation_override.?.latitude);
    try testing.expectEqual(2.2945, browser.geolocation_override.?.longitude);

    // no coordinates => emulate "position unavailable" (stored as null)
    try ctx.processMessage(.{ .id = 2, .method = "Emulation.setGeolocationOverride" });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try testing.expect(browser.geolocation_override == null);

    // re-set then clear
    try ctx.processMessage(.{
        .id = 3,
        .method = "Emulation.setGeolocationOverride",
        .params = .{ .latitude = 1.0, .longitude = 2.0, .accuracy = 5 },
    });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try ctx.processMessage(.{ .id = 4, .method = "Emulation.clearGeolocationOverride" });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try testing.expect(browser.geolocation_override == null);
}

test "cdp.Emulation: navigator.geolocation reads the override" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-GEO2", .url = "cdp/dom1.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Browser.grantPermissions",
        .params = .{ .permissions = &[_][]const u8{"geolocation"} },
    });
    try ctx.expectSentResult(null, .{ .id = 1, .session_id = null });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Emulation.setGeolocationOverride",
        .params = .{ .latitude = 48.0, .longitude = 2.0, .accuracy = 10 },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });

    const frame = bc.mainFrame() orelse unreachable;

    {
        // Registers the callback synchronously; getCurrentPosition schedules
        // delivery on the calling context's scheduler and returns before it runs.
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        _ = try ls.local.exec(
            \\ window.__geo_ok = false;
            \\ navigator.geolocation.getCurrentPosition(p => {
            \\   window.__geo_ok = (Math.round(p.coords.latitude) === 48 && Math.round(p.coords.longitude) === 2);
            \\   // outlives both the callback and the position wrapper
            \\   window.__geo_coords = p.coords;
            \\   window.__geo_json = JSON.stringify(p);
            \\ });
        , null);
    }

    // Drive the session loop so the scheduled Task fires: Runner._tick runs
    // browser.runMacrotasks() (which drains frame.js.scheduler) on every tick
    // for a loaded page, same primitive Runner.waitForSelector/waitForScript
    // use to pump pending scheduler work under a CDP-loaded page.
    var runner = bc.session.runner(.{});
    _ = try runner.tickForFrame(bc.page_handle.?.frame_id, 1000, .{ .until = .done });

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const v = try ls.local.exec("window.__geo_ok && Math.round(window.__geo_coords.latitude) === 48", null);
    try testing.expect(v.isTrue());

    // toJSON nests a plain object, so the coords survive JSON.stringify
    const j = try ls.local.exec(
        \\ (() => {
        \\   const p = JSON.parse(window.__geo_json);
        \\   return Math.round(p.coords.latitude) === 48 && p.coords.altitude === null && p.timestamp > 0;
        \\ })()
    , null);
    try testing.expect(j.isTrue());
}

test "cdp.Emulation: navigator.geolocation watchPosition delivers the override" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-GEO4", .url = "cdp/dom1.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Browser.grantPermissions",
        .params = .{ .permissions = &[_][]const u8{"geolocation"} },
    });
    try ctx.expectSentResult(null, .{ .id = 1, .session_id = null });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Emulation.setGeolocationOverride",
        .params = .{ .latitude = 48.0, .longitude = 2.0, .accuracy = 10 },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });

    const frame = bc.mainFrame() orelse unreachable;

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        // The second watch is cleared before the scheduler gets to run either,
        // so only the first one may report.
        _ = try ls.local.exec(
            \\ window.__geo_watched = 0;
            \\ window.__geo_cleared = 0;
            \\ navigator.geolocation.watchPosition(p => { window.__geo_watched = p.coords.latitude; });
            \\ const id = navigator.geolocation.watchPosition(() => { window.__geo_cleared += 1; });
            \\ navigator.geolocation.clearWatch(id);
        , null);
    }

    var runner = bc.session.runner(.{});
    _ = try runner.tickForFrame(bc.page_handle.?.frame_id, 1000, .{ .until = .done });

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const v = try ls.local.exec("window.__geo_watched === 48 && window.__geo_cleared === 0", null);
    try testing.expect(v.isTrue());
}

test "cdp.Emulation: navigator.geolocation needs an explicit permission grant" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-GEO5", .url = "cdp/dom1.html" });

    // An override with no grant leaves the permission at "prompt", which headless
    // Chrome resolves as denied.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Emulation.setGeolocationOverride",
        .params = .{ .latitude = 48.0, .longitude = 2.0, .accuracy = 10 },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    try testing.expectEqual(1, try errorCodeFor(bc));
}

test "cdp.Emulation: navigator.geolocation granted without an override is POSITION_UNAVAILABLE" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-GEO6", .url = "cdp/dom1.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Browser.grantPermissions",
        .params = .{ .permissions = &[_][]const u8{"geolocation"} },
    });
    try ctx.expectSentResult(null, .{ .id = 1, .session_id = null });

    try testing.expectEqual(2, try errorCodeFor(bc));
}

// Runs getCurrentPosition, pumps the scheduler, and returns the code the error
// callback saw (0 if the success callback ran instead).
fn errorCodeFor(bc: *CDP.BrowserContext) !i32 {
    const frame = bc.mainFrame() orelse unreachable;

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        _ = try ls.local.exec(
            \\ window.__geo_code = 0;
            \\ navigator.geolocation.getCurrentPosition(
            \\   () => { window.__geo_code = 0; },
            \\   (err) => { window.__geo_code = err.code; },
            \\ );
        , null);
    }

    var runner = bc.session.runner(.{});
    _ = try runner.tickForFrame(bc.page_handle.?.frame_id, 1000, .{ .until = .done });

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    return (try ls.local.exec("window.__geo_code", null)).toZig(i32);
}

test "cdp.Emulation: navigator.geolocation errors PERMISSION_DENIED when permission is denied" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-GEO3", .url = "cdp/dom1.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Browser.setPermission",
        .params = .{ .permission = .{ .name = "geolocation" }, .setting = "denied" },
    });
    try ctx.expectSentResult(null, .{ .id = 1, .session_id = null });

    // Denied is authoritative over the override: even though an override is
    // set, the denied permission must still win and produce PERMISSION_DENIED.
    try ctx.processMessage(.{
        .id = 2,
        .method = "Emulation.setGeolocationOverride",
        .params = .{ .latitude = 48.0, .longitude = 2.0, .accuracy = 10 },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });

    const frame = bc.mainFrame() orelse unreachable;

    {
        // Registers the callback synchronously; getCurrentPosition schedules
        // delivery on the calling context's scheduler and returns before it runs.
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        _ = try ls.local.exec(
            \\ window.__geo_code = 0;
            \\ navigator.geolocation.getCurrentPosition(p => {
            \\   p;
            \\ }, error => {
            \\   window.__geo_code = error.code;
            \\ });
        , null);
    }

    // Drive the session loop so the scheduled Task fires: Runner._tick runs
    // browser.runMacrotasks() (which drains frame.js.scheduler) on every tick
    // for a loaded page, same primitive Runner.waitForSelector/waitForScript
    // use to pump pending scheduler work under a CDP-loaded page.
    var runner = bc.session.runner(.{});
    _ = try runner.tickForFrame(bc.page_handle.?.frame_id, 1000, .{ .until = .done });

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const v = try ls.local.exec("window.__geo_code === 1", null);
    try testing.expect(v.isTrue());
}
