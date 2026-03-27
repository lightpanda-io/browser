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
const URL = @import("URL.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");
const Element = @import("webapi/Element.zig");
const Node = @import("webapi/Node.zig");
const isAllWhitespace = @import("../string.zig").isAllWhitespace;

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
    pre_node: ?*Node = null,
    in_code: bool = false,
    in_table: bool = false,
    table_row_index: usize = 0,
    table_col_count: usize = 0,
    last_char_was_newline: bool = true,
};

fn shouldAddSpacing(tag: Element.Tag) bool {
    return switch (tag) {
        .p, .h1, .h2, .h3, .h4, .h5, .h6, .blockquote, .pre, .table => true,
        else => false,
    };
}

fn isLayoutBlock(tag: Element.Tag) bool {
    return switch (tag) {
        .main, .section, .article, .nav, .aside, .header, .footer, .div, .ul, .ol => true,
        else => false,
    };
}

fn isStandaloneAnchor(el: *Element) bool {
    const node = el.asNode();
    const parent = node.parentNode() orelse return false;
    const parent_el = parent.is(Element) orelse return false;

    if (!isLayoutBlock(parent_el.getTag())) return false;

    var prev = node.previousSibling();
    while (prev) |p| : (prev = p.previousSibling()) {
        if (isSignificantText(p)) return false;
        if (p.is(Element)) |pe| {
            if (isVisibleElement(pe)) break;
        }
    }

    var next = node.nextSibling();
    while (next) |n| : (next = n.nextSibling()) {
        if (isSignificantText(n)) return false;
        if (n.is(Element)) |ne| {
            if (isVisibleElement(ne)) break;
        }
    }

    return true;
}

fn isSignificantText(node: *Node) bool {
    const text = node.is(Node.CData.Text) orelse return false;
    return !isAllWhitespace(text.getWholeText());
}

fn isVisibleElement(el: *Element) bool {
    const tag = el.getTag();
    return !tag.isMetadata() and tag != .svg;
}

fn getAnchorLabel(el: *Element) ?[]const u8 {
    return el.getAttributeSafe(comptime .wrap("aria-label")) orelse el.getAttributeSafe(comptime .wrap("title"));
}

fn hasBlockDescendant(root: *Node) bool {
    var tw = TreeWalker.FullExcludeSelf.Elements.init(root, .{});
    while (tw.next()) |el| {
        if (el.getTag().isBlock()) return true;
    }
    return false;
}

fn hasVisibleContent(root: *Node) bool {
    var tw = TreeWalker.FullExcludeSelf.init(root, .{});
    while (tw.next()) |node| {
        if (isSignificantText(node)) return true;
        if (node.is(Element)) |el| {
            if (!isVisibleElement(el)) {
                tw.skipChildren();
            } else if (el.getTag() == .img) {
                return true;
            }
        }
    }
    return false;
}

