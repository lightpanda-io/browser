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
const Frame = @import("../../Frame.zig");

const CSSRule = @import("CSSRule.zig");
const GenericIterator = @import("../collections/iterator.zig").Entry;

const CSSRuleList = @This();

pub fn registerTypes() []const type {
    return &.{ CSSRuleList, ValueIterator };
}

_rules: std.ArrayList(*CSSRule) = .empty,

pub fn init(frame: *Frame) !*CSSRuleList {
    return frame._factory.create(CSSRuleList{});
}

pub fn length(self: *const CSSRuleList) u32 {
    return @intCast(self._rules.items.len);
}

pub fn item(self: *const CSSRuleList, index: usize) ?*CSSRule {
    if (index >= self._rules.items.len) {
        return null;
    }
    return self._rules.items[index];
}

pub fn insert(self: *CSSRuleList, index: u32, rule: *CSSRule, frame: *Frame) !void {
    if (index > self._rules.items.len) {
        return error.IndexSizeError;
    }
    try self._rules.insert(frame.page_arena, index, rule);
}

pub fn remove(self: *CSSRuleList, index: u32) !void {
    if (index >= self._rules.items.len) {
        return error.IndexSizeError;
    }
    _ = self._rules.orderedRemove(index);
}

pub fn clear(self: *CSSRuleList) void {
    self._rules.clearRetainingCapacity();
}

fn values(self: *CSSRuleList, frame: *Frame) !*ValueIterator {
    return .init(.{ .list = self }, frame);
}

const ValueIterator = GenericIterator(Iterator, null);

const Iterator = struct {
    index: u32 = 0,
    list: *CSSRuleList,

    pub fn next(self: *Iterator, _: *Frame) ?*CSSRule {
        const rule = self.list.item(self.index) orelse return null;
        self.index += 1;
        return rule;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSRuleList);

    pub const Meta = struct {
        pub const name = "CSSRuleList";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(CSSRuleList.length, null, .{});
    pub const @"[]" = bridge.indexed(CSSRuleList.item, null, .{ .null_as_undefined = true });
    pub const symbol_iterator = bridge.iterator(CSSRuleList.values, .{});
};
