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

const TextTrack = @import("TextTrack.zig");
const TextTrackCue = @import("TextTrackCue.zig");

const TextTrackCueList = @This();

_track: ?*TextTrack,

pub fn getLength(self: *const TextTrackCueList) u32 {
    const track = self._track orelse return 0;
    return @intCast(track.cues().len);
}

pub fn item(self: *const TextTrackCueList, index: usize) ?*TextTrackCue {
    const track = self._track orelse return null;
    const cues = track.cues();
    if (index >= cues.len) {
        return null;
    }
    return cues[index];
}

fn getCueById(self: *const TextTrackCueList, id: []const u8) ?*TextTrackCue {
    if (id.len == 0) {
        return null;
    }
    const track = self._track orelse return null;
    for (track.cues()) |cue| {
        if (std.mem.eql(u8, cue._id, id)) {
            return cue;
        }
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextTrackCueList);

    pub const Meta = struct {
        pub const name = "TextTrackCueList";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(TextTrackCueList.getLength, null, .{});
    pub const @"[]" = bridge.indexed(TextTrackCueList.item, getIndexes, .{ .null_as_undefined = true });
    pub const getCueById = bridge.function(TextTrackCueList.getCueById, .{});

    fn getIndexes(self: *TextTrackCueList, exec: *const js.Execution) !js.Array {
        const len = self.getLength();
        var arr = exec.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }
};
