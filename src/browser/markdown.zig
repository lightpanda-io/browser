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

const parser = @import("netsurf.zig");
const Walker = @import("dom/walker.zig").WalkerChildren;

const URL = @import("../url.zig").URL;

const NP = "\n\n";

const Elem = struct {
    inlin: bool = false,
    list_order: ?u8 = null,
    parent: ?*Elem = null,
};

const State = struct {
    block: bool,
    last_char: u8,
    elem: ?*Elem = null,

    fn is_inline(state: *State) bool {
        if (state.elem == null) return false;
        return state.elem.?.inlin;
    }

    fn last_char_space(state: *State) bool {
        if (state.last_char == ' ' or state.last_char == '\n') return true;
        return false;
    }
};

// writer must be a std.io.Writer
pub fn writeMarkdown(url: URL, doc: *parser.Document, writer: anytype) !void {
    var state = State{ .block = true, .last_char = '\n' };
    _ = try writeChildren(url, parser.documentToNode(doc), &state, writer);
    try writer.writeAll("\n");
}

fn writeChildren(url: URL, root: *parser.Node, state: *State, writer: anytype) !void {
    const walker = Walker{};
    var next: ?*parser.Node = null;
    while (true) {
        next = try walker.get_next(root, next) orelse break;
        try writeNode(url, next.?, state, writer);
    }
}

fn ensureBlock(state: *State, writer: anytype) !void {
    if (state.is_inline()) return;
    if (!state.block) {
        try writer.writeAll(NP);
        state.last_char = '\n';
        state.block = true;
    }
}

fn writeInline(state: *State, text: []const u8, writer: anytype) !void {
    try writer.writeAll(text);
    state.last_char = text[text.len - 1];
    if (state.block) state.block = false;
}

const order = [_][]const u8{
    "1",  "2",  "3",  "4",  "5",  "6",  "7",  "8",  "9",  "10",
    "11", "12", "13", "14", "15", "16", "17", "18", "19", "20",
    "21", "22", "23", "24", "25", "26", "27", "28", "29", "30",
    "31", "32", "33", "34", "35", "36", "37", "38", "39", "40",
    "41", "42", "43", "44", "45", "46", "47", "48", "49", "50",
};

