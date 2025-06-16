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

const NP = "\n\n";

// writer must be a std.io.Writer
pub fn writeMarkdown(doc: *parser.Document, writer: anytype) !void {
    _ = try writeChildren(parser.documentToNode(doc), true, writer);
    try writer.writeAll("\n");
}

fn writeChildren(root: *parser.Node, new_para: bool, writer: anytype) !bool {
    const walker = Walker{};
    var next: ?*parser.Node = null;
    var _new_para = new_para;
    while (true) {
        next = try walker.get_next(root, next) orelse break;
        _new_para = try writeNode(next.?, _new_para, writer);
    }
    return _new_para;
}

fn skipTextChild(root: *parser.Node) !*parser.Node {
    const child = parser.nodeFirstChild(root) orelse return root;
    const node_type = try parser.nodeType(child);
    if (node_type == .text) return child;
    return root;
}

// the returned boolean can be either:
// - true if a new paragraph has been written at the end
// - false if an inline text (ie. without new paragraph) has been written at the end
// - the value of the writeChildren function if it has been called recursively at the end
// - the new_para received as argument otherwise
fn writeNode(node: *parser.Node, new_para: bool, writer: anytype) anyerror!bool {
    switch (try parser.nodeType(node)) {
        .element => {
            const html_element: *parser.ElementHTML = @ptrCast(node);
            const tag = try parser.elementHTMLGetTagType(html_element);

            // debug
            // try writer.writeAll(@tagName(tag));
            // try writer.writeAll("-");
            // if (new_para) {
            //     try writer.writeAll("1");
            // } else {
            //     try writer.writeAll("0");
            // }

            switch (tag) {

                // skip element, go to children
                .html, .head, .header, .footer, .meta, .link, .body => {
                    return try writeChildren(node, new_para, writer);
                },

                // skip element and children (eg. text)
                .title, .i, .script, .noscript, .undef, .style => return new_para,

                // generic elements
                .h1, .h2, .h3, .h4 => {
                    if (!new_para) {
                        try writer.writeAll(NP);
                    }
                    switch (tag) {
                        .h1 => try writer.writeAll("# "),
                        .h2 => try writer.writeAll("## "),
                        .h3 => try writer.writeAll("### "),
                        .h4 => try writer.writeAll("#### "),
                        else => @panic("only headers tags are supported here"),
                    }
                    const np = try writeChildren(node, false, writer);
                    if (!np) try writer.writeAll(NP);
                    return true;
                },

                // containers and dividers
                .nav, .section, .article, .p, .div, .button, .form => {
                    if (!new_para) try writer.writeAll(NP);
                    const np = try writeChildren(node, true, writer);
                    if (!np) try writer.writeAll(NP);
                    return true;
                },
                .span => {
                    return try writeChildren(node, new_para, writer);
                },
                .b => {
                    try writer.writeAll("**");
                    _ = try writeChildren(node, false, writer);
                    try writer.writeAll("**");
                    return false;
                },
                .br => {
                    if (!new_para) try writer.writeAll(NP);
                    return try writeChildren(node, true, writer);
                },
                .hr => {
                    if (!new_para) try writer.writeAll(NP);
                    try writer.writeAll("---");
                    try writer.writeAll(NP);
                    return true;
                },

                // specific elements
                .a => {
                    const element = parser.nodeToElement(node);
                    if (try getAttributeValue(element, "href")) |href| {
                        // TODO: absolute path?
                        try writer.writeAll("[");
                        _ = try writeChildren(node, false, writer);
                        try writer.writeAll("](");
                        try writer.writeAll(href);
                        try writer.writeAll(")");
                        return false;
                    }
                    return try writeChildren(node, new_para, writer);
                },
                .img => {
                    const element = parser.nodeToElement(node);
                    if (try getAttributeValue(element, "src")) |src| {
                        // TODO: absolute path?
                        try writer.writeAll("![");
                        if (try getAttributeValue(element, "alt")) |alt| {
                            try writer.writeAll(alt);
                        } else {
                            try writer.writeAll(src);
                        }
                        try writer.writeAll("](");
                        try writer.writeAll(src);
                        try writer.writeAll(")");
                        return false;
                    }
                    return new_para;
                },
                .ol => {
                    if (!new_para) try writer.writeAll(NP);
                    const np = try writeChildren(node, true, writer);
                    if (!np) try writer.writeAll(NP);
                    return true;
                },
                .ul => {
                    if (!new_para) try writer.writeAll(NP);
                    const np = try writeChildren(node, true, writer);
                    if (!np) try writer.writeAll(NP);
                    return true;
                },
                .li => {
                    if (!new_para) try writer.writeAll("\n");
                    try writer.writeAll("- ");
                    return try writeChildren(node, false, writer);
                },
                .input => {
                    const element = parser.nodeToElement(node);
                    if (try getAttributeValue(element, "value")) |value| {
                        try writer.writeAll(value);
                        try writer.writeAll(" ");
                    }
                    return false;
                },
                else => {
                    try writer.writeAll("\n");
                    try writer.writeAll(@tagName(tag));
                    try writer.writeAll(" not supported\n");
                },
            }
            // panic
        },
        .text => {
            const v = try parser.nodeValue(node) orelse return new_para;
            const printed = try writeText(v, writer);
            if (printed) return false;
            return new_para;
        },
        .cdata_section => {
            return new_para;
        },
        .comment => {
            return new_para;
        },
        // TODO handle processing instruction dump
        .processing_instruction => return new_para,
        // document fragment is outside of the main document DOM, so we
        // don't output it.
        .document_fragment => return new_para,
        // document will never be called, but required for completeness.
        .document => return new_para,
        // done globally instead, but required for completeness. Only the outer DOCTYPE should be written
        .document_type => return new_para,
        // deprecated
        .attribute, .entity_reference, .entity, .notation => return new_para,
    }
    return new_para;
}

// TODO: not sure about + - . ! as they are very common characters
// I fear that we add too much escape strings
// TODO: | (pipe)
const escape = [_]u8{ '\\', '`', '*', '_', '{', '}', '[', ']', '<', '>', '(', ')', '#' };

fn writeText(value: []const u8, writer: anytype) !bool {
    if (value.len == 0) return false;

    var last_char: u8 = ' ';
    var printed: u64 = 0;
    for (value) |v| {
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

        last_char = v;
        printed += 1;
        const x = [_]u8{v}; // TODO: do we have something better?
        try writer.writeAll(&x);
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
