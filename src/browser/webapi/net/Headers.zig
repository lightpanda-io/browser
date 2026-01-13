const std = @import("std");
const js = @import("../../js/js.zig");
const log = @import("../../../log.zig");

const Page = @import("../../Page.zig");
const KeyValueList = @import("../KeyValueList.zig");

const Allocator = std.mem.Allocator;

const Headers = @This();

_list: KeyValueList,

pub const InitOpts = union(enum) {
    obj: *Headers,
    strings: []const [2][]const u8,
    js_obj: js.Object,
};

pub fn init(opts_: ?InitOpts, page: *Page) !*Headers {
    const list = if (opts_) |opts| switch (opts) {
        .obj => |obj| try KeyValueList.copy(page.arena, obj._list),
        .js_obj => |js_obj| try KeyValueList.fromJsObject(page.arena, js_obj, normalizeHeaderName, page),
        .strings => |kvs| try KeyValueList.fromArray(page.arena, kvs, normalizeHeaderName, page),
    } else KeyValueList.init();

    return page._factory.create(Headers{
        ._list = list,
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

pub fn get(self: *const Headers, name: []const u8, page: *Page) !?[]const u8 {
    const normalized_name = normalizeHeaderName(name, page);
    const all_values = try self._list.getAll(normalized_name, page);

    if (all_values.len == 0) {
        return null;
    }
    if (all_values.len == 1) {
        return all_values[0];
    }
    return try std.mem.join(page.call_arena, ", ", all_values);
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
        var caught: js.TryCatch.Caught = undefined;
        cb.tryCall(void, .{ entry.value.str(), entry.name.str(), self }, &caught) catch {
            log.debug(.js, "forEach callback", .{ .caught = caught, .source = "headers" });
        };
    }
}

// TODO: do we really need 2 different header structs??
const Http = @import("../../../http/Http.zig");
pub fn populateHttpHeader(self: *Headers, allocator: Allocator, http_headers: *Http.Headers) !void {
    for (self._list._entries.items) |entry| {
        const merged = try std.mem.concatWithSentinel(allocator, u8, &.{ entry.name.str(), ": ", entry.value.str() }, 0);
        try http_headers.add(merged);
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
