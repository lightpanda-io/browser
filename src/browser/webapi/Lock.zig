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

const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/Lock
// https://w3c.github.io/web-locks/#lock
const Lock = @This();

_mode: LockMode,
_name: lp.String,

pub const LockMode = enum {
    shared,
    exclusive,

    pub const js_enum_from_string = true;
};

fn getMode(self: *const Lock) []const u8 {
    return @tagName(self._mode);
}

fn getName(self: *const Lock) lp.String {
    return self._name;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Lock);

    pub const Meta = struct {
        pub const name = "Lock";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const mode = bridge.accessor(Lock.getMode, null, .{});
    pub const name = bridge.accessor(Lock.getName, null, .{});
};
