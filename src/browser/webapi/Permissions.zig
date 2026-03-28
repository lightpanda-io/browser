// Copyright (C) 2023-2025 Lightpanda (Selecy SAS)
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
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Session = @import("../Session.zig");

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ Permissions, PermissionStatus };
}

const Permissions = @This();

// Padding to avoid zero-size struct pointer collisions
_pad: bool = false,

const QueryDescriptor = struct {
    name: []const u8,
};
// We always report 'prompt' (the default safe value — neither granted nor denied).
pub fn query(_: *const Permissions, qd: QueryDescriptor, page: *Page) !js.Promise {
    const arena = try page.getArena(.{ .debug = "PermissionStatus" });
    errdefer page.releaseArena(arena);

    const status = try arena.create(PermissionStatus);
    status.* = .{
        ._arena = arena,
        ._state = "prompt",
        ._name = try arena.dupe(u8, qd.name),
    };
    return page.js.local.?.resolvePromise(status);
}

const PermissionStatus = struct {
    _rc: lp.RC(u8) = .{},
    _arena: Allocator,
    _name: []const u8,
    _state: []const u8,

    pub fn deinit(self: *PermissionStatus, session: *Session) void {
        session.releaseArena(self._arena);
    }

    pub fn releaseRef(self: *PermissionStatus, session: *Session) void {
        self._rc.release(self, session);
    }

    pub fn acquireRef(self: *PermissionStatus) void {
        self._rc.acquire();
    }

    fn getName(self: *const PermissionStatus) []const u8 {
        return self._name;
    }

    fn getState(self: *const PermissionStatus) []const u8 {
        return self._state;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PermissionStatus);
        pub const Meta = struct {
            pub const name = "PermissionStatus";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const name = bridge.accessor(getName, null, .{});
        pub const state = bridge.accessor(getState, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Permissions);

    pub const Meta = struct {
        pub const name = "Permissions";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const query = bridge.function(Permissions.query, .{ .dom_exception = true });
};
