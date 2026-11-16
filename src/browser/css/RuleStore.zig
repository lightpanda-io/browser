// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const CSSStyleSheet = @import("../webapi/css/CSSStyleSheet.zig");

const DeclarationBlock = @import("DeclarationBlock.zig");

const Allocator = std.mem.Allocator;

/// The internal representation of a sheet's rule. Rather than creating every
/// rule as a CSSRule upfront, we create them JIT, from the data here. Just like
/// Attributes.List does for Attr nodes.
/// All allocations are on the factory's storage allocator.
const RuleStore = @This();

/// The sheet the rules were parsed into.
_sheet: *CSSStyleSheet,

/// Removed from the sheet, with a rule that JS still holds.
_detached: bool = false,
_len: u32 = 0,
_cap: u32 = 0,
_entries: [*]Entry = @constCast(&empty_entries),

const empty_entries: [0]Entry = .{};

pub fn init(allocator: Allocator, sheet: *CSSStyleSheet) !*RuleStore {
    const self = try allocator.create(RuleStore);
    self.* = .{ ._sheet = sheet };
    return self;
}

/// Frees the list itself, not its rules: the caller has taken or freed them.
pub fn deinit(self: *RuleStore, allocator: Allocator) void {
    allocator.free(self._entries[0..self._cap]);
    allocator.destroy(self);
}

pub fn entries(self: *const RuleStore) []Entry {
    return self._entries[0..self._len];
}

pub fn length(self: *const RuleStore) u32 {
    return self._len;
}

/// The index of the rule numbered `id`
pub fn indexOf(self: *const RuleStore, id: u32, hint: u32) ?u32 {
    const all = self.entries();
    // check hint first
    if (hint < all.len and all[hint]._id == id) {
        return hint;
    }

    for (all, 0..) |*entry, i| {
        if (entry._id == id) {
            return @intCast(i);
        }
    }
    return null;
}

pub fn insert(self: *RuleStore, allocator: Allocator, index: u32, entry: Entry) !void {
    std.debug.assert(index <= self._len);
    try self.ensureUnusedCapacity(allocator, 1);
    const all = self._entries[0 .. self._len + 1];
    std.mem.copyBackwards(Entry, all[index + 1 ..], all[index .. all.len - 1]);
    all[index] = entry;
    self._len += 1;
}

pub fn ensureUnusedCapacity(self: *RuleStore, allocator: Allocator, count: u32) !void {
    const needed = std.math.add(u32, self._len, count) catch return error.OutOfMemory;
    if (needed <= self._cap) {
        return;
    }
    const grown = std.math.add(u32, self._cap, self._cap / 2 + 4) catch return error.OutOfMemory;
    try self.setCapacity(allocator, @max(needed, grown));
}

pub fn appendAssumeCapacity(self: *RuleStore, entry: Entry) void {
    std.debug.assert(self._len < self._cap);
    self._entries[self._len] = entry;
    self._len += 1;
}

pub fn append(self: *RuleStore, allocator: Allocator, entry: Entry) !void {
    return self.insert(allocator, self._len, entry);
}

pub fn appendSlice(self: *RuleStore, allocator: Allocator, items: []const Entry) !void {
    const len = std.math.add(u32, self._len, std.math.cast(u32, items.len) orelse return error.OutOfMemory) catch return error.OutOfMemory;
    if (len > self._cap) {
        // A first parse is sized exactly: a sheet arrives in one piece. One
        // re-parsed as it grows (text appended to a <style>) grows by half, or
        // every new size would leave the old array behind.
        const grown = if (self._cap == 0) len else @max(len, self._cap +| self._cap / 2);
        try self.setCapacity(allocator, grown);
    }
    @memcpy(self._entries[self._len..len], items);
    self._len = len;
}

/// Removes the rule at `index` and hands it to the caller.
pub fn take(self: *RuleStore, index: u32) Entry {
    const all = self.entries();
    const entry = all[index];
    std.mem.copyForwards(Entry, all[index..], all[index + 1 ..]);
    self._len -= 1;
    return entry;
}

/// A parsed list rarely changes after. Gives back the spare room.
pub fn trim(self: *RuleStore, allocator: Allocator) !void {
    if (self._cap > self._len) {
        try self.setCapacity(allocator, self._len);
    }
}

