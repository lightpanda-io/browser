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
const Config = @import("../../Config.zig");

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        setEmulatedMedia,
        setFocusEmulationEnabled,
        setDeviceMetricsOverride,
        clearDeviceMetricsOverride,
        setTouchEmulationEnabled,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .setEmulatedMedia => return setEmulatedMedia(cmd),
        .setFocusEmulationEnabled => return setFocusEmulationEnabled(cmd),
        .setDeviceMetricsOverride => return setDeviceMetricsOverride(cmd),
        .clearDeviceMetricsOverride => return clearDeviceMetricsOverride(cmd),
        .setTouchEmulationEnabled => return setTouchEmulationEnabled(cmd),
    }
}

// TODO: noop method
fn setEmulatedMedia(cmd: anytype) !void {
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
fn setFocusEmulationEnabled(cmd: anytype) !void {
    // const input = (try const incoming.params(struct {
    //     enabled: bool,
    // })) orelse return error.InvalidParams;
    return cmd.sendResult(null, .{});
}

fn setDeviceMetricsOverride(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        width: u32,
        height: u32,
        deviceScaleFactor: f64 = 1.0,
        mobile: bool = false,
    })) orelse return error.InvalidParams;

    if (params.width == 0 or params.height == 0) {
        return error.InvalidParams;
    }

    const device_pixel_ratio = if (params.deviceScaleFactor <= 0) 1.0 else params.deviceScaleFactor;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.setViewportOverride(params.width, params.height, device_pixel_ratio);
    return cmd.sendResult(null, .{});
}

fn clearDeviceMetricsOverride(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.clearViewportOverride();
    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn setTouchEmulationEnabled(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

const testing = @import("../testing.zig");

test "cdp.emulation: setDeviceMetricsOverride updates display viewport" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{});

    try ctx.processMessage(.{
        .id = 101,
        .method = "Emulation.setDeviceMetricsOverride",
        .params = .{
            .width = 1280,
            .height = 720,
            .deviceScaleFactor = 2.0,
            .mobile = false,
        },
    });

    try ctx.expectSentCount(1);
    try ctx.expectSentResult(null, .{ .id = 101, .index = 0 });
    try testing.expectEqual(@as(u32, 1280), ctx.cdp().browser.app.display.viewport.width);
    try testing.expectEqual(@as(u32, 720), ctx.cdp().browser.app.display.viewport.height);
    try testing.expectEqual(@as(f64, 2.0), ctx.cdp().browser.app.display.viewport.device_pixel_ratio);
}

test "cdp.emulation: clearDeviceMetricsOverride resets default viewport" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{});

    try ctx.processMessage(.{
        .id = 102,
        .method = "Emulation.setDeviceMetricsOverride",
        .params = .{
            .width = 1440,
            .height = 900,
            .deviceScaleFactor = 1.5,
            .mobile = false,
        },
    });
    try ctx.processMessage(.{
        .id = 103,
        .method = "Emulation.clearDeviceMetricsOverride",
    });

    try ctx.expectSentCount(2);
    try ctx.expectSentResult(null, .{ .id = 102, .index = 0 });
    try ctx.expectSentResult(null, .{ .id = 103, .index = 0 });
    try testing.expectEqual(@as(u32, Config.DEFAULT_VIEWPORT_WIDTH), ctx.cdp().browser.app.display.viewport.width);
    try testing.expectEqual(@as(u32, Config.DEFAULT_VIEWPORT_HEIGHT), ctx.cdp().browser.app.display.viewport.height);
    try testing.expectEqual(@as(f64, 1.0), ctx.cdp().browser.app.display.viewport.device_pixel_ratio);
}
