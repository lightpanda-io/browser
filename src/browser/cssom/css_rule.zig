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

const Session = @import("../session.zig").Session;

const CSSStyleDeclaration = @import("css_style_declaration.zig").CSSStyleDeclaration;
const CSSStyleSheet = @import("css_stylesheet.zig").CSSStyleSheet;

const Interfaces = .{
    CSSRule,
    CSSGroupingRule,
    CSSStyleRule,
    CSSImportRule,
};

pub const CSSRule = struct {
    css_text: []const u8,
    parent_rule: ?*CSSRule,
    parent_stylesheet: ?*CSSStyleSheet,
};

pub const CSSGroupingRule = struct {
    pub const prototype = *CSSRule;
    list: std.ArrayListUnmanaged(CSSRule),

    pub fn _insertRule(self: *CSSGroupingRule, rule: []const u8, _index: ?usize, session: *Session) !usize {
        if (_index > self.list.items.len) return error.IndexSizeError;

        const index = _index orelse 0;
        const css_rule: CSSRule = .{ .css_text = rule };
        try self.list.insert(session.arena, index, css_rule);
    }

    pub fn _deleteRule(self: *CSSGroupingRule, index: usize) !void {
        if (index > self.list.items.len) return error.IndexSizeError;

        try self.list.orderedRemove(index);
    }
};

pub const CSSStyleRule = struct {
    pub const prototype = *CSSGroupingRule;
    selector_text: []const u8,
    style: CSSStyleDeclaration,
};

pub const CSSImportRule = struct {
    pub const prototype = *CSSRule;
    href: []const u8,
    layer_name: ?[]const u8,
    media: void,
    style_sheet: CSSStyleSheet,
    supports_text: ?[]const u8,
};
