const std = @import("std");
const js = @import("../../js/js.zig");

const Element = @import("../Element.zig");
const GenericIterator = @import("iterator.zig").Entry;
const Page = @import("../../Page.zig");

pub const DOMTokenList = @This();

// There are a lot of inefficiencies in this code because the list is meant to
// be live, e.g. reflect changes to the underlying attribute. The only good news
// is that lists tend to be very short (often just 1 item).

_element: *Element,
_attribute_name: []const u8,

const Lookup = std.StringArrayHashMapUnmanaged(void);

const WHITESPACE = " \t\n\r\x0C";

pub fn length(self: *const DOMTokenList, page: *Page) !u32 {
    const tokens = try self.getTokens(page);
    return @intCast(tokens.count());
}

// TODO: soooo..inefficient
pub fn item(self: *const DOMTokenList, index: usize, page: *Page) !?[]const u8 {
    var i: usize = 0;

    const allocator = page.call_arena;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;

    var it = std.mem.tokenizeAny(u8, self.getValue(), WHITESPACE);
    while (it.next()) |token| {
        const gop = try seen.getOrPut(allocator, token);
        if (!gop.found_existing) {
            if (i == index) {
                return token;
            }
            i += 1;
        }
    }
    return null;
}

pub fn contains(self: *const DOMTokenList, search: []const u8) !bool {
    var it = std.mem.tokenizeAny(u8, self.getValue(), WHITESPACE);
    while (it.next()) |token| {
        if (std.mem.eql(u8, search, token)) {
            return true;
        }
    }
    return false;
}

pub fn add(self: *DOMTokenList, tokens: []const []const u8, page: *Page) !void {
    for (tokens) |token| {
        try validateToken(token);
    }

    var lookup = try self.getTokens(page);
    const allocator = page.call_arena;
    try lookup.ensureUnusedCapacity(allocator, tokens.len);

    for (tokens) |token| {
        try lookup.put(allocator, token, {});
    }

    try self.updateAttribute(lookup, page);
}

pub fn remove(self: *DOMTokenList, tokens: []const []const u8, page: *Page) !void {
    for (tokens) |token| {
        try validateToken(token);
    }

    var lookup = try self.getTokens(page);
    for (tokens) |token| {
        _ = lookup.orderedRemove(token);
    }
    try self.updateAttribute(lookup, page);
}

pub fn toggle(self: *DOMTokenList, token: []const u8, force: ?bool, page: *Page) !bool {
    try validateToken(token);

    const has_token = try self.contains(token);

    if (force) |f| {
        if (f) {
            if (!has_token) {
                const tokens_to_add = [_][]const u8{token};
                try self.add(&tokens_to_add, page);
            }
            return true;
        } else {
            if (has_token) {
                const tokens_to_remove = [_][]const u8{token};
                try self.remove(&tokens_to_remove, page);
            }
            return false;
        }
    } else {
        if (has_token) {
            const tokens_to_remove = [_][]const u8{token};
            try self.remove(tokens_to_remove[0..], page);
            return false;
        } else {
            const tokens_to_add = [_][]const u8{token};
            try self.add(tokens_to_add[0..], page);
            return true;
        }
    }
}

pub fn replace(self: *DOMTokenList, old_token: []const u8, new_token: []const u8, page: *Page) !bool {
    try validateToken(old_token);
    try validateToken(new_token);

    var lookup = try self.getTokens(page);
    if (lookup.contains(new_token)) {
        if (std.mem.eql(u8, new_token, old_token) == false) {
            _ = lookup.orderedRemove(old_token);
            try self.updateAttribute(lookup, page);
        }
        return true;
    }

    const key_ptr = lookup.getKeyPtr(old_token) orelse return false;
    key_ptr.* = new_token;
    try self.updateAttribute(lookup, page);
    return true;
}

pub fn getValue(self: *const DOMTokenList) []const u8 {
    return self._element.getAttributeSafe(self._attribute_name) orelse "";
}

pub fn setValue(self: *DOMTokenList, value: []const u8, page: *Page) !void {
    try self._element.setAttribute(self._attribute_name, value, page);
}

pub fn iterator(self: *const DOMTokenList, page: *Page) !*Iterator {
    return Iterator.init(.{ .list = self }, page);
}

pub const Iterator = GenericIterator(struct {
    index: usize = 0,
    list: *const DOMTokenList,

    // TODO: the underlying list.iten is very inefficient!
    pub fn next(self: *@This(), page: *Page) !?[]const u8 {
        const index = self.index;
        self.index = index + 1;
        return self.list.item(index, page);
    }
}, null);

fn getTokens(self: *const DOMTokenList, page: *Page) !Lookup {
    const value = self.getValue();
    if (value.len == 0) {
        return .empty;
    }

    var list: Lookup = .empty;
    const allocator = page.call_arena;
    try list.ensureTotalCapacity(allocator, 4);

    var it = std.mem.tokenizeAny(u8, value, WHITESPACE);
    while (it.next()) |token| {
        try list.put(allocator, token, {});
    }
    return list;
}

fn validateToken(token: []const u8) !void {
    if (token.len == 0) {
        return error.SyntaxError;
    }
    if (std.mem.indexOfAny(u8, token, &std.ascii.whitespace) != null) {
        return error.InvalidCharacterError;
    }
}

fn updateAttribute(self: *DOMTokenList, tokens: Lookup, page: *Page) !void {
    const joined = try std.mem.join(page.call_arena, " ", tokens.keys());
    try self._element.setAttribute(self._attribute_name, joined, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMTokenList);

    pub const Meta = struct {
        pub const name = "DOMTokenList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(DOMTokenList.length, null, .{});
    pub const item = bridge.function(_item, .{});
    fn _item(self: *const DOMTokenList, index: i32, page: *Page) !?[]const u8 {
        if (index < 0) {
            return null;
        }
        return self.item(@intCast(index), page);
    }

    pub const contains = bridge.function(DOMTokenList.contains, .{ .dom_exception = true });
    pub const add = bridge.function(DOMTokenList.add, .{ .dom_exception = true });
    pub const remove = bridge.function(DOMTokenList.remove, .{ .dom_exception = true });
    pub const toggle = bridge.function(DOMTokenList.toggle, .{ .dom_exception = true });
    pub const replace = bridge.function(DOMTokenList.replace, .{ .dom_exception = true });
    pub const value = bridge.accessor(DOMTokenList.getValue, DOMTokenList.setValue, .{});
    pub const symbol_iterator = bridge.iterator(DOMTokenList.iterator, .{});
    pub const @"[]" = bridge.indexed(DOMTokenList.item, .{ .null_as_undefined = true });
};
