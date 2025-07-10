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
    } = .{},

    pub fn load(name: []const u8, source: []const u8, js_context: *Env.JsContext) !void {
        var try_catch: Env.TryCatch = undefined;
        try_catch.init(js_context);
        defer try_catch.deinit();

        _ = js_context.exec(source, name) catch |err| {
            if (try try_catch.err(js_context.call_arena)) |msg| {
                log.fatal(.app, "polyfill error", .{ .name = name, .err = msg });
            }
            return err;
        };
    }

    pub fn missing(self: *Loader, name: []const u8, js_context: *Env.JsContext) bool {
        // Avoid recursive calls during polyfill loading.
        if (self.state == .loading) {
            return false;
        }

        if (!self.done.fetch and isFetch(name)) {
            self.state = .loading;
            defer self.state = .empty;

            const _name = "fetch";
            const source = @import("fetch.zig").source;
            log.debug(.polyfill, "dynamic load", .{ .property = name });
            load(_name, source, js_context) catch |err| {
                log.fatal(.app, "polyfill load", .{ .name = name, .err = err });
            };

            // load the polyfill once.
            self.done.fetch = true;

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
};
