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
const Frame = @import("../../Frame.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");
const NodeLive = @import("node_live.zig").NodeLive;
const Execution = js.Execution;

const Mode = enum {
    tag,
    tag_name,
    tag_name_ns,
    class_name,
    all_elements,
    child_elements,
    child_tag,
    cells,
    selected_options,
    links,
    anchors,
    form,
    empty,
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
    cells: NodeLive(.cells),
    selected_options: NodeLive(.selected_options),
    links: NodeLive(.links),
    anchors: NodeLive(.anchors),
    form: NodeLive(.form),
    empty: void,
},
_rc: lp.RC = .{},

pub fn deinit(self: *HTMLCollection, page: *Page) void {
    page.factory.destroy(self);
}

pub fn releaseRef(self: *HTMLCollection, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *HTMLCollection) void {
    self._rc.acquire();
}

pub fn length(self: *HTMLCollection, frame: *const Frame) u32 {
    return switch (self._data) {
        .empty => 0,
        inline else => |*impl| impl.length(frame),
    };
}

pub fn getAtIndex(self: *HTMLCollection, index: usize, frame: *const Frame) ?*Element {
    return switch (self._data) {
        .empty => null,
        inline else => |*impl| impl.getAtIndex(index, frame),
    };
}

pub fn getByName(self: *HTMLCollection, name: []const u8, frame: *Frame) ?*Element {
    if (name.len == 0) {
        return null;
    }

    return switch (self._data) {
        .empty => null,
        inline else => |*impl| impl.getByName(name, frame),
    };
}

