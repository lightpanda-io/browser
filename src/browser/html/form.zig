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
const Allocator = std.mem.Allocator;

const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;
const HTMLElement = @import("elements.zig").HTMLElement;

pub const HTMLFormElement = struct {
    pub const Self = parser.Form;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn _submit(self: *parser.Form, page: *Page) !void {
        return page.submitForm(self, null);
    }

    pub fn _reset(self: *parser.Form) !void {
        try parser.formElementReset(self);
    }
};
