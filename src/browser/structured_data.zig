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

const Allocator = std.mem.Allocator;

/// Key-value pair for structured data properties.
pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

pub const AlternateLink = struct {
    href: []const u8,
    hreflang: ?[]const u8,
    type: ?[]const u8,
    title: ?[]const u8,
};

pub const StructuredData = struct {
    json_ld: []const []const u8,
    open_graph: []const Property,
    twitter_card: []const Property,
    meta: []const Property,
    links: []const Property,
    alternate: []const AlternateLink,

    pub fn jsonStringify(self: *const StructuredData, jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("jsonLd");
        try jw.write(self.json_ld);

        try jw.objectField("openGraph");
        try writeProperties(jw, self.open_graph);

        try jw.objectField("twitterCard");
        try writeProperties(jw, self.twitter_card);

        try jw.objectField("meta");
        try writeProperties(jw, self.meta);

        try jw.objectField("links");
        try writeProperties(jw, self.links);

        if (self.alternate.len > 0) {
            try jw.objectField("alternate");
            try jw.beginArray();
            for (self.alternate) |alt| {
                try jw.beginObject();
                try jw.objectField("href");
                try jw.write(alt.href);
                if (alt.hreflang) |v| {
                    try jw.objectField("hreflang");
                    try jw.write(v);
                }
                if (alt.type) |v| {
                    try jw.objectField("type");
                    try jw.write(v);
                }
                if (alt.title) |v| {
                    try jw.objectField("title");
                    try jw.write(v);
                }
                try jw.endObject();
            }
            try jw.endArray();
        }

        try jw.endObject();
    }
};

/// Serializes properties as a JSON object. When a key appears multiple times
/// (e.g. multiple og:image tags), values are grouped into an array.
/// Alternatives considered: always-array values (verbose), or an array of
/// {key, value} pairs (preserves order but less ergonomic for consumers).
fn writeProperties(jw: anytype, properties: []const Property) !void {
    try jw.beginObject();
    for (properties, 0..) |prop, i| {
        // Skip keys already written by an earlier occurrence.
        var already_written = false;
        for (properties[0..i]) |prev| {
            if (std.mem.eql(u8, prev.key, prop.key)) {
                already_written = true;
                break;
            }
        }
        if (already_written) continue;

        // Count total occurrences to decide string vs array.
        var count: usize = 0;
        for (properties) |p| {
            if (std.mem.eql(u8, p.key, prop.key)) count += 1;
        }

        try jw.objectField(prop.key);
        if (count == 1) {
            try jw.write(prop.value);
        } else {
            try jw.beginArray();
            for (properties) |p| {
                if (std.mem.eql(u8, p.key, prop.key)) {
                    try jw.write(p.value);
                }
            }
            try jw.endArray();
        }
    }
    try jw.endObject();
}

/// Extract all structured data from the page.
pub fn collectStructuredData(
    root: *Node,
    arena: Allocator,
    page: *Page,
) !StructuredData {
    var json_ld: std.ArrayList([]const u8) = .empty;
    var open_graph: std.ArrayList(Property) = .empty;
    var twitter_card: std.ArrayList(Property) = .empty;
    var meta: std.ArrayList(Property) = .empty;
    var links: std.ArrayList(Property) = .empty;
    var alternate: std.ArrayList(AlternateLink) = .empty;

    // Extract language from the root <html> element.
    if (root.is(Element)) |root_el| {
        if (root_el.getAttributeSafe(comptime .wrap("lang"))) |lang| {
            try meta.append(arena, .{ .key = "language", .value = lang });
        }
    } else {
        // Root is document — check documentElement.
        var children = root.childrenIterator();
        while (children.next()) |child| {
            const el = child.is(Element) orelse continue;
            if (el.getTag() == .html) {
                if (el.getAttributeSafe(comptime .wrap("lang"))) |lang| {
                    try meta.append(arena, .{ .key = "language", .value = lang });
                }
                break;
            }
        }
    }

    var tw = TreeWalker.Full.init(root, .{});
    while (tw.next()) |node| {
        const el = node.is(Element) orelse continue;

        switch (el.getTag()) {
            .script => {
                try collectJsonLd(el, arena, &json_ld);
                tw.skipChildren();
            },
            .meta => collectMeta(el, &open_graph, &twitter_card, &meta, arena) catch {},
            .title => try collectTitle(node, arena, &meta),
            .link => try collectLink(el, arena, page, &links, &alternate),
            // Skip body subtree for non-JSON-LD — all other metadata is in <head>.
            // JSON-LD can appear in <body> so we don't skip the whole body.
            else => {},
        }
    }

    return .{
        .json_ld = json_ld.items,
        .open_graph = open_graph.items,
        .twitter_card = twitter_card.items,
        .meta = meta.items,
        .links = links.items,
        .alternate = alternate.items,
    };
}

