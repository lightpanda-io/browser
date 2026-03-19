// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const host = @import("host.zig");

pub const Host = host.Host;

pub fn init(allocator: std.mem.Allocator) Host {
    return Host.initMock(allocator);
}

test "mock host init returns the mock mode" {
    var host_instance = init(std.testing.allocator);
    defer host_instance.deinit();

    try std.testing.expectEqual(host.storage.Storage.Mode.mock, host_instance.storage.mode);
}
