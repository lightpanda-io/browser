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

const Pool = @import("Pool.zig");
pub const c = @cImport(@cInclude("sqlite3.h"));

const log = lp.log;
const Allocator = std.mem.Allocator;

const Sqlite = @This();

pool: Pool,

pub fn init(allocator: Allocator, path_: ?[:0]const u8) !Sqlite {
    const path = path_ orelse ":memory:";
    var pool = try Pool.init(allocator, path);
    errdefer pool.deinit(allocator);

    {
        // copy by value warning! The connection HAS to be returned to the
        // pool in this scope. If we didn't have this scope, we'd assign the
        // pool to the return value (copy A) and then release the original
        const conn = try pool.acquire();
        defer pool.release(conn);

        const version = try @import("migrations.zig").run(conn);
        log.info(.storage, "storage initialized", .{ .engine = "sqlite", .version = version, .path = path });
    }

    return .{
        .pool = pool,
    };
}

pub fn deinit(self: *Sqlite, allocator: Allocator) void {
    self.pool.deinit(allocator);
}

pub fn Migrations(comptime migrations: []const [:0]const u8) type {
    const hashes = comptime blk: {
        var h: [migrations.len]i64 = undefined;
        for (migrations, 0..) |sql, i| {
            const hash = std.hash.Wyhash.hash(0, sql);
            h[i] = @as(i64, @bitCast(hash));
        }
        break :blk h;
    };

    return struct {
        pub fn run(conn: Conn) !usize {
            try conn.exec(
                \\create table if not exists migrations (
                \\  id integer primary key,
                \\  hash integer not null,
                \\  applied_at integer not null
                \\)
            , .{});

            const current = (try conn.scalar(
                i64,
                "select max(id) from migrations",
                .{},
            )) orelse 0;

            const start: usize = @intCast(current);

            if (start > migrations.len) {
                log.err(.storage, "migrations removed", .{
                    .applied = start,
                    .defined = migrations.len,
                });
                return error.MigrationsRemoved;
            }

            if (start > 0) {
                var rows = try conn.rows("select id, hash from migrations order by id asc", .{});
                defer rows.deinit();

                while (try rows.next()) |row| {
                    const id = row.get(i64, 0);
                    const hash = row.get(i64, 1);
                    const idx: usize = @intCast(id - 1);
                    const stored_hash = hashes[idx];

                    if (hash != stored_hash) {
                        log.err(.storage, "migration hash mismatch", .{
                            .id = id,
                            .expected = stored_hash,
                            .got = hash,
                        });

                        return error.MigrationHashMismatch;
                    }
                }
            }

            if (start == migrations.len) {
                return start;
            }

            try conn.begin();
            errdefer conn.rollback() catch {};

            for (migrations[start..], start..) |sql, i| {
                try conn.exec(sql, .{});
                try conn.exec(
                    "insert into migrations (id, hash, applied_at) values ($1, $2, $3)",
                    .{ @as(i64, @intCast(i + 1)), hashes[i], std.time.timestamp() },
                );
            }

            try conn.commit();
            return migrations.len;
        }
    };
}

