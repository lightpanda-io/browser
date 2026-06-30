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

const Sqlite = @import("../../../../storage/sqlite/Sqlite.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const Engine = @This();

conn: Sqlite.Conn,

pub fn open(path: [:0]const u8) !Engine {
    const conn = try Sqlite.Conn.open(path);
    errdefer conn.close();

    try conn.busyTimeout(1000);
    try conn.exec("pragma journal_mode=wal", .{});
    try conn.exec(
        \\ create table if not exists idb_databases (
        \\   id integer primary key,
        \\   name text not null unique,
        \\   version integer not null
        \\ );
        \\ create table if not exists idb_object_stores (
        \\   id integer primary key,
        \\   database_id integer not null references idb_databases(id),
        \\   name text not null,
        \\   key_path text,
        \\   auto_increment integer not null default 0,
        \\   key_generator integer not null default 1,
        \\   unique(database_id, name)
        \\ );
        \\ create table if not exists idb_records (
        \\   object_store_id integer not null references idb_object_stores(id),
        \\   key blob not null,
        \\   value blob not null,
        \\   primary key (object_store_id, key)
        \\ ) without rowid;
    , .{});
    return .{ .conn = conn };
}

pub fn close(self: *Engine) void {
    self.conn.close();
}

pub fn begin(self: *Engine) !void {
    return self.conn.exec("begin immediate", .{});
}

pub fn commit(self: *Engine) !void {
    return self.conn.exec("commit", .{});
}

pub fn rollback(self: *Engine) void {
    self.conn.exec("rollback", .{}) catch |err| {
        log.warn(.storage, "idb rollback", .{ .err = err, .sqlite = self.conn.lastError() });
    };
}
pub fn databaseId(self: *const Engine, name: []const u8) !?i64 {
    return self.conn.scalar(i64, "select id from idb_databases where name = ?1", .{name});
}

pub fn databaseVersion(self: *const Engine, name: []const u8) !?i64 {
    return self.conn.scalar(i64, "select version from idb_databases where name = ?1", .{name});
}

pub fn upsertDatabase(self: *Engine, name: []const u8, version: i64) !i64 {
    try self.conn.exec(
        \\ insert into idb_databases (name, version) values (?1, ?2)
        \\ on conflict(name) do update set version = ?2
    , .{ name, version });

    return (try self.databaseId(name)).?;
}

pub fn deleteDatabase(self: *Engine, name: []const u8) !void {
    const database_id = (try self.databaseId(name)) orelse return;

    try self.begin();
    errdefer self.rollback();
    try self.conn.exec(
        "delete from idb_records where object_store_id in (select id from idb_object_stores where database_id = ?1)",
        .{database_id},
    );
    try self.conn.exec("delete from idb_object_stores where database_id = ?1", .{database_id});
    try self.conn.exec("delete from idb_databases where id = ?1", .{database_id});
    try self.commit();
}

pub fn objectStoreId(self: *const Engine, database_id: i64, name: []const u8) !?i64 {
    return self.conn.scalar(
        i64,
        "select id from idb_object_stores where database_id = ?1 and name = ?2",
        .{ database_id, name },
    );
}

pub const StoreInfo = struct {
    id: i64,
    key_path: ?[]const u8,
    auto_increment: bool,
};

pub fn objectStoreInfo(self: *const Engine, arena: Allocator, database_id: i64, name: []const u8) !?StoreInfo {
    var row = (try self.conn.row(
        "select id, key_path, auto_increment from idb_object_stores where database_id = ?1 and name = ?2",
        .{ database_id, name },
    )) orelse return null;
    defer row.deinit();

    const key_path = row.get(?[]const u8, 1);
    return .{
        .id = row.get(i64, 0),
        .key_path = if (key_path) |kp| try arena.dupe(u8, kp) else null,
        .auto_increment = row.get(bool, 2),
    };
}

// key_generator starts at 1, we increment it, but want to return the
// previous value, hence the - 1.
pub fn nextGeneratedKey(self: *Engine, store_id: i64) !i64 {
    return (try self.conn.scalar(
        i64,
        "update idb_object_stores set key_generator = key_generator + 1 where id = ?1 returning key_generator - 1",
        .{store_id},
    )) orelse error.NotFound;
}

// If an explicit key was given, we need to bump the generator so that a future
// generated key doesn't collide
pub fn maybeBumpGenerator(self: *Engine, store_id: i64, key: f64) !void {
    if (key < 1) {
        return;
    }

    // Cap at 2^53, the largest integer the generator tracks per spec.
    const capped = @min(@floor(key), 9007199254740992);
    const want: i64 = @intFromFloat(capped + 1);
    try self.conn.exec(
        "update idb_object_stores set key_generator = ?2 where id = ?1 and key_generator < ?2",
        .{ store_id, want },
    );
}

pub fn createObjectStore(
    self: *Engine,
    database_id: i64,
    name: []const u8,
    key_path: ?[]const u8,
    auto_increment: bool,
) !i64 {
    try self.conn.exec(
        \\ insert into idb_object_stores (database_id, name, key_path, auto_increment)
        \\ values (?1, ?2, ?3, ?4)
    , .{ database_id, name, key_path, auto_increment });
    return (try self.objectStoreId(database_id, name)).?;
}

pub fn deleteObjectStore(self: *Engine, database_id: i64, name: []const u8) !void {
    const store_id = (try self.objectStoreId(database_id, name)) orelse return error.NotFound;
    // caller has a transaction open
    try self.conn.exec("delete from idb_records where object_store_id = ?1", .{store_id});
    try self.conn.exec("delete from idb_object_stores where id = ?1", .{store_id});
}

pub fn add(self: *Engine, object_store_id: i64, key: []const u8, value: []const u8) !void {
    return self.conn.exec(
        "insert into idb_records (object_store_id, key, value) values (?1, ?2, ?3)",
        .{ object_store_id, key, value },
    );
}

pub fn put(self: *Engine, object_store_id: i64, key: []const u8, value: []const u8) !void {
    return self.conn.exec(
        \\ insert into idb_records (object_store_id, key, value) values (?1, ?2, ?3)
        \\ on conflict(object_store_id, key) do update set value = ?3
    , .{ object_store_id, key, value });
}

pub fn get(self: *const Engine, allocator: Allocator, object_store_id: i64, key: []const u8) !?[]u8 {
    var row = (try self.conn.row(
        "select value from idb_records where object_store_id = ?1 and key = ?2",
        .{ object_store_id, key },
    )) orelse return null;
    defer row.deinit();
    return try allocator.dupe(u8, row.get([]const u8, 0));
}

pub fn clear(self: *Engine, object_store_id: i64) !void {
    return self.conn.exec("delete from idb_records where object_store_id = ?1", .{object_store_id});
}

pub const Bounds = struct {
    lower: []const u8,
    upper: []const u8,

    // These are built-time string literal operators, e.g. ">= ". Not worried
    // about some SQL injection.
    lower_op: []const u8,
    upper_op: []const u8,

    // optimization flag for point queries.
    is_point: bool,

    // Every encoded key begins with a type tag from 10 to 50]...
    // 0 sorts below, and...
    pub const min_sentinel: []const u8 = &.{0x00};
    // 255 sorts above
    pub const max_sentinel: []const u8 = &.{0xFF};

    pub fn unbounded() Bounds {
        return .{ .lower = min_sentinel, .upper = max_sentinel, .lower_op = ">= ", .upper_op = "<= ", .is_point = false };
    }

    pub fn point(encoded: []const u8) Bounds {
        return .{ .lower = encoded, .upper = encoded, .lower_op = "", .upper_op = "", .is_point = true };
    }
};

pub fn getRange(self: *const Engine, allocator: Allocator, object_store_id: i64, b: Bounds) !?[]u8 {
    var buf: [256]u8 = undefined;
    const sql = try rangeSql(&buf, "select value", b, " order by key limit 1");
    var row = (try self.conn.row(sql, .{ object_store_id, b.lower, b.upper })) orelse return null;
    defer row.deinit();
    return try allocator.dupe(u8, row.get([]const u8, 0));
}

pub fn getKeyRange(self: *const Engine, allocator: Allocator, object_store_id: i64, b: Bounds) !?[]u8 {
    var buf: [256]u8 = undefined;
    const sql = try rangeSql(&buf, "select key", b, " order by key limit 1");
    var row = (try self.conn.row(sql, .{ object_store_id, b.lower, b.upper })) orelse return null;
    defer row.deinit();
    return try allocator.dupe(u8, row.get([]const u8, 0));
}

pub fn countRange(self: *const Engine, object_store_id: i64, b: Bounds) !i64 {
    var buf: [256]u8 = undefined;
    const sql = try rangeSql(&buf, "select count(*)", b, "");
    return (try self.conn.scalar(i64, sql, .{ object_store_id, b.lower, b.upper })) orelse 0;
}

pub fn deleteRange(self: *Engine, object_store_id: i64, b: Bounds) !void {
    var buf: [256]u8 = undefined;
    const sql = try rangeSql(&buf, "delete", b, "");
    return self.conn.exec(sql, .{ object_store_id, b.lower, b.upper });
}

// Every injected string is a compile-time known/safe value.
fn rangeSql(buf: []u8, head: []const u8, b: Bounds, tail: []const u8) ![:0]u8 {
    if (b.is_point) {
        // optimized query for [common] point query. (key = ?2 or key = ?3)
        // to keep the param list the side for the caller.
        return std.fmt.bufPrintZ(
            buf,
            "{s} from idb_records where object_store_id = ?1 and (key = ?2 or key = ?3) {s}",
            .{ head, tail },
        );
    }

    return std.fmt.bufPrintZ(
        buf,
        "{s} from idb_records where object_store_id = ?1 and key {s} ?2 and key {s} ?3{s}",
        .{ head, b.lower_op, b.upper_op, tail },
    );
}

// What a ranged getAll/getAllKeys returns: the value or key column.
pub const Column = enum {
    value,
    key,
};

pub fn getAllRange(self: *const Engine, arena: Allocator, object_store_id: i64, b: Bounds, column: Column, limit_: ?u32) ![]const []u8 {
    var buf: [256]u8 = undefined;
    const head = if (column == .value) "select value" else "select key";
    const sql = try rangeSql(&buf, head, b, " order by key limit ?4");
    // SQLite treats a negative LIMIT as "no limit".
    const limit: i64 = if (limit_) |c| @intCast(c) else -1;

    var rows = try self.conn.rows(sql, .{ object_store_id, b.lower, b.upper, limit });
    defer rows.deinit();

    var list: std.ArrayList([]u8) = .empty;
    while (try rows.next()) |row| {
        try list.append(arena, try arena.dupe(u8, row.get([]const u8, 0)));
    }
    return list.items;
}

const testing = @import("../../../../testing.zig");
test "IDB - Engine: ranged getAll/count honour open and closed bounds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var engine = try Engine.open(":memory:");
    defer engine.close();
    const db_id = try engine.upsertDatabase("app", 1);
    const store_id = try engine.createObjectStore(db_id, "s", null, false);
    try seedNumbers(&engine, store_id, arena, &.{ 3, 1, 5, 2, 4 });

    const k2 = try numKey(arena, 2);
    const k4 = try numKey(arena, 4);

    // Closed [2,4]: keys 2,3,4 in sorted order.
    {
        const b = boundsFor(k2, false, k4, false);
        const vals = try engine.getAllRange(arena, store_id, b, .value, null);
        try testing.expectEqual(3, vals.len);
        try testing.expectEqualSlices(u8, "v2", vals[0]);
        try testing.expectEqualSlices(u8, "v4", vals[2]);
        try testing.expectEqual(3, try engine.countRange(store_id, b));
    }

    // Open lower (2,4]: keys 3,4.
    {
        const b = boundsFor(k2, true, k4, false);
        try testing.expectEqual(2, try engine.countRange(store_id, b));
        const vals = try engine.getAllRange(arena, store_id, b, .value, null);
        try testing.expectEqualSlices(u8, "v3", vals[0]);
    }

    // Open both (2,4): only key 3.
    {
        const b = boundsFor(k2, true, k4, true);
        try testing.expectEqual(1, try engine.countRange(store_id, b));
    }

    // Unbounded and point ranges.
    try testing.expectEqual(5, try engine.countRange(store_id, Engine.Bounds.unbounded()));
    try testing.expectEqual(1, try engine.countRange(store_id, Engine.Bounds.point(try numKey(arena, 3))));

    // A limit caps the result count.
    const limited = try engine.getAllRange(arena, store_id, Engine.Bounds.unbounded(), .value, 2);
    try testing.expectEqual(2, limited.len);

    // The .key column returns encoded keys, sorted.
    const keys = try engine.getAllRange(arena, store_id, Engine.Bounds.unbounded(), .key, null);
    try testing.expectEqualSlices(u8, try numKey(arena, 1), keys[0]);
    try testing.expectEqualSlices(u8, try numKey(arena, 5), keys[4]);
}