fn collectJsonLd(
    el: *Element,
    arena: Allocator,
    json_ld: *std.ArrayList([]const u8),
) !void {
    const type_attr = el.getAttributeSafe(comptime .wrap("type")) orelse return;
    if (!std.ascii.eqlIgnoreCase(type_attr, "application/ld+json")) return;

    var buf: std.Io.Writer.Allocating = .init(arena);
    try el.asNode().getTextContent(&buf.writer);
    const text = buf.written();
    if (text.len > 0) {
        try json_ld.append(arena, std.mem.trim(u8, text, &std.ascii.whitespace));
    }
}

fn collectMeta(
    el: *Element,
    open_graph: *std.ArrayList(Property),
    twitter_card: *std.ArrayList(Property),
    meta: *std.ArrayList(Property),
    arena: Allocator,
) !void {
    // charset: <meta charset="..."> (no content attribute needed).
    if (el.getAttributeSafe(comptime .wrap("charset"))) |charset| {
        try meta.append(arena, .{ .key = "charset", .value = charset });
    }

    const content = el.getAttributeSafe(comptime .wrap("content")) orelse return;

    // Open Graph: <meta property="og:...">
    if (el.getAttributeSafe(comptime .wrap("property"))) |property| {
        if (std.mem.startsWith(u8, property, "og:")) {
            try open_graph.append(arena, .{ .key = property[3..], .value = content });
            return;
        }
        // Article, profile, etc. are OG sub-namespaces.
        if (std.mem.startsWith(u8, property, "article:") or
            std.mem.startsWith(u8, property, "profile:") or
            std.mem.startsWith(u8, property, "book:") or
            std.mem.startsWith(u8, property, "music:") or
            std.mem.startsWith(u8, property, "video:"))
        {
            try open_graph.append(arena, .{ .key = property, .value = content });
            return;
        }
    }

    // Twitter Cards: <meta name="twitter:...">
    if (el.getAttributeSafe(comptime .wrap("name"))) |name| {
        if (std.mem.startsWith(u8, name, "twitter:")) {
            try twitter_card.append(arena, .{ .key = name[8..], .value = content });
            return;
        }

        // Standard meta tags by name.
        const known_names = [_][]const u8{
            "description", "author",    "keywords",    "robots",
            "viewport",    "generator", "theme-color",
        };
        for (known_names) |known| {
            if (std.ascii.eqlIgnoreCase(name, known)) {
                try meta.append(arena, .{ .key = known, .value = content });
                return;
            }
        }
    }

    // http-equiv (e.g. Content-Type, refresh)
    if (el.getAttributeSafe(comptime .wrap("http-equiv"))) |http_equiv| {
        try meta.append(arena, .{ .key = http_equiv, .value = content });
    }
}

fn collectTitle(
    node: *Node,
    arena: Allocator,
    meta: *std.ArrayList(Property),
) !void {
    var buf: std.Io.Writer.Allocating = .init(arena);
    try node.getTextContent(&buf.writer);
    const text = std.mem.trim(u8, buf.written(), &std.ascii.whitespace);
    if (text.len > 0) {
        try meta.append(arena, .{ .key = "title", .value = text });
    }
}

