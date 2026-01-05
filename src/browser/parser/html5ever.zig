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

const ParsedNode = @import("Parser.zig").ParsedNode;

pub extern "c" fn html5ever_parse_document(
    html: [*c]const u8,
    len: usize,
    doc: *anyopaque,
    ctx: *anyopaque,
    createElementCallback: *const fn (ctx: *anyopaque, data: *anyopaque, QualName, AttributeIterator) callconv(.c) ?*anyopaque,
    elemNameCallback: *const fn (node_ref: *anyopaque) callconv(.c) *anyopaque,
    appendCallback: *const fn (ctx: *anyopaque, parent_ref: *anyopaque, NodeOrText) callconv(.c) void,
    parseErrorCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) void,
    popCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque) callconv(.c) void,
    createCommentCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) ?*anyopaque,
    createProcessingInstruction: *const fn (ctx: *anyopaque, StringSlice, StringSlice) callconv(.c) ?*anyopaque,
    appendDoctypeToDocument: *const fn (ctx: *anyopaque, StringSlice, StringSlice, StringSlice) callconv(.c) void,
    addAttrsIfMissingCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque, AttributeIterator) callconv(.c) void,
    getTemplateContentsCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) ?*anyopaque,
    removeFromParentCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) void,
    reparentChildrenCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque, new_parent_ref: *anyopaque) callconv(.c) void,
    appendBeforeSiblingCallback: *const fn (ctx: *anyopaque, sibling_ref: *anyopaque, NodeOrText) callconv(.c) void,
    appendBasedOnParentNodeCallback: *const fn (ctx: *anyopaque, element_ref: *anyopaque, prev_element_ref: *anyopaque, NodeOrText) callconv(.c) void,
) void;

pub extern "c" fn html5ever_parse_fragment(
    html: [*c]const u8,
    len: usize,
    doc: *anyopaque,
    ctx: *anyopaque,
    createElementCallback: *const fn (ctx: *anyopaque, data: *anyopaque, QualName, AttributeIterator) callconv(.c) ?*anyopaque,
    elemNameCallback: *const fn (node_ref: *anyopaque) callconv(.c) *anyopaque,
    appendCallback: *const fn (ctx: *anyopaque, parent_ref: *anyopaque, NodeOrText) callconv(.c) void,
    parseErrorCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) void,
    popCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque) callconv(.c) void,
    createCommentCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) ?*anyopaque,
    createProcessingInstruction: *const fn (ctx: *anyopaque, StringSlice, StringSlice) callconv(.c) ?*anyopaque,
    appendDoctypeToDocument: *const fn (ctx: *anyopaque, StringSlice, StringSlice, StringSlice) callconv(.c) void,
    addAttrsIfMissingCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque, AttributeIterator) callconv(.c) void,
    getTemplateContentsCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) ?*anyopaque,
    removeFromParentCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) void,
    reparentChildrenCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque, new_parent_ref: *anyopaque) callconv(.c) void,
    appendBeforeSiblingCallback: *const fn (ctx: *anyopaque, sibling_ref: *anyopaque, NodeOrText) callconv(.c) void,
    appendBasedOnParentNodeCallback: *const fn (ctx: *anyopaque, element_ref: *anyopaque, prev_element_ref: *anyopaque, NodeOrText) callconv(.c) void,
) void;

pub extern "c" fn html5ever_attribute_iterator_next(ctx: *anyopaque) Nullable(Attribute);
pub extern "c" fn html5ever_attribute_iterator_count(ctx: *anyopaque) usize;

pub extern "c" fn html5ever_get_memory_usage() MemoryUsage;

pub const MemoryUsage = extern struct {
    resident: usize,
    allocated: usize,
};