pub const Conn = struct {
    conn: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Conn {
        var conn: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        const rc = c.sqlite3_open_v2(path.ptr, &conn, flags, null);
        if (rc != c.SQLITE_OK) {
            if (conn) |connection| {
                _ = c.sqlite3_close_v2(connection);
            }
            return errorFromCode(rc);
        }
        return .{ .conn = conn.? };
    }

    pub fn close(self: Conn) void {
        _ = c.sqlite3_close_v2(self.conn);
    }

    pub fn exec(self: Conn, sql: [:0]const u8, values: anytype) !void {
        if (values.len == 0) {
            const rc = c.sqlite3_exec(self.conn, sql, null, null, null);
            if (rc != c.SQLITE_OK) {
                return errorFromCode(rc);
            }
            return;
        }

        const stmt = try self.prepare(sql);
        defer stmt.deinit();
        try stmt.bind(values);
        try stmt.stepToCompletion();
    }

    pub fn scalar(self: Conn, comptime T: type, sql: []const u8, values: anytype) !?T {
        if (comptime isScalar(T) == false) {
            @compileError("Cannot use `sqlite.scalar` function with a non-scalar type. Who owns that memory?");
        }

        const stmt = try self.prepare(sql);
        errdefer stmt.deinit();

        try stmt.bind(values);
        if (try stmt.step() == false) {
            stmt.deinit();
            return null;
        }
        var r = Row{ .stmt = stmt };
        defer r.deinit();
        return r.get(T, 0);
    }

    pub fn row(self: Conn, sql: []const u8, values: anytype) !?Row {
        const stmt = try self.prepare(sql);
        errdefer stmt.deinit();

        try stmt.bind(values);
        if (try stmt.step() == false) {
            stmt.deinit();
            return null;
        }
        return .{ .stmt = stmt };
    }

    pub fn rows(self: Conn, sql: []const u8, values: anytype) !Rows {
        const stmt = try self.prepare(sql);
        errdefer stmt.deinit();
        try stmt.bind(values);
        return .{ .stmt = stmt };
    }

    fn prepare(self: Conn, sql: []const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        var pz_tail: [*:0]const u8 = undefined;

        const rc = c.sqlite3_prepare_v2(self.conn, sql.ptr, @intCast(sql.len), &stmt, @ptrCast(&pz_tail));
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }

        return .{ .stmt = stmt.?, .conn = self.conn };
    }

    pub fn begin(self: Conn) !void {
        try self.exec("begin", .{});
    }

    pub fn commit(self: Conn) !void {
        try self.exec("commit", .{});
    }

    pub fn rollback(self: Conn) !void {
        try self.exec("rollback", .{});
    }

    pub fn busyTimeout(self: Conn, ms: c_int) !void {
        const rc = c.sqlite3_busy_timeout(self.conn, ms);
        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    pub fn lastError(self: Conn) [:0]const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.conn));
    }
};

const Statement = struct {
    conn: *c.sqlite3,
    stmt: *c.sqlite3_stmt,

    pub fn deinit(self: Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn bind(self: Statement, values: anytype) !void {
        const stmt = self.stmt;
        inline for (values, 0..) |value, i| {
            try _bind(@TypeOf(value), stmt, value, i + 1);
        }
    }

    pub fn get(self: Statement, comptime T: type, index: usize) T {
        const stmt = self.stmt;

        const TT = switch (@typeInfo(T)) {
            .optional => |opt| blk: {
                if (c.sqlite3_column_type(stmt, @intCast(index)) == c.SQLITE_NULL) {
                    return null;
                }
                break :blk opt.child;
            },
            else => T,
        };

        return switch (TT) {
            i64 => @intCast(c.sqlite3_column_int64(stmt, @intCast(index))),
            bool => @as(i64, @intCast(c.sqlite3_column_int64(stmt, @intCast(index)))) == 1,
            f64 => @floatCast(c.sqlite3_column_double(stmt, @intCast(index))),
            []const u8 => {
                const len = c.sqlite3_column_bytes(stmt, @intCast(index));
                if (len == 0) {
                    return "";
                }
                const data = c.sqlite3_column_text(stmt, @intCast(index));
                return @as([*c]const u8, @ptrCast(data))[0..@intCast(len)];
            },
            [:0]const u8 => {
                const len = c.sqlite3_column_bytes(stmt, @intCast(index));
                if (len == 0) {
                    return "";
                }
                const data = c.sqlite3_column_text(stmt, @intCast(index));
                return @as([*c]const u8, @ptrCast(data))[0..@intCast(len) :0];
            },
            else => @compileError("unsupported column type: " ++ @typeName(T)),
        };
    }

    pub fn step(self: Statement) !bool {
        const s = self.stmt;
        const rc = c.sqlite3_step(s);
        if (rc == c.SQLITE_DONE) {
            return false;
        }
        if (rc != c.SQLITE_ROW) {
            return errorFromCode(rc);
        }
        return true;
    }

    pub fn stepToCompletion(self: Statement) !void {
        const stmt = self.stmt;
        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_DONE => return,
                c.SQLITE_ROW => continue,
                else => |rc| return errorFromCode(rc),
            }
        }
    }

    pub fn reset(self: Statement) !void {
        switch (c.sqlite3_reset(self.stmt)) {
            c.SQLITE_OK => return,
            else => |rc| return errorFromCode(rc),
        }
    }

    fn _bind(comptime T: type, stmt: *c.sqlite3_stmt, value: anytype, bind_index: c_int) !void {
        var rc: c_int = 0;

        switch (@typeInfo(T)) {
            .null => rc = c.sqlite3_bind_null(stmt, bind_index),
            .int, .comptime_int => rc = c.sqlite3_bind_int64(stmt, bind_index, @intCast(value)),
            .float, .comptime_float => rc = c.sqlite3_bind_double(stmt, bind_index, value),
            .bool => {
                if (value) {
                    rc = c.sqlite3_bind_int64(stmt, bind_index, @intCast(1));
                } else {
                    rc = c.sqlite3_bind_int64(stmt, bind_index, @intCast(0));
                }
            },
            .pointer => |ptr| {
                switch (ptr.size) {
                    .one => switch (@typeInfo(ptr.child)) {
                        .array => |arr| {
                            if (arr.child == u8) {
                                rc = c.sqlite3_bind_text(stmt, bind_index, value.ptr, @intCast(value.len), c.SQLITE_STATIC);
                            } else {
                                bindError(T);
                            }
                        },
                        else => bindError(T),
                    },
                    .slice => switch (ptr.child) {
                        u8 => rc = c.sqlite3_bind_text(stmt, bind_index, value.ptr, @intCast(value.len), c.SQLITE_STATIC),
                        else => bindError(T),
                    },
                    else => bindError(T),
                }
            },
            .array => |arr| {
                if (arr.child == u8) {
                    @compileError("Pass a string slice, rather than an array, to bind a text/blob. String arrays will be supported when https://github.com/ziglang/zig/issues/15893#issuecomment-1925092582 is fixed");
                    // const data: []const u8 = value[0..arr.len];
                    // rc = c.sqlite3_bind_text(stmt, bind_index, data.ptr, @intCast(data.len), c.SQLITE_TRANSIENT);
                } else {
                    bindError(T);
                }
            },
            .optional => |opt| {
                if (value) |v| {
                    return _bind(opt.child, stmt, v, bind_index);
                } else {
                    rc = c.sqlite3_bind_null(stmt, bind_index);
                }
            },
            else => bindError(T),
        }

        if (rc != c.SQLITE_OK) {
            return errorFromCode(rc);
        }
    }

    fn bindError(comptime T: type) void {
        @compileError("cannot bind value of type " ++ @typeName(T));
    }
};