const Context = struct {
    state: State,
    writer: *std.Io.Writer,
    page: *Page,

    fn ensureNewline(self: *Context) !void {
        if (!self.state.last_char_was_newline) {
            try self.writer.writeByte('\n');
            self.state.last_char_was_newline = true;
        }
    }

    fn render(self: *Context, node: *Node) error{WriteFailed}!void {
        switch (node._type) {
            .document, .document_fragment => {
                try self.renderChildren(node);
            },
            .element => |el| {
                try self.renderElement(el);
            },
            .cdata => |cd| {
                if (node.is(Node.CData.Text)) |_| {
                    var text = cd.getData().str();
                    if (self.state.pre_node) |pre| {
                        if (node.parentNode() == pre and node.nextSibling() == null) {
                            text = std.mem.trimRight(u8, text, " \t\r\n");
                        }
                    }
                    try self.renderText(text);
                }
            },
            else => {},
        }
    }

    fn renderChildren(self: *Context, parent: *Node) !void {
        var it = parent.childrenIterator();
        while (it.next()) |child| {
            try self.render(child);
        }
    }

    fn renderElement(self: *Context, el: *Element) !void {
        const tag = el.getTag();

        if (!isVisibleElement(el)) return;

        // --- Opening Tag Logic ---

        // Ensure block elements start on a new line (double newline for paragraphs etc)
        if (tag.isBlock() and !self.state.in_table) {
            try self.ensureNewline();
            if (shouldAddSpacing(tag)) {
                try self.writer.writeByte('\n');
            }
        } else if (tag == .li or tag == .tr) {
            try self.ensureNewline();
        }

        // Prefixes
        switch (tag) {
            .h1 => try self.writer.writeAll("# "),
            .h2 => try self.writer.writeAll("## "),
            .h3 => try self.writer.writeAll("### "),
            .h4 => try self.writer.writeAll("#### "),
            .h5 => try self.writer.writeAll("##### "),
            .h6 => try self.writer.writeAll("###### "),
            .ul => {
                if (self.state.list_depth < self.state.list_stack.len) {
                    self.state.list_stack[self.state.list_depth] = .{ .type = .unordered, .index = 0 };
                    self.state.list_depth += 1;
                }
            },
            .ol => {
                if (self.state.list_depth < self.state.list_stack.len) {
                    self.state.list_stack[self.state.list_depth] = .{ .type = .ordered, .index = 1 };
                    self.state.list_depth += 1;
                }
            },
            .li => {
                const indent = if (self.state.list_depth > 0) self.state.list_depth - 1 else 0;
                for (0..indent) |_| try self.writer.writeAll("  ");

                if (self.state.list_depth > 0 and self.state.list_stack[self.state.list_depth - 1].type == .ordered) {
                    const current_list = &self.state.list_stack[self.state.list_depth - 1];
                    try self.writer.print("{d}. ", .{current_list.index});
                    current_list.index += 1;
                } else {
                    try self.writer.writeAll("- ");
                }
                self.state.last_char_was_newline = false;
            },
            .table => {
                self.state.in_table = true;
                self.state.table_row_index = 0;
                self.state.table_col_count = 0;
            },
            .tr => {
                self.state.table_col_count = 0;
                try self.writer.writeByte('|');
            },
            .td, .th => {
                // Note: leading pipe handled by previous cell closing or tr opening
                self.state.last_char_was_newline = false;
                try self.writer.writeByte(' ');
            },
            .blockquote => {
                try self.writer.writeAll("> ");
                self.state.last_char_was_newline = false;
            },
            .pre => {
                try self.writer.writeAll("```\n");
                self.state.pre_node = el.asNode();
                self.state.last_char_was_newline = true;
            },
            .code => {
                if (self.state.pre_node == null) {
                    try self.writer.writeByte('`');
                    self.state.in_code = true;
                    self.state.last_char_was_newline = false;
                }
            },
            .b, .strong => {
                try self.writer.writeAll("**");
                self.state.last_char_was_newline = false;
            },
            .i, .em => {
                try self.writer.writeAll("*");
                self.state.last_char_was_newline = false;
            },
            .s, .del => {
                try self.writer.writeAll("~~");
                self.state.last_char_was_newline = false;
            },
            .hr => {
                try self.writer.writeAll("---\n");
                self.state.last_char_was_newline = true;
                return;
            },
            .br => {
                if (self.state.in_table) {
                    try self.writer.writeByte(' ');
                } else {
                    try self.writer.writeByte('\n');
                    self.state.last_char_was_newline = true;
                }
                return;
            },
            .img => {
                try self.writer.writeAll("![");
                if (el.getAttributeSafe(comptime .wrap("alt"))) |alt| {
                    try self.escape(alt);
                }
                try self.writer.writeAll("](");
                if (el.getAttributeSafe(comptime .wrap("src"))) |src| {
                    const absolute_src = URL.resolve(self.page.call_arena, self.page.base(), src, .{ .encode = true }) catch src;
                    try self.writer.writeAll(absolute_src);
                }
                try self.writer.writeAll(")");
                self.state.last_char_was_newline = false;
                return;
            },
            .anchor => {
                const has_content = hasVisibleContent(el.asNode());
                const label = getAnchorLabel(el);
                const href_raw = el.getAttributeSafe(comptime .wrap("href"));

                if (!has_content and label == null and href_raw == null) return;

                const has_block = hasBlockDescendant(el.asNode());
                const href = if (href_raw) |h| URL.resolve(self.page.call_arena, self.page.base(), h, .{ .encode = true }) catch h else null;

                if (has_block) {
                    try self.renderChildren(el.asNode());
                    if (href) |h| {
                        if (!self.state.last_char_was_newline) try self.writer.writeByte('\n');
                        try self.writer.writeAll("([](");
                        try self.writer.writeAll(h);
                        try self.writer.writeAll("))\n");
                        self.state.last_char_was_newline = true;
                    }
                    return;
                }

                if (isStandaloneAnchor(el)) {
                    if (!self.state.last_char_was_newline) try self.writer.writeByte('\n');
                    try self.writer.writeByte('[');
                    if (has_content) {
                        try self.renderChildren(el.asNode());
                    } else {
                        try self.writer.writeAll(label orelse "");
                    }
                    try self.writer.writeAll("](");
                    if (href) |h| {
                        try self.writer.writeAll(h);
                    }
                    try self.writer.writeAll(")\n");
                    self.state.last_char_was_newline = true;
                    return;
                }

                try self.writer.writeByte('[');
                if (has_content) {
                    try self.renderChildren(el.asNode());
                } else {
                    try self.writer.writeAll(label orelse "");
                }
                try self.writer.writeAll("](");
                if (href) |h| {
                    try self.writer.writeAll(h);
                }
                try self.writer.writeByte(')');
                self.state.last_char_was_newline = false;
                return;
            },
            .input => {
                const type_attr = el.getAttributeSafe(comptime .wrap("type")) orelse return;
                if (std.ascii.eqlIgnoreCase(type_attr, "checkbox")) {
                    const checked = el.getAttributeSafe(comptime .wrap("checked")) != null;
                    try self.writer.writeAll(if (checked) "[x] " else "[ ] ");
                    self.state.last_char_was_newline = false;
                }
                return;
            },
            else => {},
        }

        // --- Render Children ---
        try self.renderChildren(el.asNode());

        // --- Closing Tag Logic ---

        // Suffixes
        switch (tag) {
            .pre => {
                if (!self.state.last_char_was_newline) {
                    try self.writer.writeByte('\n');
                }
                try self.writer.writeAll("```\n");
                self.state.pre_node = null;
                self.state.last_char_was_newline = true;
            },
            .code => {
                if (self.state.pre_node == null) {
                    try self.writer.writeByte('`');
                    self.state.in_code = false;
                    self.state.last_char_was_newline = false;
                }
            },
            .b, .strong => {
                try self.writer.writeAll("**");
                self.state.last_char_was_newline = false;
            },
            .i, .em => {
                try self.writer.writeAll("*");
                self.state.last_char_was_newline = false;
            },
            .s, .del => {
                try self.writer.writeAll("~~");
                self.state.last_char_was_newline = false;
            },
            .blockquote => {},
            .ul, .ol => {
                if (self.state.list_depth > 0) self.state.list_depth -= 1;
            },
            .table => {
                self.state.in_table = false;
            },
            .tr => {
                try self.writer.writeByte('\n');
                if (self.state.table_row_index == 0) {
                    try self.writer.writeByte('|');
                    for (0..self.state.table_col_count) |_| {
                        try self.writer.writeAll("---|");
                    }
                    try self.writer.writeByte('\n');
                }
                self.state.table_row_index += 1;
                self.state.last_char_was_newline = true;
            },
            .td, .th => {
                try self.writer.writeAll(" |");
                self.state.table_col_count += 1;
                self.state.last_char_was_newline = false;
            },
            else => {},
        }

        // Post-block newlines
        if (tag.isBlock() and !self.state.in_table) {
            try self.ensureNewline();
        }
    }

    fn renderText(self: *Context, text: []const u8) !void {
        if (text.len == 0) return;

        if (self.state.pre_node) |_| {
            try self.writer.writeAll(text);
            self.state.last_char_was_newline = text[text.len - 1] == '\n';
            return;
        }

        // Check for pure whitespace
        if (isAllWhitespace(text)) {
            if (!self.state.last_char_was_newline) {
                try self.writer.writeByte(' ');
            }
            return;
        }

        // Collapse whitespace
        var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
        var first = true;
        while (it.next()) |word| {
            if (!first or (!self.state.last_char_was_newline and std.ascii.isWhitespace(text[0]))) {
                try self.writer.writeByte(' ');
            }

            try self.escape(word);
            self.state.last_char_was_newline = false;
            first = false;
        }

        // Handle trailing whitespace from the original text
        if (!first and !self.state.last_char_was_newline and std.ascii.isWhitespace(text[text.len - 1])) {
            try self.writer.writeByte(' ');
        }
    }

    fn escape(self: *Context, text: []const u8) !void {
        for (text) |c| {
            switch (c) {
                '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '!', '|' => {
                    try self.writer.writeByte('\\');
                    try self.writer.writeByte(c);
                },
                else => try self.writer.writeByte(c),
            }
        }
    }
};

