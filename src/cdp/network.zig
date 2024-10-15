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

const Methods = enum {
    enable,
    setCacheDisabled,
};

pub fn network(
    alloc: std.mem.Allocator,
    id: ?u16,
    action: []const u8,
    scanner: *std.json.Scanner,
    ctx: *Ctx,
) ![]const u8 {
    const method = std.meta.stringToEnum(Methods, action) orelse
        return error.UnknownMethod;

    return switch (method) {
        .enable => enable(alloc, id, scanner, ctx),
        .setCacheDisabled => setCacheDisabled(alloc, id, scanner, ctx),
    };
}

fn enable(
    alloc: std.mem.Allocator,
    _id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const msg = try getMsg(alloc, _id, void, scanner);

    return result(alloc, msg.id, null, null, msg.sessionID);
}

// TODO: noop method
fn setCacheDisabled(
    alloc: std.mem.Allocator,
    _id: ?u16,
    scanner: *std.json.Scanner,
    _: *Ctx,
) ![]const u8 {
    const msg = try getMsg(alloc, _id, void, scanner);

    return result(alloc, msg.id, null, null, msg.sessionID);
}