const Row = struct {
    stmt: Statement,

    pub fn deinit(self: Row) void {
        self.stmt.deinit();
    }

    pub fn get(self: Row, comptime T: type, index: usize) T {
        return self.stmt.get(T, index);
    }
};

const Rows = struct {
    stmt: Statement,

    pub fn deinit(self: Rows) void {
        self.stmt.deinit();
    }
    pub fn next(self: *Rows) !?Row {
        const stmt = self.stmt;
        const has_data = try stmt.step();
        if (!has_data) {
            return null;
        }
        return .{ .stmt = stmt };
    }
};

pub fn errorFromCode(result: c_int) Error {
    return switch (result) {
        c.SQLITE_ABORT => error.SqliteAbort,
        c.SQLITE_AUTH => error.SqliteAuth,
        c.SQLITE_BUSY => error.SqliteBusy,
        c.SQLITE_CANTOPEN => error.SqliteCantOpen,
        c.SQLITE_CONSTRAINT => error.SqliteConstraint,
        c.SQLITE_CORRUPT => error.SqliteCorrupt,
        c.SQLITE_EMPTY => error.SqliteEmpty,
        c.SQLITE_ERROR => error.SqliteError,
        c.SQLITE_FORMAT => error.SqliteFormat,
        c.SQLITE_FULL => error.SqliteFull,
        c.SQLITE_INTERNAL => error.SqliteInternal,
        c.SQLITE_INTERRUPT => error.SqliteInterrupt,
        c.SQLITE_IOERR => error.SqliteIoErr,
        c.SQLITE_LOCKED => error.SqliteLocked,
        c.SQLITE_MISMATCH => error.SqliteMismatch,
        c.SQLITE_MISUSE => error.SqliteMisuse,
        c.SQLITE_NOLFS => error.SqliteNoLFS,
        c.SQLITE_NOMEM => error.SqliteNoMem,
        c.SQLITE_NOTADB => error.SqliteNotADB,
        c.SQLITE_NOTFOUND => error.SqliteNotFound,
        c.SQLITE_NOTICE => error.SqliteNotice,
        c.SQLITE_PERM => error.SqlitePerm,
        c.SQLITE_PROTOCOL => error.SqliteProtocol,
        c.SQLITE_RANGE => error.SqliteRange,
        c.SQLITE_READONLY => error.SqliteReadOnly,
        c.SQLITE_SCHEMA => error.SqliteSchema,
        c.SQLITE_TOOBIG => error.SqliteTooBig,
        c.SQLITE_WARNING => error.SqliteWarning,
        // Extended codes
        c.SQLITE_ERROR_MISSING_COLLSEQ => error.SqliteErrorMissingCollseq,
        c.SQLITE_ERROR_RETRY => error.SqliteErrorRetry,
        c.SQLITE_ERROR_SNAPSHOT => error.SqliteErrorSnapshot,
        c.SQLITE_IOERR_READ => error.SqliteIoerrRead,
        c.SQLITE_IOERR_SHORT_READ => error.SqliteIoerrShortRead,
        c.SQLITE_IOERR_WRITE => error.SqliteIoerrWrite,
        c.SQLITE_IOERR_FSYNC => error.SqliteIoerrFsync,
        c.SQLITE_IOERR_DIR_FSYNC => error.SqliteIoerrDirFsync,
        c.SQLITE_IOERR_TRUNCATE => error.SqliteIoerrTruncate,
        c.SQLITE_IOERR_FSTAT => error.SqliteIoerrFstat,
        c.SQLITE_IOERR_UNLOCK => error.SqliteIoerrUnlock,
        c.SQLITE_IOERR_RDLOCK => error.SqliteIoerrRdlock,
        c.SQLITE_IOERR_DELETE => error.SqliteIoerrDelete,
        c.SQLITE_IOERR_BLOCKED => error.SqliteIoerrBlocked,
        c.SQLITE_IOERR_NOMEM => error.SqliteIoerrNomem,
        c.SQLITE_IOERR_ACCESS => error.SqliteIoerrAccess,
        c.SQLITE_IOERR_CHECKRESERVEDLOCK => error.SqliteIoerrCheckreservedlock,
        c.SQLITE_IOERR_LOCK => error.SqliteIoerrLock,
        c.SQLITE_IOERR_CLOSE => error.SqliteIoerrClose,
        c.SQLITE_IOERR_DIR_CLOSE => error.SqliteIoerrDirClose,
        c.SQLITE_IOERR_SHMOPEN => error.SqliteIoerrShmopen,
        c.SQLITE_IOERR_SHMSIZE => error.SqliteIoerrShmsize,
        c.SQLITE_IOERR_SHMLOCK => error.SqliteIoerrShmlock,
        c.SQLITE_IOERR_SHMMAP => error.SqliteIoerrShmmap,
        c.SQLITE_IOERR_SEEK => error.SqliteIoerrSeek,
        c.SQLITE_IOERR_DELETE_NOENT => error.SqliteIoerrDeleteNoent,
        c.SQLITE_IOERR_MMAP => error.SqliteIoerrMmap,
        c.SQLITE_IOERR_GETTEMPPATH => error.SqliteIoerrGetTempPath,
        c.SQLITE_IOERR_CONVPATH => error.SqliteIoerrConvPath,
        c.SQLITE_IOERR_VNODE => error.SqliteIoerrVnode,
        c.SQLITE_IOERR_AUTH => error.SqliteIoerrAuth,
        c.SQLITE_IOERR_BEGIN_ATOMIC => error.SqliteIoerrBeginAtomic,
        c.SQLITE_IOERR_COMMIT_ATOMIC => error.SqliteIoerrCommitAtomic,
        c.SQLITE_IOERR_ROLLBACK_ATOMIC => error.SqliteIoerrRollbackAtomic,
        c.SQLITE_IOERR_DATA => error.SqliteIoerrData,
        c.SQLITE_IOERR_CORRUPTFS => error.SqliteIoerrCorruptFS,
        c.SQLITE_LOCKED_SHAREDCACHE => error.SqliteLockedSharedCache,
        c.SQLITE_LOCKED_VTAB => error.SqliteLockedVTab,
        c.SQLITE_BUSY_RECOVERY => error.SqliteBusyRecovery,
        c.SQLITE_BUSY_SNAPSHOT => error.SqliteBusySnapshot,
        c.SQLITE_BUSY_TIMEOUT => error.SqliteBusyTimeout,
        c.SQLITE_CANTOPEN_NOTEMPDIR => error.SqliteCantOpenNoTempDir,
        c.SQLITE_CANTOPEN_ISDIR => error.SqliteCantOpenIsDir,
        c.SQLITE_CANTOPEN_FULLPATH => error.SqliteCantOpenFullPath,
        c.SQLITE_CANTOPEN_CONVPATH => error.SqliteCantOpenConvPath,
        c.SQLITE_CANTOPEN_DIRTYWAL => error.SqliteCantOpenDirtyWal,
        c.SQLITE_CANTOPEN_SYMLINK => error.SqliteCantOpenSymlink,
        c.SQLITE_CORRUPT_VTAB => error.SqliteCorruptVTab,
        c.SQLITE_CORRUPT_SEQUENCE => error.SqliteCorruptSequence,
        c.SQLITE_CORRUPT_INDEX => error.SqliteCorruptIndex,
        c.SQLITE_READONLY_RECOVERY => error.SqliteReadonlyRecovery,
        c.SQLITE_READONLY_CANTLOCK => error.SqliteReadonlyCantlock,
        c.SQLITE_READONLY_ROLLBACK => error.SqliteReadonlyRollback,
        c.SQLITE_READONLY_DBMOVED => error.SqliteReadonlyDbMoved,
        c.SQLITE_READONLY_CANTINIT => error.SqliteReadonlyCantInit,
        c.SQLITE_READONLY_DIRECTORY => error.SqliteReadonlyDirectory,
        c.SQLITE_ABORT_ROLLBACK => error.SqliteAbortRollback,
        c.SQLITE_CONSTRAINT_CHECK => error.SqliteConstraintCheck,
        c.SQLITE_CONSTRAINT_COMMITHOOK => error.SqliteConstraintCommithook,
        c.SQLITE_CONSTRAINT_FOREIGNKEY => error.SqliteConstraintForeignKey,
        c.SQLITE_CONSTRAINT_FUNCTION => error.SqliteConstraintFunction,
        c.SQLITE_CONSTRAINT_NOTNULL => error.SqliteConstraintNotNull,
        c.SQLITE_CONSTRAINT_PRIMARYKEY => error.SqliteConstraintPrimaryKey,
        c.SQLITE_CONSTRAINT_TRIGGER => error.SqliteConstraintTrigger,
        c.SQLITE_CONSTRAINT_UNIQUE => error.SqliteConstraintUnique,
        c.SQLITE_CONSTRAINT_VTAB => error.SqliteConstraintVTab,
        c.SQLITE_CONSTRAINT_ROWID => error.SqliteConstraintRowId,
        c.SQLITE_CONSTRAINT_PINNED => error.SqliteConstraintPinned,
        c.SQLITE_CONSTRAINT_DATATYPE => error.SqliteConstraintDatatype,
        c.SQLITE_NOTICE_RECOVER_WAL => error.SqliteNoticeRecoverWal,
        c.SQLITE_NOTICE_RECOVER_ROLLBACK => error.SqliteNoticeRecoverRollback,
        c.SQLITE_WARNING_AUTOINDEX => error.SqliteWarningAutoIndex,
        c.SQLITE_AUTH_USER => error.SqliteAuthUser,
        c.SQLITE_OK_LOAD_PERMANENTLY => error.SqliteOkLoadPermanently,
        else => {
            log.err(.storage, "unknown error", .{ .engine = "sqlite", .code = result });
            return error.SqliteUnknown;
        },
    };
}

