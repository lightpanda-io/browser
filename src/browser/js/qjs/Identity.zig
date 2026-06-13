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

// Identity maps Zig instances to their JS wrappers, so the same Zig
// instance always maps to the same JS object. The map holds a strong
// (ref-counted) reference; wrappers live until the owning scope tears
// down. See v8/Identity.zig for the multi-world rationale (with quickjs
// there's only ever the main world).
const std = @import("std");
const js = @import("js.zig");

const Identity = @This();

identity_map: std.AutoHashMapUnmanaged(usize, js.PersistentHandle) = .empty,

pub fn deinit(self: *Identity) void {
    var it = self.identity_map.valueIterator();
    while (it.next()) |handle| {
        js.resetPersistentHandle(handle);
    }
}
