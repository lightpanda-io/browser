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

// CSS Selector parser and query
// This package is a rewrite in Zig of Cascadia CSS Selector parser.
// see https://github.com/andybalholm/cascadia
const std = @import("std");
const Selector = @import("selector.zig").Selector;
const parser = @import("parser.zig");

pub const Interfaces = .{
    Css,
};

// https://developer.mozilla.org/en-US/docs/Web/API/CSS
pub const Css = struct {
    _not_empty: bool = true,

    pub fn _supports(_: *Css, _: []const u8, _: ?[]const u8) bool {
        // TODO: Actually respond with which CSS features we support.
        return true;
    }
};

// parse parse a selector string and returns the parsed result or an error.
pub fn parse(alloc: std.mem.Allocator, s: []const u8, opts: parser.ParseOptions) parser.ParseError!Selector {
    var p = parser.Parser{ .s = s, .i = 0, .opts = opts };
    return p.parse(alloc);
}

// matchFirst call m.match with the first node that matches the selector s, from the
// descendants of n and returns true. If none matches, it returns false.
pub fn matchFirst(s: *const Selector, node: anytype, m: anytype) !bool {
    var child = node.firstChild();
    while (child) |c| {
        if (try s.match(c)) {
            try m.match(c);
            return true;
        }

        if (try matchFirst(s, c, m)) return true;
        child = c.nextSibling();
    }
    return false;
}

// matchAll call m.match with the all the nodes that matches the selector s, from the
// descendants of n.
pub fn matchAll(s: *const Selector, node: anytype, m: anytype) !void {
    var child = node.firstChild();
    while (child) |c| {
        if (try s.match(c)) try m.match(c);
        try matchAll(s, c, m);
        child = c.nextSibling();
    }
}

test "parse" {
    const alloc = std.testing.allocator;

    const testcases = [_][]const u8{
        "address",
        "*",
        "#foo",
        "li#t1",
        "*#t4",
        ".t1",
        "p.t1",
        "div.teST",
        ".t1.fail",
        "p.t1.t2",
        "p.--t1",
        "p.--t1.--t2",
        "p[title]",
        "div[class=\"red\" i]",
        "address[title=\"foo\"]",
        "address[title=\"FoOIgnoRECaSe\" i]",
        "address[title!=\"foo\"]",
        "address[title!=\"foo\" i]",
        "p[title!=\"FooBarUFoo\" i]",
        "[  \t title        ~=       foo    ]",
        "p[title~=\"FOO\" i]",
        "p[title~=toofoo i]",
        "[title~=\"hello world\"]",
        "[title~=\"hello\" i]",
        "[title~=\"hello\"          I]",
        "[lang|=\"en\"]",
        "[lang|=\"EN\" i]",
        "[lang|=\"EN\"     i]",
        "[title^=\"foo\"]",
        "[title^=\"foo\" i]",
        "[title$=\"bar\"]",
        "[title$=\"BAR\" i]",
        "[title*=\"bar\"]",
        "[title*=\"BaRu\" i]",
        "[title*=\"BaRu\" I]",
        "p[class$=\" \"]",
        "p[class$=\"\"]",
        "p[class^=\" \"]",
        "p[class^=\"\"]",
        "p[class*=\" \"]",
        "p[class*=\"\"]",
        "input[name=Sex][value=F]",
        "table[border=\"0\"][cellpadding=\"0\"][cellspacing=\"0\"]",
        ".t1:not(.t2)",
        "div:not(.t1)",
        "div:not([class=\"t2\"])",
        "li:nth-child(odd)",
        "li:nth-child(even)",
        "li:nth-child(-n+2)",
        "li:nth-child(3n+1)",
        "li:nth-last-child(odd)",
        "li:nth-last-child(even)",
        "li:nth-last-child(-n+2)",
        "li:nth-last-child(3n+1)",
        "span:first-child",
        "span:last-child",
        "p:nth-of-type(2)",
        "p:nth-last-of-type(2)",
        "p:last-of-type",
        "p:first-of-type",
        "p:only-child",
        "p:only-of-type",
        ":empty",
        "div p",
        "div table p",
        "div > p",
        "p ~ p",
        "p + p",
        "li, p",
        "p +/*This is a comment*/ p",
        "p:contains(\"that wraps\")",
        "p:containsOwn(\"that wraps\")",
        ":containsOwn(\"inner\")",
        "p:containsOwn(\"block\")",
        "div:has(#p1)",
        "div:has(:containsOwn(\"2\"))",
        "body :has(:containsOwn(\"2\"))",
        "body :haschild(:containsOwn(\"2\"))",
        "p:matches([\\d])",
        "p:matches([a-z])",
        "p:matches([a-zA-Z])",
        "p:matches([^\\d])",
        "p:matches(^(0|a))",
        "p:matches(^\\d+$)",
        "p:not(:matches(^\\d+$))",
        "div :matchesOwn(^\\d+$)",
        "[href#=(fina)]:not([href#=(\\/\\/[^\\/]+untrusted)])",
        "[href#=(^https:\\/\\/[^\\/]*\\/?news)]",
        ":input",
        ":root",
        "*:root",
        "html:nth-child(1)",
        "*:root:first-child",
        "*:root:nth-child(1)",
        "a:not(:root)",
        "body > *:nth-child(3n+2)",
        "input:disabled",
        ":disabled",
        ":enabled",
        "div.class1, div.class2",
    };

    for (testcases) |tc| {
        const s = parse(alloc, tc, .{}) catch |e| {
            std.debug.print("query {s}", .{tc});
            return e;
        };
        defer s.deinit(alloc);
    }
}

const testing = @import("../../testing.zig");
test "Browser: CSS" {
    try testing.htmlRunner("css.html");
}
