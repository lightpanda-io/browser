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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Geolocation = @import("Geolocation.zig");
const GeolocationCoordinates = @import("GeolocationCoordinates.zig");

const GeolocationPosition = @This();

_rc: lp.RC = .{},
_timestamp: f64,
_arena: *lp.Arena,
_coords: *GeolocationCoordinates,

pub fn init(exec: *js.Execution, override: Geolocation.Override) !*GeolocationPosition {
    const arena = try exec.getArena(.tiny, "GeolocationPosition");
    errdefer arena.release();

    // coords needs it own distinct address from position, else it will collide
    // in the identity map
    const coords = try arena.create(GeolocationCoordinates);
    const position = try arena.create(GeolocationPosition);

    position.* = .{
        ._arena = arena,
        ._coords = coords,
        ._timestamp = @floatFromInt(lp.datetime.milliTimestamp(.real)),
    };
    coords.* = .{
        ._position = position,
        ._latitude = override.latitude,
        ._longitude = override.longitude,
        ._accuracy = override.accuracy,
    };
    return position;
}

pub fn deinit(self: *GeolocationPosition, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *GeolocationPosition) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *GeolocationPosition, page: *Page) void {
    self._rc.release(self, page);
}

fn getCoords(self: *const GeolocationPosition) *GeolocationCoordinates {
    return self._coords;
}

fn getTimestamp(self: *const GeolocationPosition) f64 {
    return self._timestamp;
}

pub fn toJSON(self: *const GeolocationPosition) struct {
    coords: GeolocationCoordinates.Json,
    timestamp: f64,
} {
    return .{
        .coords = self._coords.toJSON(),
        .timestamp = self._timestamp,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GeolocationPosition);

    pub const Meta = struct {
        pub const name = "GeolocationPosition";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const coords = bridge.accessor(GeolocationPosition.getCoords, null, .{});
    pub const timestamp = bridge.accessor(GeolocationPosition.getTimestamp, null, .{});
    pub const toJSON = bridge.function(GeolocationPosition.toJSON, .{});
};
