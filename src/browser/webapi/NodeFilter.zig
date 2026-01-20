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
const js = @import("../js/js.zig");
const Node = @import("Node.zig");

const NodeFilter = @This();

_func: ?js.Function.Global,
_original_filter: ?FilterOpts,

pub const FilterOpts = union(enum) {
    function: js.Function.Global,
    object: struct {
        pub const js_as_object = true;
        acceptNode: js.Function.Global,
    },
};

pub fn init(opts_: ?FilterOpts) !NodeFilter {
    const opts = opts_ orelse return .{ ._func = null, ._original_filter = null };
    const func = switch (opts) {
        .function => |func| func,
        .object => |obj| obj.acceptNode,
    };
    return .{
        ._func = func,
        ._original_filter = opts_,
    };
}

// Constants
pub const FILTER_ACCEPT: i32 = 1;
pub const FILTER_REJECT: i32 = 2;
pub const FILTER_SKIP: i32 = 3;

// whatToShow constants
pub const SHOW_ALL: u32 = 0xFFFFFFFF;
pub const SHOW_ELEMENT: u32 = 0x1;
pub const SHOW_ATTRIBUTE: u32 = 0x2;
pub const SHOW_TEXT: u32 = 0x4;
pub const SHOW_CDATA_SECTION: u32 = 0x8;
pub const SHOW_ENTITY_REFERENCE: u32 = 0x10;
pub const SHOW_ENTITY: u32 = 0x20;
pub const SHOW_PROCESSING_INSTRUCTION: u32 = 0x40;
pub const SHOW_COMMENT: u32 = 0x80;
pub const SHOW_DOCUMENT: u32 = 0x100;
pub const SHOW_DOCUMENT_TYPE: u32 = 0x200;
pub const SHOW_DOCUMENT_FRAGMENT: u32 = 0x400;
pub const SHOW_NOTATION: u32 = 0x800;

pub fn acceptNode(self: *const NodeFilter, node: *Node, local: *const js.Local) !i32 {
    const func = self._func orelse return FILTER_ACCEPT;
    return local.toLocal(func).call(i32, .{node});
}

pub fn shouldShow(node: *const Node, what_to_show: u32) bool {
    // TODO: Test this mapping thoroughly!
    // nodeType values (1=ELEMENT, 3=TEXT, 9=DOCUMENT, etc.) need to map to
    // SHOW_* bitmask positions (0x1, 0x4, 0x100, etc.)
    const node_type_value = node.getNodeType();
    const bit_position = node_type_value - 1;
    const node_type_bit: u32 = @as(u32, 1) << @intCast(bit_position);
    return (what_to_show & node_type_bit) != 0;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NodeFilter);

    pub const Meta = struct {
        pub const name = "NodeFilter";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const FILTER_ACCEPT = bridge.property(NodeFilter.FILTER_ACCEPT);
    pub const FILTER_REJECT = bridge.property(NodeFilter.FILTER_REJECT);
    pub const FILTER_SKIP = bridge.property(NodeFilter.FILTER_SKIP);

    pub const SHOW_ALL = bridge.property(NodeFilter.SHOW_ALL);
    pub const SHOW_ELEMENT = bridge.property(NodeFilter.SHOW_ELEMENT);
    pub const SHOW_ATTRIBUTE = bridge.property(NodeFilter.SHOW_ATTRIBUTE);
    pub const SHOW_TEXT = bridge.property(NodeFilter.SHOW_TEXT);
    pub const SHOW_CDATA_SECTION = bridge.property(NodeFilter.SHOW_CDATA_SECTION);
    pub const SHOW_ENTITY_REFERENCE = bridge.property(NodeFilter.SHOW_ENTITY_REFERENCE);
    pub const SHOW_ENTITY = bridge.property(NodeFilter.SHOW_ENTITY);
    pub const SHOW_PROCESSING_INSTRUCTION = bridge.property(NodeFilter.SHOW_PROCESSING_INSTRUCTION);
    pub const SHOW_COMMENT = bridge.property(NodeFilter.SHOW_COMMENT);
    pub const SHOW_DOCUMENT = bridge.property(NodeFilter.SHOW_DOCUMENT);
    pub const SHOW_DOCUMENT_TYPE = bridge.property(NodeFilter.SHOW_DOCUMENT_TYPE);
    pub const SHOW_DOCUMENT_FRAGMENT = bridge.property(NodeFilter.SHOW_DOCUMENT_FRAGMENT);
    pub const SHOW_NOTATION = bridge.property(NodeFilter.SHOW_NOTATION);
};
