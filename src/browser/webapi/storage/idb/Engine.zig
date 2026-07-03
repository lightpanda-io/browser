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

const Key = @import("Key.zig");
const Sqlite = @import("../../../../storage/sqlite/Sqlite.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const Engine = @This();

conn: Sqlite.Conn,

// A single sqlite connection backs every database of an origin, so only one
// transaction (or open/delete) may hold it in a `begin`/`commit` bracket at a
// time. `_gate_owner` is whoever currently holds it; contenders park their
// (intrusive, caller-owned) node on `_gate_waiters` and are handed ownership in
// FIFO order as it's released.
//
// The Engine is session-scoped but the waiters (IDBTransaction /
// Open+DeleteContext) are context-scoped, so these are the only session->page
// pointers in IDB. Every participant tags its waiter with its js Context;
// detach() must be called before that context's scheduler is reset or torn
// down, otherwise a parked waiter dangles here and a later wake would schedule
// onto a dead scheduler.
_gate_owner: ?*GateWaiter = null,
_gate_waiters: std.DoublyLinkedList = .{},

pub const GateWaiter = struct {
    node: std.DoublyLinkedList.Node = .{},
    // A bit unusual. Normally, if we need to tear something down when the frame
    // is destroyed, we track that on the frame (see Frame._file_lists). And
    // we _could_ do that here too, but the Engine still needs the list, so that
    // would require book-keeping in 2 lists. Instead, Engine owns the list and
    // we track the *js.Context (because it needs to work for both WGS and
    // frames). On context teardown, we can iterate the list and remove any
    // waiters associated with that context.
    ctx: *anyopaque,

    // Called when this waiter is handed the gate; typically reschedules the
    // owner's task so it re-runs and finds itself the owner.
    wake: *const fn (waiter: *GateWaiter) void,

    // Called when detach() removes this waiter because its context is going away.
    cancel: *const fn (waiter: *GateWaiter) void,
};

pub fn acquireGate(self: *Engine, waiter: *GateWaiter) bool {
    if (self._gate_owner == null) {
        self._gate_owner = waiter;
        return true;
    }

    if (self._gate_owner == waiter) {
        return true;
    }

    self._gate_waiters.append(&waiter.node);
    return false;
}

// Release the gate held by `waiter`, handing it directly to the next parked
// waiter (no window where an unrelated contender can grab it) and waking it.
pub fn releaseGate(self: *Engine, waiter: *GateWaiter) bool {
    if (self._gate_owner != waiter) {
        return false;
    }
    if (self._gate_waiters.popFirst()) |node| {
        const next: *GateWaiter = @fieldParentPtr("node", node);
        self._gate_owner = next;
        next.wake(next);
        return true;
    }
    self._gate_owner = null;
    return true;
}

// A js Context is being torn down: remove every waiter associated with it.
pub fn detach(self: *Engine, ctx: *anyopaque) void {
    var node = self._gate_waiters.first;
    while (node) |n| {
        const next = n.next;
        const waiter: *GateWaiter = @fieldParentPtr("node", n);
        if (waiter.ctx == ctx) {
            self._gate_waiters.remove(n);
            waiter.cancel(waiter);
        }
        node = next;
    }

    const owner = self._gate_owner orelse return;
    if (owner.ctx != ctx) {
        return;
    }
    owner.cancel(owner);
    _ = self.releaseGate(owner);
}

pub fn open(path: [:0]const u8) !Engine {
    const conn = try Sqlite.Conn.open(path);
    errdefer conn.close();

    try conn.busyTimeout(1000);
    try conn.exec("pragma journal_mode=wal", .{});
    try conn.exec("pragma foreign_keys = on", .{});

    try conn.exec(
        \\ create table if not exists idb_databases (
        \\   id integer primary key,
        \\   name text not null unique,
        \\   version integer not null
        \\ );
        \\
        \\ create table if not exists idb_object_stores (
        \\   id integer primary key,
        \\   database_id integer not null references idb_databases(id) on delete cascade,
        \\   name text not null,
        \\   key_path text,
        \\   key_path_component_length integer not null default 0,
        \\   auto_increment integer not null default 0,
        \\   key_generator integer not null default 1,
        \\   unique(database_id, name)
        \\ );
        \\
        \\ create table if not exists idb_records (
        \\   object_store_id integer not null references idb_object_stores(id) on delete cascade,
        \\   key blob not null,
        \\   value blob not null,
        \\   primary key (object_store_id, key)
        \\ ) without rowid;
        \\
        \\ create table if not exists idb_indexes (
        \\   id integer primary key,
        \\   object_store_id integer not null references idb_object_stores(id) on delete cascade,
        \\   name text not null,
        \\   key_path text not null,
        \\   key_path_component_length integer not null default 0,
        \\   is_unique integer not null default 0,
        \\   multi_entry integer not null default 0,
        \\   unique(object_store_id, name)
        \\ );
        \\
        \\ create table if not exists idb_index_records (
        \\   index_id integer not null references idb_indexes(id) on delete cascade,
        \\   key blob not null,
        \\   primary_key blob not null,
        \\   is_unique integer not null,
        \\   primary key (index_id, key, primary_key)
        \\ ) without rowid;
        \\ create unique index if not exists idb_index_unique
        \\   on idb_index_records(index_id, key) where is_unique = 1;
    , .{});
    return .{ .conn = conn };
}

pub fn close(self: *Engine) void {
    self.conn.close();
}

pub fn lastError(self: *const Engine) [:0]const u8 {
    return self.conn.lastError();
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
    return self.conn.exec("delete from idb_databases where name = ?1", .{name});
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
    key_path: ?Key.KeyPath,
    auto_increment: bool,
};

pub fn objectStoreInfo(self: *const Engine, arena: Allocator, database_id: i64, name: []const u8) !?StoreInfo {
    var row = (try self.conn.row(
        "select id, key_path, key_path_component_length, auto_increment from idb_object_stores where database_id = ?1 and name = ?2",
        .{ database_id, name },
    )) orelse return null;
    defer row.deinit();

    const key_path = row.get(?[]const u8, 1);
    return .{
        .id = row.get(i64, 0),
        .key_path = if (key_path) |kp| try Key.decodeKeyPathColumn(arena, kp, @intCast(row.get(i64, 2))) else null,
        .auto_increment = row.get(bool, 3),
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
    arena: Allocator,
    database_id: i64,
    name: []const u8,
    key_path: ?Key.KeyPath,
    auto_increment: bool,
) !i64 {
    const column = if (key_path) |kp| try Key.encodeKeyPathColumn(arena, kp) else null;
    try self.conn.exec(
        \\ insert into idb_object_stores (database_id, name, key_path, key_path_component_length, auto_increment)
        \\ values (?1, ?2, ?3, ?4, ?5)
    , .{
        database_id,
        name,
        if (column) |c| c.text else null,
        if (column) |c| c.component_length else @as(usize, 0),
        auto_increment,
    });
    return (try self.objectStoreId(database_id, name)).?;
}

pub fn deleteObjectStore(self: *Engine, database_id: i64, name: []const u8) !void {
    // caller has a transaction open; cascade drops records, indexes and index
    // records.
    const deleted = try self.conn.scalar(i64,
        \\ delete from idb_object_stores where database_id = ?1 and name = ?2
        \\ returning id
    , .{ database_id, name });
    if (deleted == null) {
        return error.NotFound;
    }
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

pub const IndexInfo = struct {
    id: i64,
    key_path: Key.KeyPath,
    unique: bool,
    multi_entry: bool,
};

pub fn createIndexRow(self: *Engine, arena: Allocator, object_store_id: i64, name: []const u8, key_path: Key.KeyPath, unique: bool, multi_entry: bool) !i64 {
    const column = try Key.encodeKeyPathColumn(arena, key_path);
    return (try self.conn.scalar(
        i64,
        \\ insert into idb_indexes (object_store_id, name, key_path, key_path_component_length, is_unique, multi_entry)
        \\ values (?1, ?2, ?3, ?4, ?5, ?6) returning id
    ,
        .{ object_store_id, name, column.text, column.component_length, unique, multi_entry },
    )) orelse error.UnknownError;
}

pub fn deleteIndexRow(self: *Engine, object_store_id: i64, name: []const u8) !void {
    const deleted = try self.conn.scalar(
        i64,
        "delete from idb_indexes where object_store_id = ?1 and name = ?2 returning id",
        .{ object_store_id, name },
    );
    if (deleted == null) {
        return error.NotFound;
    }
}

pub fn indexInfo(self: *const Engine, arena: Allocator, object_store_id: i64, name: []const u8) !?IndexInfo {
    var row = (try self.conn.row(
        "select id, key_path, key_path_component_length, is_unique, multi_entry from idb_indexes where object_store_id = ?1 and name = ?2",
        .{ object_store_id, name },
    )) orelse return null;
    defer row.deinit();

    return .{
        .id = row.get(i64, 0),
        .key_path = try Key.decodeKeyPathColumn(arena, row.get([]const u8, 1), @intCast(row.get(i64, 2))),
        .unique = row.get(bool, 3),
        .multi_entry = row.get(bool, 4),
    };
}

pub fn indexesForStore(self: *const Engine, arena: Allocator, object_store_id: i64) ![]IndexInfo {
    var rows = try self.conn.rows(
        "select id, key_path, key_path_component_length, is_unique, multi_entry from idb_indexes where object_store_id = ?1",
        .{object_store_id},
    );
    defer rows.deinit();

    var list: std.ArrayList(IndexInfo) = .empty;
    while (try rows.next()) |row| {
        try list.append(arena, .{
            .id = row.get(i64, 0),
            .key_path = try Key.decodeKeyPathColumn(arena, row.get([]const u8, 1), @intCast(row.get(i64, 2))),
            .unique = row.get(bool, 3),
            .multi_entry = row.get(bool, 4),
        });
    }
    return list.items;
}

pub fn indexNames(self: *const Engine, arena: Allocator, object_store_id: i64) ![]const []const u8 {
    var rows = try self.conn.rows(
        "select name from idb_indexes where object_store_id = ?1 order by name",
        .{object_store_id},
    );
    defer rows.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    while (try rows.next()) |row| {
        try list.append(arena, try arena.dupe(u8, row.get([]const u8, 0)));
    }
    return list.items;
}

pub fn objectStoreNames(self: *const Engine, arena: Allocator, database_id: i64) ![]const []const u8 {
    var rows = try self.conn.rows(
        "select name from idb_object_stores where database_id = ?1 order by name",
        .{database_id},
    );
    defer rows.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    while (try rows.next()) |row| {
        try list.append(arena, try arena.dupe(u8, row.get([]const u8, 0)));
    }
    return list.items;
}

pub fn addIndexRecord(self: *Engine, index_id: i64, key: []const u8, primary_key: []const u8, unique: bool) !void {
    return self.conn.exec(
        "insert into idb_index_records (index_id, key, primary_key, is_unique) values (?1, ?2, ?3, ?4)",
        .{ index_id, key, primary_key, unique },
    );
}

pub fn deleteIndexRecordsForKey(self: *Engine, object_store_id: i64, primary_key: []const u8) !void {
    return self.conn.exec(
        \\ delete from idb_index_records
        \\ where primary_key = ?2 and index_id in (
        \\   select id from idb_indexes where object_store_id = ?1
        \\ )
    , .{ object_store_id, primary_key });
}

pub fn clearIndexRecordsForStore(self: *Engine, object_store_id: i64) !void {
    return self.conn.exec(
        "delete from idb_index_records where index_id in (select id from idb_indexes where object_store_id = ?1)",
        .{object_store_id},
    );
}

// Drop index entries for every record about to be deleted by a ranged delete.
pub fn deleteIndexRecordsForRange(self: *Engine, object_store_id: i64, b: Bounds) !void {
    const ops = rangeOps(b);
    var buf: [400]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&buf,
        \\ delete from idb_index_records where index_id in (
        \\   select id from idb_indexes where object_store_id = ?1
        \\ ) and primary_key in (
        \\   select key from idb_records where object_store_id = ?1 and key {s} ?2 and key {s} ?3
        \\)
    , .{ ops.lo, ops.hi });

    return self.conn.exec(sql, .{ object_store_id, b.lower, b.upper });
}

pub fn savepoint(self: *Engine) !void {
    return self.conn.exec("savepoint idb_op", .{});
}

pub fn releaseSavepoint(self: *Engine) !void {
    return self.conn.exec("release idb_op", .{});
}

pub fn rollbackSavepoint(self: *Engine) void {
    self.conn.exec("rollback to idb_op", .{}) catch |err| {
        log.warn(.storage, "idb savepoint rollback", .{ .err = err, .sqlite = self.conn.lastError() });
    };
    self.conn.exec("release idb_op", .{}) catch |err| {
        log.warn(.storage, "idb savepoint release", .{ .err = err });
    };
}

// First record value in an index range (joins back to the store by primary key).
pub fn indexGetRange(self: *const Engine, arena: Allocator, object_store_id: i64, index_id: i64, b: Bounds) !?[]u8 {
    const ops = rangeOps(b);

    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf,
        \\ select r.value
        \\ from idb_index_records ir
        \\ join idb_records r on r.object_store_id = ?1 and r.key = ir.primary_key
        \\ where ir.index_id = ?2 and ir.key {s} ?3 and ir.key {s} ?4 order by ir.key, ir.primary_key
        \\ limit 1
    , .{ ops.lo, ops.hi });

    var row = (try self.conn.row(sql, .{ object_store_id, index_id, b.lower, b.upper })) orelse return null;
    defer row.deinit();

    return try arena.dupe(u8, row.get([]const u8, 0));
}

// First primary key in an index range.
pub fn indexGetKeyRange(self: *const Engine, arena: Allocator, index_id: i64, b: Bounds) !?[]u8 {
    const ops = rangeOps(b);
    var buf: [320]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf,
        \\ select primary_key
        \\ from idb_index_records
        \\ where index_id = ?1 and key {s} ?2 and key {s} ?3
        \\ order by key, primary_key limit 1
    , .{ ops.lo, ops.hi });

    var row = (try self.conn.row(sql, .{ index_id, b.lower, b.upper })) orelse return null;
    defer row.deinit();

    return try arena.dupe(u8, row.get([]const u8, 0));
}