test "IDB - Engine: getRange/getKeyRange first-in-range and deleteRange" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var engine = try Engine.open(":memory:");
    defer engine.close();
    const db_id = try engine.upsertDatabase("app", 1);
    const store_id = try engine.createObjectStore(db_id, "s", null, false);
    try seedNumbers(&engine, store_id, arena, &.{ 1, 2, 3, 4, 5 });

    const k2 = try numKey(arena, 2);
    const k4 = try numKey(arena, 4);

    // First value/key in [2,4] is for key 2.
    try testing.expectEqualSlices(u8, "v2", (try engine.getRange(arena, store_id, boundsFor(k2, false, k4, false))).?);
    try testing.expectEqualSlices(u8, k2, (try engine.getKeyRange(arena, store_id, boundsFor(k2, false, k4, false))).?);

    // Open lower skips key 2.
    try testing.expectEqualSlices(u8, "v3", (try engine.getRange(arena, store_id, boundsFor(k2, true, k4, false))).?);

    // Empty range yields null.
    try testing.expectEqual(null, try engine.getRange(arena, store_id, Engine.Bounds.point(try numKey(arena, 99))));

    // deleteRange removes [4,5], leaving 1,2,3.
    try engine.deleteRange(store_id, boundsFor(k4, false, try numKey(arena, 5), false));
    try testing.expectEqual(3, try engine.countRange(store_id, Engine.Bounds.unbounded()));
}

