const std = @import("std");

const log = @import("../../../log.zig");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const KeyValueList = @import("../KeyValueList.zig");

const Alloctor = std.mem.Allocator;

const FormData = @This();

_arena: Alloctor,
_list: KeyValueList,

pub fn init(page: *Page) !*FormData {
    return page._factory.create(FormData{
        ._arena = page.arena,
        ._list = KeyValueList.init(),
    });
}

pub fn get(self: *const FormData, name: []const u8) ?[]const u8 {
    return self._list.get(name);
}

pub fn getAll(self: *const FormData, name: []const u8, page: *Page) ![]const []const u8 {
    return self._list.getAll(name, page);
}

pub fn has(self: *const FormData, name: []const u8) bool {
    return self._list.has(name);
}

pub fn set(self: *FormData, name: []const u8, value: []const u8) !void {
    return self._list.set(self._arena, name, value);
}

pub fn append(self: *FormData, name: []const u8, value: []const u8) !void {
    return self._list.append(self._arena, name, value);
}

pub fn delete(self: *FormData, name: []const u8) void {
    self._list.delete(name, null);
}

pub fn keys(self: *FormData, page: *Page) !*KeyValueList.KeyIterator {
    return KeyValueList.KeyIterator.init(.{ .list = self, .kv = &self._list }, page);
}

pub fn values(self: *FormData, page: *Page) !*KeyValueList.ValueIterator {
    return KeyValueList.ValueIterator.init(.{ .list = self, .kv = &self._list }, page);
}

pub fn entries(self: *FormData, page: *Page) !*KeyValueList.EntryIterator {
    return KeyValueList.EntryIterator.init(.{ .list = self, .kv = &self._list }, page);
}

pub fn forEach(self: *FormData, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    for (self._list._entries.items) |entry| {
        cb.call(void, .{ entry.value.str(), entry.name.str(), self }) catch |err| {
            // this is a non-JS error
            log.warn(.js, "FormData.forEach", .{ .err = err });
        };
    }
}

pub const Iterator = struct {
    index: u32 = 0,
    list: *const FormData,

    const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, _: *Page) !?Iterator.Entry {
        const index = self.index;
        const items = self.list._list.items();
        if (index >= items.len) {
            return null;
        }
        self.index = index + 1;

        const e = &items[index];
        return .{ e.name.str(), e.value.str() };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(FormData);

    pub const Meta = struct {
        pub const name = "FormData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(FormData.init, .{});
    pub const has = bridge.function(FormData.has, .{});
    pub const get = bridge.function(FormData.get, .{});
    pub const set = bridge.function(FormData.set, .{});
    pub const append = bridge.function(FormData.append, .{});
    pub const getAll = bridge.function(FormData.getAll, .{});
    pub const delete = bridge.function(FormData.delete, .{});
    pub const keys = bridge.function(FormData.keys, .{});
    pub const values = bridge.function(FormData.values, .{});
    pub const entries = bridge.function(FormData.entries, .{});
    pub const symbol_iterator = bridge.iterator(FormData.entries, .{});
    pub const forEach = bridge.function(FormData.forEach, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: FormData" {
    try testing.htmlRunner("net/form_data.html", .{});
}
