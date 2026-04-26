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

const lp = @import("lightpanda");

const Sqlite = @import("Sqlite.zig");

const log = lp.log;

pub fn run(conn: Sqlite.Conn) !i64 {
    const version = try getVersion(conn);
    return version;
}

fn getVersion(conn: Sqlite.Conn) !i64 {
    const exists_sql = "select exists (select 1 from sqlite_schema where type='table' and name='migrations')";
    if (try conn.scalar(bool, exists_sql, .{}) orelse false) {
        if (try conn.scalar(i64, "select max(id) from migrations", .{})) |version| {
            return version;
        }

        log.fatal(.storage, "corrupt database", .{ .engine = "sqlite", .note = "The sqlite database has an existing but empty `migrations` table" });
        return error.CorruptDatabase;
    }

    // this pragma is one of the the few (if not only) one that's persisted, so
    // we only have to do it the first time.
    conn.exec("pragma journal_mode=wal", .{}) catch |err| {
        log.fatal(.storage, "migrate", .{
            .err = err,
            .step = "journal_mode",
            .sqlite = conn.lastError(),
        });
        return err;
    };

    const create_sql =
        \\ create table migrations as
        \\ select 1 as id, current_timestamp as created_at
    ;
    conn.exec(create_sql, .{}) catch |err| {
        log.fatal(.storage, "migrate", .{ .err = err, .sqlite = conn.lastError(), .step = "create migrations" });
        return err;
    };

    return 1;
}