fn collectLink(
    el: *Element,
    arena: Allocator,
    page: *Page,
    links: *std.ArrayList(Property),
    alternate: *std.ArrayList(AlternateLink),
) !void {
    const rel = el.getAttributeSafe(comptime .wrap("rel")) orelse return;
    const raw_href = el.getAttributeSafe(comptime .wrap("href")) orelse return;
    const href = URL.resolve(arena, page.base(), raw_href, .{ .encode = true }) catch raw_href;

    if (std.ascii.eqlIgnoreCase(rel, "alternate")) {
        try alternate.append(arena, .{
            .href = href,
            .hreflang = el.getAttributeSafe(comptime .wrap("hreflang")),
            .type = el.getAttributeSafe(comptime .wrap("type")),
            .title = el.getAttributeSafe(comptime .wrap("title")),
        });
        return;
    }

    const relevant_rels = [_][]const u8{
        "canonical",        "icon",       "manifest", "shortcut icon",
        "apple-touch-icon", "search",     "author",   "license",
        "dns-prefetch",     "preconnect",
    };
    for (relevant_rels) |known| {
        if (std.ascii.eqlIgnoreCase(rel, known)) {
            try links.append(arena, .{ .key = known, .value = href });
            return;
        }
    }
}

// --- Tests ---

const testing = @import("../testing.zig");

fn testStructuredData(html: []const u8) !StructuredData {
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();

    const doc = page.window._document;
    const div = try doc.createElement("div", null, page);
    try page.parseHtmlAsChildren(div.asNode(), html);

    return collectStructuredData(div.asNode(), page.call_arena, page);
}

fn findProperty(props: []const Property, key: []const u8) ?[]const u8 {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.value;
    }
    return null;
}

test "structured_data: json-ld" {
    const data = try testStructuredData(
        \\<script type="application/ld+json">
        \\{"@context":"https://schema.org","@type":"Article","headline":"Test"}
        \\</script>
    );
    try testing.expectEqual(1, data.json_ld.len);
    try testing.expect(std.mem.indexOf(u8, data.json_ld[0], "Article") != null);
}

test "structured_data: multiple json-ld" {
    const data = try testStructuredData(
        \\<script type="application/ld+json">{"@type":"Organization"}</script>
        \\<script type="application/ld+json">{"@type":"BreadcrumbList"}</script>
        \\<script type="text/javascript">var x = 1;</script>
    );
    try testing.expectEqual(2, data.json_ld.len);
}

test "structured_data: open graph" {
    const data = try testStructuredData(
        \\<meta property="og:title" content="My Page">
        \\<meta property="og:description" content="A description">
        \\<meta property="og:image" content="https://example.com/img.jpg">
        \\<meta property="og:url" content="https://example.com">
        \\<meta property="og:type" content="article">
        \\<meta property="article:published_time" content="2026-03-10">
    );
    try testing.expectEqual(6, data.open_graph.len);
    try testing.expectEqual("My Page", findProperty(data.open_graph, "title").?);
    try testing.expectEqual("article", findProperty(data.open_graph, "type").?);
    try testing.expectEqual("2026-03-10", findProperty(data.open_graph, "article:published_time").?);
}

