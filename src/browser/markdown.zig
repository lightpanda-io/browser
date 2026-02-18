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
const Element = @import("webapi/Element.zig");
const Node = @import("webapi/Node.zig");

pub const Opts = struct {
    // Options for future customization (e.g., dialect)
};

const State = struct {
    const ListType = enum { ordered, unordered };
    const ListState = struct {
        type: ListType,
        index: usize,
    };

    list_depth: usize = 0,
    list_stack: [32]ListState = undefined,
    in_pre: bool = false,
    pre_node: ?*Node = null,
    in_code: bool = false,
    in_table: bool = false,
    table_row_index: usize = 0,
    table_col_count: usize = 0,
    last_char_was_newline: bool = true,
};

fn isBlock(tag: Element.Tag) bool {
    return switch (tag) {
        .p, .div, .section, .article, .header, .footer, .nav, .aside, .h1, .h2, .h3, .h4, .h5, .h6, .ul, .ol, .blockquote, .pre, .table, .hr => true,
        else => false,
    };
}

fn shouldAddSpacing(tag: Element.Tag) bool {
    return switch (tag) {
        .p, .h1, .h2, .h3, .h4, .h5, .h6, .blockquote, .pre, .table => true,
        else => false,
    };
}

fn ensureNewline(state: *State, writer: *std.Io.Writer) !void {
    if (!state.last_char_was_newline) {
        try writer.writeByte('\n');
        state.last_char_was_newline = true;
    }
}

pub fn dump(node: *Node, opts: Opts, writer: *std.Io.Writer, page: *Page) !void {
    _ = opts;
    var state = State{};
    try render(node, &state, writer, page);
    if (!state.last_char_was_newline) {
        try writer.writeByte('\n');
    }
}

fn render(node: *Node, state: *State, writer: *std.Io.Writer, page: *Page) error{WriteFailed}!void {
    switch (node.getNodeType()) {
        .document, .document_fragment => {
            try renderChildren(node, state, writer, page);
        },
        .element => {
            try renderElement(node.as(Element), state, writer, page);
        },
        .text, .cdata_section => {
            if (node.is(Node.CData.Text)) |_| {
                const cd = node.as(Node.CData);
                var text = cd.getData();
                if (state.in_pre) {
                    if (state.pre_node) |pre| {
                        if (node.parentNode() == pre and node.nextSibling() == null) {
                            text = std.mem.trimRight(u8, text, " \t\r\n");
                        }
                    }
                }
                try renderText(text, state, writer);
            }
        },
        else => {}, // Ignore other node types
    }
}

fn renderChildren(parent: *Node, state: *State, writer: *std.Io.Writer, page: *Page) !void {
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        try render(child, state, writer, page);
    }
}

