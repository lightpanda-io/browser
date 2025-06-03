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

const parser = @import("../netsurf.zig");

// https://developer.mozilla.org/en-US/docs/Web/API/StyleSheet#specifications
pub const StyleSheet = struct {
    disabled: bool,
    href: []const u8,
    owner_node: *parser.Node,
    parent_stylesheet: ?*StyleSheet,
    title: []const u8,
    type: []const u8,

    pub fn get_disabled(self: *StyleSheet) bool {
        return self.disabled;
    }

    pub fn get_href(self: *StyleSheet) []const u8 {
        return self.href;
    }

    // TODO: media

    pub fn get_ownerNode(self: *StyleSheet) *parser.Node {
        return self.owner_node;
    }

    pub fn get_parentStyleSheet(self: *StyleSheet) ?*StyleSheet {
        return self.parent_stylesheet;
    }

    pub fn get_title(self: *StyleSheet) []const u8 {
        return self.title;
    }

    pub fn get_type(self: *StyleSheet) []const u8 {
        return self.type;
    }
};
