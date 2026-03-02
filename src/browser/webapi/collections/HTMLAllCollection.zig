// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");

const HTMLAllCollection = @This();

_tw: TreeWalker.FullExcludeSelf,
_last_index: usize,
_last_length: ?u32,
_cached_version: usize,

pub fn init(root: *Node, page: *Page) HTMLAllCollection {
    return .{
        ._last_index = 0,
        ._last_length = null,
        ._tw = TreeWalker.FullExcludeSelf.init(root, .{}),
        ._cached_version = page.version,
    };
}

fn versionCheck(self: *HTMLAllCollection, page: *const Page) bool {
    if (self._cached_version != page.version) {
        self._cached_version = page.version;
        self._last_index = 0;
        self._last_length = null;
        self._tw.reset();
        return false;
    }
    return true;
}

pub fn length(self: *HTMLAllCollection, page: *const Page) u32 {
    if (self.versionCheck(page)) {
        if (self._last_length) |cached_length| {
            return cached_length;
        }
    }

    lp.assert(self._last_index == 0, "HTMLAllCollection.length", .{ .last_index = self._last_index });

    var tw = &self._tw;
    defer tw.reset();

    var l: u32 = 0;
    while (tw.next()) |node| {
        if (node.is(Element) != null) {
            l += 1;
        }
    }

    self._last_length = l;
    return l;
}

pub fn getAtIndex(self: *HTMLAllCollection, index: usize, page: *const Page) ?*Element {
    _ = self.versionCheck(page);
    var current = self._last_index;
    if (index <= current) {
        current = 0;
        self._tw.reset();
    }
    defer self._last_index = current + 1;

    const tw = &self._tw;
    while (tw.next()) |node| {
        if (node.is(Element)) |el| {
            if (index == current) {
                return el;
            }
            current += 1;
        }
    }

    return null;
}

pub fn getByName(self: *HTMLAllCollection, name: []const u8, page: *Page) ?*Element {
    // First, try fast ID lookup using the document's element map
    if (page.document._elements_by_id.get(name)) |el| {
        return el;
    }

    // Fall back to searching by name attribute
    // Clone the tree walker to preserve _last_index optimization
    _ = self.versionCheck(page);
    var tw = self._tw.clone();
    tw.reset();

    while (tw.next()) |node| {
        if (node.is(Element)) |el| {
            if (el.getAttributeSafe(comptime .wrap("name"))) |attr_name| {
                if (std.mem.eql(u8, attr_name, name)) {
                    return el;
                }
            }
        }
    }

    return null;
}

const CAllAsFunctionArg = union(enum) {
    index: u32,
    id: []const u8,
};
pub fn callable(self: *HTMLAllCollection, arg: CAllAsFunctionArg, page: *Page) ?*Element {
    return switch (arg) {
        .index => |i| self.getAtIndex(i, page),
        .id => |id| self.getByName(id, page),
    };
}

pub fn iterator(self: *HTMLAllCollection, page: *Page) !*Iterator {
    return Iterator.init(.{
        .list = self,
        .tw = self._tw.clone(),
    }, page);
}

const GenericIterator = @import("iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    list: *HTMLAllCollection,
    tw: TreeWalker.FullExcludeSelf,

    pub fn next(self: *@This(), _: *Page) ?*Element {
        while (self.tw.next()) |node| {
            if (node.is(Element)) |el| {
                return el;
            }
        }
        return null;
    }
}, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLAllCollection);

    pub const Meta = struct {
        pub const name = "HTMLAllCollection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;

        // This is a very weird class that requires special JavaScript behavior
        // this htmldda and callable are only used here..
        pub const htmldda = true;
        pub const callable = JsApi.callable;
    };

    pub const length = bridge.accessor(HTMLAllCollection.length, null, .{});
    pub const @"[int]" = bridge.indexed(HTMLAllCollection.getAtIndex, null, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(HTMLAllCollection.getByName, null, null, .{ .null_as_undefined = true });

    pub const item = bridge.function(_item, .{});
    fn _item(self: *HTMLAllCollection, index: i32, page: *Page) ?*Element {
        if (index < 0) {
            return null;
        }
        return self.getAtIndex(@intCast(index), page);
    }

    pub const namedItem = bridge.function(HTMLAllCollection.getByName, .{});
    pub const symbol_iterator = bridge.iterator(HTMLAllCollection.iterator, .{});

    pub const callable = bridge.callable(HTMLAllCollection.callable, .{ .null_as_undefined = true });
};