pub const Error = error{
    SqliteAbort,
    SqliteAuth,
    SqliteBusy,
    SqliteCantOpen,
    SqliteConstraint,
    SqliteCorrupt,
    SqliteEmpty,
    SqliteError,
    SqliteFormat,
    SqliteFull,
    SqliteInternal,
    SqliteInterrupt,
    SqliteIoErr,
    SqliteLocked,
    SqliteMismatch,
    SqliteMisuse,
    SqliteNoLFS,
    SqliteNoMem,
    SqliteNotADB,
    SqliteNotFound,
    SqliteNotice,
    SqlitePerm,
    SqliteProtocol,
    SqliteRange,
    SqliteReadOnly,
    SqliteSchema,
    SqliteTooBig,
    SqliteWarning,
    SqliteErrorMissingCollseq,
    SqliteErrorRetry,
    SqliteErrorSnapshot,
    SqliteIoerrRead,
    SqliteIoerrShortRead,
    SqliteIoerrWrite,
    SqliteIoerrFsync,
    SqliteIoerrDirFsync,
    SqliteIoerrTruncate,
    SqliteIoerrFstat,
    SqliteIoerrUnlock,
    SqliteIoerrRdlock,
    SqliteIoerrDelete,
    SqliteIoerrBlocked,
    SqliteIoerrNomem,
    SqliteIoerrAccess,
    SqliteIoerrCheckreservedlock,
    SqliteIoerrLock,
    SqliteIoerrClose,
    SqliteIoerrDirClose,
    SqliteIoerrShmopen,
    SqliteIoerrShmsize,
    SqliteIoerrShmlock,
    SqliteIoerrShmmap,
    SqliteIoerrSeek,
    SqliteIoerrDeleteNoent,
    SqliteIoerrMmap,
    SqliteIoerrGetTempPath,
    SqliteIoerrConvPath,
    SqliteIoerrVnode,
    SqliteIoerrAuth,
    SqliteIoerrBeginAtomic,
    SqliteIoerrCommitAtomic,
    SqliteIoerrRollbackAtomic,
    SqliteIoerrData,
    SqliteIoerrCorruptFS,
    SqliteLockedSharedCache,
    SqliteLockedVTab,
    SqliteBusyRecovery,
    SqliteBusySnapshot,
    SqliteBusyTimeout,
    SqliteCantOpenNoTempDir,
    SqliteCantOpenIsDir,
    SqliteCantOpenFullPath,
    SqliteCantOpenConvPath,
    SqliteCantOpenDirtyWal,
    SqliteCantOpenSymlink,
    SqliteCorruptVTab,
    SqliteCorruptSequence,
    SqliteCorruptIndex,
    SqliteReadonlyRecovery,
    SqliteReadonlyCantlock,
    SqliteReadonlyRollback,
    SqliteReadonlyDbMoved,
    SqliteReadonlyCantInit,
    SqliteReadonlyDirectory,
    SqliteAbortRollback,
    SqliteConstraintCheck,
    SqliteConstraintCommithook,
    SqliteConstraintForeignKey,
    SqliteConstraintFunction,
    SqliteConstraintNotNull,
    SqliteConstraintPrimaryKey,
    SqliteConstraintTrigger,
    SqliteConstraintUnique,
    SqliteConstraintVTab,
    SqliteConstraintRowId,
    SqliteConstraintPinned,
    SqliteConstraintDatatype,
    SqliteNoticeRecoverWal,
    SqliteNoticeRecoverRollback,
    SqliteWarningAutoIndex,
    SqliteAuthUser,
    SqliteOkLoadPermanently,
    SqliteUnknown,
};