fn renderElement(el: *Element, state: *State, writer: *std.Io.Writer, page: *Page) !void {
    const tag = el.getTag();

    // Skip hidden/metadata elements
    switch (tag) {
        .script, .style, .noscript, .template, .head, .meta, .link, .title, .svg => return,
        else => {},
    }

    // --- Opening Tag Logic ---

    // Ensure block elements start on a new line (double newline for paragraphs etc)
    if (isBlock(tag)) {
        if (!state.in_table) {
            try ensureNewline(state, writer);
            if (shouldAddSpacing(tag)) {
                // Add an extra newline for spacing between blocks
                try writer.writeByte('\n');
            }
        }
    } else if (tag == .li or tag == .tr) {
        try ensureNewline(state, writer);
    }

    // Prefixes
    switch (tag) {
        .h1 => try writer.writeAll("# "),
        .h2 => try writer.writeAll("## "),
        .h3 => try writer.writeAll("### "),
        .h4 => try writer.writeAll("#### "),
        .h5 => try writer.writeAll("##### "),
        .h6 => try writer.writeAll("###### "),
        .ul => {
            if (state.list_depth < state.list_stack.len) {
                state.list_stack[state.list_depth] = .{ .type = .unordered, .index = 0 };
                state.list_depth += 1;
            }
        },
        .ol => {
            if (state.list_depth < state.list_stack.len) {
                state.list_stack[state.list_depth] = .{ .type = .ordered, .index = 1 };
                state.list_depth += 1;
            }
        },
        .li => {
            const indent = if (state.list_depth > 0) state.list_depth - 1 else 0;
            for (0..indent) |_| try writer.writeAll("  ");

            if (state.list_depth > 0) {
                const current_list = &state.list_stack[state.list_depth - 1];
                if (current_list.type == .ordered) {
                    try writer.print("{d}. ", .{current_list.index});
                    current_list.index += 1;
                } else {
                    try writer.writeAll("- ");
                }
            } else {
                try writer.writeAll("- ");
            }
            state.last_char_was_newline = false;
        },
        .table => {
            state.in_table = true;
            state.table_row_index = 0;
            state.table_col_count = 0;
        },
        .tr => {
            state.table_col_count = 0;
            try writer.writeByte('|');
        },
        .td, .th => {
            // Note: leading pipe handled by previous cell closing or tr opening
            state.last_char_was_newline = false;
            try writer.writeByte(' ');
        },
        .blockquote => {
            try writer.writeAll("> ");
            state.last_char_was_newline = false;
        },
        .pre => {
            try writer.writeAll("```\n");
            state.in_pre = true;
            state.pre_node = el.asNode();
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
        .s, .del => {
            try writer.writeAll("~~");
            state.last_char_was_newline = false;
        },
        .hr => {
            try writer.writeAll("---\n");
            state.last_char_was_newline = true;
            return; // Void element
        },
        .br => {
            if (state.in_table) {
                try writer.writeByte(' ');
            } else {
                try writer.writeByte('\n');
                state.last_char_was_newline = true;
            }
            return; // Void element
        },
        .img => {
            try writer.writeAll("![");
            if (el.getAttributeSafe(comptime .wrap("alt"))) |alt| {
                try escapeMarkdown(writer, alt);
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
            try renderChildren(el.asNode(), state, writer, page);
            try writer.writeAll("](");
            if (el.getAttributeSafe(comptime .wrap("href"))) |href| {
                try writer.writeAll(href);
            }
            try writer.writeByte(')');
            state.last_char_was_newline = false;
            return;
        },
        .input => {
            if (el.getAttributeSafe(comptime .wrap("type"))) |type_attr| {
                if (std.ascii.eqlIgnoreCase(type_attr, "checkbox")) {
                    if (el.getAttributeSafe(comptime .wrap("checked"))) |_| {
                        try writer.writeAll("[x] ");
                    } else {
                        try writer.writeAll("[ ] ");
                    }
                    state.last_char_was_newline = false;
                }
            }
            return;
        },
        else => {},
    }

    // --- Render Children ---
    try renderChildren(el.asNode(), state, writer, page);

    // --- Closing Tag Logic ---

    // Suffixes
    switch (tag) {
        .pre => {
            if (!state.last_char_was_newline) {
                try writer.writeByte('\n');
            }
            try writer.writeAll("```\n");
            state.in_pre = false;
            state.pre_node = null;
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
        .s, .del => {
            try writer.writeAll("~~");
            state.last_char_was_newline = false;
        },
        .blockquote => {},
        .ul, .ol => {
            if (state.list_depth > 0) state.list_depth -= 1;
        },
        .table => {
            state.in_table = false;
        },
        .tr => {
            try writer.writeByte('\n');
            if (state.table_row_index == 0) {
                try writer.writeByte('|');
                var i: usize = 0;
                while (i < state.table_col_count) : (i += 1) {
                    try writer.writeAll("---|");
                }
                try writer.writeByte('\n');
            }
            state.table_row_index += 1;
            state.last_char_was_newline = true;
        },
        .td, .th => {
            try writer.writeAll(" |");
            state.table_col_count += 1;
            state.last_char_was_newline = false;
        },
        else => {},
    }

    // Post-block newlines
    if (isBlock(tag)) {
        if (!state.in_table) {
            try ensureNewline(state, writer);
        }
    }
}

fn renderText(text: []const u8, state: *State, writer: *std.Io.Writer) !void {
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

    // Check for pure whitespace
    const is_all_whitespace = for (text) |c| {
        if (!std.ascii.isWhitespace(c)) break false;
    } else true;

    if (is_all_whitespace) {
        if (!state.last_char_was_newline) {
            try writer.writeByte(' ');
        }
        return;
    }

    // Collapse whitespace
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
    var first = true;
    while (it.next()) |word| {
        if (first) {
            if (!state.last_char_was_newline) {
                if (text.len > 0 and std.ascii.isWhitespace(text[0])) {
                    try writer.writeByte(' ');
                }
            }
        } else {
            try writer.writeByte(' ');
        }

        try escapeMarkdown(writer, word);
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

fn escapeMarkdown(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '!', '|' => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            else => try writer.writeByte(c),
        }
    }
}

fn testMarkdownHTML(html: []const u8, expected: []const u8) !void {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    const doc = page.window._document;

    const div = try doc.createElement("div", null, page);
    try page.parseHtmlAsChildren(div.asNode(), html);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    try testing.expectString(expected, aw.written());
}

test "markdown: basic" {
    try testMarkdownHTML("Hello world", "Hello world\n");
}

test "markdown: whitespace" {
    try testMarkdownHTML("<span>A</span> <span>B</span>", "A B\n");
}

test "markdown: escaping" {
    try testMarkdownHTML("<p># Not a header</p>", "\n\\# Not a header\n");
}

test "markdown: strikethrough" {
    try testMarkdownHTML("<s>deleted</s>", "~~deleted~~\n");
}

test "markdown: task list" {
    try testMarkdownHTML(
        \\<input type="checkbox" checked><input type="checkbox">
    , "[x] [ ] \n");
}

test "markdown: ordered list" {
    try testMarkdownHTML(
        \\<ol><li>First</li><li>Second</li></ol>
    , "1. First\n2. Second\n");
}

test "markdown: table" {
    try testMarkdownHTML(
        \\<table><thead><tr><th>Head 1</th><th>Head 2</th></tr></thead>
        \\<tbody><tr><td>Cell 1</td><td>Cell 2</td></tr></tbody></table>
    ,
        \\
        \\| Head 1 | Head 2 |
        \\|---|---|
        \\| Cell 1 | Cell 2 |
        \\
    );
}

test "markdown: nested lists" {
    try testMarkdownHTML(
        \\<ul><li>Parent<ul><li>Child</li></ul></li></ul>
    ,
        \\- Parent
        \\  - Child
        \\
    );
}

test "markdown: blockquote" {
    try testMarkdownHTML("<blockquote>Hello world</blockquote>", "\n> Hello world\n");
}

test "markdown: links" {
    try testMarkdownHTML("<a href=\"https://lightpanda.io\">Lightpanda</a>", "[Lightpanda](https://lightpanda.io)\n");
}

test "markdown: images" {
    try testMarkdownHTML("<img src=\"logo.png\" alt=\"Logo\">", "![Logo](logo.png)\n");
}

test "markdown: headings" {
    try testMarkdownHTML("<h1>Title</h1><h2>Subtitle</h2>",
        \\
        \\# Title
        \\
        \\## Subtitle
        \\
    );
}

test "markdown: code" {
    try testMarkdownHTML(
        \\<p>Use git push</p>
        \\<pre><code>line 1
        \\line 2</code></pre>
    ,
        \\
        \\Use git push
        \\
        \\```
        \\line 1
        \\line 2
        \\```
        \\
    );
}