fn setCapacity(self: *RuleStore, allocator: Allocator, cap: u32) !void {
    const resized = try allocator.realloc(self._entries[0..self._cap], cap);
    self._entries = resized.ptr;
    self._cap = cap;
}

/// Marks this list and every list nested in it as removed from the sheet.
pub fn markDetached(self: *RuleStore) void {
    self._detached = true;
    for (self.entries()) |*entry| {
        if (entry._children) |children| {
            children.markDetached();
        }
    }
}

pub const Entry = struct {
    // A grouping rule's rules, or those nested in a style rule's block (CSS
    // Nesting). Always set for a grouping rule with a block.
    _children: ?*RuleStore = null,
    // A style rule's declarations, or those of a grouping rule nested in a
    // style rule. Otherwise empty.
    _block: DeclarationBlock = .{},
    // A style rule's selector; a grouping rule's keyword and prelude
    // (`@media <query>`, see initPrelude); any other at-rule's source as written.
    _text_ptr: [*]const u8,
    _text_len: u32,
    // Unique within the sheet, so a view finds its rule after inserts and
    // deletes shift it.
    _id: u32,
    _kind: Kind,

    comptime {
        std.debug.assert(@sizeOf(Entry) <= 48);
    }

    pub fn init(allocator: Allocator, kind: Kind, text_: []const u8, id: u32) !Entry {
        if (text_.len > std.math.maxInt(u32)) {
            return error.StringTooLarge;
        }
        const owned = try allocator.dupe(u8, text_);
        return .{
            ._id = id,
            ._kind = kind,
            ._text_ptr = owned.ptr,
            ._text_len = @intCast(owned.len),
        };
    }

    /// A grouping rule (@media, @supports, @layer): its keyword, lowercased
    /// as Chrome serializes it, then its prelude.
    pub fn initPrelude(allocator: Allocator, kind: Kind, prelude: []const u8, id: u32) !Entry {
        const name = switch (kind) {
            .media => "@media",
            .supports => "@supports",
            .layer => "@layer",
            else => unreachable,
        };
        const len = name.len + @intFromBool(prelude.len > 0) + prelude.len;
        if (len > std.math.maxInt(u32)) {
            return error.StringTooLarge;
        }
        const owned = try allocator.alloc(u8, len);
        @memcpy(owned[0..name.len], name);
        if (prelude.len > 0) {
            owned[name.len] = ' ';
            @memcpy(owned[name.len + 1 ..], prelude);
        }
        return .{
            ._id = id,
            ._kind = kind,
            ._text_ptr = owned.ptr,
            ._text_len = @intCast(owned.len),
        };
    }

    /// Frees the rule's own text and declarations, not its children.
    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.text());
        self._block.deinit(allocator);
    }

    pub fn text(self: *const Entry) []const u8 {
        return self._text_ptr[0..self._text_len];
    }

    pub fn setText(self: *Entry, allocator: Allocator, new_text: []const u8) !void {
        if (new_text.len > std.math.maxInt(u32)) {
            return error.StringTooLarge;
        }
        const owned = try allocator.dupe(u8, new_text);
        allocator.free(self.text());
        self._text_ptr = owned.ptr;
        self._text_len = @intCast(owned.len);
    }
};

/// What a rule is. The at-rules are in the order of the CSSOM rule-type
/// constants, starting at CHARSET_RULE (2).
pub const Kind = enum(u8) {
    style,
    charset,
    import,
    media,
    font_face,
    page,
    keyframes,
    keyframe,
    margin,
    namespace,
    counter_style,
    supports,
    document,
    font_feature_values,
    viewport,
    region_style,
    layer,
    unknown,

    pub fn ruleType(self: Kind) u16 {
        return switch (self) {
            .layer, .unknown => 0,
            else => @as(u16, @backingInt(self)) + 1,
        };
    }

    /// The kind of an at-rule from its keyword (without `@`).
    pub fn ofAtRule(keyword_with_prefix: []const u8) Kind {
        var keyword = keyword_with_prefix;

        // strip vendor prefixes
        inline for (.{ "-webkit-", "-moz-", "-ms-", "-o-" }) |prefix| {
            if (std.ascii.startsWithIgnoreCase(keyword, prefix)) {
                keyword = keyword[prefix.len..];
                break;
            }
        }

        const eql = std.ascii.eqlIgnoreCase;
        if (eql(keyword, "media")) {
            return .media;
        }
        if (eql(keyword, "keyframes")) {
            return .keyframes;
        }
        if (eql(keyword, "supports")) {
            return .supports;
        }
        if (eql(keyword, "font-face")) {
            return .font_face;
        }
        if (eql(keyword, "import")) {
            return .import;
        }
        if (eql(keyword, "charset")) {
            return .charset;
        }
        if (eql(keyword, "namespace")) {
            return .namespace;
        }
        if (eql(keyword, "page")) {
            return .page;
        }
        if (eql(keyword, "counter-style")) {
            return .counter_style;
        }
        if (eql(keyword, "font-feature-values")) {
            return .font_feature_values;
        }
        if (eql(keyword, "viewport")) {
            return .viewport;
        }
        if (eql(keyword, "document")) {
            return .document;
        }
        if (eql(keyword, "layer")) {
            return .layer;
        }
        return .unknown;
    }
};

