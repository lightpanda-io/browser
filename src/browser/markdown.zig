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
const Page = @import("Page.zig");
const Node = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const Slot = @import("webapi/element/html/Slot.zig");

pub const Opts = struct {
    // Options for future customization (e.g., dialect)
};

const State = struct {
    list_depth: usize = 0,
    in_pre: bool = false,
    in_code: bool = false,
    in_blockquote: bool = false,
    last_char_was_newline: bool = true,
};

pub fn dump(node: *Node, opts: Opts, writer: *std.Io.Writer, page: *Page) !void {
    _ = opts;
    var state = State{};
    try render(node, &state, writer, page);
    if (!state.last_char_was_newline) {
        try writer.writeByte('\n');
    }
}

fn render(node: *Node, state: *State, writer: *std.Io.Writer, page: *Page) anyerror!void {
    switch (node._type) {
        .document, .document_fragment => {
            try renderChildren(node, state, writer, page);
        },
        .element => |el| {
            try renderElement(el, state, writer, page);
        },
        .cdata => |cd| {
            if (node.is(Node.CData.Text)) |_| {
                try renderText(cd.getData(), state, writer);
            }
        },
        else => {}, // Ignore other node types
    }
}

fn renderChildren(parent: *Node, state: *State, writer: *std.Io.Writer, page: *Page) anyerror!void {
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        try render(child, state, writer, page);
    }
}

fn renderElement(el: *Element, state: *State, writer: *std.Io.Writer, page: *Page) anyerror!void {
    const tag = el.getTag();

    // Skip hidden/metadata elements
    switch (tag) {
        .script, .style, .noscript, .template, .head, .meta, .link, .title, .svg => return,
        else => {},
    }

    // --- Opening Tag Logic ---

    // Ensure block elements start on a new line (double newline for paragraphs etc)
    switch (tag) {
        .p, .div, .section, .article, .header, .footer, .nav, .aside, .h1, .h2, .h3, .h4, .h5, .h6, .ul, .ol, .blockquote, .pre, .table, .hr => {
            if (!state.last_char_was_newline) {
                try writer.writeByte('\n');
                state.last_char_was_newline = true;
            }
            if (tag == .p or tag == .h1 or tag == .h2 or tag == .h3 or tag == .h4 or tag == .h5 or tag == .h6 or tag == .blockquote or tag == .pre or tag == .table) {
                // Add an extra newline for spacing between blocks
                try writer.writeByte('\n');
            }
        },
        .li, .tr => {
            if (!state.last_char_was_newline) {
                try writer.writeByte('\n');
                state.last_char_was_newline = true;
            }
        },
        else => {},
    }

    // Prefixes
    switch (tag) {
        .h1 => try writer.writeAll("# "),
        .h2 => try writer.writeAll("## "),
        .h3 => try writer.writeAll("### "),
        .h4 => try writer.writeAll("#### "),
        .h5 => try writer.writeAll("##### "),
        .h6 => try writer.writeAll("###### "),
        .ul, .ol => {
            state.list_depth += 1;
        },
        .li => {
            const indent = if (state.list_depth > 0) state.list_depth - 1 else 0;
            try writeIndentation(indent, writer);
            try writer.writeAll("- ");
            state.last_char_was_newline = false;
        },
        .blockquote => {
            try writer.writeAll("> ");
            state.in_blockquote = true;
            state.last_char_was_newline = false;
        },
        .pre => {
            try writer.writeAll("```\n");
            state.in_pre = true;
            state.last_char_was_newline = true;
        },
        .code => {
            if (!state.in_pre) {
                try writer.writeByte('`');
                state.in_code = true;
                state.last_char_was_newline = false;
            }
        },
        .b, .strong => {
            try writer.writeAll("**");
            state.last_char_was_newline = false;
        },
        .i, .em => {
            try writer.writeAll("*");
            state.last_char_was_newline = false;
        },
        .hr => {
            try writer.writeAll("---\n");
            state.last_char_was_newline = true;
            return; // Void element
        },
        .br => {
            try writer.writeByte('\n');
            state.last_char_was_newline = true;
            return; // Void element
        },
        .img => {
            try writer.writeAll("![");
            if (el.getAttributeSafe(comptime .wrap("alt"))) |alt| {
                try writer.writeAll(alt);
            }
            try writer.writeAll("](");
            if (el.getAttributeSafe(comptime .wrap("src"))) |src| {
                try writer.writeAll(src);
            }
            try writer.writeAll(")");
            state.last_char_was_newline = false;
            return; // Treat as void
        },
        .anchor => {
            try writer.writeByte('[');
            state.last_char_was_newline = false;
        },
        else => {},
    }

    // --- Render Children ---
    try renderChildren(el.asNode(), state, writer, page);

    // --- Closing Tag Logic ---

    // Suffixes
    switch (tag) {
        .anchor => {
            try writer.writeAll("](");
            if (el.getAttributeSafe(comptime .wrap("href"))) |href| {
                try writer.writeAll(href);
            }
            try writer.writeByte(')');
            state.last_char_was_newline = false;
        },
        .pre => {
            if (!state.last_char_was_newline) {
                try writer.writeByte('\n');
            }
            try writer.writeAll("```\n");
            state.in_pre = false;
            state.last_char_was_newline = true;
        },
        .code => {
            if (!state.in_pre) {
                try writer.writeByte('`');
                state.in_code = false;
                state.last_char_was_newline = false;
            }
        },
        .b, .strong => {
            try writer.writeAll("**");
            state.last_char_was_newline = false;
        },
        .i, .em => {
            try writer.writeAll("*");
            state.last_char_was_newline = false;
        },
        .blockquote => {
            state.in_blockquote = false;
        },
        .ul, .ol => {
            if (state.list_depth > 0) state.list_depth -= 1;
        },
        else => {},
    }

    // Post-block newlines
    switch (tag) {
        .p, .div, .section, .article, .header, .footer, .nav, .aside, .h1, .h2, .h3, .h4, .h5, .h6, .ul, .ol, .blockquote, .table, .tr => {
            if (!state.last_char_was_newline) {
                try writer.writeByte('\n');
                state.last_char_was_newline = true;
            }
        },
        else => {},
    }
}

fn renderText(text: []const u8, state: *State, writer: *std.Io.Writer) anyerror!void {
    if (text.len == 0) return;

    if (state.in_pre) {
        try writer.writeAll(text);
        if (text.len > 0 and text[text.len - 1] == '\n') {
            state.last_char_was_newline = true;
        } else {
            state.last_char_was_newline = false;
        }
        return;
    }

    // Collapse whitespace
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
    var first = true;
    while (it.next()) |word| {
        // If this is the first word we're writing in this sequence...
        if (first) {
            // ...and we didn't just write a newline...
            if (!state.last_char_was_newline) {
                // ...check if the original text had leading whitespace.
                if (text.len > 0 and std.ascii.isWhitespace(text[0])) {
                    try writer.writeByte(' ');
                }
            }
        } else {
            // Between words always add space
            try writer.writeByte(' ');
        }

        try writer.writeAll(word);
        state.last_char_was_newline = false;
        first = false;
    }

    // Handle trailing whitespace from the original text
    if (!first and !state.last_char_was_newline) {
        if (text.len > 0 and std.ascii.isWhitespace(text[text.len - 1])) {
            try writer.writeByte(' ');
        }
    }
}

fn writeIndentation(level: usize, writer: *std.Io.Writer) anyerror!void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll("  ");
    }
}
