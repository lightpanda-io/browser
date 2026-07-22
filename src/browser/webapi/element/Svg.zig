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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const AnimatedString = @import("../svg/AnimatedString.zig");
pub const Generic = @import("svg/Generic.zig");
pub const Graphics = @import("svg/Graphics.zig");
pub const View = @import("svg/View.zig");
pub const Title = @import("svg/Title.zig");
pub const Desc = @import("svg/Desc.zig");
pub const Metadata = @import("svg/Metadata.zig");
pub const GradientElement = @import("svg/GradientElement.zig");
pub const ClipPath = @import("svg/ClipPath.zig");
pub const Marker = @import("svg/Marker.zig");
pub const Mask = @import("svg/Mask.zig");
pub const Pattern = @import("svg/Pattern.zig");
pub const Stop = @import("svg/Stop.zig");

const String = lp.String;

const Svg = @This();
_type: Type,
_proto: *Element,
_tag_name: String, // Svg elements are case-preserving

pub const Type = union(enum) {
    graphics: *Graphics,
    view: *View,
    title: *Title,
    desc: *Desc,
    metadata: *Metadata,
    gradient: *GradientElement,
    clip_path: *ClipPath,
    marker: *Marker,
    mask: *Mask,
    pattern: *Pattern,
    stop: *Stop,
    generic: *Generic,
};

pub fn is(self: *Svg, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |field| {
        if (@field(Type, field.name) == self._type) {
            if (field.type == *T) {
                return @field(self._type, field.name);
            }
        }
    }
    if (self._type == .graphics) return self._type.graphics.is(T);
    if (self._type == .gradient) return self._type.gradient.is(T);
    return null;
}

pub fn getTag(self: *const Svg) Element.Tag {
    return switch (self._type) {
        .graphics => |g| switch (g._type) {
            .svg => .svg,
            .g => .g,
            // No dedicated Element.Tag values; tag-name matching falls back
            // to _tag_name, like it does for generic SVG elements.
            .a, .use, .image, .defs, .symbol, .switch_element, .foreign_object => .unknown,
            .text_content => |content| switch (content._type) {
                .positioning => |positioning| switch (positioning._type) {
                    .text => .text,
                    .tspan => .unknown,
                },
                .text_path => .unknown,
            },
            .geometry => |geo| switch (geo._type) {
                .rect => .rect,
                .circle => .circle,
                .ellipse => .ellipse,
                .line => .line,
                .path => .path,
                .polygon => .polygon,
                .polyline => .polyline,
            },
        },
        .generic => |g| g._tag,
        .title => .title,
        .view, .desc, .metadata, .gradient, .clip_path, .marker, .mask, .pattern, .stop => .unknown,
    };
}

pub fn asElement(self: *Svg) *Element {
    return self._proto;
}
pub fn asNode(self: *Svg) *Node {
    return self.asElement().asNode();
}

// The nearest ancestor <svg> element, null when this is the outermost svg.
pub fn getOwnerSvgElement(self: *Svg) ?*Graphics.Svg {
    var node = self.asNode().parentNode();
    while (node) |n| : (node = n.parentNode()) {
        const element = n.is(Element) orelse return null;
        if (element._namespace != .svg) {
            return null;
        }
        const svg = element.as(Svg);
        if (svg.is(Graphics.Svg)) |gfx_svg| {
            return gfx_svg;
        }
        if (svg._tag_name.eql(.wrap("foreignObject"))) {
            return null;
        }
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Svg);

    pub const Meta = struct {
        pub const name = "SVGElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    //  Overrides el.className to return a readonly AnimatedString
    pub const className = bridge.accessor(_className, null, .{});
    fn _className(self: *Svg, frame: *Frame) !*AnimatedString {
        return AnimatedString.getOrCreate(self.asElement(), .class, frame);
    }

    pub const ownerSVGElement = bridge.accessor(Svg.getOwnerSvgElement, null, .{});
    // closest thing we can provide
    pub const viewportElement = bridge.accessor(Svg.getOwnerSvgElement, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Svg" {
    try testing.htmlRunner("element/svg", .{});
}
