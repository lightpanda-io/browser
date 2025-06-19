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

pub const Stylesheet = @import("stylesheet.zig").StyleSheet;
pub const CSSStylesheet = @import("css_stylesheet.zig").CSSStyleSheet;
pub const CSSStyleDeclaration = @import("css_style_declaration.zig").CSSStyleDeclaration;
pub const CSSRuleList = @import("css_rule_list.zig").CSSRuleList;

pub const Interfaces = .{
    Stylesheet,
    CSSStylesheet,
    CSSStyleDeclaration,
    CSSRuleList,
    @import("css_rule.zig").Interfaces,
};
