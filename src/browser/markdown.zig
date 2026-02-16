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
    const ListType = enum { ordered, unordered };
    const ListState = struct {
        type: ListType,
        index: usize,
    };

        list_depth: usize = 0,
        list_stack: [32]ListState = undefined,
        in_pre: bool = false,
        in_code: bool = false,
        in_blockquote: bool = false,
        in_table: bool = false,
        table_row_index: usize = 0,
        table_col_count: usize = 0,
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
                if (!state.in_table) {
                    if (!state.last_char_was_newline) {
                        try writer.writeByte('\n');
                        state.last_char_was_newline = true;
                    }
                    if (tag == .p or tag == .h1 or tag == .h2 or tag == .h3 or tag == .h4 or tag == .h5 or tag == .h6 or tag == .blockquote or tag == .pre or tag == .table) {
                        // Add an extra newline for spacing between blocks
                        try writer.writeByte('\n');
                    }
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
                try writeIndentation(indent, writer);
                
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
                // Add spacing
                try writer.writeByte(' ');
            },
            .blockquote => {            try writer.writeAll("> ");
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
            state.last_char_was_newline = false;
        },
        .input => {
            if (el.getAttributeSafe(comptime .wrap("type"))) |t| {
                if (std.mem.eql(u8, t, "checkbox")) {
                    if (el.hasAttributeSafe(comptime .wrap("checked"))) {
                        try writer.writeAll("[x] ");
                    } else {
                        try writer.writeAll("[ ] ");
                    }
                    state.last_char_was_newline = false;
                }
            }
            return; // Void element
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
        .s, .del => {
            try writer.writeAll("~~");
            state.last_char_was_newline = false;
        },
        .blockquote => {
            state.in_blockquote = false;
        },
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
    switch (tag) {
        .p, .div, .section, .article, .header, .footer, .nav, .aside, .h1, .h2, .h3, .h4, .h5, .h6, .ul, .ol, .blockquote, .table => {
            if (!state.in_table) {
                if (!state.last_char_was_newline) {
                    try writer.writeByte('\n');
                    state.last_char_was_newline = true;
                }
            }
        },
        .tr => {}, // Handled explicitly in closing tag logic
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
    // Escaping: \ ` * _ { } [ ] ( ) # + - . ! | < >
    for (text) |c| {
        switch (c) {
            '\\',
            '`',
            '*',
            '_',
            '{',
            '}',
            '[',
            ']',
            '(',
            ')',
            '#',
            '+',
            '-',
            '.',
            '!',
            '|',
            '<',
            '>',
            => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            else => try writer.writeByte(c),
        }
    }
}

fn writeIndentation(level: usize, writer: *std.Io.Writer) anyerror!void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll("  ");
    }
}

test "markdown: basic" {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    const doc = page.window._document;

    const div = try doc.createElement("div", null, page);
    try div.asNode().setTextContent("Hello world", page);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    try testing.expectString("Hello world\n", aw.written());
}

test "markdown: whitespace" {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    const doc = page.window._document;

    const div = try doc.createElement("div", null, page);

    const s1 = try doc.createElement("span", null, page);
    try s1.asNode().setTextContent("A", page);
    const s2 = try doc.createElement("span", null, page);
    try s2.asNode().setTextContent("B", page);

    _ = try div.asNode().appendChild(s1.asNode(), page);
    // Add text node with space
    const txt = try page.createTextNode(" ");
    _ = try div.asNode().appendChild(txt, page);
    _ = try div.asNode().appendChild(s2.asNode(), page);

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    try testing.expectString("A B\n", aw.written());
}

test "markdown: escaping" {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    const doc = page.window._document;

    const div = try doc.createElement("div", null, page);

    const p = try doc.createElement("p", null, page);
    try p.asNode().setTextContent("# Not a header", page);
    _ = try div.asNode().appendChild(p.asNode(), page);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    try testing.expectString("\n\\# Not a header\n", aw.written());
}

test "markdown: strikethrough" {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    const doc = page.window._document;

    const div = try doc.createElement("div", null, page);

    const s = try doc.createElement("s", null, page);
    try s.asNode().setTextContent("deleted", page);
    _ = try div.asNode().appendChild(s.asNode(), page);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    try testing.expectString("~~deleted~~\n", aw.written());
}

test "markdown: task list" {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    const doc = page.window._document;

    const div = try doc.createElement("div", null, page);

    const input1 = try doc.createElement("input", null, page);
    try input1.setAttributeSafe(comptime .wrap("type"), .wrap("checkbox"), page);
    try input1.setAttributeSafe(comptime .wrap("checked"), .wrap(""), page);
    _ = try div.asNode().appendChild(input1.asNode(), page);

    const input2 = try doc.createElement("input", null, page);
    try input2.setAttributeSafe(comptime .wrap("type"), .wrap("checkbox"), page);
    _ = try div.asNode().appendChild(input2.asNode(), page);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    try testing.expectString("[x] [ ] \n", aw.written());
}

test "markdown: ordered list" {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    const doc = page.window._document;

    const div = try doc.createElement("div", null, page);

    const ol = try doc.createElement("ol", null, page);
    _ = try div.asNode().appendChild(ol.asNode(), page);

    const li1 = try doc.createElement("li", null, page);
    try li1.asNode().setTextContent("First", page);
    _ = try ol.asNode().appendChild(li1.asNode(), page);

    const li2 = try doc.createElement("li", null, page);
    try li2.asNode().setTextContent("Second", page);
    _ = try ol.asNode().appendChild(li2.asNode(), page);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    try testing.expectString("1. First\n2. Second\n", aw.written());
}

test "markdown: table" {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    const doc = page.window._document;

    const div = try doc.createElement("div", null, page);

    const table = try doc.createElement("table", null, page);
    _ = try div.asNode().appendChild(table.asNode(), page);

    const thead = try doc.createElement("thead", null, page);
    _ = try table.asNode().appendChild(thead.asNode(), page);

    const tr1 = try doc.createElement("tr", null, page);
    _ = try thead.asNode().appendChild(tr1.asNode(), page);

    const th1 = try doc.createElement("th", null, page);
    try th1.asNode().setTextContent("Head 1", page);
    _ = try tr1.asNode().appendChild(th1.asNode(), page);

    const th2 = try doc.createElement("th", null, page);
    try th2.asNode().setTextContent("Head 2", page);
    _ = try tr1.asNode().appendChild(th2.asNode(), page);

    const tbody = try doc.createElement("tbody", null, page);
    _ = try table.asNode().appendChild(tbody.asNode(), page);

    const tr2 = try doc.createElement("tr", null, page);
    _ = try tbody.asNode().appendChild(tr2.asNode(), page);

    const td1 = try doc.createElement("td", null, page);
    try td1.asNode().setTextContent("Cell 1", page);
    _ = try tr2.asNode().appendChild(td1.asNode(), page);

    const td2 = try doc.createElement("td", null, page);
    try td2.asNode().setTextContent("Cell 2", page);
    _ = try tr2.asNode().appendChild(td2.asNode(), page);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    const expected =
        \\
        \\| Head 1 | Head 2 |
        \\|---|---|
        \\| Cell 1 | Cell 2 |
        \\
    ;
    try testing.expectString(expected, aw.written());
}
