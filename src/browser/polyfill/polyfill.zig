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

const modules = [_]struct {
    name: []const u8,
    source: []const u8,
}{
    .{ .name = "polyfill-fetch", .source = @import("fetch.zig").source },
};

pub fn load(allocator: Allocator, js_context: *Env.JsContext) !void {
    var try_catch: Env.TryCatch = undefined;
    try_catch.init(js_context);
    defer try_catch.deinit();

    for (modules) |m| {
        _ = js_context.exec(m.source, m.name) catch |err| {
            if (try try_catch.err(allocator)) |msg| {
                defer allocator.free(msg);
                log.fatal(.app, "polyfill error", .{ .name = m.name, .err = msg });
            }
            return err;
        };
    }
}
