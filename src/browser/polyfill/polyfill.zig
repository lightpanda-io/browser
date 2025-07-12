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
const builtin = @import("builtin");

const log = @import("../../log.zig");
const Allocator = std.mem.Allocator;
const Env = @import("../env.zig").Env;

pub const Loader = struct {
    state: enum { empty, loading } = .empty,

    done: struct {
        fetch: bool = false,
        webcomponents: bool = false,
    } = .{},

    fn load(self: *Loader, comptime name: []const u8, source: []const u8, js_context: *Env.JsContext) void {
        var try_catch: Env.TryCatch = undefined;
        try_catch.init(js_context);
        defer try_catch.deinit();

        self.state = .loading;
        defer self.state = .empty;

        log.debug(.js, "polyfill load", .{ .name = name });
        _ = js_context.exec(source, name) catch |err| {
            log.fatal(.app, "polyfill error", .{
                .name = name,
                .err = try_catch.err(js_context.call_arena) catch @errorName(err) orelse @errorName(err),
            });
        };

        @field(self.done, name) = true;
    }

    // CompilationCallback implementation
    pub fn script(self: *Loader, src: []const u8, _: ?[]const u8, js_context: *Env.JsContext) void {
        if (!self.done.webcomponents and containsWebcomponents(src)) {
            const source = @import("webcomponents.zig").source;
            self.load("webcomponents", source, js_context);
        }
    }

    // CompilationCallback implementation
    pub fn module(self: *Loader, src: []const u8, _: []const u8, js_context: *Env.JsContext) void {
        if (!self.done.webcomponents and containsWebcomponents(src)) {
            const source = @import("webcomponents.zig").source;
            self.load("webcomponents", source, js_context);
        }
    }

    // GlobalMissingCallback implementation
    pub fn missing(self: *Loader, name: []const u8, js_context: *Env.JsContext) bool {
        // Avoid recursive calls during polyfill loading.
        if (self.state == .loading) {
            return false;
        }

        if (!self.done.fetch and isFetch(name)) {
            const source = @import("fetch.zig").source;
            self.load("fetch", source, js_context);

            // We return false here: We want v8 to continue the calling chain
            // to finally find the polyfill we just inserted. If we want to
            // return false and stops the call chain, we have to use
            // `info.GetReturnValue.Set()` function, or `undefined` will be
            // returned immediately.
            return false;
        }

        if (!self.done.webcomponents and isWebcomponents(name)) {
            const source = @import("webcomponents.zig").source;
            self.load("webcomponents", source, js_context);

            // We return false here: We want v8 to continue the calling chain
            // to finally find the polyfill we just inserted. If we want to
            // return false and stops the call chain, we have to use
            // `info.GetReturnValue.Set()` function, or `undefined` will be
            // returned immediately.
            return false;
        }

        if (comptime builtin.mode == .Debug) {
            log.debug(.unknown_prop, "unkown global property", .{
                .info = "but the property can exist in pure JS",
                .property = name,
            });
        }

        return false;
    }

    fn isFetch(name: []const u8) bool {
        if (std.mem.eql(u8, name, "fetch")) return true;
        if (std.mem.eql(u8, name, "Request")) return true;
        if (std.mem.eql(u8, name, "Response")) return true;
        if (std.mem.eql(u8, name, "Headers")) return true;
        return false;
    }

    fn isWebcomponents(name: []const u8) bool {
        if (std.mem.eql(u8, name, "customElements")) return true;
        return false;
    }

    fn containsWebcomponents(src: []const u8) bool {
        return std.mem.indexOf(u8, src, " extends ") != null;
    }
};
