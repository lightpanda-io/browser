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

const std = @import("std");
const Net = @import("../Net.zig");

const ENABLE_DEBUG = Net.ENABLE_DEBUG;
pub const Client = @import("Client.zig");
pub const Transfer = Client.Transfer;

pub const Method = Net.Method;
pub const Header = Net.Header;
pub const Headers = Net.Headers;

const Config = @import("../Config.zig");
const RobotStore = @import("../browser/Robots.zig").RobotStore;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

// Client.zig does the bulk of the work and is loosely tied to a browser Page.
// But we still need something above Client.zig for the "utility" http stuff
// we need to do, like telemetry. The most important thing we want from this
// is to be able to share the ca_blob, which can be quite large - loading it
// once for all http connections is a win.
const Http = @This();

arena: ArenaAllocator,
allocator: Allocator,
config: *const Config,
ca_blob: ?Net.Blob,
robot_store: *RobotStore,

pub fn init(allocator: Allocator, robot_store: *RobotStore, config: *const Config) !Http {
    try Net.globalInit();
    errdefer Net.globalDeinit();

    if (comptime ENABLE_DEBUG) {
        std.debug.print("curl version: {s}\n\n", .{Net.curl_version()});
    }

    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var ca_blob: ?Net.Blob = null;
    if (config.tlsVerifyHost()) {
        ca_blob = try Net.loadCerts(allocator);
    }

    return .{
        .arena = arena,
        .allocator = allocator,
        .config = config,
        .ca_blob = ca_blob,
        .robot_store = robot_store,
    };
}

pub fn deinit(self: *Http) void {
    if (self.ca_blob) |ca_blob| {
        const data: [*]u8 = @ptrCast(ca_blob.data);
        self.allocator.free(data[0..ca_blob.len]);
    }
    Net.globalDeinit();
    self.arena.deinit();
}

pub fn createClient(self: *Http, allocator: Allocator) !*Client {
    return Client.init(allocator, self.ca_blob, self.robot_store, self.config);
}

pub fn newConnection(self: *Http) !Net.Connection {
    return Net.Connection.init(self.ca_blob, self.config);
}
