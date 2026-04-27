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
const log = @import("../log.zig");
const Config = @import("../Config.zig");
const Blackhole = @import("Blackhole.zig");
const Sqlite = @import("sqlite/Sqlite.zig");

const Allocator = std.mem.Allocator;

const Storage = @This();

pub const EngineType = enum {
    none,
    sqlite,
};

const Engine = union(EngineType) {
    none: Blackhole,
    sqlite: Sqlite,
};

engine: Engine,

pub fn init(allocator: Allocator, config: *const Config) !Storage {
    const engine_type = config.storageEngine() orelse .none;
    const engine = initEngine(allocator, engine_type, config) catch |err| {
        log.fatal(.storage, "storage setup", .{ .engine = engine_type, .err = err });
        return err;
    };

    return .{
        .engine = engine,
    };
}

fn initEngine(allocator: Allocator, engine_type: EngineType, config: *const Config) !Engine {
    switch (engine_type) {
        .none => return .{ .none = Blackhole{} },
        .sqlite => {
            const sqlite_path = config.storageSqlitePath();
            return .{ .sqlite = try Sqlite.init(allocator, sqlite_path) };
        },
    }
}

pub fn deinit(self: *Storage, allocator: Allocator) void {
    switch (self.engine) {
        inline else => |*engine| engine.deinit(allocator),
    }
}
