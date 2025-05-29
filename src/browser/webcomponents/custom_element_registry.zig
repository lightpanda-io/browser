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
    map: std.StringHashMapUnmanaged(v8.FunctionTemplate) = .empty,
    constructors: std.StringHashMapUnmanaged(v8.Persistent(v8.Function)) = .empty,

    pub fn _define(self: *CustomElementRegistry, name: []const u8, el: Env.Function, page: *Page) !void {
        log.info(.browser, "Registering WebComponent", .{ .component = name });

        const context = page.main_context;
        const duped_name = try page.arena.dupe(u8, name);

        const template = v8.FunctionTemplate.initCallback(context.isolate, struct {
            fn callback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                const this = info.getThis();

                const isolate = info.getIsolate();
                const ctx = isolate.getCurrentContext();

                const registry_key = v8.String.initUtf8(isolate, "__lightpanda_constructor");
                const original_function = this.getValue(ctx, registry_key.toName()) catch unreachable;
                if (original_function.isFunction()) {
                    const f = original_function.castTo(Env.Function);
                    f.call(void, .{}) catch unreachable;
                }
            }
        }.callback);

        const instance_template = template.getInstanceTemplate();
        instance_template.setInternalFieldCount(1);

        const registry_key = v8.String.initUtf8(context.isolate, "__lightpanda_constructor");
        instance_template.set(registry_key.toName(), el.func, (1 << 1));

        const class_name = v8.String.initUtf8(context.isolate, name);
        template.setClassName(class_name);

        try self.map.put(page.arena, duped_name, template);

        // const entry = try self.map.getOrPut(page.arena, try page.arena.dupe(u8, name));
        // if (entry.found_existing) return error.NotSupportedError;
        // entry.value_ptr.* = el;
    }

    pub fn _get(self: *CustomElementRegistry, name: []const u8, page: *Page) ?Env.Function {
        if (self.map.get(name)) |template| {
            const func = template.getFunction(page.main_context.v8_context);
            return Env.Function{
                .js_context = page.main_context,
                .func = v8.Persistent(v8.Function).init(page.main_context.isolate, func),
                .id = func.toObject().getIdentityHash(),
            };
        } else return null;
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
            \\ class MyElement {
            \\   constructor() {
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
        // .{ "el instanceof MyElement", "true" },
        // .{ "el instanceof HTMLElement", "true" },
        // .{ "el.tagName", "MY-ELEMENT" },
        // .{ "el.textContent", "Hello World" },

        // Create element via HTML parsing
        // .{ "document.body.innerHTML = '<my-element></my-element>'", "undefined" },
        // .{ "let parsed = document.querySelector('my-element')", "undefined" },
        // .{ "parsed instanceof MyElement", "true" },
        // .{ "parsed.textContent", "Hello World" },
    }, .{});
}