fn writeNode(url: URL, node: *parser.Node, state: *State, writer: anytype) anyerror!void {
    switch (try parser.nodeType(node)) {
        .element => {
            const html_element: *parser.ElementHTML = @ptrCast(node);
            const tag = try parser.elementHTMLGetTagType(html_element);

            // debug
            // try writer.writeAll("\nstart - ");
            // try writer.writeAll(@tagName(tag));
            // try writer.writeAll("\n");

            switch (tag) {

                // skip element, go to children
                .html, .head, .meta, .link, .body, .span => {
                    try writeChildren(url, node, state, writer);
                },

                // skip element and children
                .title, .i, .script, .noscript, .undef, .style => {},

                // generic elements
                .h1, .h2, .h3, .h4, .h5, .h6 => {
                    try ensureBlock(state, writer);
                    if (!state.is_inline()) {
                        switch (tag) {
                            .h1 => try writeInline(state, "# ", writer),
                            .h2 => try writeInline(state, "## ", writer),
                            .h3 => try writeInline(state, "### ", writer),
                            .h4 => try writeInline(state, "#### ", writer),
                            .h5 => try writeInline(state, "##### ", writer),
                            .h6 => try writeInline(state, "###### ", writer),
                            else => @panic("only headers tags are supported here"),
                        }
                    }
                    try writeChildren(url, node, state, writer);
                    try ensureBlock(state, writer);
                },

                // containers and dividers
                .header, .footer, .nav, .section, .div, .article, .p, .button, .form => {
                    try ensureBlock(state, writer);
                    try writeChildren(url, node, state, writer);
                    try ensureBlock(state, writer);
                },
                .br => {
                    try ensureBlock(state, writer);
                    try writeChildren(url, node, state, writer);
                },
                .hr => {
                    try ensureBlock(state, writer);
                    try writeInline(state, "---", writer);
                    try ensureBlock(state, writer);
                },

                // styling
                .b => {
                    var elem = Elem{ .parent = state.elem, .inlin = true };
                    state.elem = &elem;
                    defer state.elem = elem.parent;
                    try writeInline(state, "**", writer);
                    try writeChildren(url, node, state, writer);
                    try writeInline(state, "**", writer);
                },

                // specific elements
                .a => {
                    if (!state.last_char_space()) try writeInline(state, " ", writer);
                    var elem = Elem{ .parent = state.elem, .inlin = true };
                    state.elem = &elem;
                    defer state.elem = elem.parent;
                    const element = parser.nodeToElement(node);
                    if (try getAttributeValue(element, "href")) |href| {
                        try writeInline(state, "[", writer);
                        try writeChildren(url, node, state, writer);
                        try writeInline(state, "](", writer);
                        // handle relative path
                        if (href[0] == '/') {
                            try writeInline(state, url.scheme(), writer);
                            try writeInline(state, "://", writer);
                            try writeInline(state, url.host(), writer);
                        }
                        try writeInline(state, href, writer);
                        try writeInline(state, ")", writer);
                    } else {
                        try writeChildren(url, node, state, writer);
                    }
                },
                .img => {
                    var elem = Elem{ .parent = state.elem, .inlin = true };
                    state.elem = &elem;
                    defer state.elem = elem.parent;
                    const element = parser.nodeToElement(node);
                    if (try getAttributeValue(element, "src")) |src| {
                        try writeInline(state, "![", writer);
                        if (try getAttributeValue(element, "alt")) |alt| {
                            try writeInline(state, alt, writer);
                        } else {
                            try writeInline(state, src, writer);
                        }
                        try writeInline(state, "](", writer);
                        // handle relative path
                        if (src[0] == '/') {
                            try writeInline(state, url.scheme(), writer);
                            try writeInline(state, "://", writer);
                            try writeInline(state, url.host(), writer);
                        }
                        try writeInline(state, src, writer);
                        try writeInline(state, ")", writer);
                    }
                },
                .ul => {
                    var elem = Elem{ .parent = state.elem, .list_order = 0 };
                    state.elem = &elem;
                    defer state.elem = elem.parent;
                    try ensureBlock(state, writer);
                    try writeChildren(url, node, state, writer);
                    try ensureBlock(state, writer);
                },
                .ol => {
                    var elem = Elem{ .parent = state.elem, .list_order = 1 };
                    state.elem = &elem;
                    defer state.elem = elem.parent;
                    try ensureBlock(state, writer);
                    try writeChildren(url, node, state, writer);
                    try ensureBlock(state, writer);
                },
                .li => blk: {
                    const parent = state.elem orelse break :blk;
                    const list_order = parent.list_order orelse break :blk;
                    if (!state.block) try writer.writeAll("\n");
                    if (list_order > 0) {
                        // ordered list
                        try writeInline(state, order[list_order - 1], writer);
                        try writeInline(state, ". ", writer);
                        parent.list_order = list_order + 1;
                    } else {
                        // unordered list
                        try writeInline(state, "- ", writer);
                    }
                    try writeChildren(url, node, state, writer);
                },
                .input => {
                    var elem = Elem{ .parent = state.elem, .inlin = true };
                    state.elem = &elem;
                    defer state.elem = elem.parent;
                    const element = parser.nodeToElement(node);
                    if (try getAttributeValue(element, "value")) |value| {
                        try writeInline(state, value, writer);
                        try writeInline(state, " ", writer);
                    }
                },

                else => {
                    try ensureBlock(state, writer);
                    try writer.writeAll(@tagName(tag));
                    try writer.writeAll(" not supported");
                    try ensureBlock(state, writer);
                },
            }
            // try writer.writeAll("\nend - ");
            // try writer.writeAll(@tagName(tag));
            // try writer.writeAll("\n");
        },
        .text => {
            const v = try parser.nodeValue(node) orelse return;
            const printed = try writeText(state, v, writer);
            if (printed) state.block = false;
        },
        .cdata_section => {},
        .comment => {},
        // TODO handle processing instruction dump
        .processing_instruction => {},
        // document fragment is outside of the main document DOM, so we
        // don't output it.
        .document_fragment => {},
        // document will never be called, but required for completeness.
        .document => {},
        // done globally instead, but required for completeness. Only the outer DOCTYPE should be written
        .document_type => {},
        // deprecated
        .attribute, .entity_reference, .entity, .notation => {},
    }
}

// TODO: not sure about + - . ! as they are very common characters
// I fear that we add too much escape strings
// TODO: | (pipe)
const escape = [_]u8{ '\\', '`', '*', '_', '{', '}', '[', ']', '<', '>', '(', ')', '#' };

fn writeText(state: *State, value: []const u8, writer: anytype) !bool {
    if (value.len == 0) return false;

    var last_char: u8 = ' ';
    var printed: u64 = 0;
    for (value, 0..) |v, i| {
        // do not print:
        // - multiple spaces
        // - return line
        // - tabs
        if (v == last_char and v == ' ') continue;
        if (v == '\n') continue;
        if (v == '\t') continue;

        // escape char
        for (escape) |esc| {
            if (v == esc) try writer.writeAll("\\");
        }

        if (printed == 0 and !state.is_inline()) {
            if (state.last_char != '\n' and state.last_char != ' ') {
                try writer.writeAll(" ");
            }
        }

        last_char = v;
        printed += 1;
        const x = [_]u8{v}; // TODO: do we have something better?
        try writer.writeAll(&x);
        if (i == value.len - 1) state.last_char = v;
    }
    if (printed > 0) return true;
    return false;
}

fn getAttributeValue(elem: *parser.Element, attr: []const u8) !?[]const u8 {
    if (try parser.elementGetAttribute(elem, attr)) |value| {
        if (value.len > 0) return value;
    }
    return null;
}

fn writeEscapedTextNode(writer: anytype, value: []const u8) !void {
    var v = value;
    while (v.len > 0) {
        try writer.writeAll("TEXT: ");
        const index = std.mem.indexOfAnyPos(u8, v, 0, &.{ '&', '<', '>' }) orelse {
            return writer.writeAll(v);
        };
        try writer.writeAll(v[0..index]);
        switch (v[index]) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => unreachable,
        }
        v = v[index + 1 ..];
    }
}
