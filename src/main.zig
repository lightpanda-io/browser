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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = lp.log;
const App = lp.App;
const Config = lp.Config;
const SigHandler = @import("Sighandler.zig");
pub const panic = lp.crash_handler.panic;

pub fn main() !void {
    // allocator
    // - in Debug mode we use the General Purpose Allocator to detect memory leaks
    // - in Release mode we use the c allocator
    var gpa_instance: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    const gpa = if (builtin.mode == .Debug) gpa_instance.allocator() else std.heap.c_allocator;

    defer if (builtin.mode == .Debug) {
        if (gpa_instance.detectLeaks()) std.posix.exit(1);
    };

    // arena for main-specific allocations
    var main_arena_instance = std.heap.ArenaAllocator.init(gpa);
    const main_arena = main_arena_instance.allocator();
    defer main_arena_instance.deinit();

    try useSqlite3();

    run(gpa, main_arena) catch |err| {
        log.fatal(.app, "exit", .{ .err = err });
        std.posix.exit(1);
    };
}

fn run(allocator: Allocator, main_arena: Allocator) !void {
    const args = try Config.parseArgs(main_arena);
    defer args.deinit(main_arena);

    switch (args.mode) {
        .help => {
            args.printUsageAndExit(args.mode.help);
            return std.process.cleanExit();
        },
        .version => {
            var stdout = std.fs.File.stdout().writer(&.{});
            try stdout.interface.print("{s}\n", .{lp.build_config.version});
            return std.process.cleanExit();
        },
        else => {},
    }

    if (args.logLevel()) |ll| {
        log.opts.level = ll;
    }
    if (args.logFormat()) |lf| {
        log.opts.format = lf;
    }
    if (args.logFilterScopes()) |lfs| {
        log.opts.filter_scopes = lfs;
    }

    // must be installed before any other threads
    const sighandler = try main_arena.create(SigHandler);
    sighandler.* = .{ .arena = main_arena };
    try sighandler.install();

    // _app is global to handle graceful shutdown.
    var app = try App.init(allocator, &args);
    defer app.deinit();

    try sighandler.on(lp.Network.stop, .{&app.network});

    app.telemetry.record(.{ .run = {} });

    switch (args.mode) {
        .serve => |opts| {
            log.debug(.app, "startup", .{ .mode = "serve", .snapshot = app.snapshot.fromEmbedded() });
            const address = std.net.Address.parseIp(opts.host, opts.port) catch |err| {
                log.fatal(.app, "invalid server address", .{ .err = err, .host = opts.host, .port = opts.port });
                return args.printUsageAndExit(false);
            };

            var server = lp.Server.init(app, address) catch |err| {
                if (err == error.AddressInUse) {
                    log.fatal(.app, "address already in use", .{
                        .host = opts.host,
                        .port = opts.port,
                        .hint = "Another process is already listening on this address. " ++
                            "Stop the other process or use --port to choose a different port.",
                    });
                } else {
                    log.fatal(.app, "server run error", .{ .err = err });
                }
                return err;
            };
            defer server.deinit();

            try sighandler.on(lp.Server.shutdown, .{server});

            app.network.run();
        },
        .fetch => |opts| {
            const url = opts.url;
            log.debug(.app, "startup", .{ .mode = "fetch", .dump_mode = opts.dump_mode, .url = url, .snapshot = app.snapshot.fromEmbedded() });

            var fetch_opts = lp.FetchOpts{
                .wait_ms = opts.wait_ms,
                .wait_until = opts.wait_until,
                .wait_script = opts.wait_script,
                .wait_selector = opts.wait_selector,
                .dump_mode = opts.dump_mode,
                .dump = .{
                    .strip = opts.strip,
                    .with_base = opts.with_base,
                    .with_frames = opts.with_frames,
                },
            };

            var stdout = std.fs.File.stdout();
            var writer = stdout.writer(&.{});
            if (opts.dump_mode != null) {
                fetch_opts.writer = &writer.interface;
            }

            var worker_thread = try std.Thread.spawn(.{}, fetchThread, .{ app, url, fetch_opts });
            defer worker_thread.join();

            app.network.run();
        },
        .mcp => |opts| {
            log.info(.mcp, "starting server", .{});

            log.opts.format = .logfmt;

            var cdp_server: ?*lp.Server = null;
            if (opts.cdp_port) |port| {
                const address = std.net.Address.parseIp("127.0.0.1", port) catch |err| {
                    log.fatal(.mcp, "invalid cdp address", .{ .err = err, .port = port });
                    return;
                };
                cdp_server = try lp.Server.init(app, address);
                try sighandler.on(lp.Server.shutdown, .{cdp_server.?});
            }
            defer if (cdp_server) |s| s.deinit();

            var worker_thread = try std.Thread.spawn(.{}, mcpThread, .{ allocator, app });
            defer worker_thread.join();

            app.network.run();
        },
        else => unreachable,
    }
}

fn fetchThread(app: *App, url: [:0]const u8, fetch_opts: lp.FetchOpts) void {
    defer app.network.stop();
    lp.fetch(app, url, fetch_opts) catch |err| {
        log.fatal(.app, "fetch error", .{ .err = err, .url = url });
    };
}

fn mcpThread(allocator: std.mem.Allocator, app: *App) void {
    defer app.network.stop();

    var stdout = std.fs.File.stdout().writer(&.{});
    var mcp_server: *lp.mcp.Server = lp.mcp.Server.init(allocator, app, &stdout.interface) catch |err| {
        log.fatal(.mcp, "mcp init error", .{ .err = err });
        return;
    };
    defer mcp_server.deinit();

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buf);
    lp.mcp.router.processRequests(mcp_server, &stdin.interface) catch |err| {
        log.fatal(.mcp, "mcp error", .{ .err = err });
    };
}

fn useSqlite3() !void {
    const c = @cImport(@cInclude("sqlite3.h"));

    const flags = c.SQLITE_OPEN_READWRITE;

    var conn: ?*c.sqlite3 = null;
    {
        const rc = c.sqlite3_open_v2(":memory:", &conn, flags, null);
        if (rc != c.SQLITE_OK) {
            return sqlite3Error(rc);
        }
    }
    defer _ = c.sqlite3_close_v2(conn);

    var stmt: ?*c.sqlite3_stmt = null;
    {
        const sql = "select sqlite_version()";
        var tail: [*:0]const u8 = undefined;
        const rc = c.sqlite3_prepare_v2(conn, sql, @intCast(sql.len), &stmt, @ptrCast(&tail));
        if (rc != c.SQLITE_OK) {
            return sqlite3Error(rc);
        }
    }
    defer _ = c.sqlite3_finalize(stmt);

    {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) {
            return error.NoRow;
        }
        if (rc != c.SQLITE_ROW) {
            return sqlite3Error(rc);
        }

        const data = c.sqlite3_column_text(stmt, 0);
        const len = c.sqlite3_column_bytes(stmt, 0);
        if (len == 0) {
            return error.EmptyValue;
        }
        std.debug.print("sqlite version: {s}\n", .{@as([*c]const u8, @ptrCast(data))[0..@intCast(len)]});
    }
}

fn sqlite3Error(result: c_int) !void {
    const c = @cImport(@cInclude("sqlite3.h"));
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

        // extended codes:
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
        c.SQLITE_IOERR_SHMMAP => error.ioerrshmmap,
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

        else => std.debug.panic("{s} {d}", .{ c.sqlite3_errstr(result), result }),
    };
}
