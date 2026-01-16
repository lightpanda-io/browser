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
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Media = @import("Media.zig");

const Audio = @This();

_proto: *Media,

pub fn constructor(maybe_url: ?[]const u8, page: *Page) !*Media {
    const node = try page.createElementNS(.html, "audio", null);
    const el = node.as(Element);

    const list = try el.getOrCreateAttributeList(page);
    // Always set to "auto" initially.
    _ = try list.putSafe("preload", "auto", el, page);
    // Set URL if provided.
    if (maybe_url) |url| {
        _ = try list.putSafe("src", url, el, page);
    }

    return node.as(Media);
}

pub fn asMedia(self: *Audio) *Media {
    return self._proto;
}

pub fn asElement(self: *Audio) *Element {
    return self._proto.asElement();
}

pub fn asNode(self: *Audio) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Audio);

    pub const Meta = struct {
        pub const name = "HTMLAudioElement";
        pub const constructor_alias = "Audio";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Audio.constructor, .{});
};
