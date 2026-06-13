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

const Element = @import("webapi/Element.zig");
const Node = @import("webapi/Node.zig");
const Frame = @import("Frame.zig");
const Selector = @import("webapi/selector/Selector.zig");
const interactive = @import("interactive.zig");
const log = @import("../lightpanda.zig").log;

const Allocator = std.mem.Allocator;

pub const Link = struct {
    backendNodeId: ?u32 = null,
    node: *Node,
    text: ?[]const u8,
    href: []const u8,

    pub fn jsonStringify(self: *const Link, jw: anytype) !void {
        try jw.beginObject();
        if (self.backendNodeId) |id| {
            try jw.objectField("backendNodeId");
            try jw.write(id);
        }
        if (self.text) |t| {
            try jw.objectField("text");
            try jw.write(t);
        }
        try jw.objectField("href");
        try jw.write(self.href);
        try jw.endObject();
    }
};

/// Populate backendNodeId on each link by registering its node in the registry.
pub fn registerNodes(links: []Link, registry: anytype) !void {
    for (links) |*l| {
        const registered = try registry.register(l.node);
        l.backendNodeId = registered.id;
    }
}

/// Collect all links (anchor tags with an href) under `root`.
pub fn collectLinks(arena: Allocator, root: *Node, frame: *Frame) ![]Link {
    var links: std.ArrayList(Link) = .empty;

    if (Selector.querySelectorAll(root, "a[href]", frame)) |list| {
        defer list.deinit(frame._page);

        for (list._nodes) |node| {
            const anchor = node.is(Element.Html.Anchor) orelse continue;
            const href = anchor.getHref(frame) catch |err| {
                log.err(.app, "resolve href failed", .{ .err = err });
                continue;
            };
            if (href.len == 0) continue;

            try links.append(arena, .{
                .node = node,
                .text = interactive.getTextContent(node, arena) catch null,
                .href = href,
            });
        }
    } else |err| {
        log.err(.app, "query links failed", .{ .err = err });
        return err;
    }

    return links.items;
}

const testing = @import("../testing.zig");

// Caller must `defer testing.test_session.removePage()` after a successful
// call — the returned slices live in the page's call_arena.
fn testLinks(html: []const u8) ![]Link {
    const frame = try testing.test_session.createPage();
    errdefer testing.test_session.removePage();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try frame.parseHtmlAsChildren(div.asNode(), html);

    return collectLinks(frame.call_arena, div.asNode(), frame);
}

test "links: text and href" {
    const links = try testLinks(
        \\<a href="https://example.com/login">Sign in</a>
        \\<a href="/page/2">  Next page </a>
        \\<a>no href, skipped</a>
    );
    defer testing.test_session.removePage();

    try testing.expectEqual(2, links.len);
    try testing.expectEqual("Sign in", links[0].text.?);
    try testing.expectEqual("https://example.com/login", links[0].href);
    try testing.expectEqual("Next page", links[1].text.?);
}

test "links: empty text" {
    const links = try testLinks(
        \\<a href="/icon"><img src="i.png"></a>
    );
    defer testing.test_session.removePage();

    try testing.expectEqual(1, links.len);
    try testing.expectEqual(null, links[0].text);
}