pub fn indexCountRange(self: *const Engine, index_id: i64, b: Bounds) !i64 {
    const ops = rangeOps(b);
    var buf: [320]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf,
        \\ select count(*)
        \\ from idb_index_records
        \\ where index_id = ?1 and key {s} ?2 and key {s} ?3
    , .{ ops.lo, ops.hi });

    return (try self.conn.scalar(i64, sql, .{ index_id, b.lower, b.upper })) orelse 0;
}

// Full (index key, primary key, value) rows over an index range, ordered by index
// key (then primary key), ascending or — for a reverse direction — descending, and
// limited to `limit_` rows (null = no limit).
//
// When unique is true, we use sqlite3 bare aggregates to resolve the uniqueness
// Note that min(ir.primary_key) is used regardless of `reverse` because
// uniqueness is always based on ascending order.
pub fn indexGetAllRows(self: *const Engine, object_store_id: i64, index_id: i64, b: Bounds, reverse: bool, unique: bool, limit_: ?u32) !Sqlite.Rows {
    const ops = rangeOps(b);
    const order = if (reverse) "desc" else "asc";

    var buf: [640]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf,
        \\ select ir.key, {s}, r.value
        \\ from idb_index_records ir
        \\ join idb_records r on r.object_store_id = ?1 and r.key = ir.primary_key
        \\ where ir.index_id = ?2 and ir.key {s} ?3 and ir.key {s} ?4
        \\ {s}
        \\ order by ir.key {s}{s}
        \\ limit ?5
    , .{
        if (unique) "min(ir.primary_key)" else "ir.primary_key",
        ops.lo,
        ops.hi,
        if (unique) "group by ir.key" else "",
        order,
        if (unique) "" else if (reverse) ", ir.primary_key desc" else ", ir.primary_key asc",
    });

    // SQLite treats a negative LIMIT as "no limit".
    const limit: i64 = if (limit_) |c| @intCast(c) else -1;
    return self.conn.rows(sql, .{ object_store_id, index_id, b.lower, b.upper, limit });
}

