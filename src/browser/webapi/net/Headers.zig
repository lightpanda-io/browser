const std = @import("std");
const js = @import("../../js/js.zig");
const log = @import("../../../log.zig");

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
    const normalized_name = normalizeHeaderName(name, page);
    try self._list.append(page.arena, normalized_name, value);
}

pub fn delete(self: *Headers, name: []const u8, page: *Page) void {
    const normalized_name = normalizeHeaderName(name, page);
    self._list.delete(normalized_name, null);
}

pub fn get(self: *const Headers, name: []const u8, page: *Page) ?[]const u8 {
    const normalized_name = normalizeHeaderName(name, page);
    return self._list.get(normalized_name);
}

pub fn has(self: *const Headers, name: []const u8, page: *Page) bool {
    const normalized_name = normalizeHeaderName(name, page);
    return self._list.has(normalized_name);
}

pub fn set(self: *Headers, name: []const u8, value: []const u8, page: *Page) !void {
    const normalized_name = normalizeHeaderName(name, page);
    try self._list.set(page.arena, normalized_name, value);
}

pub fn keys(self: *Headers, page: *Page) !*KeyValueList.KeyIterator {
    return KeyValueList.KeyIterator.init(.{ .list = self, .kv = &self._list }, page);
}

pub fn values(self: *Headers, page: *Page) !*KeyValueList.ValueIterator {
    return KeyValueList.ValueIterator.init(.{ .list = self, .kv = &self._list }, page);
}

pub fn entries(self: *Headers, page: *Page) !*KeyValueList.EntryIterator {
    return KeyValueList.EntryIterator.init(.{ .list = self, .kv = &self._list }, page);
}

pub fn forEach(self: *Headers, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    for (self._list._entries.items) |entry| {
        var result: js.Function.Result = undefined;
        cb.tryCall(void, .{ entry.value.str(), entry.name.str(), self }, &result) catch {
            log.debug(.js, "forEach callback", .{ .err = result.exception, .stack = result.stack, .source = "headers" });
        };
    }
}

fn normalizeHeaderName(name: []const u8, page: *Page) []const u8 {
    if (name.len > page.buf.len) {
        return name;
    }
    return std.ascii.lowerString(&page.buf, name);
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
    pub const has = bridge.function(Headers.has, .{});
    pub const set = bridge.function(Headers.set, .{});
    pub const keys = bridge.function(Headers.keys, .{});
    pub const values = bridge.function(Headers.values, .{});
    pub const entries = bridge.function(Headers.entries, .{});
    pub const forEach = bridge.function(Headers.forEach, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Headers" {
    try testing.htmlRunner("net/headers.html", .{});
}
