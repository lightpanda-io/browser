// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// Same-origin bookkeeping. The v8 backend keeps a shared SecurityToken
// here; quickjs has no equivalent concept (there are no isolated worlds
// and no cross-context access checks), so this is just the refcounted key.
const std = @import("std");

const App = @import("../../../App.zig");

const Allocator = std.mem.Allocator;

const Origin = @This();

rc: usize = 1,
arena: Allocator,

// The key, e.g. lightpanda.io:443
key: []const u8,

pub fn init(app: *App, isolate: anytype, key: []const u8) !*Origin {
    _ = isolate;
    const arena = try app.arena_pool.acquire(.tiny, "Origin");
    errdefer app.arena_pool.release(arena);

    const owned_key = try arena.dupe(u8, key);
    const self = try arena.create(Origin);
    self.* = .{
        .rc = 1,
        .arena = arena,
        .key = owned_key,
    };
    return self;
}

pub fn deinit(self: *Origin, app: *App) void {
    app.arena_pool.release(self.arena);
}
