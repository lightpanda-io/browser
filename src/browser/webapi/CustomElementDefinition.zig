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
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Element = @import("Element.zig");

const CustomElementDefinition = @This();

name: []const u8,
constructor: js.Function.Global,
observed_attributes: std.StringHashMapUnmanaged(void) = .{},
// For customized built-in elements, this is the element tag they extend (e.g., .button)
// For autonomous custom elements, this is null
extends: ?Element.Tag = null,

pub fn isAttributeObserved(self: *const CustomElementDefinition, name: []const u8) bool {
    return self.observed_attributes.contains(name);
}

pub fn isAutonomous(self: *const CustomElementDefinition) bool {
    return self.extends == null;
}

pub fn isCustomizedBuiltIn(self: *const CustomElementDefinition) bool {
    return self.extends != null;
}
