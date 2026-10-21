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
const lp = @import("lightpanda");

const Node = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");

const Allocator = std.mem.Allocator;

// The ids of one tree scope (a Document or a ShadowRoot).
const IdMap = @This();

// key is the element's attribute name, which lives in page.arena
_lookup: std.StringHashMapUnmanaged(Entry) = .empty,

// number of ids carried by more than 1 element
_duplicated: u32 = 0,

const Entry = struct {
    // ids aren't necessarily unique, and that impacts querySelectorAll and what
    // happens when a duplicate is added or removed from the tree
    count: u32,

    // first element (in tree order) with the id. null means it needs to be
    // recomputed (the first was removed, or duplicates were moved), which
    // get() does lazily, if ever requested
    first: ?*Element,
};

pub fn add(self: *IdMap, allocator: Allocator, element: *Element, id: []const u8) !void {
    const gop = try self._lookup.getOrPut(allocator, id);
    if (gop.found_existing == false) {
        gop.value_ptr.* = .{ .count = 1, .first = element };
        return;
    }

    const entry = gop.value_ptr;
    entry.count += 1;
    if (entry.count == 2) {
        self._duplicated += 1;
    }
    const first = entry.first orelse return;
    if (element.asNode().compareDocumentPosition(first.asNode()) & 0x04 != 0) {
        // new element comes before our first and thus becomes the new first
        entry.first = element;
    }
}

pub fn remove(self: *IdMap, element: *Element, id: []const u8) void {
    const kv = self._lookup.getEntry(id) orelse {
        if (comptime lp.IS_DEBUG) {
            // every remove should have a corresponding add
            std.debug.assert(false);
        }
        return;
    };

    const entry = kv.value_ptr;
    if (entry.count == 1) {
        self._lookup.removeByPtr(kv.key_ptr);
        return;
    }
    if (entry.count == 2) {
        self._duplicated -= 1;
    }
    entry.count -= 1;
    if (entry.first == element) {
        entry.first = null;
    }
}

// The subtree moved to another position within the same scope.  The ids are
// still in this scope, but things could be re-ordered and `first` could change.
pub fn moved(self: *IdMap, subtree: *Node) void {
    if (self._duplicated == 0) {
        // fast-path, we have no duplicates, moving things around can't change
        // which is first
        return;
    }
    var tw = TreeWalker.Full.Elements.init(subtree, .{});
    while (tw.next()) |el| {
        const id = el.getId() orelse continue;
        const entry = self._lookup.getPtr(id) orelse continue;
        if (entry.count > 1) {
            // it may or may not still be first, but setting it as null is simplest
            // and signals for a lazy-resolution. This is the most efficient
            // option: we could do it now, but if we delay we might never have
            // to do it (or things might change again which will just invalidate
            // anything we do now)
            entry.first = null;
        }
    }
}

pub fn clear(self: *IdMap, allocator: Allocator) void {
    self._lookup.clearAndFree(allocator);
    self._duplicated = 0;
}

// first element with this id (in tree-order). `scope` is the Document or
// ShadowRoot that owns self.
pub fn get(self: *IdMap, scope: *Node, id: []const u8) ?*Element {
    const entry = self._lookup.getPtr(id) orelse return null;
    if (entry.first) |first| {
        return first;
    }
    return getInTree(entry, scope, id);
}

pub const Unique = union(enum) {
    none,
    one: *Element,
    many,
};

pub fn getUnique(self: *IdMap, scope: *Node, id: []const u8) Unique {
    const entry = self._lookup.getPtr(id) orelse return .none;
    if (entry.count > 1) {
        return .many;
    }
    const el = entry.first orelse getInTree(entry, scope, id) orelse return .none;
    return .{ .one = el };
}

fn getInTree(entry: *Entry, scope: *Node, id: []const u8) ?*Element {
    var tw = TreeWalker.Full.Elements.init(scope, .{});
    while (tw.next()) |el| {
        const element_id = el.getId() orelse continue;
        if (std.mem.eql(u8, element_id, id)) {
            entry.first = el;
            return el;
        }
    }

    if (comptime lp.IS_DEBUG) {
        // there *was* an entry for this id in _lookup, if we didn't find it
        // in the tree (the walk above), we haven't kept _lookup in sync correctly
        std.debug.assert(false);
    }
    return null;
}
