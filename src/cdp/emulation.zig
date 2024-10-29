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
const stringify = cdp.stringify;
const IncomingMessage = @import("msg.zig").IncomingMessage;

const log = std.log.scoped(.cdp);

const Methods = enum {
    setEmulatedMedia,
    setFocusEmulationEnabled,
    setDeviceMetricsOverride,
    setTouchEmulationEnabled,
};

pub fn emulation(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    action: []const u8,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .setEmulatedMedia => setEmulatedMedia(alloc, msg, ctx),
        .setFocusEmulationEnabled => setFocusEmulationEnabled(alloc, msg, ctx),
        .setDeviceMetricsOverride => setDeviceMetricsOverride(alloc, msg, ctx),
        .setTouchEmulationEnabled => setTouchEmulationEnabled(alloc, msg, ctx),
    };
}

const MediaFeature = struct {
    name: []const u8,
    value: []const u8,
};

// TODO: noop method
fn setEmulatedMedia(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        media: ?[]const u8 = null,
        features: ?[]MediaFeature = null,
    };
    const input = try msg.getInput(alloc, Params);
    log.debug("Req > id {d}, method {s}", .{ input.id, "emulation.setEmulatedMedia" });

    // output
    return result(alloc, input.id, null, null, input.sessionId);
}

// TODO: noop method
fn setFocusEmulationEnabled(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {
    // input
    const Params = struct {
        enabled: bool,
    };
    const input = try msg.getInput(alloc, Params);
    log.debug("Req > id {d}, method {s}", .{ input.id, "emulation.setFocusEmulationEnabled" });

    // output
    return result(alloc, input.id, null, null, input.sessionId);
}

// TODO: noop method
fn setDeviceMetricsOverride(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {
    // input
    const input = try msg.getInput(alloc, void);
    log.debug("Req > id {d}, method {s}", .{ input.id, "emulation.setDeviceMetricsOverride" });

    // output
    return result(alloc, input.id, null, null, input.sessionId);
}

// TODO: noop method
fn setTouchEmulationEnabled(
    alloc: std.mem.Allocator,
    msg: *IncomingMessage,
    _: *Ctx,
) ![]const u8 {
    const input = try msg.getInput(alloc, void);
    log.debug("Req > id {d}, method {s}", .{ input.id, "emulation.setTouchEmulationEnabled" });

    return result(alloc, input.id, null, null, input.sessionId);
}
