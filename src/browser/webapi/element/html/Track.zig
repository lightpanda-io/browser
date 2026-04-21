// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const js = @import("../../../js/js.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const String = lp.String;

const Track = @This();

_proto: *HtmlElement,
_kind: String,
_ready_state: ReadyState,

const ReadyState = enum(u8) { none, loading, loaded, @"error" };

pub fn asElement(self: *Track) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Track) *Node {
    return self.asElement().asNode();
}

pub fn setKind(self: *Track, maybe_kind: ?String) void {
    const kind = maybe_kind orelse {
        self._kind = comptime .wrap("metadata");
        return;
    };

    // Special case, for some reason, FF does this case-insensitive.
    if (std.ascii.eqlIgnoreCase(kind.str(), "subtitles")) {
        self._kind = comptime .wrap("subtitles");
        return;
    }
    if (kind.eql(comptime .wrap("captions"))) {
        self._kind = comptime .wrap("captions");
        return;
    }
    if (kind.eql(comptime .wrap("descriptions"))) {
        self._kind = comptime .wrap("descriptions");
        return;
    }
    if (kind.eql(comptime .wrap("chapters"))) {
        self._kind = comptime .wrap("chapters");
        return;
    }

    // Anything else must be considered as `metadata`.
    self._kind = comptime .wrap("metadata");
}

pub fn getKind(self: *const Track) String {
    return self._kind;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Track);

    pub const Meta = struct {
        pub const name = "HTMLTrackElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const kind = bridge.accessor(Track.getKind, Track.setKind, .{});

    pub const NONE = bridge.property(@as(u16, @intFromEnum(ReadyState.none)), .{ .template = true });
    pub const LOADING = bridge.property(@as(u16, @intFromEnum(ReadyState.loading)), .{ .template = true });
    pub const LOADED = bridge.property(@as(u16, @intFromEnum(ReadyState.loaded)), .{ .template = true });
    pub const ERROR = bridge.property(@as(u16, @intFromEnum(ReadyState.@"error")), .{ .template = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Track" {
    try testing.htmlRunner("element/html/track.html", .{});
}
