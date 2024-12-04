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

const jsruntime = @import("jsruntime");
const Env = jsruntime.Env;

const fetch = @import("fetch.zig").fetch_polyfill;

const log = std.log.scoped(.polyfill);

const modules = [_]struct {
    name: []const u8,
    source: []const u8,
}{
    .{ .name = "polyfill-fetch", .source = @import("fetch.zig").source },
};

pub fn load(alloc: std.mem.Allocator, env: Env) !void {
    var try_catch: jsruntime.TryCatch = undefined;
    try_catch.init(env);
    defer try_catch.deinit();

    for (modules) |m| {
        const res = env.exec(m.source, m.name) catch {
            if (try try_catch.err(alloc, env)) |msg| {
                defer alloc.free(msg);
                log.err("load {s}: {s}", .{ m.name, msg });
            }
            return;
        };

        if (builtin.mode == .Debug) {
            const msg = try res.toString(alloc, env);
            defer alloc.free(msg);
            log.debug("load {s}: {s}", .{ m.name, msg });
        }
    }
}
