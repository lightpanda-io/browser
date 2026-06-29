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

pub fn delete(self: *Engine, object_store_id: i64, key: []const u8) !void {
    return self.conn.exec(
        "delete from idb_records where object_store_id = ?1 and key = ?2",
        .{ object_store_id, key },
    );
}

pub fn clear(self: *Engine, object_store_id: i64) !void {
    return self.conn.exec("delete from idb_records where object_store_id = ?1", .{object_store_id});
}

pub fn count(self: *const Engine, object_store_id: i64) !i64 {
    return (try self.conn.scalar(
        i64,
        "select count(*) from idb_records where object_store_id = ?1",
        .{object_store_id},
    )) orelse 0;
}

pub fn getAll(self: *const Engine, arena: Allocator, object_store_id: i64) ![]const []u8 {
    var rows = try self.conn.rows(
        "select value from idb_records where object_store_id = ?1 order by key",
        .{object_store_id},
    );
    defer rows.deinit();

    var list: std.ArrayList([]u8) = .empty;
    while (try rows.next()) |row| {
        try list.append(arena, try arena.dupe(u8, row.get([]const u8, 0)));
    }
    return list.items;
}

const testing = @import("../../../../testing.zig");

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
