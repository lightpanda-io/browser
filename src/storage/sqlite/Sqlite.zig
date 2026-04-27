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
            else => @compileError("unsupport column type: " ++ @typeName(T)),
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
        c.SQLITE_ABORT => error.Abort,
        c.SQLITE_AUTH => error.Auth,
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CORRUPT => error.Corrupt,
        c.SQLITE_EMPTY => error.Empty,
        c.SQLITE_ERROR => error.Error,
        c.SQLITE_FORMAT => error.Format,
        c.SQLITE_FULL => error.Full,
        c.SQLITE_INTERNAL => error.Internal,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_IOERR => error.IoErr,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_MISMATCH => error.Mismatch,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_NOLFS => error.NoLFS,
        c.SQLITE_NOMEM => error.NoMem,
        c.SQLITE_NOTADB => error.NotADB,
        c.SQLITE_NOTFOUND => error.Notfound,
        c.SQLITE_NOTICE => error.Notice,
        c.SQLITE_PERM => error.Perm,
        c.SQLITE_PROTOCOL => error.Protocol,
        c.SQLITE_RANGE => error.Range,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_SCHEMA => error.Schema,
        c.SQLITE_TOOBIG => error.TooBig,
        c.SQLITE_WARNING => error.Warning,
        // Extended codes
        c.SQLITE_ERROR_MISSING_COLLSEQ => error.ErrorMissingCollseq,
        c.SQLITE_ERROR_RETRY => error.ErrorRetry,
        c.SQLITE_ERROR_SNAPSHOT => error.ErrorSnapshot,
        c.SQLITE_IOERR_READ => error.IoerrRead,
        c.SQLITE_IOERR_SHORT_READ => error.IoerrShortRead,
        c.SQLITE_IOERR_WRITE => error.IoerrWrite,
        c.SQLITE_IOERR_FSYNC => error.IoerrFsync,
        c.SQLITE_IOERR_DIR_FSYNC => error.IoerrDir_fsync,
        c.SQLITE_IOERR_TRUNCATE => error.IoerrTruncate,
        c.SQLITE_IOERR_FSTAT => error.IoerrFstat,
        c.SQLITE_IOERR_UNLOCK => error.IoerrUnlock,
        c.SQLITE_IOERR_RDLOCK => error.IoerrRdlock,
        c.SQLITE_IOERR_DELETE => error.IoerrDelete,
        c.SQLITE_IOERR_BLOCKED => error.IoerrBlocked,
        c.SQLITE_IOERR_NOMEM => error.IoerrNomem,
        c.SQLITE_IOERR_ACCESS => error.IoerrAccess,
        c.SQLITE_IOERR_CHECKRESERVEDLOCK => error.IoerrCheckreservedlock,
        c.SQLITE_IOERR_LOCK => error.IoerrLock,
        c.SQLITE_IOERR_CLOSE => error.IoerrClose,
        c.SQLITE_IOERR_DIR_CLOSE => error.IoerrDirClose,
        c.SQLITE_IOERR_SHMOPEN => error.IoerrShmopen,
        c.SQLITE_IOERR_SHMSIZE => error.IoerrShmsize,
        c.SQLITE_IOERR_SHMLOCK => error.IoerrShmlock,
        c.SQLITE_IOERR_SHMMAP => error.IoerrShmmap,
        c.SQLITE_IOERR_SEEK => error.IoerrSeek,
        c.SQLITE_IOERR_DELETE_NOENT => error.IoerrDeleteNoent,
        c.SQLITE_IOERR_MMAP => error.IoerrMmap,
        c.SQLITE_IOERR_GETTEMPPATH => error.IoerrGetTempPath,
        c.SQLITE_IOERR_CONVPATH => error.IoerrConvPath,
        c.SQLITE_IOERR_VNODE => error.IoerrVnode,
        c.SQLITE_IOERR_AUTH => error.IoerrAuth,
        c.SQLITE_IOERR_BEGIN_ATOMIC => error.IoerrBeginAtomic,
        c.SQLITE_IOERR_COMMIT_ATOMIC => error.IoerrCommitAtomic,
        c.SQLITE_IOERR_ROLLBACK_ATOMIC => error.IoerrRollbackAtomic,
        c.SQLITE_IOERR_DATA => error.IoerrData,
        c.SQLITE_IOERR_CORRUPTFS => error.IoerrCorruptFS,
        c.SQLITE_LOCKED_SHAREDCACHE => error.LockedSharedCache,
        c.SQLITE_LOCKED_VTAB => error.LockedVTab,
        c.SQLITE_BUSY_RECOVERY => error.BusyRecovery,
        c.SQLITE_BUSY_SNAPSHOT => error.BusySnapshot,
        c.SQLITE_BUSY_TIMEOUT => error.BusyTimeout,
        c.SQLITE_CANTOPEN_NOTEMPDIR => error.CantOpenNoTempDir,
        c.SQLITE_CANTOPEN_ISDIR => error.CantOpenIsDir,
        c.SQLITE_CANTOPEN_FULLPATH => error.CantOpenFullPath,
        c.SQLITE_CANTOPEN_CONVPATH => error.CantOpenConvPath,
        c.SQLITE_CANTOPEN_DIRTYWAL => error.CantOpenDirtyWal,
        c.SQLITE_CANTOPEN_SYMLINK => error.CantOpenSymlink,
        c.SQLITE_CORRUPT_VTAB => error.CorruptVTab,
        c.SQLITE_CORRUPT_SEQUENCE => error.CorruptSequence,
        c.SQLITE_CORRUPT_INDEX => error.CorruptIndex,
        c.SQLITE_READONLY_RECOVERY => error.ReadonlyRecovery,
        c.SQLITE_READONLY_CANTLOCK => error.ReadonlyCantlock,
        c.SQLITE_READONLY_ROLLBACK => error.ReadonlyRollback,
        c.SQLITE_READONLY_DBMOVED => error.ReadonlyDbMoved,
        c.SQLITE_READONLY_CANTINIT => error.ReadonlyCantInit,
        c.SQLITE_READONLY_DIRECTORY => error.ReadonlyDirectory,
        c.SQLITE_ABORT_ROLLBACK => error.AbortRollback,
        c.SQLITE_CONSTRAINT_CHECK => error.ConstraintCheck,
        c.SQLITE_CONSTRAINT_COMMITHOOK => error.ConstraintCommithook,
        c.SQLITE_CONSTRAINT_FOREIGNKEY => error.ConstraintForeignKey,
        c.SQLITE_CONSTRAINT_FUNCTION => error.ConstraintFunction,
        c.SQLITE_CONSTRAINT_NOTNULL => error.ConstraintNotNull,
        c.SQLITE_CONSTRAINT_PRIMARYKEY => error.ConstraintPrimaryKey,
        c.SQLITE_CONSTRAINT_TRIGGER => error.ConstraintTrigger,
        c.SQLITE_CONSTRAINT_UNIQUE => error.ConstraintUnique,
        c.SQLITE_CONSTRAINT_VTAB => error.ConstraintVTab,
        c.SQLITE_CONSTRAINT_ROWID => error.ConstraintRowId,
        c.SQLITE_CONSTRAINT_PINNED => error.ConstraintPinned,
        c.SQLITE_CONSTRAINT_DATATYPE => error.ConstraintDatatype,
        c.SQLITE_NOTICE_RECOVER_WAL => error.NoticeRecoverWal,
        c.SQLITE_NOTICE_RECOVER_ROLLBACK => error.NoticeRecoverRollback,
        c.SQLITE_WARNING_AUTOINDEX => error.WarningAutoIndex,
        c.SQLITE_AUTH_USER => error.AuthUser,
        c.SQLITE_OK_LOAD_PERMANENTLY => error.OkLoadPermanently,
        else => {
            log.err(.storage, "unknown error", .{ .engine = "sqlite", .code = result });
            return error.Unknown;
        },
    };
}

