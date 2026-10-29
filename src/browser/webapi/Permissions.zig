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

const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const EventTarget = @import("EventTarget.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ Permissions, PermissionStatus };
}

pub const State = enum {
    granted,
    prompt,
    denied,
};

const Permissions = @This();

// Padding to avoid zero-size struct pointer collisions
_pad: bool = false,

const QueryDescriptor = struct {
    name: []const u8,
};

// Report the state set via CDP Browser.grantPermissions / setPermission, or
// 'prompt' (the default safe value — neither granted nor denied) when unset.
pub fn query(_: *const Permissions, qd: QueryDescriptor, exec: *const Execution) !js.Promise {
    const arena = try exec.getArena(.tiny, "PermissionStatus");
    errdefer arena.release();

    const state = exec.session.browser.permissions.get(qd.name) orelse .prompt;
    const status = try exec._factory.eventTargetWithAllocator(arena.allocator(), PermissionStatus{
        ._arena = arena,
        ._proto = undefined,
        ._state = state,
        ._name = try arena.dupe(u8, qd.name),
    });
    return exec.js.local.?.resolvePromise(status);
}

pub const PermissionStatus = struct {
    _rc: lp.RC = .{},
    _arena: *lp.Arena,
    _proto: *EventTarget,
    _name: []const u8,
    _state: State,

    pub const Proto = EventTarget;

    pub fn deinit(self: *PermissionStatus, page: *Page) void {
        page.removeTarget(self._proto);
        self._arena.release();
    }

    pub fn releaseRef(self: *PermissionStatus, page: *Page) void {
        self._rc.release(self, page);
    }

    pub fn acquireRef(self: *PermissionStatus) void {
        self._rc.acquire();
    }

    pub fn asEventTarget(self: *PermissionStatus) *EventTarget {
        return self._proto;
    }

    fn getName(self: *const PermissionStatus) []const u8 {
        return self._name;
    }

    fn getState(self: *const PermissionStatus) []const u8 {
        return @tagName(self._state);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PermissionStatus);
        pub const Meta = struct {
            pub const name = "PermissionStatus";
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const name = bridge.accessor(getName, null, .{});
        pub const state = bridge.accessor(getState, null, .{});
        pub const onchange = EventTarget.handlerAccessor(PermissionStatus, "change");
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Permissions);

    pub const Meta = struct {
        pub const name = "Permissions";
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const query = bridge.function(Permissions.query, .{});
};
