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

const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;
const StyleSheet = @import("StyleSheet.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const CSSImportRule = @import("CSSRule.zig").CSSImportRule;

const CSSStyleSheet = @This();
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
        .proto = .{ .disabled = opts.disabled },
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

pub fn _replace(self: *CSSStyleSheet, text: []const u8, page: *Page) !Env.Promise {
    _ = self;
    _ = text;
    // TODO: clear self.css_rules
    // parse text and re-populate self.css_rules

    const resolver = page.main_context.createPromiseResolver();
    try resolver.resolve({});
    return resolver.promise();
}

pub fn _replaceSync(self: *CSSStyleSheet, text: []const u8) !void {
    _ = self;
    _ = text;
    // TODO: clear self.css_rules
    // parse text and re-populate self.css_rules
}

const testing = @import("../../testing.zig");
test "Browser: CSS.StyleSheet" {
    try testing.htmlRunner("cssom/css_stylesheet.html");
}
