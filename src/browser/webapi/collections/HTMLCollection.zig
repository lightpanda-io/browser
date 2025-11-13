const std = @import("std");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");
const NodeLive = @import("node_live.zig").NodeLive;

const Mode = enum {
    tag,
    tag_name,
    class_name,
    child_elements,
};

const HTMLCollection = @This();

data: union(Mode) {
    tag: NodeLive(.tag),
    tag_name: NodeLive(.tag_name),
    class_name: NodeLive(.class_name),
    child_elements: NodeLive(.child_elements),
},

pub fn length(self: *HTMLCollection, page: *const Page) u32 {
    return switch (self.data) {
        inline else => |*impl| impl.length(page),
    };
}

pub fn getAtIndex(self: *HTMLCollection, index: usize, page: *const Page) ?*Element {
    return switch (self.data) {
        inline else => |*impl| impl.getAtIndex(index, page),
    };
}

pub fn getByName(self: *HTMLCollection, name: []const u8, page: *Page) ?*Element {
    return switch (self.data) {
        inline else => |*impl| impl.getByName(name, page),
    };
}

pub fn iterator(self: *HTMLCollection, page: *Page) !*Iterator {
    return Iterator.init(.{
        .list = self,
        .tw = switch (self.data) {
            .tag => |*impl| .{ .tag = impl._tw.clone() },
            .tag_name => |*impl| .{ .tag_name = impl._tw.clone() },
            .class_name => |*impl| .{ .class_name = impl._tw.clone() },
            .child_elements => |*impl| .{ .child_elements = impl._tw.clone() },
        },
    }, page);
}

const GenericIterator = @import("iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    list: *HTMLCollection,
    tw: union(Mode) {
        tag: TreeWalker.FullExcludeSelf,
        tag_name: TreeWalker.FullExcludeSelf,
        class_name: TreeWalker.FullExcludeSelf,
        child_elements: TreeWalker.Children,
    },

    pub fn next(self: *@This(), _: *Page) ?*Element {
        return switch (self.list.data) {
            .tag => |*impl| impl.nextTw(&self.tw.tag),
            .tag_name => |*impl| impl.nextTw(&self.tw.tag_name),
            .class_name => |*impl| impl.nextTw(&self.tw.class_name),
            .child_elements => |*impl| impl.nextTw(&self.tw.child_elements),
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
    pub const @"[int]" = bridge.indexed(HTMLCollection.getAtIndex, .{ .null_as_undefined = true });
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
