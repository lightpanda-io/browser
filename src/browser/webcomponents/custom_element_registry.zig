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
const log = @import("../../log.zig");

const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

const Element = @import("../dom/element.zig").Element;

pub const CustomElementRegistry = struct {
    map: std.StringHashMapUnmanaged(Env.Function) = .empty,

    pub fn _define(self: *CustomElementRegistry, name: []const u8, el: Env.Function, page: *Page) !void {
        log.info(.browser, "Registering WebComponent", .{ .component = name });
        try self.map.put(page.arena, try page.arena.dupe(u8, name), el);
        // const entry = try self.map.getOrPut(page.arena, try page.arena.dupe(u8, name));
        // if (entry.found_existing) return error.NotSupportedError;
        // entry.value_ptr.* = el;
    }
};
