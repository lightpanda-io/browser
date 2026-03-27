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
const Page = @import("Page.zig");
const Selector = @import("webapi/selector/Selector.zig");

const Allocator = std.mem.Allocator;

/// Collect all links (href attributes from anchor tags) under `root`.
/// Returns a slice of strings allocated with `arena`.
pub fn collectLinks(arena: Allocator, root: *Node, page: *Page) ![]const []const u8 {
    var links: std.ArrayList([]const u8) = .empty;

    if (Selector.querySelectorAll(root, "a[href]", page)) |list| {
        defer list.deinit(page._session);

        for (list._nodes) |node| {
            if (node.is(Element.Html.Anchor)) |anchor| {
                const href = anchor.getHref(page) catch |err| {
                    @import("../lightpanda.zig").log.err(.app, "resolve href failed", .{ .err = err });
                    continue;
                };

                if (href.len > 0) {
                    try links.append(arena, href);
                }
            }
        }
    } else |err| {
        @import("../lightpanda.zig").log.err(.app, "query links failed", .{ .err = err });
        return err;
    }

    return links.items;
}
