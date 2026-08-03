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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");

const Number = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_value: f32 = 0,

pub fn detached(frame: *Frame) !*Number {
    const arena = try frame._page.getArena(.tiny, "SVGNumber");
    errdefer arena.release();
    const self = try arena.create(Number);
    self.* = .{ ._arena = arena };
    return self;
}

pub fn deinit(self: *Number, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *Number) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *Number, page: *Page) void {
    self._rc.release(self, page);
}

pub fn getValue(self: *const Number) f32 {
    return self._value;
}

pub fn setValue(self: *Number, value: f32) !void {
    // WebIDL float is restricted, and the bridge does not police that for us.
    if (!std.math.isFinite(value)) {
        return error.TypeError;
    }
    self._value = value;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Number);

    pub const Meta = struct {
        pub const name = "SVGNumber";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(Number.getValue, Number.setValue, .{});
};
