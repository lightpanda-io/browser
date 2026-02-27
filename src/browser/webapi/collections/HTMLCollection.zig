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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");
const NodeLive = @import("node_live.zig").NodeLive;

const Mode = enum {
    tag,
    tag_name,
    tag_name_ns,
    class_name,
    all_elements,
    child_elements,
    child_tag,
    selected_options,
    links,
    anchors,
    form,
};

const HTMLCollection = @This();

_data: union(Mode) {
    tag: NodeLive(.tag),
    tag_name: NodeLive(.tag_name),
    tag_name_ns: NodeLive(.tag_name_ns),
    class_name: NodeLive(.class_name),
    all_elements: NodeLive(.all_elements),
    child_elements: NodeLive(.child_elements),
    child_tag: NodeLive(.child_tag),
    selected_options: NodeLive(.selected_options),
    links: NodeLive(.links),
    anchors: NodeLive(.anchors),
    form: NodeLive(.form),
},

pub fn length(self: *HTMLCollection, page: *const Page) u32 {
    return switch (self._data) {
        inline else => |*impl| impl.length(page),
    };
}

pub fn getAtIndex(self: *HTMLCollection, index: usize, page: *const Page) ?*Element {
    return switch (self._data) {
        inline else => |*impl| impl.getAtIndex(index, page),
    };
}

pub fn getByName(self: *HTMLCollection, name: []const u8, page: *Page) ?*Element {
    return switch (self._data) {
        inline else => |*impl| impl.getByName(name, page),
    };
}

pub fn iterator(self: *HTMLCollection, page: *Page) !*Iterator {
    return Iterator.init(.{
        .list = self,
        .tw = switch (self._data) {
            .tag => |*impl| .{ .tag = impl._tw.clone() },
            .tag_name => |*impl| .{ .tag_name = impl._tw.clone() },
            .tag_name_ns => |*impl| .{ .tag_name_ns = impl._tw.clone() },
            .class_name => |*impl| .{ .class_name = impl._tw.clone() },
            .all_elements => |*impl| .{ .all_elements = impl._tw.clone() },
            .child_elements => |*impl| .{ .child_elements = impl._tw.clone() },
            .child_tag => |*impl| .{ .child_tag = impl._tw.clone() },
            .selected_options => |*impl| .{ .selected_options = impl._tw.clone() },
            .links => |*impl| .{ .links = impl._tw.clone() },
            .anchors => |*impl| .{ .anchors = impl._tw.clone() },
            .form => |*impl| .{ .form = impl._tw.clone() },
        },
    }, page);
}

const GenericIterator = @import("iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    list: *HTMLCollection,
    tw: union(Mode) {
        tag: TreeWalker.FullExcludeSelf,
        tag_name: TreeWalker.FullExcludeSelf,
        tag_name_ns: TreeWalker.FullExcludeSelf,
        class_name: TreeWalker.FullExcludeSelf,
        all_elements: TreeWalker.FullExcludeSelf,
        child_elements: TreeWalker.Children,
        child_tag: TreeWalker.Children,
        selected_options: TreeWalker.Children,
        links: TreeWalker.FullExcludeSelf,
        anchors: TreeWalker.FullExcludeSelf,
        form: TreeWalker.FullExcludeSelf,
    },

    pub fn next(self: *@This(), _: *Page) ?*Element {
        return switch (self.list._data) {
            .tag => |*impl| impl.nextTw(&self.tw.tag),
            .tag_name => |*impl| impl.nextTw(&self.tw.tag_name),
            .tag_name_ns => |*impl| impl.nextTw(&self.tw.tag_name_ns),
            .class_name => |*impl| impl.nextTw(&self.tw.class_name),
            .all_elements => |*impl| impl.nextTw(&self.tw.all_elements),
            .child_elements => |*impl| impl.nextTw(&self.tw.child_elements),
            .child_tag => |*impl| impl.nextTw(&self.tw.child_tag),
            .selected_options => |*impl| impl.nextTw(&self.tw.selected_options),
            .links => |*impl| impl.nextTw(&self.tw.links),
            .anchors => |*impl| impl.nextTw(&self.tw.anchors),
            .form => |*impl| impl.nextTw(&self.tw.form),
        };
    }
}, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLCollection);

    pub const Meta = struct {
        pub const name = "HTMLCollection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const length = bridge.accessor(HTMLCollection.length, null, .{});
    pub const @"[int]" = bridge.indexed(HTMLCollection.getAtIndex, null, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(HTMLCollection.getByName, null, null, .{ .null_as_undefined = true });

    pub const item = bridge.function(_item, .{});
    fn _item(self: *HTMLCollection, index: i32, page: *Page) ?*Element {
        if (index < 0) {
            return null;
        }
        return self.getAtIndex(@intCast(index), page);
    }

    pub const namedItem = bridge.function(HTMLCollection.getByName, .{});
    pub const symbol_iterator = bridge.iterator(HTMLCollection.iterator, .{});
};