test "IDB - Engine: open creates schema" {
    var engine = try Engine.open(":memory:");
    defer engine.close();
    try testing.expectEqual(null, try engine.databaseVersion("missing"));
}

test "IDB - Engine: database + object store + add/get round-trip" {
    var engine = try Engine.open(":memory:");
    defer engine.close();

    const db_id = try engine.upsertDatabase("app", 1);
    try testing.expectEqual(1, (try engine.databaseVersion("app")).?);

    const store_id = try engine.createObjectStore(db_id, "books", null, false);

    // Value bytes deliberately include an embedded NUL and high bytes to prove
    // the BLOB path is binary-safe (serialized values are arbitrary bytes).
    const value = "a\x00b\xffc";
    try engine.add(store_id, "key1", value);

    const got = (try engine.get(testing.allocator, store_id, "key1")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, value, got);

    try testing.expectEqual(null, try engine.get(testing.allocator, store_id, "absent"));
}

test "IDB - Engine: add rejects duplicate key, put overwrites" {
    var engine = try Engine.open(":memory:");
    defer engine.close();

    const db_id = try engine.upsertDatabase("app", 1);
    const store_id = try engine.createObjectStore(db_id, "s", null, false);

    try engine.add(store_id, "k", "v1");
    try testing.expectError(error.Constraint, engine.add(store_id, "k", "v2"));

    try engine.put(store_id, "k", "v2");
    const got = (try engine.get(testing.allocator, store_id, "k")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, "v2", got);
}

