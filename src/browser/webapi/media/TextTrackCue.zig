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

const Frame = @import("../../Frame.zig");
const EventTarget = @import("../EventTarget.zig");
const TextTrack = @import("TextTrack.zig");

const TextTrackCue = @This();

pub const Proto = EventTarget;

_type: Type,
_proto: *EventTarget,
_id: []const u8 = "",
_start_time: f64 = 0,
_end_time: f64 = 0,
_pause_on_exit: bool = false,
_track: ?*TextTrack = null, // The track whose list of cues this cue is in.

pub const Type = union(enum) {
    vtt: *@import("VTTCue.zig"),
};

pub fn asEventTarget(self: *TextTrackCue) *EventTarget {
    return self._proto;
}

fn getTrack(self: *const TextTrackCue) ?*TextTrack {
    return self._track;
}

pub fn getId(self: *const TextTrackCue) []const u8 {
    return self._id;
}

fn setId(self: *TextTrackCue, value: []const u8, frame: *Frame) !void {
    self._id = try frame.dupeString(value);
}

pub fn getStartTime(self: *const TextTrackCue) f64 {
    return self._start_time;
}

fn setStartTime(self: *TextTrackCue, value: f64, frame: *Frame) !void {
    if (std.math.isFinite(value) == false) {
        return error.TypeError;
    }
    self._start_time = value;
    if (self._track) |track| {
        try track.reorder(self, frame);
    }
}

fn getEndTime(self: *const TextTrackCue) f64 {
    return self._end_time;
}

fn setEndTime(self: *TextTrackCue, value: f64, frame: *Frame) !void {
    self._end_time = value;
    if (self._track) |track| {
        try track.reorder(self, frame);
    }
}

fn getPauseOnExit(self: *const TextTrackCue) bool {
    return self._pause_on_exit;
}

fn setPauseOnExit(self: *TextTrackCue, value: bool) void {
    self._pause_on_exit = value;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextTrackCue);

    pub const Meta = struct {
        pub const name = "TextTrackCue";

        pub var class_id: bridge.ClassId = undefined;
    };

    pub const Prototype = EventTarget;

    pub const track = bridge.accessor(TextTrackCue.getTrack, null, .{});
    pub const id = bridge.accessor(TextTrackCue.getId, TextTrackCue.setId, .{});
    pub const startTime = bridge.accessor(TextTrackCue.getStartTime, TextTrackCue.setStartTime, .{});
    pub const endTime = bridge.accessor(TextTrackCue.getEndTime, TextTrackCue.setEndTime, .{});
    pub const pauseOnExit = bridge.accessor(TextTrackCue.getPauseOnExit, TextTrackCue.setPauseOnExit, .{});
    pub const onenter = EventTarget.handlerAccessor(TextTrackCue, "enter");
    pub const onexit = EventTarget.handlerAccessor(TextTrackCue, "exit");
};