test "structured_data: open graph duplicate keys" {
    const data = try testStructuredData(
        \\<meta property="og:title" content="My Page">
        \\<meta property="og:image" content="https://example.com/img1.jpg">
        \\<meta property="og:image" content="https://example.com/img2.jpg">
        \\<meta property="og:image" content="https://example.com/img3.jpg">
    );
    // Duplicate keys are preserved as separate Property entries.
    try testing.expectEqual(4, data.open_graph.len);

    // Verify serialization groups duplicates into arrays.
    const json = try std.json.Stringify.valueAlloc(testing.allocator, data, .{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const og = parsed.value.object.get("openGraph").?.object;
    // "title" appears once → string.
    switch (og.get("title").?) {
        .string => {},
        else => return error.TestUnexpectedResult,
    }
    // "image" appears 3 times → array.
    switch (og.get("image").?) {
        .array => |arr| try testing.expectEqual(3, arr.items.len),
        else => return error.TestUnexpectedResult,
    }
}

test "structured_data: twitter card" {
    const data = try testStructuredData(
        \\<meta name="twitter:card" content="summary_large_image">
        \\<meta name="twitter:site" content="@example">
        \\<meta name="twitter:title" content="My Page">
    );
    try testing.expectEqual(3, data.twitter_card.len);
    try testing.expectEqual("summary_large_image", findProperty(data.twitter_card, "card").?);
    try testing.expectEqual("@example", findProperty(data.twitter_card, "site").?);
}

test "structured_data: meta tags" {
    const data = try testStructuredData(
        \\<title>Page Title</title>
        \\<meta name="description" content="A test page">
        \\<meta name="author" content="Test Author">
        \\<meta name="keywords" content="test, example">
        \\<meta name="robots" content="index, follow">
    );
    try testing.expectEqual("Page Title", findProperty(data.meta, "title").?);
    try testing.expectEqual("A test page", findProperty(data.meta, "description").?);
    try testing.expectEqual("Test Author", findProperty(data.meta, "author").?);
    try testing.expectEqual("test, example", findProperty(data.meta, "keywords").?);
    try testing.expectEqual("index, follow", findProperty(data.meta, "robots").?);
}

test "structured_data: link elements" {
    const data = try testStructuredData(
        \\<link rel="canonical" href="https://example.com/page">
        \\<link rel="icon" href="/favicon.ico">
        \\<link rel="manifest" href="/manifest.json">
        \\<link rel="stylesheet" href="/style.css">
    );
    try testing.expectEqual(3, data.links.len);
    try testing.expectEqual("https://example.com/page", findProperty(data.links, "canonical").?);
    // stylesheet should be filtered out
    try testing.expectEqual(null, findProperty(data.links, "stylesheet"));
}

test "structured_data: alternate links" {
    const data = try testStructuredData(
        \\<link rel="alternate" href="https://example.com/fr" hreflang="fr" title="French">
        \\<link rel="alternate" href="https://example.com/de" hreflang="de">
    );
    try testing.expectEqual(2, data.alternate.len);
    try testing.expectEqual("fr", data.alternate[0].hreflang.?);
    try testing.expectEqual("French", data.alternate[0].title.?);
    try testing.expectEqual("de", data.alternate[1].hreflang.?);
    try testing.expectEqual(null, data.alternate[1].title);
}

test "structured_data: non-metadata elements ignored" {
    const data = try testStructuredData(
        \\<div>Just text</div>
        \\<p>More text</p>
        \\<a href="/link">Link</a>
    );
    try testing.expectEqual(0, data.json_ld.len);
    try testing.expectEqual(0, data.open_graph.len);
    try testing.expectEqual(0, data.twitter_card.len);
    try testing.expectEqual(0, data.meta.len);
    try testing.expectEqual(0, data.links.len);
}

test "structured_data: charset and http-equiv" {
    const data = try testStructuredData(
        \\<meta charset="utf-8">
        \\<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
    );
    try testing.expectEqual("utf-8", findProperty(data.meta, "charset").?);
    try testing.expectEqual("text/html; charset=utf-8", findProperty(data.meta, "Content-Type").?);
}

test "structured_data: mixed content" {
    const data = try testStructuredData(
        \\<title>My Site</title>
        \\<meta property="og:title" content="OG Title">
        \\<meta name="twitter:card" content="summary">
        \\<meta name="description" content="A page">
        \\<link rel="canonical" href="https://example.com">
        \\<script type="application/ld+json">{"@type":"WebSite"}</script>
    );
    try testing.expectEqual(1, data.json_ld.len);
    try testing.expectEqual(1, data.open_graph.len);
    try testing.expectEqual(1, data.twitter_card.len);
    try testing.expectEqual("My Site", findProperty(data.meta, "title").?);
    try testing.expectEqual("A page", findProperty(data.meta, "description").?);
    try testing.expectEqual(1, data.links.len);
}
