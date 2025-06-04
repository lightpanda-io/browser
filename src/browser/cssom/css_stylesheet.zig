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

const StyleSheet = @import("stylesheet.zig").StyleSheet;

const CSSRule = @import("css_rule.zig").CSSRule;
const CSSImportRule = @import("css_rule.zig").CSSImportRule;

pub const CSSStyleSheet = struct {
    pub const prototype = *StyleSheet;

    css_rules: std.ArrayListUnmanaged(CSSRule),
    owner_rule: ?*CSSImportRule,

    pub fn constructor() CSSStyleSheet {
        return .{ .css_rules = .empty, .owner_rule = null };
    }

    // pub fn _insertRule(self: *CSSStyleSheet, rule: []const u8) u32 {
    //     const next_index = self.css_rules.items.len + 1;
    //     _ = next_index;
    //     _ = rule;
    //     return 0;
    // }
};
