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

// quickjs has no snapshot mechanism - classes are registered on the
// runtime and prototypes built per-context at creation time (see Env).
// This stub keeps App's platform/snapshot fields working unchanged.
const Snapshot = @This();

pub fn load() !Snapshot {
    return .{};
}

pub fn deinit(self: Snapshot) void {
    _ = self;
}

pub fn write(self: Snapshot, writer: anytype) !void {
    _ = self;
    _ = writer;
    return error.NotSupported;
}

pub fn fromEmbedded(self: Snapshot) bool {
    _ = self;
    return true;
}
