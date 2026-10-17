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

const Node = @import("../Node.zig");
const EventTarget = @import("../EventTarget.zig");
const Media = @import("../element/html/Media.zig");
const Track = @import("../element/html/Track.zig");

const TextTrack = @import("TextTrack.zig");

const TextTrackList = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_media: *Media,

pub fn init(media: *Media, frame: *Frame) !*TextTrackList {
    return frame._factory.eventTarget(TextTrackList{
        ._proto = undefined,
        ._media = media,
    });
}

pub fn asEventTarget(self: *TextTrackList) *EventTarget {
    return self._proto;
}

fn getLength(self: *const TextTrackList, frame: *Frame) !u32 {
    var it = self.iterator(frame);
    var count: u32 = 0;
    while (try it.next()) |_| {
        count += 1;
    }
    return count + @as(u32, @intCast(self._media._added_text_tracks.items.len));
}

fn item(self: *const TextTrackList, index: usize, frame: *Frame) !?*TextTrack {
    var it = self.iterator(frame);
    var child_index: usize = 0;
    while (try it.next()) |track| : (child_index += 1) {
        if (child_index == index) {
            return track;
        }
    }
    const added_index = index - child_index;
    const added = self._media._added_text_tracks.items;
    if (added_index < added.len) {
        return added[added_index];
    }
    return null;
}

fn getTrackById(self: *const TextTrackList, id: []const u8, frame: *Frame) !?*TextTrack {
    var it = self.iterator(frame);
    while (try it.next()) |track| {
        if (std.mem.eql(u8, track.getId(), id)) {
            return track;
        }
    }
    for (self._media._added_text_tracks.items) |track| {
        if (std.mem.eql(u8, track.getId(), id)) {
            return track;
        }
    }
    return null;
}

// only used internally
const Iterator = struct {
    child: ?*Node,
    frame: *Frame,

    fn next(self: *Iterator) !?*TextTrack {
        while (self.child) |child| {
            self.child = child.nextSibling();
            if (child.is(Track)) |track| {
                return try track.getTrack(self.frame);
            }
        }
        return null;
    }
};

fn iterator(self: *const TextTrackList, frame: *Frame) Iterator {
    return .{
        .frame = frame,
        .child = self._media.asNode().firstChild(),
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextTrackList);

    pub const Meta = struct {
        pub const name = "TextTrackList";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(TextTrackList.getLength, null, .{});
    pub const @"[]" = bridge.indexed(TextTrackList.item, getIndexes, .{ .null_as_undefined = true });
    pub const getTrackById = bridge.function(TextTrackList.getTrackById, .{});
    pub const onchange = EventTarget.handlerAccessor(TextTrackList, "change");
    pub const onaddtrack = EventTarget.handlerAccessor(TextTrackList, "addtrack");
    pub const onremovetrack = EventTarget.handlerAccessor(TextTrackList, "removetrack");

    fn getIndexes(self: *TextTrackList, frame: *Frame) !js.Array {
        const len = try self.getLength(frame);
        var arr = frame.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }
};
