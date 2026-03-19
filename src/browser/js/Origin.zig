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

// Origin represents the security token for contexts within the same origin.
// Multiple contexts (frames) from the same origin share a single Origin,
// which provides the V8 SecurityToken that allows cross-context access.
//
// Note: Identity tracking (mapping Zig instances to v8::Objects) is managed
// separately via js.Identity - Session has the main world Identity, and
// IsolatedWorlds have their own Identity instances.

const std = @import("std");
const js = @import("js.zig");

const App = @import("../../App.zig");

const v8 = js.v8;
const Allocator = std.mem.Allocator;

const Origin = @This();

rc: usize = 1,
arena: Allocator,

// The key, e.g. lightpanda.io:443
key: []const u8,

// Security token - all contexts in this origin must use the same v8::Value instance
// as their security token for V8 to allow cross-context access
security_token: v8.Global,

pub fn init(app: *App, isolate: js.Isolate, key: []const u8) !*Origin {
    const arena = try app.arena_pool.acquire(.{ .debug = "Origin" });
    errdefer app.arena_pool.release(arena);

    var hs: js.HandleScope = undefined;
    hs.init(isolate);
    defer hs.deinit();

    const owned_key = try arena.dupe(u8, key);
    const token_local = isolate.initStringHandle(owned_key);
    var token_global: v8.Global = undefined;
    v8.v8__Global__New(isolate.handle, token_local, &token_global);

    const self = try arena.create(Origin);
    self.* = .{
        .rc = 1,
        .arena = arena,
        .key = owned_key,
        .security_token = token_global,
    };
    return self;
}

pub fn deinit(self: *Origin, app: *App) void {
    v8.v8__Global__Reset(&self.security_token);
    app.arena_pool.release(self.arena);
}