pub const IndexCursorRecord = struct {
    key: []u8,
    primary_key: []u8,
    value: ?[]u8,
};

pub fn indexCursorSeek(
    self: *const Engine,
    arena: Allocator,
    object_store_id: i64,
    index_id: i64,
    b: Bounds,
    reverse: bool,
    from_key: []const u8,
    from_pk: []const u8,
    pk_inclusive: bool,
    with_value: bool,
    offset: u32,
) !?IndexCursorRecord {
    const ops = rangeOps(b);
    const order = if (reverse) "desc" else "asc";
    // Position past the current (key, primary_key): a strictly-greater key, or an
    // equal key with a greater (or, for continuePrimaryKey, >=) primary key.
    const key_op = if (reverse) "< " else "> ";
    const pk_op = if (reverse) (if (pk_inclusive) "<= " else "< ") else (if (pk_inclusive) ">= " else "> ");

    var buf: [640]u8 = undefined;
    const select = if (with_value)
        "select ir.key, ir.primary_key, r.value from idb_index_records ir join idb_records r on r.object_store_id = ?1 and r.key = ir.primary_key"
    else
        "select ir.key, ir.primary_key from idb_index_records ir";

    const sql = try std.fmt.bufPrint(
        &buf,
        \\ {s} where ir.index_id = ?2 and ir.key {s} ?3 and ir.key {s} ?4 and (ir.key {s}?5 or (ir.key = ?5 and ir.primary_key {s}?6))
        \\ order by ir.key {s}, ir.primary_key {s}
        \\ limit 1 offset ?7
    ,
        .{ select, ops.lo, ops.hi, key_op, pk_op, order, order },
    );

    var row = (try self.conn.row(sql, .{ object_store_id, index_id, b.lower, b.upper, from_key, from_pk, @as(i64, offset) })) orelse return null;
    defer row.deinit();

    return .{
        .key = try arena.dupe(u8, row.get([]const u8, 0)),
        .primary_key = try arena.dupe(u8, row.get([]const u8, 1)),
        .value = if (with_value) try arena.dupe(u8, row.get([]const u8, 2)) else null,
    };
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

// A point range stores empty operators; index queries want a closed range.
fn rangeOps(b: Bounds) struct { lo: []const u8, hi: []const u8 } {
    return .{
        .lo = if (b.is_point) ">= " else b.lower_op,
        .hi = if (b.is_point) "<= " else b.upper_op,
    };
}

// What a ranged getAll/getAllKeys returns: the value or key column.
pub const Column = enum {
    value,
    key,
};

// Open a getAll/getAllKeys cursor. The JS layer streams rows straight into a JS
// array, avoiding a copy of the whole result set out of sqlite. (The SQL text is
// copied into the prepared statement, so the stack `buf` can be discarded.)
pub fn getAllRangeRows(self: *const Engine, object_store_id: i64, b: Bounds, column: Column, limit_: ?u32) !Sqlite.Rows {
    var buf: [256]u8 = undefined;
    const head = if (column == .value) "select value" else "select key";
    const sql = try rangeSql(&buf, head, b, " order by key limit ?4");

    // SQLite treats a negative LIMIT as "no limit".
    const limit: i64 = if (limit_) |c| @intCast(c) else -1;
    return self.conn.rows(sql, .{ object_store_id, b.lower, b.upper, limit });
}

// Full (key, value) rows over a store range, ordered by key
pub fn getAllRows(self: *const Engine, object_store_id: i64, b: Bounds, reverse: bool, limit_: ?u32) !Sqlite.Rows {
    var buf: [256]u8 = undefined;
    const sql = try rangeSql(&buf, "select key, value", b, if (reverse) " order by key desc limit ?4" else " order by key limit ?4");
    // SQLite treats a negative LIMIT as "no limit".
    const limit: i64 = if (limit_) |c| @intCast(c) else -1;
    return self.conn.rows(sql, .{ object_store_id, b.lower, b.upper, limit });
}

pub fn getAllRange(self: *const Engine, arena: Allocator, object_store_id: i64, b: Bounds, column: Column, limit_: ?u32) ![]const []u8 {
    var rows = try self.getAllRangeRows(object_store_id, b, column, limit_);
    defer rows.deinit();

    var list: std.ArrayList([]u8) = .empty;
    while (try rows.next()) |row| {
        try list.append(arena, try arena.dupe(u8, row.get([]const u8, 0)));
    }
    return list.items;
}

pub const CursorRecord = struct {
    key: []u8,
    // null for a key-only cursor (the value column isn't selected or duped).
    value: ?[]u8,
};

// Seek a single record for a cursor: within `b`, in `reverse` order or not,
// positioned by `from_op ?4` (e.g. "> " last_key) and skipping `offset` matches
// (for advance). `from_key` of the min/max sentinel makes the position clause a
// no-op for the first step. `with_value` is false for openKeyCursor, which skips
// the (potentially large) value column entirely.
pub fn cursorSeek(
    self: *const Engine,
    arena: Allocator,
    object_store_id: i64,
    b: Bounds,
    reverse: bool,
    from_op: []const u8,
    from_key: []const u8,
    offset: u32,
    with_value: bool,
) !?CursorRecord {
    // A point range stores its operators empty; a cursor still wants a closed
    // range over the single key.
    const lower_op = if (b.is_point) ">= " else b.lower_op;
    const upper_op = if (b.is_point) "<= " else b.upper_op;
    const order = if (reverse) "desc" else "asc";

    var buf: [320]u8 = undefined;
    const sql = try std.fmt.bufPrint(
        &buf,
        "{s} from idb_records where object_store_id = ?1 and key {s} ?2 and key {s} ?3 and key {s} ?4 order by key {s} limit 1 offset ?5",
        .{ if (with_value) "select key, value" else "select key", lower_op, upper_op, from_op, order },
    );

    var row = (try self.conn.row(sql, .{ object_store_id, b.lower, b.upper, from_key, @as(i64, offset) })) orelse return null;
    defer row.deinit();
    return .{
        .key = try arena.dupe(u8, row.get([]const u8, 0)),
        .value = if (with_value) try arena.dupe(u8, row.get([]const u8, 1)) else null,
    };
}

const testing = @import("../../../../testing.zig");
test "IDB - Engine: ranged getAll/count honour open and closed bounds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var engine = try Engine.open(":memory:");
    defer engine.close();
    const db_id = try engine.upsertDatabase("app", 1);
    const store_id = try engine.createObjectStore(testing.allocator, db_id, "s", null, false);
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
    const store_id = try engine.createObjectStore(testing.allocator, db_id, "s", null, false);
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

test "IDB - Engine: detach unlinks parked waiters and hands off an owned gate" {
    var engine = try Engine.open(":memory:");
    defer engine.close();

    const TestWaiter = struct {
        waiter: Engine.GateWaiter,
        woken: u32 = 0,
        cancelled: u32 = 0,

        fn init(ctx: *anyopaque) @This() {
            return .{ .waiter = .{ .ctx = ctx, .wake = wake, .cancel = cancel } };
        }
        fn wake(w: *Engine.GateWaiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            self.woken += 1;
        }
        fn cancel(w: *Engine.GateWaiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            self.cancelled += 1;
        }
    };

    var ctx_a: u8 = 0;
    var ctx_b: u8 = 0;

    // a1 owns; a2 and b1 park behind it.
    var a1 = TestWaiter.init(&ctx_a);
    var a2 = TestWaiter.init(&ctx_a);
    var b1 = TestWaiter.init(&ctx_b);
    try testing.expectEqual(true, engine.acquireGate(&a1.waiter));
    try testing.expectEqual(false, engine.acquireGate(&a2.waiter));
    try testing.expectEqual(false, engine.acquireGate(&b1.waiter));

    // Detaching context A cancels both its waiters (owner + parked, no wakes
    // for either) and hands the gate straight to b1.
    engine.detach(&ctx_a);
    try testing.expectEqual(1, a1.cancelled);
    try testing.expectEqual(0, a1.woken);
    try testing.expectEqual(1, a2.cancelled);
    try testing.expectEqual(0, a2.woken);
    try testing.expectEqual(0, b1.cancelled);
    try testing.expectEqual(1, b1.woken);
    try testing.expect(engine._gate_owner == &b1.waiter);

    // Detaching a context with no participants is a no-op.
    engine.detach(&ctx_a);
    try testing.expect(engine._gate_owner == &b1.waiter);

    // releaseGate reports whether the caller actually owned the gate.
    try testing.expectEqual(false, engine.releaseGate(&a1.waiter));
    try testing.expectEqual(true, engine.releaseGate(&b1.waiter));
    try testing.expectEqual(null, engine._gate_owner);
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

    const store_id = try engine.createObjectStore(testing.allocator, db_id, "books", null, false);

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
    const store_id = try engine.createObjectStore(testing.allocator, db_id, "s", null, false);

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
    _ = try engine.createObjectStore(testing.allocator, db_id, "s", null, false);
    try testing.expectError(error.Constraint, engine.createObjectStore(testing.allocator, db_id, "s", null, false));
}

test "IDB - Engine: rollback discards uncommitted writes" {
    var engine = try Engine.open(":memory:");
    defer engine.close();

    const db_id = try engine.upsertDatabase("app", 1);
    const store_id = try engine.createObjectStore(testing.allocator, db_id, "s", null, false);

    try engine.begin();
    try engine.add(store_id, "k", "v");
    engine.rollback();

    try testing.expectEqual(null, try engine.get(testing.allocator, store_id, "k"));
}

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
