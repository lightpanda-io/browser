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
const getMsg = cdp.getMsg;
const stringify = cdp.stringify;

const Methods = enum {
    setEmulatedMedia,
    setFocusEmulationEnabled,
    setDeviceMetricsOverride,
    setTouchEmulationEnabled,
};

pub fn emulation(
    alloc: std.mem.Allocator,
    id: ?u16,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        return error.UnknownMethod;
    return switch (method) {
        .setEmulatedMedia => setEmulatedMedia(alloc, id, scanner, ctx),
        .setFocusEmulationEnabled => setFocusEmulationEnabled(alloc, id, scanner, ctx),
        .setDeviceMetricsOverride => setDeviceMetricsOverride(alloc, id, scanner, ctx),
        .setTouchEmulationEnabled => setTouchEmulationEnabled(alloc, id, scanner, ctx),
    };
}

const MediaFeature = struct {
    name: []const u8,
    value: []const u8,
};

// TODO: noop method
fn setEmulatedMedia(
    alloc: std.mem.Allocator,
    _id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        media: ?[]const u8 = null,
        features: ?[]MediaFeature = null,
    };
    const msg = try getMsg(alloc, _id, Params, scanner);

    // output
    return result(alloc, msg.id, null, null, msg.sessionID);
}

// TODO: noop method
fn setFocusEmulationEnabled(
    alloc: std.mem.Allocator,
    _id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const Params = struct {
        enabled: bool,
    };
    const msg = try getMsg(alloc, _id, Params, scanner);

    // output
    return result(alloc, msg.id, null, null, msg.sessionID);
}

// TODO: noop method
fn setDeviceMetricsOverride(
    alloc: std.mem.Allocator,
    _id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {

    // input
    const msg = try cdp.getMsg(alloc, _id, void, scanner);

    // output
    return result(alloc, msg.id, null, null, msg.sessionID);
}

// TODO: noop method
fn setTouchEmulationEnabled(
    alloc: std.mem.Allocator,
    _id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const msg = try cdp.getMsg(alloc, _id, void, scanner);

    return result(alloc, msg.id, null, null, msg.sessionID);
}
