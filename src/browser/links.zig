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

const AXNode = @import("../cdp/AXNode.zig");
const Element = @import("webapi/Element.zig");
const Node = @import("webapi/Node.zig");
const Frame = @import("Frame.zig");
const Selector = @import("webapi/selector/Selector.zig");
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

/// Collect the visible links (anchor tags with an href) under `root`, one
/// entry per resolved href. `text` is the accessible name, the same one the
/// semantic tree reports for the node.
pub fn collectLinks(arena: Allocator, root: *Node, frame: *Frame) ![]Link {
    var links: std.StringArrayHashMapUnmanaged(Link) = .empty;
    var visibility_cache: Element.VisibilityCache = .empty;

    if (Selector.querySelectorAll(root, "a[href]", frame)) |list| {
        defer list.deinit(frame._page);

        for (list._nodes) |node| {
            const anchor = node.is(Element.Html.Anchor) orelse continue;
            const el = anchor.asElement();
            if (!el.checkVisibilityCached(&visibility_cache, frame, .scan)) continue;

            const href = anchor.getHref(frame) catch |err| {
                log.err(.app, "resolve href failed", .{ .err = err });
                continue;
            };
            if (href.len == 0) continue;

            const gop = try links.getOrPut(arena, href);
            if (gop.found_existing) {
                if (gop.value_ptr.text == null) gop.value_ptr.text = try AXNode.fromNode(node).getName(frame, arena);
                continue;
            }
            gop.value_ptr.* = .{
                .node = node,
                .text = try AXNode.fromNode(node).getName(frame, arena),
                .href = href,
            };
        }
    } else |err| {
        log.err(.app, "query links failed", .{ .err = err });
        return err;
    }

    return links.values();
}

const testing = @import("../testing.zig");

fn testLinks(html: []const u8) ![]Link {
    const frame = try testing.createFrame();
    errdefer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), html);

    return collectLinks(frame.call_arena, div.asNode(), frame);
}

test "links: text and href" {
    defer testing.test_session.closeAllPages();
    const links = try testLinks(
        \\<a href="https://example.com/login">Sign in</a>
        \\<a href="/page/2">  Next page </a>
        \\<a>no href, skipped</a>
    );

    try testing.expectEqual(2, links.len);
    try testing.expectEqual("Sign in", links[0].text.?);
    try testing.expectEqual("https://example.com/login", links[0].href);
    try testing.expectEqual("Next page", links[1].text.?);
}

test "links: empty text" {
    defer testing.test_session.closeAllPages();
    const links = try testLinks(
        \\<a href="/icon"><img src="i.png"></a>
    );

    try testing.expectEqual(1, links.len);
    try testing.expectEqual(null, links[0].text);
}

test "links: text fallbacks for image and icon links" {
    defer testing.test_session.closeAllPages();
    const links = try testLinks(
        \\<a href="/logo"><img src="logo.png" alt="Acme"></a>
        \\<a href="/discord" aria-label="Discord"><svg></svg></a>
        \\<a href="/help" title="Help"><svg></svg></a>
        \\<a href="/both" aria-label="Label"><img alt="Alt"></a>
    );

    try testing.expectEqual(4, links.len);
    try testing.expectEqual("Acme", links[0].text.?);
    try testing.expectEqual("Discord", links[1].text.?);
    try testing.expectEqual("Help", links[2].text.?);
    try testing.expectEqual("Label", links[3].text.?);
}

test "links: one entry per href, keeping the first with text" {
    defer testing.test_session.closeAllPages();
    const links = try testLinks(
        \\<a href="/post/1"><img src="t.png"></a>
        \\<a href="/post/1">Read the post</a>
        \\<a href="/post/1">Comments</a>
        \\<a href="/post/2">Other</a>
    );

    try testing.expectEqual(2, links.len);
    try testing.expectEqual("Read the post", links[0].text.?);
    try testing.expectEqual("/post/1", links[0].href);
    try testing.expectEqual("Other", links[1].text.?);
}

test "links: hidden links are skipped" {
    defer testing.test_session.closeAllPages();
    const links = try testLinks(
        \\<a href="/a" style="display:none">Inline</a>
        \\<a href="/b" hidden>Attribute</a>
        \\<div style="display:none"><a href="/c">Ancestor</a></div>
        \\<a href="/d">Visible</a>
    );

    try testing.expectEqual(1, links.len);
    try testing.expectEqual("Visible", links[0].text.?);
}
