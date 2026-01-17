// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const EventTarget = @import("../EventTarget.zig");

const TextTrackCue = @This();

_type: Type,
_proto: *EventTarget,
_id: []const u8 = "",
_start_time: f64 = 0,
_end_time: f64 = 0,
_pause_on_exit: bool = false,
_on_enter: ?js.Function.Global = null,
_on_exit: ?js.Function.Global = null,

pub const Type = union(enum) {
    vtt: *@import("VTTCue.zig"),
};

pub fn asEventTarget(self: *TextTrackCue) *EventTarget {
    return self._proto;
}

pub fn getId(self: *const TextTrackCue) []const u8 {
    return self._id;
}

pub fn setId(self: *TextTrackCue, value: []const u8, page: *Page) !void {
    self._id = try page.dupeString(value);
}

pub fn getStartTime(self: *const TextTrackCue) f64 {
    return self._start_time;
}

pub fn setStartTime(self: *TextTrackCue, value: f64) void {
    self._start_time = value;
}

pub fn getEndTime(self: *const TextTrackCue) f64 {
    return self._end_time;
}

pub fn setEndTime(self: *TextTrackCue, value: f64) void {
    self._end_time = value;
}

pub fn getPauseOnExit(self: *const TextTrackCue) bool {
    return self._pause_on_exit;
}

pub fn setPauseOnExit(self: *TextTrackCue, value: bool) void {
    self._pause_on_exit = value;
}

pub fn getOnEnter(self: *const TextTrackCue) ?js.Function.Global {
    return self._on_enter;
}

pub fn setOnEnter(self: *TextTrackCue, cb: ?js.Function.Global) !void {
    self._on_enter = cb;
}

pub fn getOnExit(self: *const TextTrackCue) ?js.Function.Global {
    return self._on_exit;
}

pub fn setOnExit(self: *TextTrackCue, cb: ?js.Function.Global) !void {
    self._on_exit = cb;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextTrackCue);

    pub const Meta = struct {
        pub const name = "TextTrackCue";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const Prototype = EventTarget;

    pub const id = bridge.accessor(TextTrackCue.getId, TextTrackCue.setId, .{});
    pub const startTime = bridge.accessor(TextTrackCue.getStartTime, TextTrackCue.setStartTime, .{});
    pub const endTime = bridge.accessor(TextTrackCue.getEndTime, TextTrackCue.setEndTime, .{});
    pub const pauseOnExit = bridge.accessor(TextTrackCue.getPauseOnExit, TextTrackCue.setPauseOnExit, .{});
    pub const onenter = bridge.accessor(TextTrackCue.getOnEnter, TextTrackCue.setOnEnter, .{});
    pub const onexit = bridge.accessor(TextTrackCue.getOnExit, TextTrackCue.setOnExit, .{});
};