pub fn dump(node: *Node, opts: Opts, writer: *std.Io.Writer, page: *Page) !void {
    _ = opts;
    var ctx: Context = .{
        .state = .{},
        .writer = writer,
        .page = page,
    };
    try ctx.render(node);
    if (!ctx.state.last_char_was_newline) {
        try writer.writeByte('\n');
    }
}

fn testMarkdownHTML(html: []const u8, expected: []const u8) !void {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    page.url = "http://localhost/";

    const doc = page.window._document;

    const div = try doc.createElement("div", null, page);
    try page.parseHtmlAsChildren(div.asNode(), html);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    try testing.expectString(expected, aw.written());
}

test "browser.markdown: basic" {
    try testMarkdownHTML("Hello world", "Hello world\n");
}

test "browser.markdown: whitespace" {
    try testMarkdownHTML("<span>A</span> <span>B</span>", "A B\n");
}

test "browser.markdown: escaping" {
    try testMarkdownHTML("<p># Not a header</p>", "\n\\# Not a header\n");
}

test "browser.markdown: strikethrough" {
    try testMarkdownHTML("<s>deleted</s>", "~~deleted~~\n");
}

test "browser.markdown: task list" {
    try testMarkdownHTML(
        \\<input type="checkbox" checked><input type="checkbox">
    , "[x] [ ] \n");
}

