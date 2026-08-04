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
const lp = @import("lightpanda");
const js = @import("../../../js/js.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Factory = @import("../../../Factory.zig");

const TextContent = @import("TextContent.zig");

pub const Text = @import("Text.zig");
pub const TSpan = @import("TSpan.zig");

const TextPositioning = @This();

pub const Proto = TextContent;
_type: Type,
_proto_canary: if (lp.IS_DEBUG) *TextContent else void = undefined,

pub const Type = enum(u8) {
    text,
    tspan,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .text => Text,
        .tspan => TSpan,
    };
}

pub fn subtype(self: *const TextPositioning, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, TextPositioning);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *TextPositioning, comptime T: type) ?*T {
    switch (self._type) {
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    return null;
}

pub fn asElement(self: *TextPositioning) *Element {
    return Factory.protoOf(self).asElement();
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