// Streaming parser API
pub extern "c" fn html5ever_streaming_parser_create(
    doc: *anyopaque,
    ctx: *anyopaque,
    createElementCallback: *const fn (ctx: *anyopaque, data: *anyopaque, QualName, AttributeIterator) callconv(.c) ?*anyopaque,
    elemNameCallback: *const fn (node_ref: *anyopaque) callconv(.c) *anyopaque,
    appendCallback: *const fn (ctx: *anyopaque, parent_ref: *anyopaque, NodeOrText) callconv(.c) void,
    parseErrorCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) void,
    popCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque) callconv(.c) void,
    createCommentCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) ?*anyopaque,
    createProcessingInstruction: *const fn (ctx: *anyopaque, StringSlice, StringSlice) callconv(.c) ?*anyopaque,
    appendDoctypeToDocument: *const fn (ctx: *anyopaque, StringSlice, StringSlice, StringSlice) callconv(.c) void,
    addAttrsIfMissingCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque, AttributeIterator) callconv(.c) void,
    getTemplateContentsCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) ?*anyopaque,
    removeFromParentCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) void,
    reparentChildrenCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque, new_parent_ref: *anyopaque) callconv(.c) void,
    appendBeforeSiblingCallback: *const fn (ctx: *anyopaque, sibling_ref: *anyopaque, NodeOrText) callconv(.c) void,
    appendBasedOnParentNodeCallback: *const fn (ctx: *anyopaque, element_ref: *anyopaque, prev_element_ref: *anyopaque, NodeOrText) callconv(.c) void,
) ?*anyopaque;

pub extern "c" fn html5ever_streaming_parser_feed(
    parser: *anyopaque,
    html: [*c]const u8,
    len: usize,
) c_int;

pub extern "c" fn html5ever_streaming_parser_finish(
    parser: *anyopaque,
) void;

pub extern "c" fn html5ever_streaming_parser_destroy(
    parser: *anyopaque,
) void;

pub fn Nullable(comptime T: type) type {
    return extern struct {
        tag: u8,
        value: T,

        pub fn unwrap(self: @This()) ?T {
            return if (self.tag == 0) null else self.value;
        }

        pub fn none() @This() {
            return .{ .tag = 0, .value = undefined };
        }
    };
}

pub const StringSlice = Slice(u8);
pub fn Slice(comptime T: type) type {
    return extern struct {
        ptr: [*]const T,
        len: usize,

        pub fn slice(self: @This()) []const T {
            return self.ptr[0..self.len];
        }
    };
}

pub const QualName = extern struct {
    prefix: Nullable(StringSlice),
    ns: StringSlice,
    local: StringSlice,
};

pub const Attribute = extern struct {
    name: QualName,
    value: StringSlice,
};

pub const AttributeIterator = extern struct {
    iter: *anyopaque,

    pub fn next(self: AttributeIterator) ?Attribute {
        return html5ever_attribute_iterator_next(self.iter).unwrap();
    }

    pub fn count(self: AttributeIterator) usize {
        return html5ever_attribute_iterator_count(self.iter);
    }
};

pub const NodeOrText = extern struct {
    tag: u8,
    node: *anyopaque,
    text: StringSlice,

    pub fn toUnion(self: NodeOrText) Union {
        if (self.tag == 0) {
            return .{ .node = @ptrCast(@alignCast(self.node)) };
        }
        return .{ .text = self.text.slice() };
    }

    const Union = union(enum) {
        node: *ParsedNode,
        text: []const u8,
    };
};

pub extern "c" fn xml5ever_parse_document(
    html: [*c]const u8,
    len: usize,
    doc: *anyopaque,
    ctx: *anyopaque,
    createElementCallback: *const fn (ctx: *anyopaque, data: *anyopaque, QualName, AttributeIterator) callconv(.c) ?*anyopaque,
    elemNameCallback: *const fn (node_ref: *anyopaque) callconv(.c) *anyopaque,
    appendCallback: *const fn (ctx: *anyopaque, parent_ref: *anyopaque, NodeOrText) callconv(.c) void,
    parseErrorCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) void,
    popCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque) callconv(.c) void,
    createCommentCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) ?*anyopaque,
    createProcessingInstruction: *const fn (ctx: *anyopaque, StringSlice, StringSlice) callconv(.c) ?*anyopaque,
    appendDoctypeToDocument: *const fn (ctx: *anyopaque, StringSlice, StringSlice, StringSlice) callconv(.c) void,
    addAttrsIfMissingCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque, AttributeIterator) callconv(.c) void,
    getTemplateContentsCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) ?*anyopaque,
    removeFromParentCallback: *const fn (ctx: *anyopaque, target_ref: *anyopaque) callconv(.c) void,
    reparentChildrenCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque, new_parent_ref: *anyopaque) callconv(.c) void,
    appendBeforeSiblingCallback: *const fn (ctx: *anyopaque, sibling_ref: *anyopaque, NodeOrText) callconv(.c) void,
    appendBasedOnParentNodeCallback: *const fn (ctx: *anyopaque, element_ref: *anyopaque, prev_element_ref: *anyopaque, NodeOrText) callconv(.c) void,
) void;
