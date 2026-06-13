// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// Stand-in for CDP.zig when CDP is compiled out (the quickjs engine has no
// inspector, so `lightpanda serve` and everything CDP is unsupported).
// Code that holds a `?*CDP` keeps compiling against this type; since
// nothing ever constructs one (Server.zig is compiled out), the pointer is
// always null and none of these methods can be reached.
const Disabled = @This();

// Keep struct-identity distinct from a zero-bit type so `?*Disabled`
// behaves like any other optional pointer.
_unused: u8 = 0,

pub const InputMessage = struct {
    id: ?i64 = null,
    method: []const u8,
    params: ?InputParams = null,
    sessionId: ?[]const u8 = null,
};

pub const InputParams = struct {
    raw: []const u8,
};

pub fn onMessage(_: *Disabled, _: anytype) !void {
    unreachable;
}

pub fn onPing(_: *Disabled, _: anytype) void {
    unreachable;
}

pub fn onClose(_: *Disabled) void {
    unreachable;
}

pub fn onDisconnect(_: *Disabled, _: anytype) void {
    unreachable;
}

pub fn onData(_: *Disabled, _: anytype) !bool {
    unreachable;
}

pub fn onLinkDisconnect(_: *Disabled, _: anytype) void {
    unreachable;
}

pub fn terminateFromNetwork(_: *Disabled) void {
    unreachable;
}