test "IDB - Engine: createObjectStore rejects duplicate name" {
    var engine = try Engine.open(":memory:");
    defer engine.close();

    const db_id = try engine.upsertDatabase("app", 1);
    _ = try engine.createObjectStore(db_id, "s", null, false);
    try testing.expectError(error.Constraint, engine.createObjectStore(db_id, "s", null, false));
}

test "IDB - Engine: rollback discards uncommitted writes" {
    var engine = try Engine.open(":memory:");
    defer engine.close();

    const db_id = try engine.upsertDatabase("app", 1);
    const store_id = try engine.createObjectStore(db_id, "s", null, false);

    try engine.begin();
    try engine.add(store_id, "k", "v");
    engine.rollback();

    try testing.expectEqual(null, try engine.get(testing.allocator, store_id, "k"));
}

const Key = @import("Key.zig");

// Seed a store with numeric keys n and values "v<n>", inserted out of order so
// the range tests prove ORDER BY rather than insertion order.
fn seedNumbers(engine: *Engine, store_id: i64, arena: Allocator, ns: []const u8) !void {
    for (ns) |n| {
        const enc = try Key.number(@floatFromInt(n)).encode(arena);
        var buf: [8]u8 = undefined;
        try engine.add(store_id, enc, try std.fmt.bufPrint(&buf, "v{d}", .{n}));
    }
}

fn numKey(arena: Allocator, n: u8) ![]u8 {
    return Key.number(@floatFromInt(n)).encode(arena);
}

fn boundsFor(lower: ?[]const u8, lower_open: bool, upper: ?[]const u8, upper_open: bool) Engine.Bounds {
    return .{
        .is_point = false,
        .lower = lower orelse Engine.Bounds.min_sentinel,
        .upper = upper orelse Engine.Bounds.max_sentinel,
        .lower_op = if (lower_open) "> " else ">= ",
        .upper_op = if (upper_open) "< " else "<= ",
    };
}
