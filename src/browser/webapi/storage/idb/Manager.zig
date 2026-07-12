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
const lp = @import("lightpanda");

const Engine = @import("Engine.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const Manager = @This();

allocator: Allocator,
engines: std.StringHashMapUnmanaged(*Engine) = .empty,

pub fn init(allocator: Allocator) Manager {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Manager) void {
    var it = self.engines.iterator();
    while (it.next()) |kv| {
        kv.value_ptr.*.close();
        self.allocator.destroy(kv.value_ptr.*);
        self.allocator.free(kv.key_ptr.*);
    }
    self.engines.deinit(self.allocator);
}

// A js Context is being torn down (navigation, popup close, worker close):
// every engine must drop any gate participant whose callbacks would run in it.
// Must be called before that context's scheduler is reset or deinit'd.
pub fn detachContext(self: *Manager, ctx: *anyopaque) void {
    var it = self.engines.valueIterator();
    while (it.next()) |engine| {
        engine.*.detach(ctx);
    }
}

// Gets or creates the engine for the given origin.
pub fn engineForOrigin(self: *Manager, origin: []const u8) !*Engine {
    const gop = try self.engines.getOrPut(self.allocator, origin);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }
    errdefer _ = self.engines.remove(origin);

    const engine = try self.allocator.create(Engine);
    errdefer self.allocator.destroy(engine);

    engine.* = try Engine.open(":memory:");
    errdefer engine.close();

    gop.key_ptr.* = try self.allocator.dupe(u8, origin);
    gop.value_ptr.* = engine;
    return engine;
}

const testing = @import("../../../../testing.zig");
test "IDB - Manager: same origin returns same engine, distinct origins differ" {
    var mgr = Manager.init(testing.allocator);
    defer mgr.deinit();

    const a1 = try mgr.engineForOrigin("https://a.com");
    const a2 = try mgr.engineForOrigin("https://a.com");
    const b1 = try mgr.engineForOrigin("https://b.com");

    try testing.expect(a1 == a2);
    try testing.expect(a1 != b1);
}

test "IDB - Manager: in-memory engines are origin-isolated" {
    var mgr = Manager.init(testing.allocator);
    defer mgr.deinit();

    const a = try mgr.engineForOrigin("https://a.com");
    const b = try mgr.engineForOrigin("https://b.com");

    _ = try a.upsertDatabase("db", 1);
    try testing.expectEqual(null, try b.databaseVersion("db"));
}

test "IDB - Manager: on-disk engines hash to per-origin files, isolated" {
    var mgr = Manager.init(testing.allocator);
    defer mgr.deinit();

    // A long origin (hostname near the 253-byte limit) must still open: the
    // hashed file name stays well under NAME_MAX where a transcribed one would
    // not.
    const long_host = "https://" ++ ("a" ** 250) ++ ".com";
    const a = try mgr.engineForOrigin(long_host);
    _ = try a.upsertDatabase("db", 7);

    const b = try mgr.engineForOrigin("https://b.com");
    try testing.expectEqual(null, try b.databaseVersion("db"));
    try testing.expectEqual(7, (try a.databaseVersion("db")).?);
}
