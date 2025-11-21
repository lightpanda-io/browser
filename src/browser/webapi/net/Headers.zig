const std = @import("std");
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const KeyValueList = @import("../KeyValueList.zig");

const Headers = @This();

_list: KeyValueList,

pub fn init(page: *Page) !*Headers {
    return page._factory.create(Headers{
        ._list = KeyValueList.init(),
    });
}


pub fn append(self: *Headers, name: []const u8, value: []const u8, page: *Page) !void {
    try self._list.append(page.arena, name, value);
}

pub fn delete(self: *Headers, name: []const u8) void {
    self._list.delete(name, null);
}

pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
    return self._list.get(name);
}

pub fn getAll(self: *const Headers, name: []const u8, page: *Page) ![]const []const u8 {
    return self._list.getAll(name, page);
}

pub fn has(self: *const Headers, name: []const u8) bool {
    return self._list.has(name);
}

pub fn set(self: *Headers, name: []const u8, value: []const u8, page: *Page) !void {
    try self._list.set(page.arena, name, value);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Headers);

    pub const Meta = struct {
        pub const name = "Headers";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Headers.init, .{});
    pub const append = bridge.function(Headers.append, .{});
    pub const delete = bridge.function(Headers.delete, .{});
    pub const get = bridge.function(Headers.get, .{});
    pub const getAll = bridge.function(Headers.getAll, .{});
    pub const has = bridge.function(Headers.has, .{});
    pub const set = bridge.function(Headers.set, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Headers" {
    try testing.htmlRunner("net/headers.html", .{});
}
