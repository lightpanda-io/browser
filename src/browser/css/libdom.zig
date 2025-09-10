// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const parser = @import("../netsurf.zig");
const css = @import("css.zig");
const Allocator = std.mem.Allocator;

// Node implementation with Netsurf Libdom C lib.
pub const Node = struct {
    node: *parser.Node,

    pub fn firstChild(n: Node) !?Node {
        const c = try parser.nodeFirstChild(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn lastChild(n: Node) !?Node {
        const c = try parser.nodeLastChild(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn nextSibling(n: Node) !?Node {
        const c = try parser.nodeNextSibling(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn prevSibling(n: Node) !?Node {
        const c = try parser.nodePreviousSibling(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn parent(n: Node) !?Node {
        const c = try parser.nodeParentNode(n.node);
        if (c) |cc| return .{ .node = cc };

        return null;
    }

    pub fn isElement(n: Node) bool {
        const t = parser.nodeType(n.node) catch return false;
        return t == .element;
    }

    pub fn isDocument(n: Node) bool {
        const t = parser.nodeType(n.node) catch return false;
        return t == .document;
    }

    pub fn isComment(n: Node) bool {
        const t = parser.nodeType(n.node) catch return false;
        return t == .comment;
    }

    pub fn isText(n: Node) bool {
        const t = parser.nodeType(n.node) catch return false;
        return t == .text;
    }

    pub fn text(n: Node) !?[]const u8 {
        const data = try parser.nodeTextContent(n.node);
        if (data == null) return null;
        if (data.?.len == 0) return null;

        return std.mem.trim(u8, data.?, &std.ascii.whitespace);
    }

    pub fn isEmptyText(n: Node) !bool {
        const data = try parser.nodeTextContent(n.node);
        if (data == null) return true;
        if (data.?.len == 0) return true;

        return std.mem.trim(u8, data.?, &std.ascii.whitespace).len == 0;
    }

    pub fn tag(n: Node) ![]const u8 {
        return try parser.nodeName(n.node);
    }

    pub fn attr(n: Node, key: []const u8) !?[]const u8 {
        if (!n.isElement()) return null;
        return try parser.elementGetAttribute(parser.nodeToElement(n.node), key);
    }

    pub fn eql(a: Node, b: Node) bool {
        return a.node == b.node;
    }
};

const MatcherTest = struct {
    const Nodes = std.ArrayListUnmanaged(Node);

    nodes: Nodes,
    allocator: Allocator,

    fn init(allocator: Allocator) MatcherTest {
        return .{
            .nodes = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(m: *MatcherTest) void {
        m.nodes.deinit(m.allocator);
    }

    fn reset(m: *MatcherTest) void {
        m.nodes.clearRetainingCapacity();
    }

    pub fn match(m: *MatcherTest, n: Node) !void {
        try m.nodes.append(m.allocator, n);
    }
};

test "Browser.CSS.Libdom: matchFirst" {
    const alloc = std.testing.allocator;

    try parser.init();
    defer parser.deinit();

    var matcher = MatcherTest.init(alloc);
    defer matcher.deinit();

    const testcases = [_]struct {
        q: []const u8,
        html: []const u8,
        exp: usize,
    }{
        .{ .q = "address", .html = "<body><address>This address...</address></body>", .exp = 1 },
        .{ .q = "*", .html = "<!-- comment --><html><head></head><body>text</body></html>", .exp = 1 },
        .{ .q = "*", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "#foo", .html = "<p id=\"foo\"><p id=\"bar\">", .exp = 1 },
        .{ .q = "li#t1", .html = "<ul><li id=\"t1\"><p id=\"t1\">", .exp = 1 },
        .{ .q = ".t3", .html = "<ul><li class=\"t1\"><li class=\"t2 t3\">", .exp = 1 },
        .{ .q = "*#t4", .html = "<ol><li id=\"t4\"><li id=\"t44\">", .exp = 1 },
        .{ .q = ".t1", .html = "<ul><li class=\"t1\"><li class=\"t2\">", .exp = 1 },
        .{ .q = "p.t1", .html = "<p class=\"t1 t2\">", .exp = 1 },
        .{ .q = "div.teST", .html = "<div class=\"test\">", .exp = 0 },
        .{ .q = ".t1.fail", .html = "<p class=\"t1 t2\">", .exp = 0 },
        .{ .q = "p.t1.t2", .html = "<p class=\"t1 t2\">", .exp = 1 },
        .{ .q = "p.--t1", .html = "<p class=\"--t1 --t2\">", .exp = 1 },
        .{ .q = "p.--t1.--t2", .html = "<p class=\"--t1 --t2\">", .exp = 1 },
        .{ .q = "p[title]", .html = "<p><p title=\"title\">", .exp = 1 },
        .{ .q = "div[class=\"red\" i]", .html = "<div><div class=\"Red\">", .exp = 1 },
        .{ .q = "address[title=\"foo\"]", .html = "<address><address title=\"foo\"><address title=\"bar\">", .exp = 1 },
        .{ .q = "address[title=\"FoOIgnoRECaSe\" i]", .html = "<address><address title=\"fooIgnoreCase\"><address title=\"bar\">", .exp = 1 },
        .{ .q = "address[title!=\"foo\"]", .html = "<address><address title=\"foo\"><address title=\"bar\">", .exp = 1 },
        .{ .q = "address[title!=\"foo\" i]", .html = "<address><address title=\"FOO\"><address title=\"bar\">", .exp = 1 },
        .{ .q = "p[title!=\"FooBarUFoo\" i]", .html = "<p title=\"fooBARuFOO\"><p title=\"varfoo\">", .exp = 1 },
        .{ .q = "[   title        ~=       foo    ]", .html = "<p title=\"tot foo bar\">", .exp = 1 },
        .{ .q = "p[title~=\"FOO\" i]", .html = "<p title=\"tot foo bar\">", .exp = 1 },
        .{ .q = "p[title~=toofoo i]", .html = "<p title=\"tot foo bar\">", .exp = 0 },
        .{ .q = "[title~=\"hello world\"]", .html = "<p title=\"hello world\">", .exp = 0 },
        .{ .q = "[title~=\"hello\" i]", .html = "<p title=\"HELLO world\">", .exp = 1 },
        .{ .q = "[title~=\"hello\"          I]", .html = "<p title=\"HELLO world\">", .exp = 1 },
        .{ .q = "[lang|=\"en\"]", .html = "<p lang=\"en\"><p lang=\"en-gb\"><p lang=\"enough\"><p lang=\"fr-en\">", .exp = 1 },
        .{ .q = "[lang|=\"EN\" i]", .html = "<p lang=\"en\"><p lang=\"En-gb\"><p lang=\"enough\"><p lang=\"fr-en\">", .exp = 1 },
        .{ .q = "[lang|=\"EN\"     i]", .html = "<p lang=\"en\"><p lang=\"En-gb\"><p lang=\"enough\"><p lang=\"fr-en\">", .exp = 1 },
        .{ .q = "[title^=\"foo\"]", .html = "<p title=\"foobar\"><p title=\"barfoo\">", .exp = 1 },
        .{ .q = "[title^=\"foo\" i]", .html = "<p title=\"FooBAR\"><p title=\"barfoo\">", .exp = 1 },
        .{ .q = "[title$=\"bar\"]", .html = "<p title=\"foobar\"><p title=\"barfoo\">", .exp = 1 },
        .{ .q = "[title$=\"BAR\" i]", .html = "<p title=\"foobar\"><p title=\"barfoo\">", .exp = 1 },
        .{ .q = "[title*=\"bar\"]", .html = "<p title=\"foobarufoo\">", .exp = 1 },
        .{ .q = "[title*=\"BaRu\" i]", .html = "<p title=\"foobarufoo\">", .exp = 1 },
        .{ .q = "[title*=\"BaRu\" I]", .html = "<p title=\"foobarufoo\">", .exp = 1 },
        .{ .q = "p[class$=\" \"]", .html = "<p class=\" \">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class$=\"\"]", .html = "<p class=\"\">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class^=\" \"]", .html = "<p class=\" \">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class^=\"\"]", .html = "<p class=\"\">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class*=\" \"]", .html = "<p class=\" \">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class*=\"\"]", .html = "<p class=\"\">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "input[name=Sex][value=F]", .html = "<input type=\"radio\" name=\"Sex\" value=\"F\"/>", .exp = 1 },
        .{ .q = "table[border=\"0\"][cellpadding=\"0\"][cellspacing=\"0\"]", .html = "<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" style=\"table-layout: fixed; width: 100%; border: 0 dashed; border-color: #FFFFFF\"><tr style=\"height:64px\">aaa</tr></table>", .exp = 1 },
        .{ .q = ".t1:not(.t2)", .html = "<p class=\"t1 t2\">", .exp = 0 },
        .{ .q = "div:not(.t1)", .html = "<div class=\"t3\">", .exp = 1 },
        .{ .q = "div:not([class=\"t2\"])", .html = "<div><div class=\"t2\"><div class=\"t3\">", .exp = 1 },
        .{ .q = "li:nth-child(odd)", .html = "<ol><li id=1><li id=2><li id=3></ol>", .exp = 1 },
        .{ .q = "li:nth-child(even)", .html = "<ol><li id=1><li id=2><li id=3></ol>", .exp = 1 },
        .{ .q = "li:nth-child(-n+2)", .html = "<ol><li id=1><li id=2><li id=3></ol>", .exp = 1 },
        .{ .q = "li:nth-child(3n+1)", .html = "<ol><li id=1><li id=2><li id=3></ol>", .exp = 1 },
        .{ .q = "li:nth-last-child(odd)", .html = "<ol><li id=1><li id=2><li id=3><li id=4></ol>", .exp = 1 },
        .{ .q = "li:nth-last-child(even)", .html = "<ol><li id=1><li id=2><li id=3><li id=4></ol>", .exp = 1 },
        .{ .q = "li:nth-last-child(-n+2)", .html = "<ol><li id=1><li id=2><li id=3><li id=4></ol>", .exp = 1 },
        .{ .q = "li:nth-last-child(3n+1)", .html = "<ol><li id=1><li id=2><li id=3><li id=4></ol>", .exp = 1 },
        .{ .q = "span:first-child", .html = "<p>some text <span id=\"1\">and a span</span><span id=\"2\"> and another</span></p>", .exp = 1 },
        .{ .q = "span:last-child", .html = "<span>a span</span> and some text", .exp = 1 },
        .{ .q = "p:nth-of-type(2)", .html = "<address></address><p id=1><p id=2>", .exp = 1 },
        .{ .q = "p:nth-last-of-type(2)", .html = "<address></address><p id=1><p id=2></p><a>", .exp = 1 },
        .{ .q = "p:last-of-type", .html = "<address></address><p id=1><p id=2></p><a>", .exp = 1 },
        .{ .q = "p:first-of-type", .html = "<address></address><p id=1><p id=2></p><a>", .exp = 1 },
        .{ .q = "p:only-child", .html = "<div><p id=\"1\"></p><a></a></div><div><p id=\"2\"></p></div>", .exp = 1 },
        .{ .q = "p:only-of-type", .html = "<div><p id=\"1\"></p><a></a></div><div><p id=\"2\"></p><p id=\"3\"></p></div>", .exp = 1 },
        .{ .q = ":empty", .html = "<p id=\"1\"><!-- --><p id=\"2\">Hello<p id=\"3\"><span>", .exp = 1 },
        .{ .q = "div p", .html = "<div><p id=\"1\"><table><tr><td><p id=\"2\"></table></div><p id=\"3\">", .exp = 1 },
        .{ .q = "div table p", .html = "<div><p id=\"1\"><table><tr><td><p id=\"2\"></table></div><p id=\"3\">", .exp = 1 },
        .{ .q = "div > p", .html = "<div><p id=\"1\"><div><p id=\"2\"></div><table><tr><td><p id=\"3\"></table></div>", .exp = 1 },
        .{ .q = "p ~ p", .html = "<p id=\"1\"><p id=\"2\"></p><address></address><p id=\"3\">", .exp = 1 },
        .{ .q = "p + p", .html = "<p id=\"1\"></p> <!--comment--> <p id=\"2\"></p><address></address><p id=\"3\">", .exp = 1 },
        .{ .q = "li, p", .html = "<ul><li></li><li></li></ul><p>", .exp = 1 },
        .{ .q = "p +/*This is a comment*/ p", .html = "<p id=\"1\"><p id=\"2\"></p><address></address><p id=\"3\">", .exp = 1 },
        // .{ .q = "p:contains(\"that wraps\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 1 },
        .{ .q = "p:containsOwn(\"that wraps\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 0 },
        .{ .q = ":containsOwn(\"inner\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 1 },
        .{ .q = ":containsOwn(\"Inner\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 0 },
        .{ .q = "p:containsOwn(\"block\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 1 },
        // .{ .q = "div:has(#p1)", .html = "<div id=\"d1\"><p id=\"p1\"><span>text content</span></p></div><div id=\"d2\"/>", .exp = 1 },
        .{ .q = "div:has(:containsOwn(\"2\"))", .html = "<div id=\"d1\"><p id=\"p1\"><span>contents 1</span></p></div> <div id=\"d2\"><p>contents <em>2</em></p></div>", .exp = 1 },
        .{ .q = "body :has(:containsOwn(\"2\"))", .html = "<body><div id=\"d1\"><p id=\"p1\"><span>contents 1</span></p></div> <div id=\"d2\"><p id=\"p2\">contents <em>2</em></p></div></body>", .exp = 1 },
        .{ .q = "body :haschild(:containsOwn(\"2\"))", .html = "<body><div id=\"d1\"><p id=\"p1\"><span>contents 1</span></p></div> <div id=\"d2\"><p id=\"p2\">contents <em>2</em></p></div></body>", .exp = 1 },
        // .{ .q = "p:matches([\\d])", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 1 },
        // .{ .q = "p:matches([a-z])", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 1 },
        // .{ .q = "p:matches([a-zA-Z])", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 1 },
        // .{ .q = "p:matches([^\\d])", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 1 },
        // .{ .q = "p:matches(^(0|a))", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 1 },
        // .{ .q = "p:matches(^\\d+$)", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 1 },
        // .{ .q = "p:not(:matches(^\\d+$))", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 1 },
        // .{ .q = "div :matchesOwn(^\\d+$)", .html = "<div><p id=\"p1\">01234<em>567</em>89</p><div>", .exp = 1 },
        // .{ .q = "[href#=(fina)]:not([href#=(\\/\\/[^\\/]+untrusted)])", .html = "<ul> <li><a id=\"a1\" href=\"http://www.google.com/finance\"></a> <li><a id=\"a2\" href=\"http://finance.yahoo.com/\"></a> <li><a id=\"a2\" href=\"http://finance.untrusted.com/\"/> <li><a id=\"a3\" href=\"https://www.google.com/news\"/> <li><a id=\"a4\" href=\"http://news.yahoo.com\"/> </ul>", .exp = 1 },
        // .{ .q = "[href#=(^https:\\/\\/[^\\/]*\\/?news)]", .html = "<ul> <li><a id=\"a1\" href=\"http://www.google.com/finance\"/> <li><a id=\"a2\" href=\"http://finance.yahoo.com/\"/> <li><a id=\"a3\" href=\"https://www.google.com/news\"></a> <li><a id=\"a4\" href=\"http://news.yahoo.com\"/> </ul>", .exp = 1 },
        .{ .q = ":input", .html = "<form> <label>Username <input type=\"text\" name=\"username\" /></label> <label>Password <input type=\"password\" name=\"password\" /></label> <label>Country <select name=\"country\"> <option value=\"ca\">Canada</option> <option value=\"us\">United States</option> </select> </label> <label>Bio <textarea name=\"bio\"></textarea></label> <button>Sign up</button> </form>", .exp = 1 },
        .{ .q = ":root", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "*:root", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "html:nth-child(1)", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "*:root:first-child", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "*:root:nth-child(1)", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "a:not(:root)", .html = "<html><head></head><body><a href=\"http://www.foo.com\"></a></body></html>", .exp = 1 },
        .{ .q = "body > *:nth-child(3n+2)", .html = "<html><head></head><body><p></p><div></div><span></span><a></a><form></form></body></html>", .exp = 1 },
        .{ .q = "input:disabled", .html = "<html><head></head><body><fieldset disabled><legend id=\"1\"><input id=\"i1\"/></legend><legend id=\"2\"><input id=\"i2\"/></legend></fieldset></body></html>", .exp = 1 },
        .{ .q = ":disabled", .html = "<html><head></head><body><fieldset disabled></fieldset></body></html>", .exp = 1 },
        .{ .q = ":enabled", .html = "<html><head></head><body><fieldset></fieldset></body></html>", .exp = 1 },
        .{ .q = "div.class1, div.class2", .html = "<div class=class1></div><div class=class2></div><div class=class3></div>", .exp = 1 },
    };

    for (testcases) |tc| {
        matcher.reset();

        const doc = try parser.documentHTMLParseFromStr(tc.html);
        defer parser.documentHTMLClose(doc) catch {};

        const s = css.parse(alloc, tc.q, .{}) catch |e| {
            std.debug.print("parse, query: {s}\n", .{tc.q});
            return e;
        };

        defer s.deinit(alloc);

        const node = Node{ .node = parser.documentHTMLToNode(doc) };

        _ = css.matchFirst(&s, node, &matcher) catch |e| {
            std.debug.print("match, query: {s}\n", .{tc.q});
            return e;
        };
        std.testing.expectEqual(tc.exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("expectation, query: {s}\n", .{tc.q});
            return e;
        };
    }
}

test "Browser.CSS.Libdom: matchAll" {
    const alloc = std.testing.allocator;

    try parser.init();
    defer parser.deinit();

    var matcher = MatcherTest.init(alloc);
    defer matcher.deinit();

    const testcases = [_]struct {
        q: []const u8,
        html: []const u8,
        exp: usize,
    }{
        .{ .q = "address", .html = "<body><address>This address...</address></body>", .exp = 1 },
        .{ .q = "*", .html = "<!-- comment --><html><head></head><body>text</body></html>", .exp = 3 },
        .{ .q = "*", .html = "<html><head></head><body></body></html>", .exp = 3 },
        .{ .q = "#foo", .html = "<p id=\"foo\"><p id=\"bar\">", .exp = 1 },
        .{ .q = "li#t1", .html = "<ul><li id=\"t1\"><p id=\"t1\">", .exp = 1 },
        .{ .q = ".t3", .html = "<ul><li class=\"t1\"><li class=\"t2 t3\">", .exp = 1 },
        .{ .q = "*#t4", .html = "<ol><li id=\"t4\"><li id=\"t44\">", .exp = 1 },
        .{ .q = ".t1", .html = "<ul><li class=\"t1\"><li class=\"t2\">", .exp = 1 },
        .{ .q = "p.t1", .html = "<p class=\"t1 t2\">", .exp = 1 },
        .{ .q = "div.teST", .html = "<div class=\"test\">", .exp = 0 },
        .{ .q = ".t1.fail", .html = "<p class=\"t1 t2\">", .exp = 0 },
        .{ .q = "p.t1.t2", .html = "<p class=\"t1 t2\">", .exp = 1 },
        .{ .q = "p.--t1", .html = "<p class=\"--t1 --t2\">", .exp = 1 },
        .{ .q = "p.--t1.--t2", .html = "<p class=\"--t1 --t2\">", .exp = 1 },
        .{ .q = "p[title]", .html = "<p><p title=\"title\">", .exp = 1 },
        .{ .q = "div[class=\"red\" i]", .html = "<div><div class=\"Red\">", .exp = 1 },
        .{ .q = "address[title=\"foo\"]", .html = "<address><address title=\"foo\"><address title=\"bar\">", .exp = 1 },
        .{ .q = "address[title=\"FoOIgnoRECaSe\" i]", .html = "<address><address title=\"fooIgnoreCase\"><address title=\"bar\">", .exp = 1 },
        .{ .q = "address[title!=\"foo\"]", .html = "<address><address title=\"foo\"><address title=\"bar\">", .exp = 2 },
        .{ .q = "address[title!=\"foo\" i]", .html = "<address><address title=\"FOO\"><address title=\"bar\">", .exp = 2 },
        .{ .q = "p[title!=\"FooBarUFoo\" i]", .html = "<p title=\"fooBARuFOO\"><p title=\"varfoo\">", .exp = 1 },
        .{ .q = "[   title        ~=       foo    ]", .html = "<p title=\"tot foo bar\">", .exp = 1 },
        .{ .q = "p[title~=\"FOO\" i]", .html = "<p title=\"tot foo bar\">", .exp = 1 },
        .{ .q = "p[title~=toofoo i]", .html = "<p title=\"tot foo bar\">", .exp = 0 },
        .{ .q = "[title~=\"hello world\"]", .html = "<p title=\"hello world\">", .exp = 0 },
        .{ .q = "[title~=\"hello\" i]", .html = "<p title=\"HELLO world\">", .exp = 1 },
        .{ .q = "[title~=\"hello\"          I]", .html = "<p title=\"HELLO world\">", .exp = 1 },
        .{ .q = "[lang|=\"en\"]", .html = "<p lang=\"en\"><p lang=\"en-gb\"><p lang=\"enough\"><p lang=\"fr-en\">", .exp = 2 },
        .{ .q = "[lang|=\"EN\" i]", .html = "<p lang=\"en\"><p lang=\"En-gb\"><p lang=\"enough\"><p lang=\"fr-en\">", .exp = 2 },
        .{ .q = "[lang|=\"EN\"     i]", .html = "<p lang=\"en\"><p lang=\"En-gb\"><p lang=\"enough\"><p lang=\"fr-en\">", .exp = 2 },
        .{ .q = "[title^=\"foo\"]", .html = "<p title=\"foobar\"><p title=\"barfoo\">", .exp = 1 },
        .{ .q = "[title^=\"foo\" i]", .html = "<p title=\"FooBAR\"><p title=\"barfoo\">", .exp = 1 },
        .{ .q = "[title$=\"bar\"]", .html = "<p title=\"foobar\"><p title=\"barfoo\">", .exp = 1 },
        .{ .q = "[title$=\"BAR\" i]", .html = "<p title=\"foobar\"><p title=\"barfoo\">", .exp = 1 },
        .{ .q = "[title*=\"bar\"]", .html = "<p title=\"foobarufoo\">", .exp = 1 },
        .{ .q = "[title*=\"BaRu\" i]", .html = "<p title=\"foobarufoo\">", .exp = 1 },
        .{ .q = "[title*=\"BaRu\" I]", .html = "<p title=\"foobarufoo\">", .exp = 1 },
        .{ .q = "p[class$=\" \"]", .html = "<p class=\" \">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class$=\"\"]", .html = "<p class=\"\">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class^=\" \"]", .html = "<p class=\" \">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class^=\"\"]", .html = "<p class=\"\">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class*=\" \"]", .html = "<p class=\" \">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "p[class*=\"\"]", .html = "<p class=\"\">This text should be green.</p><p>This text should be green.</p>", .exp = 0 },
        .{ .q = "input[name=Sex][value=F]", .html = "<input type=\"radio\" name=\"Sex\" value=\"F\"/>", .exp = 1 },
        .{ .q = "table[border=\"0\"][cellpadding=\"0\"][cellspacing=\"0\"]", .html = "<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" style=\"table-layout: fixed; width: 100%; border: 0 dashed; border-color: #FFFFFF\"><tr style=\"height:64px\">aaa</tr></table>", .exp = 1 },
        .{ .q = ".t1:not(.t2)", .html = "<p class=\"t1 t2\">", .exp = 0 },
        .{ .q = "div:not(.t1)", .html = "<div class=\"t3\">", .exp = 1 },
        .{ .q = "div:not([class=\"t2\"])", .html = "<div><div class=\"t2\"><div class=\"t3\">", .exp = 2 },
        .{ .q = "li:nth-child(odd)", .html = "<ol><li id=1><li id=2><li id=3></ol>", .exp = 2 },
        .{ .q = "li:nth-child(even)", .html = "<ol><li id=1><li id=2><li id=3></ol>", .exp = 1 },
        .{ .q = "li:nth-child(-n+2)", .html = "<ol><li id=1><li id=2><li id=3></ol>", .exp = 2 },
        .{ .q = "li:nth-child(3n+1)", .html = "<ol><li id=1><li id=2><li id=3></ol>", .exp = 1 },
        .{ .q = "li:nth-last-child(odd)", .html = "<ol><li id=1><li id=2><li id=3><li id=4></ol>", .exp = 2 },
        .{ .q = "li:nth-last-child(even)", .html = "<ol><li id=1><li id=2><li id=3><li id=4></ol>", .exp = 2 },
        .{ .q = "li:nth-last-child(-n+2)", .html = "<ol><li id=1><li id=2><li id=3><li id=4></ol>", .exp = 2 },
        .{ .q = "li:nth-last-child(3n+1)", .html = "<ol><li id=1><li id=2><li id=3><li id=4></ol>", .exp = 2 },
        .{ .q = "span:first-child", .html = "<p>some text <span id=\"1\">and a span</span><span id=\"2\"> and another</span></p>", .exp = 1 },
        .{ .q = "span:last-child", .html = "<span>a span</span> and some text", .exp = 1 },
        .{ .q = "p:nth-of-type(2)", .html = "<address></address><p id=1><p id=2>", .exp = 1 },
        .{ .q = "p:nth-last-of-type(2)", .html = "<address></address><p id=1><p id=2></p><a>", .exp = 1 },
        .{ .q = "p:last-of-type", .html = "<address></address><p id=1><p id=2></p><a>", .exp = 1 },
        .{ .q = "p:first-of-type", .html = "<address></address><p id=1><p id=2></p><a>", .exp = 1 },
        .{ .q = "p:only-child", .html = "<div><p id=\"1\"></p><a></a></div><div><p id=\"2\"></p></div>", .exp = 1 },
        .{ .q = "p:only-of-type", .html = "<div><p id=\"1\"></p><a></a></div><div><p id=\"2\"></p><p id=\"3\"></p></div>", .exp = 1 },
        .{ .q = ":empty", .html = "<p id=\"1\"><!-- --><p id=\"2\">Hello<p id=\"3\"><span>", .exp = 3 },
        .{ .q = "div p", .html = "<div><p id=\"1\"><table><tr><td><p id=\"2\"></table></div><p id=\"3\">", .exp = 2 },
        .{ .q = "div table p", .html = "<div><p id=\"1\"><table><tr><td><p id=\"2\"></table></div><p id=\"3\">", .exp = 1 },
        .{ .q = "div > p", .html = "<div><p id=\"1\"><div><p id=\"2\"></div><table><tr><td><p id=\"3\"></table></div>", .exp = 2 },
        .{ .q = "p ~ p", .html = "<p id=\"1\"><p id=\"2\"></p><address></address><p id=\"3\">", .exp = 2 },
        .{ .q = "p + p", .html = "<p id=\"1\"></p> <!--comment--> <p id=\"2\"></p><address></address><p id=\"3\">", .exp = 1 },
        .{ .q = "li, p", .html = "<ul><li></li><li></li></ul><p>", .exp = 3 },
        .{ .q = "p +/*This is a comment*/ p", .html = "<p id=\"1\"><p id=\"2\"></p><address></address><p id=\"3\">", .exp = 1 },
        // .{ .q = "p:contains(\"that wraps\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 1 },
        .{ .q = "p:containsOwn(\"that wraps\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 0 },
        .{ .q = ":containsOwn(\"inner\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 1 },
        .{ .q = ":containsOwn(\"Inner\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 0 },
        .{ .q = "p:containsOwn(\"block\")", .html = "<p>Text block that <span>wraps inner text</span> and continues</p>", .exp = 1 },
        .{ .q = "div:has(#p1)", .html = "<div id=\"d1\"><p id=\"p1\"><span>text content</span></p></div><div id=\"d2\"/>", .exp = 1 },
        .{ .q = "div:has(:containsOwn(\"2\"))", .html = "<div id=\"d1\"><p id=\"p1\"><span>contents 1</span></p></div> <div id=\"d2\"><p>contents <em>2</em></p></div>", .exp = 1 },
        .{ .q = "body :has(:containsOwn(\"2\"))", .html = "<body><div id=\"d1\"><p id=\"p1\"><span>contents 1</span></p></div> <div id=\"d2\"><p id=\"p2\">contents <em>2</em></p></div></body>", .exp = 2 },
        .{ .q = "body :haschild(:containsOwn(\"2\"))", .html = "<body><div id=\"d1\"><p id=\"p1\"><span>contents 1</span></p></div> <div id=\"d2\"><p id=\"p2\">contents <em>2</em></p></div></body>", .exp = 1 },
        // .{ .q = "p:matches([\\d])", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 2 },
        // .{ .q = "p:matches([a-z])", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 1 },
        // .{ .q = "p:matches([a-zA-Z])", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 2 },
        // .{ .q = "p:matches([^\\d])", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 2 },
        // .{ .q = "p:matches(^(0|a))", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 3 },
        // .{ .q = "p:matches(^\\d+$)", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 1 },
        // .{ .q = "p:not(:matches(^\\d+$))", .html = "<p id=\"p1\">0123456789</p><p id=\"p2\">abcdef</p><p id=\"p3\">0123ABCD</p>", .exp = 2 },
        // .{ .q = "div :matchesOwn(^\\d+$)", .html = "<div><p id=\"p1\">01234<em>567</em>89</p><div>", .exp = 2 },
        // .{ .q = "[href#=(fina)]:not([href#=(\\/\\/[^\\/]+untrusted)])", .html = "<ul> <li><a id=\"a1\" href=\"http://www.google.com/finance\"></a> <li><a id=\"a2\" href=\"http://finance.yahoo.com/\"></a> <li><a id=\"a2\" href=\"http://finance.untrusted.com/\"/> <li><a id=\"a3\" href=\"https://www.google.com/news\"/> <li><a id=\"a4\" href=\"http://news.yahoo.com\"/> </ul>", .exp = 2 },
        // .{ .q = "[href#=(^https:\\/\\/[^\\/]*\\/?news)]", .html = "<ul> <li><a id=\"a1\" href=\"http://www.google.com/finance\"/> <li><a id=\"a2\" href=\"http://finance.yahoo.com/\"/> <li><a id=\"a3\" href=\"https://www.google.com/news\"></a> <li><a id=\"a4\" href=\"http://news.yahoo.com\"/> </ul>", .exp = 1 },
        .{ .q = ":input", .html = "<form> <label>Username <input type=\"text\" name=\"username\" /></label> <label>Password <input type=\"password\" name=\"password\" /></label> <label>Country <select name=\"country\"> <option value=\"ca\">Canada</option> <option value=\"us\">United States</option> </select> </label> <label>Bio <textarea name=\"bio\"></textarea></label> <button>Sign up</button> </form>", .exp = 5 },
        .{ .q = ":root", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "*:root", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "html:nth-child(1)", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "*:root:first-child", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "*:root:nth-child(1)", .html = "<html><head></head><body></body></html>", .exp = 1 },
        .{ .q = "a:not(:root)", .html = "<html><head></head><body><a href=\"http://www.foo.com\"></a></body></html>", .exp = 1 },
        .{ .q = "body > *:nth-child(3n+2)", .html = "<html><head></head><body><p></p><div></div><span></span><a></a><form></form></body></html>", .exp = 2 },
        .{ .q = "input:disabled", .html = "<html><head></head><body><fieldset disabled><legend id=\"1\"><input id=\"i1\"/></legend><legend id=\"2\"><input id=\"i2\"/></legend></fieldset></body></html>", .exp = 1 },
        .{ .q = ":disabled", .html = "<html><head></head><body><fieldset disabled></fieldset></body></html>", .exp = 1 },
        .{ .q = ":enabled", .html = "<html><head></head><body><fieldset></fieldset></body></html>", .exp = 1 },
        .{ .q = "div.class1, div.class2", .html = "<div class=class1></div><div class=class2></div><div class=class3></div>", .exp = 2 },
    };

    for (testcases) |tc| {
        matcher.reset();

        const doc = try parser.documentHTMLParseFromStr(tc.html);
        defer parser.documentHTMLClose(doc) catch {};

        const s = css.parse(alloc, tc.q, .{}) catch |e| {
            std.debug.print("parse, query: {s}\n", .{tc.q});
            return e;
        };
        defer s.deinit(alloc);

        const node = Node{ .node = parser.documentHTMLToNode(doc) };

        _ = css.matchAll(&s, node, &matcher) catch |e| {
            std.debug.print("match, query: {s}\n", .{tc.q});
            return e;
        };
        std.testing.expectEqual(tc.exp, matcher.nodes.items.len) catch |e| {
            std.debug.print("expectation, query: {s}\n", .{tc.q});
            return e;
        };
    }
}
