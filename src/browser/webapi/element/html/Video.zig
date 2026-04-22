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

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Media = @import("Media.zig");

const Video = @This();

_proto: *Media,

pub fn asMedia(self: *Video) *Media {
    return self._proto;
}

pub fn asElement(self: *Video) *Element {
    return self._proto.asElement();
}

pub fn asConstElement(self: *const Video) *const Element {
    return self._proto.asConstElement();
}

pub fn asNode(self: *Video) *Node {
    return self.asElement().asNode();
}

pub fn getVideoWidth(_: *const Video) u32 {
    return 0;
}

pub fn getVideoHeight(_: *const Video) u32 {
    return 0;
}

pub fn getPoster(self: *const Video, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const poster = element.getAttributeSafe(comptime .wrap("poster")) orelse return "";
    if (poster.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURL(poster, frame, .{});
}

pub fn setPoster(self: *Video, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("poster"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Video);

    pub const Meta = struct {
        pub const name = "HTMLVideoElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const poster = bridge.accessor(Video.getPoster, Video.setPoster, .{});
    pub const videoWidth = bridge.accessor(Video.getVideoWidth, null, .{});
    pub const videoHeight = bridge.accessor(Video.getVideoHeight, null, .{});
};