pub fn iterator(self: *HTMLCollection, exec: *const Execution) !*Iterator {
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
            .cells => |*impl| .{ .cells = impl._tw.clone() },
            .selected_options => |*impl| .{ .selected_options = impl._tw.clone() },
            .links => |*impl| .{ .links = impl._tw.clone() },
            .anchors => |*impl| .{ .anchors = impl._tw.clone() },
            .form => |*impl| .{ .form = impl._tw.clone() },
            .empty => .empty,
        },
    }, exec);
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
        cells: TreeWalker.Children,
        selected_options: TreeWalker.Children,
        links: TreeWalker.FullExcludeSelf,
        anchors: TreeWalker.FullExcludeSelf,
        form: TreeWalker.FullExcludeSelf,
        empty: void,
    },

    pub fn acquireRef(self: *@This()) void {
        self.list.acquireRef();
    }

    pub fn releaseRef(self: *@This(), page: *Page) void {
        self.list.releaseRef(page);
    }

    pub fn next(self: *@This(), _: *const Execution) ?*Element {
        return switch (self.list._data) {
            .tag => |*impl| impl.nextTw(&self.tw.tag),
            .tag_name => |*impl| impl.nextTw(&self.tw.tag_name),
            .tag_name_ns => |*impl| impl.nextTw(&self.tw.tag_name_ns),
            .class_name => |*impl| impl.nextTw(&self.tw.class_name),
            .all_elements => |*impl| impl.nextTw(&self.tw.all_elements),
            .child_elements => |*impl| impl.nextTw(&self.tw.child_elements),
            .child_tag => |*impl| impl.nextTw(&self.tw.child_tag),
            .cells => |*impl| impl.nextTw(&self.tw.cells),
            .selected_options => |*impl| impl.nextTw(&self.tw.selected_options),
            .links => |*impl| impl.nextTw(&self.tw.links),
            .anchors => |*impl| impl.nextTw(&self.tw.anchors),
            .form => |*impl| impl.nextTw(&self.tw.form),
            .empty => return null,
        };
    }
}, null);

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLCollection);

    pub const Meta = struct {
        pub const name = "HTMLCollection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(HTMLCollection.length, null, .{});
    pub const @"[int]" = bridge.indexedFull(HTMLCollection.getAtIndex, setAtIndex, deleteAtIndex, queryAtIndex, defineAtIndex, getIndexes, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexedFull(struct {
        pub fn wrap(self: *HTMLCollection, name: []const u8, frame: *Frame) !?*Element {
            if (name.len == 0) {
                return error.NotHandled;
            }

            return self.getByName(name, frame) orelse error.NotHandled;
        }
    }.wrap, null, deleteByName, getNames, queryByName, defineByName, describeByName, .{ .null_as_undefined = true });

    // Named properties are [LegacyUnenumerableNamedProperties]: the query
    // reports them non-enumerable, so for-in skips them while
    // Object.getOwnPropertyNames still lists them via the enumerator.
    fn queryByName(self: *HTMLCollection, name: []const u8, frame: *Frame) !u32 {
        if (name.len > 0 and self.getByName(name, frame) != null) {
            return js.v8.DontEnum;
        }
        return error.NotHandled;
    }

    // HTMLCollection has no indexed setter: per Web IDL, assigning to or
    // defining any array index property fails (TypeError in strict mode).
    fn setAtIndex(_: *HTMLCollection, _: u32, _: js.Value) bool {
        return false;
    }

    fn defineAtIndex(_: *HTMLCollection, _: u32) bool {
        return false;
    }

    // Supported indexed properties are enumerable, configurable, read-only.
    fn queryAtIndex(self: *HTMLCollection, idx: u32, frame: *Frame) !u32 {
        if (idx < self.length(frame)) {
            return js.v8.ReadOnly;
        }
        return error.NotHandled;
    }

    // Redefining a supported named property fails; unsupported names follow
    // the ordinary path, so expandos remain allowed. Note there is no named
    // setter and no named query: a direct assignment falls through to the
    // ordinary [[Set]] which ends up in defineByName, while an assignment
    // through a derived object (the collection as prototype) must ignore the
    // named property entirely and create an expando on the receiver.
    fn defineByName(self: *HTMLCollection, name: []const u8, frame: *Frame) !bool {
        if (name.len > 0 and self.getByName(name, frame) != null) {
            return false;
        }
        return error.NotHandled;
    }

    // Named properties are [LegacyUnenumerableNamedProperties]: not
    // enumerable, configurable, read-only.
    fn describeByName(self: *HTMLCollection, name: []const u8, frame: *Frame) !Descriptor {
        if (name.len > 0) {
            if (self.getByName(name, frame)) |element| {
                return .{
                    .value = element,
                    .writable = false,
                    .enumerable = false,
                    .configurable = true,
                };
            }
        }
        return error.NotHandled;
    }

    const Descriptor = struct {
        value: *Element,
        writable: bool,
        enumerable: bool,
        configurable: bool,
    };

    fn getIndexes(self: *HTMLCollection, frame: *Frame) !js.Array {
        const len = self.length(frame);
        var arr = frame.js.local.?.newArray(len);
        for (0..len) |i| {
            _ = try arr.set(@intCast(i), i, .{});
        }
        return arr;
    }

    // The supported property names: for each element represented by the
    // collection, in tree order, its id and (for HTML elements) its name
    // attribute, skipping empty values and duplicates.
    fn getNames(self: *HTMLCollection, frame: *Frame) !js.Array {
        var names: std.ArrayList([]const u8) = .{};
        const arena = frame.local_arena;

        const len = self.length(frame);
        for (0..len) |i| {
            const element = self.getAtIndex(i, frame) orelse break;
            if (element.getAttributeSafe(comptime .wrap("id"))) |id| {
                if (id.len > 0 and !contains(names.items, id)) {
                    try names.append(arena, id);
                }
            }
            if (element._namespace == .html) {
                if (element.getAttributeSafe(comptime .wrap("name"))) |name| {
                    if (name.len > 0 and !contains(names.items, name)) {
                        try names.append(arena, name);
                    }
                }
            }
        }

        var arr = frame.js.local.?.newArray(@intCast(names.items.len));
        for (names.items, 0..) |name, i| {
            _ = try arr.set(@intCast(i), name, .{});
        }
        return arr;
    }

    fn contains(names: []const []const u8, name: []const u8) bool {
        for (names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    // Supported indexed and named properties can't be deleted (delete returns
    // false, which throws a TypeError in strict mode); unsupported ones follow
    // the ordinary [[Delete]] path.
    fn deleteAtIndex(self: *HTMLCollection, idx: u32, frame: *Frame) !bool {
        if (idx < self.length(frame)) {
            return false;
        }
        return error.NotHandled;
    }

    fn deleteByName(self: *HTMLCollection, name: []const u8, frame: *Frame) !bool {
        if (self.getByName(name, frame) != null) {
            return false;
        }
        return error.NotHandled;
    }

    pub const item = bridge.function(_item, .{});
    fn _item(self: *HTMLCollection, index: i32, frame: *Frame) ?*Element {
        if (index < 0) {
            return null;
        }
        return self.getAtIndex(@intCast(index), frame);
    }

    pub const namedItem = bridge.function(HTMLCollection.getByName, .{});
    pub const symbol_iterator = bridge.iterator(HTMLCollection.iterator, .{});
};
