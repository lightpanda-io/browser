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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const EventTarget = @import("../EventTarget.zig");
const Track = @import("../element/html/Track.zig");

const TextTrackCue = @import("TextTrackCue.zig");
const TextTrackCueList = @import("TextTrackCueList.zig");

const TextTrack = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_source: Source,
_mode: Mode = .disabled,
_cues: std.ArrayList(*TextTrackCue) = .empty,
_cue_list: ?*TextTrackCueList = null,
_active_cue_list: ?*TextTrackCueList = null,

pub const Kind = enum { subtitles, captions, descriptions, chapters, metadata };
pub const Mode = enum { disabled, hidden, showing };

const Source = union(enum) {
    element: *Track,
    // created by HTMLMediaElement.addTextTrack()
    script: struct {
        kind: Kind,
        label: []const u8,
        language: []const u8,
    },
};

pub fn initForElement(track: *Track, frame: *Frame) !*TextTrack {
    return frame._factory.eventTarget(TextTrack{
        ._proto = undefined,
        ._source = .{ .element = track },
    });
}

pub fn initForScript(kind: Kind, label: []const u8, language: []const u8, frame: *Frame) !*TextTrack {
    return frame._factory.eventTarget(TextTrack{
        ._proto = undefined,
        // per spec, a script-created track starts out hidden
        ._mode = .hidden,
        ._source = .{ .script = .{
            .kind = kind,
            .label = try frame.dupeString(label),
            .language = try frame.dupeString(language),
        } },
    });
}

pub fn asEventTarget(self: *TextTrack) *EventTarget {
    return self._proto;
}

pub fn getKind(self: *const TextTrack) Kind {
    return switch (self._source) {
        .element => |track| track.getKind(),
        .script => |s| s.kind,
    };
}

fn getKindString(self: *const TextTrack) []const u8 {
    return @tagName(self.getKind());
}

fn getLabel(self: *const TextTrack) []const u8 {
    return switch (self._source) {
        .element => |track| track.asConstElement().getAttributeSafe(comptime .wrap("label")) orelse "",
        .script => |s| s.label,
    };
}

fn getLanguage(self: *const TextTrack) []const u8 {
    return switch (self._source) {
        .element => |track| track.asConstElement().getAttributeSafe(comptime .wrap("srclang")) orelse "",
        .script => |s| s.language,
    };
}

pub fn getId(self: *const TextTrack) []const u8 {
    return switch (self._source) {
        .element => |track| track.asConstElement().getAttributeInterned("id") orelse "",
        .script => "",
    };
}

fn getInBandMetadataTrackDispatchType(_: *const TextTrack) []const u8 {
    return "";
}

pub fn getMode(self: *const TextTrack) Mode {
    return self._mode;
}

fn getModeString(self: *const TextTrack) []const u8 {
    return @tagName(self._mode);
}

fn setModeString(self: *TextTrack, value: []const u8, frame: *Frame) !void {
    // invalid enum values are ignored
    const mode = std.meta.stringToEnum(Mode, value) orelse return;
    return self.setMode(mode, frame);
}

pub fn setMode(self: *TextTrack, mode: Mode, frame: *Frame) !void {
    if (self._mode == mode) {
        return;
    }
    self._mode = mode;
    if (mode != .disabled) {
        switch (self._source) {
            .element => |track| try track.startTrackProcessing(frame),
            .script => {},
        }
    }
}

fn getCues(self: *TextTrack, frame: *Frame) !?*TextTrackCueList {
    if (self._mode == .disabled) {
        return null;
    }
    if (self._cue_list == null) {
        self._cue_list = try frame._factory.create(TextTrackCueList{ ._track = self });
    }
    return self._cue_list;
}

fn getActiveCues(self: *TextTrack, frame: *Frame) !?*TextTrackCueList {
    if (self._mode == .disabled) {
        return null;
    }
    if (self._active_cue_list == null) {
        self._active_cue_list = try frame._factory.create(TextTrackCueList{ ._track = null });
    }
    return self._active_cue_list;
}

pub fn cues(self: *const TextTrack) []const *TextTrackCue {
    return self._cues.items;
}

pub fn addCue(self: *TextTrack, cue: *TextTrackCue, frame: *Frame) !void {
    if (cue._track) |previous| {
        previous.remove(cue);
    }
    try self.insert(cue, frame);
    cue._track = self;
}

fn removeCue(self: *TextTrack, cue: *TextTrackCue) !void {
    if (cue._track != self) {
        return error.NotFoundError;
    }
    self.remove(cue);
    cue._track = null;
}

pub fn clearCues(self: *TextTrack) void {
    for (self._cues.items) |cue| {
        cue._track = null;
    }
    self._cues.clearRetainingCapacity();
}

pub fn reorder(self: *TextTrack, cue: *TextTrackCue, frame: *Frame) !void {
    self.remove(cue);
    try self.insert(cue, frame);
}

fn insert(self: *TextTrack, cue: *TextTrackCue, frame: *Frame) !void {
    // ordered by start time, then end time descending, then insert order
    var index: usize = self._cues.items.len;
    for (self._cues.items, 0..) |existing, i| {
        if (existing._start_time > cue._start_time or (existing._start_time == cue._start_time and existing._end_time < cue._end_time)) {
            index = i;
            break;
        }
    }
    try self._cues.insert(frame.page_arena, index, cue);
}

fn remove(self: *TextTrack, cue: *TextTrackCue) void {
    const index = std.mem.findScalar(*TextTrackCue, self._cues.items, cue) orelse return;
    _ = self._cues.orderedRemove(index);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextTrack);

    pub const Meta = struct {
        pub const name = "TextTrack";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const kind = bridge.accessor(TextTrack.getKindString, null, .{});
    pub const label = bridge.accessor(TextTrack.getLabel, null, .{});
    pub const language = bridge.accessor(TextTrack.getLanguage, null, .{});
    pub const id = bridge.accessor(TextTrack.getId, null, .{});
    pub const inBandMetadataTrackDispatchType = bridge.accessor(TextTrack.getInBandMetadataTrackDispatchType, null, .{});
    pub const mode = bridge.accessor(TextTrack.getModeString, TextTrack.setModeString, .{});
    pub const cues = bridge.accessor(TextTrack.getCues, null, .{});
    pub const activeCues = bridge.accessor(TextTrack.getActiveCues, null, .{});
    pub const addCue = bridge.function(TextTrack.addCue, .{});
    pub const removeCue = bridge.function(TextTrack.removeCue, .{});
    pub const oncuechange = EventTarget.handlerAccessor(TextTrack, "cuechange");
};

const testing = @import("../../../testing.zig");
test "WebApi: TextTrack" {
    try testing.htmlRunner("media/texttrack.html", .{});
}