test "browser.markdown: ordered list" {
    try testMarkdownHTML(
        \\<ol><li>First</li><li>Second</li></ol>
    , "1. First\n2. Second\n");
}

test "browser.markdown: table" {
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

test "browser.markdown: nested lists" {
    try testMarkdownHTML(
        \\<ul><li>Parent<ul><li>Child</li></ul></li></ul>
    ,
        \\- Parent
        \\  - Child
        \\
    );
}

test "browser.markdown: blockquote" {
    try testMarkdownHTML("<blockquote>Hello world</blockquote>", "\n> Hello world\n");
}

test "browser.markdown: links" {
    try testMarkdownHTML("<a href=\"/relative\">Link</a>", "[Link](http://localhost/relative)\n");
}

test "browser.markdown: images" {
    try testMarkdownHTML("<img src=\"logo.png\" alt=\"Logo\">", "![Logo](http://localhost/logo.png)\n");
}

test "browser.markdown: headings" {
    try testMarkdownHTML("<h1>Title</h1><h2>Subtitle</h2>",
        \\
        \\# Title
        \\
        \\## Subtitle
        \\
    );
}

test "browser.markdown: code" {
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

test "browser.markdown: block link" {
    try testMarkdownHTML(
        \\<a href="https://example.com">
        \\  <h3>Title</h3>
        \\  <p>Description</p>
        \\</a>
    ,
        \\
        \\### Title
        \\
        \\Description
        \\([](https://example.com))
        \\
    );
}

test "browser.markdown: inline link" {
    try testMarkdownHTML(
        \\<p>Visit <a href="https://example.com">Example</a>.</p>
    ,
        \\
        \\Visit [Example](https://example.com).
        \\
    );
}

test "browser.markdown: standalone anchors" {
    // Inside main, with whitespace between anchors -> treated as blocks
    try testMarkdownHTML(
        \\<main>
        \\  <a href="1">Link 1</a>
        \\  <a href="2">Link 2</a>
        \\</main>
    ,
        \\[Link 1](http://localhost/1)
        \\[Link 2](http://localhost/2)
        \\
    );
}

test "browser.markdown: mixed anchors in main" {
    // Anchors surrounded by text should remain inline
    try testMarkdownHTML(
        \\<main>
        \\  Welcome <a href="1">Link 1</a>.
        \\</main>
    ,
        \\Welcome [Link 1](http://localhost/1). 
        \\
    );
}

test "browser.markdown: skip empty links" {
    try testMarkdownHTML(
        \\<a href="/"></a>
        \\<a href="/"><svg></svg></a>
    ,
        \\[](http://localhost/)
        \\[](http://localhost/)
        \\
    );
}

test "browser.markdown: resolve links" {
    const testing = @import("../testing.zig");
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();
    page.url = "https://example.com/a/index.html";

    const doc = page.window._document;
    const div = try doc.createElement("div", null, page);
    try page.parseHtmlAsChildren(div.asNode(),
        \\<a href="b">Link</a>
        \\<img src="../c.png" alt="Img">
        \\<a href="/my page">Space</a>
    );

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dump(div.asNode(), .{}, &aw.writer, page);

    try testing.expectString(
        \\[Link](https://example.com/a/b)
        \\![Img](https://example.com/c.png) 
        \\[Space](https://example.com/my%20page)
        \\
    , aw.written());
}

test "browser.markdown: anchor fallback label" {
    try testMarkdownHTML(
        \\<a href="/discord" aria-label="Discord Server"><svg></svg></a>
    , "[Discord Server](http://localhost/discord)\n");

    try testMarkdownHTML(
        \\<a href="/search" title="Search Site"><svg></svg></a>
    , "[Search Site](http://localhost/search)\n");

    try testMarkdownHTML(
        \\<a href="/no-label"><svg></svg></a>
    , "[](http://localhost/no-label)\n");
}
