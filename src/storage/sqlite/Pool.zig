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
const Sqlite = @import("Sqlite.zig");

const c = Sqlite.c;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const Pool = @This();

available: usize,
mutex: Thread.Mutex,
cond: Thread.Condition,
conns: []Sqlite.Conn,

pub fn init(allocator: Allocator, path: [:0]const u8) !Pool {
    // can't have a pool of connections to in-memory database, so, to keep the
    // API simple, we create a pool of 1.
    const count: usize = if (std.mem.eql(u8, path, ":memory:")) 1 else 5;

    var conns = try allocator.alloc(Sqlite.Conn, count);
    errdefer allocator.free(conns);

    var initialized: usize = 0;
    errdefer {
        for (0..initialized) |i| {
            conns[i].close();
        }
    }

    for (0..count) |i| {
        conns[i] = try Sqlite.Conn.open(path);
        initialized += 1;
        try conns[i].busyTimeout(1000);
    }

    return .{
        .cond = .{},
        .mutex = .{},
        .conns = conns,
        .available = count,
    };
}

pub fn deinit(self: *Pool, allocator: Allocator) void {
    for (self.conns) |conn| {
        conn.close();
    }
    allocator.free(self.conns);
}

pub fn acquire(self: *Pool) !Sqlite.Conn {
    const conns = self.conns;

    self.mutex.lock();
    while (true) {
        const available = self.available;
        if (available == 0) {
            try self.cond.timedWait(&self.mutex, 5 * std.time.ns_per_s);
            continue;
        }
        const index = available - 1;
        const conn = conns[index];
        self.available = index;
        self.mutex.unlock();
        return conn;
    }
}

pub fn release(self: *Pool, conn: Sqlite.Conn) void {
    var conns = self.conns;

    self.mutex.lock();
    const available = self.available;
    conns[available] = conn;
    self.available = available + 1;
    self.mutex.unlock();
    self.cond.signal();
}

const testing = @import("../../testing.zig");
test "Sqlite: Pool" {
    // :memory: _has_ to run with a single connetion in the pool, which isn't
    // that useful for testing. So we create a temp file.

    std.fs.cwd().deleteFile("/tmp/lightpanda_test.sqlite") catch {};
    var pool = try Pool.init(testing.allocator, "/tmp/lightpanda_test.sqlite");

    defer {
        pool.deinit(testing.allocator);
        std.fs.cwd().deleteFile("/tmp/lightpanda_test.sqlite") catch {};
    }

    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec("create table pool_test (cnt int not null)", .{});
        try conn.exec("insert into pool_test (cnt) values (0)", .{});
    }

    for (pool.conns) |conn| {
        // This is not safe and can result in corruption. This is only set
        // because the tests might be run on really slow hardware and we
        // want to avoid having a busy timeout.
        try conn.exec("pragma synchronous=off", .{});

        // Also not safe, but we're trying to avoid busy timeouts without using
        // WAL mode, which can trigger false positives in thread-sanitizer
        try conn.exec("pragma journal_mode=memory", .{});
    }

    const t1 = try Thread.spawn(.{}, testPool, .{&pool});
    const t2 = try Thread.spawn(.{}, testPool, .{&pool});
    const t3 = try Thread.spawn(.{}, testPool, .{&pool});
    const t4 = try Thread.spawn(.{}, testPool, .{&pool});
    const t5 = try Thread.spawn(.{}, testPool, .{&pool});
    const t6 = try Thread.spawn(.{}, testPool, .{&pool});

    t1.join();
    t2.join();
    t3.join();
    t4.join();
    t5.join();
    t6.join();

    const c1 = try pool.acquire();
    defer pool.release(c1);

    const row = (try c1.row("select cnt from pool_test", .{})).?;
    try testing.expectEqual(600, row.get(i64, 0));
    row.deinit();

    try c1.exec("drop table pool_test", .{});
}

fn testPool(p: *Pool) !void {
    for (0..100) |_| {
        const conn = try p.acquire();
        conn.exec("begin immediate", .{}) catch unreachable;
        conn.exec("update pool_test set cnt = cnt + 1", .{}) catch |err| {
            std.debug.print("update err: {any}\n", .{err});
            unreachable;
        };
        conn.exec("commit", .{}) catch unreachable;
        p.release(conn);
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
}
