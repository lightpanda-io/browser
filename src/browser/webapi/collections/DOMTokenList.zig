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
const log = @import("../../../log.zig");
const String = @import("../../../string.zig").String;

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const GenericIterator = @import("iterator.zig").Entry;

pub const DOMTokenList = @This();

// There are a lot of inefficiencies in this code because the list is meant to
// be live, e.g. reflect changes to the underlying attribute. The only good news
// is that lists tend to be very short (often just 1 item).

_element: *Element,
_attribute_name: String,

pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

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
    // Validate in spec order: both empty first, then both whitespace
    if (old_token.len == 0 or new_token.len == 0) {
        return error.SyntaxError;
    }
    if (std.mem.indexOfAny(u8, old_token, WHITESPACE) != null) {
        return error.InvalidCharacterError;
    }
    if (std.mem.indexOfAny(u8, new_token, WHITESPACE) != null) {
        return error.InvalidCharacterError;
    }

    var lookup = try self.getTokens(page);

    // Check if old_token exists
    if (!lookup.contains(old_token)) {
        return false;
    }

    // If replacing with the same token, still need to trigger mutation
    if (std.mem.eql(u8, new_token, old_token)) {
        try self.updateAttribute(lookup, page);
        return true;
    }

    const allocator = page.call_arena;
    // Build new token list preserving order but replacing old with new
    var new_tokens = try std.ArrayList([]const u8).initCapacity(allocator, lookup.count());
    var replaced_old = false;

    for (lookup.keys()) |token| {
        if (std.mem.eql(u8, token, old_token) and !replaced_old) {
            new_tokens.appendAssumeCapacity(new_token);
            replaced_old = true;
        } else if (std.mem.eql(u8, token, old_token)) {
            // Subsequent occurrences of old_token: skip (remove duplicates)
            continue;
        } else if (std.mem.eql(u8, token, new_token) and replaced_old) {
            // Occurrence of new_token AFTER replacement: skip (remove duplicate)
            continue;
        } else {
            // Any other token (including new_token before replacement): keep it
            new_tokens.appendAssumeCapacity(token);
        }
    }

    // Rebuild lookup
    var new_lookup: Lookup = .empty;
    try new_lookup.ensureTotalCapacity(allocator, new_tokens.items.len);
    for (new_tokens.items) |token| {
        try new_lookup.put(allocator, token, {});
    }

    try self.updateAttribute(new_lookup, page);
    return true;
}

pub fn getValue(self: *const DOMTokenList) []const u8 {
    return self._element.getAttributeSafe(self._attribute_name) orelse "";
}

pub fn setValue(self: *DOMTokenList, value: String, page: *Page) !void {
    try self._element.setAttribute(self._attribute_name, value, page);
}

pub fn keys(self: *DOMTokenList, page: *Page) !*KeyIterator {
    return .init(.{ .list = self }, page);
}

pub fn values(self: *DOMTokenList, page: *Page) !*ValueIterator {
    return .init(.{ .list = self }, page);
}

pub fn entries(self: *DOMTokenList, page: *Page) !*EntryIterator {
    return .init(.{ .list = self }, page);
}

pub fn forEach(self: *DOMTokenList, cb_: js.Function, js_this_: ?js.Object, page: *Page) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    const allocator = page.call_arena;

    var i: i32 = 0;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;

    var it = std.mem.tokenizeAny(u8, self.getValue(), WHITESPACE);
    while (it.next()) |token| {
        const gop = try seen.getOrPut(allocator, token);
        if (gop.found_existing) {
            continue;
        }
        var caught: js.TryCatch.Caught = undefined;
        cb.tryCall(void, .{ token, i, self }, &caught) catch {
            log.debug(.js, "forEach callback", .{ .caught = caught, .source = "DOMTokenList" });
            return;
        };
        i += 1;
    }
}

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
    if (tokens.count() > 0) {
        const joined = try std.mem.join(page.call_arena, " ", tokens.keys());
        return self._element.setAttribute(self._attribute_name, .wrap(joined), page);
    }

    // Only remove attribute if it didn't exist before (was null)
    // If it existed (even as ""), set it to "" to preserve its existence
    if (self._element.hasAttributeSafe(self._attribute_name)) {
        try self._element.setAttribute(self._attribute_name, .wrap(""), page);
    }
}

const Iterator = struct {
    index: u32 = 0,
    list: *DOMTokenList,

    const Entry = struct { u32, []const u8 };

    pub fn next(self: *Iterator, page: *Page) !?Entry {
        const index = self.index;
        const node = try self.list.item(index, page) orelse return null;
        self.index = index + 1;
        return .{ index, node };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMTokenList);

    pub const Meta = struct {
        pub const name = "DOMTokenList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
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
    pub const toString = bridge.function(DOMTokenList.getValue, .{});
    pub const keys = bridge.function(DOMTokenList.keys, .{});
    pub const values = bridge.function(DOMTokenList.values, .{});
    pub const entries = bridge.function(DOMTokenList.entries, .{});
    pub const symbol_iterator = bridge.iterator(DOMTokenList.values, .{});
    pub const forEach = bridge.function(DOMTokenList.forEach, .{});
    pub const @"[]" = bridge.indexed(DOMTokenList.item, null, .{ .null_as_undefined = true });
};
