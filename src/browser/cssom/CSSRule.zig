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

const CSSStyleSheet = @import("CSSStyleSheet.zig");

pub const Interfaces = .{
    CSSRule,
    CSSImportRule,
};

// https://developer.mozilla.org/en-US/docs/Web/API/CSSRule
const CSSRule = @This();
css_text: []const u8,
parent_rule: ?*CSSRule = null,
parent_stylesheet: ?*CSSStyleSheet = null,

pub const CSSImportRule = struct {
    pub const prototype = *CSSRule;
    href: []const u8,
    layer_name: ?[]const u8,
    media: void,
    style_sheet: CSSStyleSheet,
    supports_text: ?[]const u8,
};
