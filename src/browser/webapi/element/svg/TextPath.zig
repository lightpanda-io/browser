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

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const AnimatedEnumeration = @import("../../svg/AnimatedEnumeration.zig");
const AnimatedLength = @import("../../svg/AnimatedLength.zig");
const AnimatedString = @import("../../svg/AnimatedString.zig");

const TextContent = @import("TextContent.zig");

const TextPath = @This();

pub const Proto = TextContent;
_proto: *TextContent,

pub fn asElement(self: *TextPath) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *TextPath) *Node {
    return self.asElement().asNode();
}

fn getStartOffset(self: *TextPath, frame: *Frame) !*AnimatedLength {
    return AnimatedLength.getOrCreate(self.asElement(), .text_path_start_offset, frame);
}
fn getHref(self: *TextPath, frame: *Frame) !*AnimatedString {
    return AnimatedString.getOrCreate(self.asElement(), .href, frame);
}
fn getMethod(self: *TextPath, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .text_path_method, frame);
}
fn getSpacing(self: *TextPath, frame: *Frame) !*AnimatedEnumeration {
    return AnimatedEnumeration.getOrCreate(self.asElement(), .text_path_spacing, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextPath);
    pub const Meta = struct {
        pub const name = "SVGTextPathElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
    pub const TEXTPATH_METHODTYPE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const TEXTPATH_METHODTYPE_ALIGN = bridge.property(1, .{ .template = true });
    pub const TEXTPATH_METHODTYPE_STRETCH = bridge.property(2, .{ .template = true });
    pub const TEXTPATH_SPACINGTYPE_UNKNOWN = bridge.property(0, .{ .template = true });
    pub const TEXTPATH_SPACINGTYPE_AUTO = bridge.property(1, .{ .template = true });
    pub const TEXTPATH_SPACINGTYPE_EXACT = bridge.property(2, .{ .template = true });
    pub const startOffset = bridge.accessor(TextPath.getStartOffset, null, .{});
    pub const method = bridge.accessor(TextPath.getMethod, null, .{});
    pub const spacing = bridge.accessor(TextPath.getSpacing, null, .{});
    pub const href = bridge.accessor(TextPath.getHref, null, .{});
};
