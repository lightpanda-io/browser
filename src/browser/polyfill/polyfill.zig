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
const builtin = @import("builtin");

const js = @import("../js/js.zig");
const log = @import("../../log.zig");
const Allocator = std.mem.Allocator;

pub const Loader = struct {
    state: enum { empty, loading } = .empty,

    done: struct {} = .{},

    fn load(self: *Loader, comptime name: []const u8, source: []const u8, js_context: *js.Context) void {
        var try_catch: js.TryCatch = undefined;
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

    pub fn missing(self: *Loader, name: []const u8, js_context: *js.Context) bool {
        // Avoid recursive calls during polyfill loading.
        if (self.state == .loading) {
            return false;
        }

        if (comptime builtin.mode == .Debug) {
            log.debug(.unknown_prop, "unkown global property", .{
                .info = "but the property can exist in pure JS",
                .stack = js_context.stackTrace() catch "???",
                .property = name,
            });
        }

        return false;
    }
};