const testing = @import("../../testing.zig");
test "RuleStore: insert, take and find by id" {
    const allocator = testing.allocator;
    var list: RuleStore = .{ ._sheet = undefined };
    defer {
        for (list.entries()) |*entry| {
            entry.deinit(allocator);
        }
        allocator.free(list._entries[0..list._cap]);
    }

    try list.append(allocator, try .init(allocator, .style, ".a", 0));
    try list.append(allocator, try .init(allocator, .media, "@media print {}", 1));
    try list.insert(allocator, 0, try .init(allocator, .style, ".b", 2));
    try testing.expectEqual(".b", list.entries()[0].text());
    try testing.expectEqual(".a", list.entries()[1].text());

    // A stale hint falls back to a scan.
    try testing.expectEqual(1, list.indexOf(0, 0));
    try testing.expectEqual(1, list.indexOf(0, 1));
    try testing.expectEqual(2, list.indexOf(1, 99));
    try testing.expectEqual(null, list.indexOf(7, 0));

    var taken = list.take(1);
    defer taken.deinit(allocator);
    try testing.expectEqual(0, taken._id);
    try testing.expectEqual(2, list.length());
    try testing.expectEqual(1, list.indexOf(1, 2));

    try list.entries()[0].setText(allocator, ".c");
    try testing.expectEqual(".c", list.entries()[0].text());

    try list.trim(allocator);
    try testing.expectEqual(2, list._cap);

    try list.appendSlice(allocator, &.{try .init(allocator, .style, ".d", 3)});
    try testing.expectEqual(".d", list.entries()[2].text());
}

test "RuleStore: appendSlice sizing" {
    const allocator = testing.allocator;
    var list: RuleStore = .{ ._sheet = undefined };
    defer {
        for (list.entries()) |*entry| {
            entry.deinit(allocator);
        }
        allocator.free(list._entries[0..list._cap]);
    }

    // A first parse is sized exactly
    try list.appendSlice(allocator, &.{
        try .init(allocator, .style, ".a", 0),
        try .init(allocator, .style, ".b", 1),
        try .init(allocator, .style, ".c", 2),
        try .init(allocator, .style, ".d", 3),
    });
    try testing.expectEqual(4, list._cap);

    // Growing again goes up by half
    try list.appendSlice(allocator, &.{try .init(allocator, .style, ".e", 4)});
    try testing.expectEqual(6, list._cap);
    try testing.expectEqual(5, list.length());
}

test "RuleStore: Entry.initPrelude" {
    const allocator = testing.allocator;
    var media = try Entry.initPrelude(allocator, .media, "(min-width: 1px)", 1);
    defer media.deinit(allocator);
    try testing.expectEqual("@media (min-width: 1px)", media.text());

    var layer = try Entry.initPrelude(allocator, .layer, "", 2);
    defer layer.deinit(allocator);
    try testing.expectEqual("@layer", layer.text());
}

test "RuleStore: Kind" {
    try testing.expectEqual(1, Kind.style.ruleType());
    try testing.expectEqual(4, Kind.ofAtRule("media").ruleType());
    try testing.expectEqual(7, Kind.ofAtRule("-webkit-keyframes").ruleType());
    try testing.expectEqual(0, Kind.ofAtRule("layer").ruleType());
    try testing.expectEqual(0, Kind.ofAtRule("nope").ruleType());
}
