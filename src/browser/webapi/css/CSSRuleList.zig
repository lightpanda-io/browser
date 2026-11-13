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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const RuleStore = @import("../../css/RuleStore.zig");

const CSSRule = @import("CSSRule.zig");
const GenericIterator = @import("../collections/iterator.zig").Entry;

/// A view of a RuleStore: a sheet's rules, or a style rule's nested ones.
const CSSRuleList = @This();

pub fn registerTypes() []const type {
    return &.{ CSSRuleList, ValueIterator };
}

_store: *RuleStore,

pub fn init(store: *RuleStore, frame: *Frame) !*CSSRuleList {
    return frame._factory.create(CSSRuleList{ ._store = store });
}

fn parsedStore(self: *const CSSRuleList, frame: *Frame) !*RuleStore {
    const store = self._store;
    const sheet = store._sheet;
    if (store == &sheet._store) {
        // // The sheet's own rules, not a nested one. Might have changed.
        try sheet.ensureParsed(frame);
    }
    return store;
}

fn length(self: *const CSSRuleList, frame: *Frame) !u32 {
    return (try self.parsedStore(frame)).length();
}

fn item(self: *const CSSRuleList, index: usize, frame: *Frame) !?*CSSRule {
    const store = try self.parsedStore(frame);
    if (index >= store.length()) {
        return null;
    }
    return try store._sheet.ruleView(store, @intCast(index), frame);
}

fn values(self: *CSSRuleList, frame: *Frame) !*ValueIterator {
    return .init(.{ .list = self }, frame);
}

const ValueIterator = GenericIterator(Iterator, null);

const Iterator = struct {
    index: u32 = 0,
    list: *CSSRuleList,

    pub fn next(self: *Iterator, frame: *Frame) !?*CSSRule {
        const rule = try self.list.item(self.index, frame) orelse return null;
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

    pub const length = bridge.fastAccessor(CSSRuleList.length, null, .{ .getter = .safe });
    pub const @"[]" = bridge.indexed(CSSRuleList.item, null, .{ .null_as_undefined = true });
    pub const symbol_iterator = bridge.iterator(CSSRuleList.values, .{});
};
