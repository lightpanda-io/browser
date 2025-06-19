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

const Page = @import("../page.zig").Page;
const StyleSheet = @import("stylesheet.zig").StyleSheet;

const CSSRuleList = @import("css_rule_list.zig").CSSRuleList;
const CSSImportRule = @import("css_rule.zig").CSSImportRule;

pub const CSSStyleSheet = struct {
    pub const prototype = *StyleSheet;

    proto: StyleSheet,
    css_rules: CSSRuleList,
    owner_rule: ?*CSSImportRule,

    const CSSStyleSheetOpts = struct {
        base_url: ?[]const u8 = null,
        // TODO: Suupport media
        disabled: bool = false,
    };

    pub fn constructor(_opts: ?CSSStyleSheetOpts) !CSSStyleSheet {
        const opts = _opts orelse CSSStyleSheetOpts{};
        return .{
            .proto = StyleSheet{ .disabled = opts.disabled },
            .css_rules = .constructor(),
            .owner_rule = null,
        };
    }

    pub fn get_ownerRule(_: *CSSStyleSheet) ?*CSSImportRule {
        return null;
    }

    pub fn get_cssRules(self: *CSSStyleSheet) *CSSRuleList {
        return &self.css_rules;
    }

    pub fn _insertRule(self: *CSSStyleSheet, rule: []const u8, _index: ?usize, page: *Page) !usize {
        const index = _index orelse 0;
        if (index > self.css_rules.list.items.len) {
            return error.IndexSize;
        }

        const arena = page.arena;
        try self.css_rules.list.insert(arena, index, try arena.dupe(u8, rule));
        return index;
    }

    pub fn _deleteRule(self: *CSSStyleSheet, index: usize) !void {
        if (index > self.css_rules.list.items.len) {
            return error.IndexSize;
        }

        _ = self.css_rules.list.orderedRemove(index);
    }
};

const testing = @import("../../testing.zig");
test "Browser.CSS.StyleSheet" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let css = new CSSStyleSheet()", "undefined" },
        .{ "css instanceof CSSStyleSheet", "true" },
        .{ "css.cssRules.length", "0" },
        .{ "css.ownerRule", "null" },
        .{ "let index1 = css.insertRule('body { color: red; }', 0)", "undefined" },
        .{ "index1", "0" },
        .{ "css.cssRules.length", "1" },
    }, .{});
}