pub const Error = error{
    Abort,
    Auth,
    Busy,
    CantOpen,
    Constraint,
    Corrupt,
    Empty,
    Error,
    Format,
    Full,
    Internal,
    Interrupt,
    IoErr,
    Locked,
    Mismatch,
    Misuse,
    NoLFS,
    NoMem,
    NotADB,
    Notfound,
    Notice,
    Perm,
    Protocol,
    Range,
    ReadOnly,
    Schema,
    TooBig,
    Warning,
    ErrorMissingCollseq,
    ErrorRetry,
    ErrorSnapshot,
    IoerrRead,
    IoerrShortRead,
    IoerrWrite,
    IoerrFsync,
    IoerrDir_fsync,
    IoerrTruncate,
    IoerrFstat,
    IoerrUnlock,
    IoerrRdlock,
    IoerrDelete,
    IoerrBlocked,
    IoerrNomem,
    IoerrAccess,
    IoerrCheckreservedlock,
    IoerrLock,
    IoerrClose,
    IoerrDirClose,
    IoerrShmopen,
    IoerrShmsize,
    IoerrShmlock,
    IoerrShmmap,
    IoerrSeek,
    IoerrDeleteNoent,
    IoerrMmap,
    IoerrGetTempPath,
    IoerrConvPath,
    IoerrVnode,
    IoerrAuth,
    IoerrBeginAtomic,
    IoerrCommitAtomic,
    IoerrRollbackAtomic,
    IoerrData,
    IoerrCorruptFS,
    LockedSharedCache,
    LockedVTab,
    BusyRecovery,
    BusySnapshot,
    BusyTimeout,
    CantOpenNoTempDir,
    CantOpenIsDir,
    CantOpenFullPath,
    CantOpenConvPath,
    CantOpenDirtyWal,
    CantOpenSymlink,
    CorruptVTab,
    CorruptSequence,
    CorruptIndex,
    ReadonlyRecovery,
    ReadonlyCantlock,
    ReadonlyRollback,
    ReadonlyDbMoved,
    ReadonlyCantInit,
    ReadonlyDirectory,
    AbortRollback,
    ConstraintCheck,
    ConstraintCommithook,
    ConstraintForeignKey,
    ConstraintFunction,
    ConstraintNotNull,
    ConstraintPrimaryKey,
    ConstraintTrigger,
    ConstraintUnique,
    ConstraintVTab,
    ConstraintRowId,
    ConstraintPinned,
    ConstraintDatatype,
    NoticeRecoverWal,
    NoticeRecoverRollback,
    WarningAutoIndex,
    AuthUser,
    OkLoadPermanently,
    Unknown,
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

test "Sqlite: Migration" {
    var sqlite = try Sqlite.init(testing.allocator, ":memory:");
    defer sqlite.deinit(testing.allocator);

    const conn = try sqlite.pool.acquire();
    defer sqlite.pool.release(conn);

    try testing.expectEqual(1, (try conn.scalar(i64, "select max(id) from migrations", .{})).?);
}
