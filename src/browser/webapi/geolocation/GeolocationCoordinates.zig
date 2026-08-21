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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const GeolocationPosition = @import("GeolocationPosition.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/GeolocationCoordinates
const GeolocationCoordinates = @This();

_latitude: f64,
_longitude: f64,
_accuracy: f64,
_position: *GeolocationPosition,

// Nothing emulates these yet
_altitude: ?f64 = null,
_altitude_accuracy: ?f64 = null,
_heading: ?f64 = null,
_speed: ?f64 = null,

pub fn acquireRef(self: *GeolocationCoordinates) void {
    // self exists in self._position._arena
    self._position.acquireRef();
}

pub fn releaseRef(self: *GeolocationCoordinates, page: *Page) void {
    self._position.releaseRef(page);
}

fn getLatitude(self: *const GeolocationCoordinates) f64 {
    return self._latitude;
}

fn getLongitude(self: *const GeolocationCoordinates) f64 {
    return self._longitude;
}

fn getAccuracy(self: *const GeolocationCoordinates) f64 {
    return self._accuracy;
}

fn getAltitude(self: *const GeolocationCoordinates) ?f64 {
    return self._altitude;
}

fn getAltitudeAccuracy(self: *const GeolocationCoordinates) ?f64 {
    return self._altitude_accuracy;
}

fn getHeading(self: *const GeolocationCoordinates) ?f64 {
    return self._heading;
}

fn getSpeed(self: *const GeolocationCoordinates) ?f64 {
    return self._speed;
}

pub const Json = struct {
    accuracy: f64,
    latitude: f64,
    longitude: f64,
    altitude: ?f64,
    altitudeAccuracy: ?f64,
    heading: ?f64,
    speed: ?f64,
};

pub fn toJSON(self: *const GeolocationCoordinates) Json {
    return .{
        .accuracy = self._accuracy,
        .latitude = self._latitude,
        .longitude = self._longitude,
        .altitude = self._altitude,
        .altitudeAccuracy = self._altitude_accuracy,
        .heading = self._heading,
        .speed = self._speed,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GeolocationCoordinates);

    pub const Meta = struct {
        pub const name = "GeolocationCoordinates";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const latitude = bridge.accessor(GeolocationCoordinates.getLatitude, null, .{});
    pub const longitude = bridge.accessor(GeolocationCoordinates.getLongitude, null, .{});
    pub const accuracy = bridge.accessor(GeolocationCoordinates.getAccuracy, null, .{});
    pub const altitude = bridge.accessor(GeolocationCoordinates.getAltitude, null, .{});
    pub const altitudeAccuracy = bridge.accessor(GeolocationCoordinates.getAltitudeAccuracy, null, .{});
    pub const heading = bridge.accessor(GeolocationCoordinates.getHeading, null, .{});
    pub const speed = bridge.accessor(GeolocationCoordinates.getSpeed, null, .{});
    pub const toJSON = bridge.function(GeolocationCoordinates.toJSON, .{});
};
