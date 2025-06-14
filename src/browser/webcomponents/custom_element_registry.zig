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
const v8 = @import("v8");

const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

const Element = @import("../dom/element.zig").Element;

pub const CustomElementRegistry = struct {
    // tag_name -> Function
    lookup: std.StringHashMapUnmanaged(Env.Function) = .empty,

    pub fn _define(self: *CustomElementRegistry, tag_name: []const u8, fun: Env.Function, page: *Page) !void {
        log.info(.browser, "define custom element", .{ .name = tag_name });

        const arena = page.arena;
        const gop = try self.lookup.getOrPut(arena, tag_name);
        if (!gop.found_existing) {
            errdefer _ = self.lookup.remove(tag_name);
            const owned_tag_name = try arena.dupe(u8, tag_name);
            gop.key_ptr.* = owned_tag_name;
        }
        gop.value_ptr.* = fun;
        fun.setName(tag_name);
    }

    pub fn _get(self: *CustomElementRegistry, name: []const u8) ?Env.Function {
        return self.lookup.get(name);
    }
};

const testing = @import("../../testing.zig");

test "Browser.CustomElementRegistry" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();
    try runner.testCases(&.{
        // Basic registry access
        .{ "typeof customElements", "object" },
        .{ "customElements instanceof CustomElementRegistry", "true" },

        // Define a simple custom element
        .{
            \\ class MyElement extends HTMLElement {
            \\   constructor() {
            \\      super();
            \\      this.textContent = 'Hello World';
            \\   }
            \\ }
            ,
            null,
        },
        .{ "customElements.define('my-element', MyElement)", "undefined" },

        // Check if element is defined
        .{ "customElements.get('my-element') === MyElement", "true" },
        // .{ "customElements.get('non-existent')", "null" },

        // Create element via document.createElement
        .{ "let el = document.createElement('my-element')", "undefined" },
        .{ "el instanceof MyElement", "true" },
        .{ "el instanceof HTMLElement", "true" },
        .{ "el.tagName", "MY-ELEMENT" },
        .{ "el.textContent", "Hello World" },

        // Create element via HTML parsing
        // .{ "document.body.innerHTML = '<my-element></my-element>'", "undefined" },
        // .{ "let parsed = document.querySelector('my-element')", "undefined" },
        // .{ "parsed instanceof MyElement", "true" },
        // .{ "parsed.textContent", "Hello World" },
    }, .{});
}
