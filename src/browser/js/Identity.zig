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

// Identity manages the mapping between Zig instances and their v8::Object wrappers.
// This provides object identity semantics - the same Zig instance always maps to
// the same JS object within a given Identity scope.
//
// Main world contexts share a single Identity (on Session), ensuring that
// `window.top.document === top's document` works across same-origin frames.
//
// Isolated worlds (CDP inspector) have their own Identity, ensuring their
// v8::Global wrappers don't leak into the main world.

const std = @import("std");
const js = @import("js.zig");

const v8 = js.v8;

const Identity = @This();

// Maps Zig instance pointers to their v8::Global(Object) wrappers.
identity_map: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,

pub fn deinit(self: *Identity) void {
    var it = self.identity_map.valueIterator();
    while (it.next()) |global| {
        v8.v8__Global__Reset(global);
    }
}
