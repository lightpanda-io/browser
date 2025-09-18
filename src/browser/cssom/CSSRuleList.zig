// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const CSSRule = @import("CSSRule.zig");

const CSSImportRule = CSSRule.CSSImportRule;

const CSSRuleList = @This();
list: std.ArrayListUnmanaged([]const u8),

pub fn constructor() CSSRuleList {
    return .{ .list = .empty };
}

pub fn _item(self: *CSSRuleList, _index: u32) ?CSSRule {
    const index: usize = @intCast(_index);

    if (index > self.list.items.len) {
        return null;
    }

    // todo: for now, just return null.
    // this depends on properly parsing CSSRule
    return null;
}

pub fn get_length(self: *CSSRuleList) u32 {
    return @intCast(self.list.items.len);
}

const testing = @import("../../testing.zig");
test "Browser: CSS.CSSRuleList" {
    try testing.htmlRunner("cssom/css_rule_list.html");
}