fn isScalar(comptime T: type) bool {
    const TT = switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => T,
    };

    return TT == i64 or TT == bool or TT == f64;
}

const testing = @import("../../testing.zig");
test "Sqlite: exec, row and scalar" {
    var conn = try Sqlite.Conn.open(":memory:");
    defer conn.close();

    try conn.exec("create table test (id integer primary key, name text, data blob)", .{});
    try conn.exec("insert into test (name, data) values (?1, ?2)", .{ "test name", "binary data" });

    {
        var row = (try conn.row("select name, data from test where id = 1", .{})) orelse unreachable;
        defer row.deinit();
        try testing.expectEqual("test name", row.get([]const u8, 0));
    }

    {
        try testing.expectEqual(1, (try conn.scalar(i64, "select count(*) from test where id = 1", .{})).?);
    }
}

test "Sqlite: Migrations - basic" {
    var conn = try Sqlite.Conn.open(":memory:");
    defer conn.close();

    const M = Migrations(&.{
        "create table test (id integer primary key, name text)",
        "alter table test add column email text",
    });

    const v1 = try M.run(conn);
    try testing.expectEqual(@as(usize, 2), v1);

    // idempotent - running again should return same version
    const v2 = try M.run(conn);
    try testing.expectEqual(@as(usize, 2), v2);

    // verify migrations table has correct entries
    try testing.expectEqual(
        @as(i64, 2),
        (try conn.scalar(i64, "select count(*) from migrations", .{})).?,
    );
}

test "Sqlite: Migrations - hash mismatch" {
    var conn = try Sqlite.Conn.open(":memory:");
    defer conn.close();

    const M1 = Migrations(&.{
        "create table test (id integer primary key, name text)",
    });
    _ = try M1.run(conn);

    // same migration list but with different sql = hash mismatch
    const M2 = Migrations(&.{
        "create table test (id integer primary key, name text, extra text)",
    });
    try testing.expectError(error.MigrationHashMismatch, M2.run(conn));
}

test "Sqlite: Migrations - removed migration" {
    var conn = try Sqlite.Conn.open(":memory:");
    defer conn.close();

    const M1 = Migrations(&.{
        "create table test (id integer primary key, name text)",
        "alter table test add column email text",
    });
    _ = try M1.run(conn);

    // fewer migrations than were applied
    const M2 = Migrations(&.{
        "create table test (id integer primary key, name text)",
    });
    try testing.expectError(error.MigrationsRemoved, M2.run(conn));
}
