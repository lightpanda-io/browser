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

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");

const TextContent = @import("TextContent.zig");

pub const Text = @import("Text.zig");
pub const TSpan = @import("TSpan.zig");

const TextPositioning = @This();

pub const Proto = TextContent;
_proto: *TextContent,
_type: Type,

pub const Type = union(enum) {
    text: *Text,
    tspan: *TSpan,
};

pub fn is(self: *TextPositioning, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |field| {
        if (@field(Type, field.name) == self._type) {
            if (field.type == *T) return @field(self._type, field.name);
        }
    }
    return null;
}

pub fn asElement(self: *TextPositioning) *Element {
    return self._proto.asElement();
}
pub fn asNode(self: *TextPositioning) *Node {
    return self.asElement().asNode();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextPositioning);
    pub const Meta = struct {
        pub const name = "SVGTextPositioningElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
