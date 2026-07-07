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

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const AbstractRange = @import("AbstractRange.zig");

const StaticRange = @This();

// The boundary points and `collapsed` accessor live on the shared AbstractRange
// prototype. Unlike Range, a StaticRange is *static*: the factory keeps it out
// of the frame's live-range list, so DOM mutations never move its boundaries.
_proto: *AbstractRange,

// https://dom.spec.whatwg.org/#dictdef-staticrangeinit
// All members are required. The fields are non-optional with no default, so the
// argument decoder rejects a missing or null member with a TypeError.
pub const StaticRangeInit = struct {
    startContainer: *Node,
    startOffset: u32,
    endContainer: *Node,
    endOffset: u32,
};

pub fn init(opts: StaticRangeInit, frame: *Frame) !*StaticRange {
    // https://dom.spec.whatwg.org/#dom-staticrange-staticrange
    // Throw InvalidNodeTypeError if either container is a DocumentType or Attr.
    // Note: offsets are stored verbatim — StaticRange does no length validation.
    if (isInvalidContainer(opts.startContainer) or isInvalidContainer(opts.endContainer)) {
        return error.InvalidNodeType;
    }

    const arena = try frame.getArena(.medium, "StaticRange");
    errdefer frame.releaseArena(arena);

    const static_range = try frame._factory.abstractRange(arena, StaticRange{ ._proto = undefined }, frame);
    const proto = static_range._proto;
    proto._start_container = opts.startContainer;
    proto._start_offset = opts.startOffset;
    proto._end_container = opts.endContainer;
    proto._end_offset = opts.endOffset;
    return static_range;
}

fn isInvalidContainer(node: *Node) bool {
    return node._type == .document_type or node._type == .attribute;
}

pub fn asAbstractRange(self: *StaticRange) *AbstractRange {
    return self._proto;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StaticRange);

    pub const Meta = struct {
        pub const name = "StaticRange";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(StaticRange.init, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: StaticRange" {
    try testing.htmlRunner("staticrange.html", .{});
}
