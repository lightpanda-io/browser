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

//! Opt-in core-dump suppression.
//!
//! Lightpanda has no SIGSEGV handler, so a segfault (or the `abort()` in the
//! panic path) falls through to the kernel and writes a core dump. When many
//! instances run under a shared `core_pattern` crash reporter — e.g. a
//! containerized crawl fleet — those dumps become pure storage and alert
//! noise, and a browser core can capture the contents of arbitrary pages.
//! Crashes are already reported via telemetry, so `LIGHTPANDA_DISABLE_CORE_DUMP`
//! lets an operator drop the cores while leaving the default behavior
//! (and local debugging) untouched.

const std = @import("std");
const builtin = @import("builtin");
const lp = @import("lightpanda.zig");

const log = lp.log;

pub fn disableIfRequested() void {
    if (!shouldDisable()) return;
    disable() catch |err| {
        log.warn(.app, "could not disable core dumps", .{ .err = err });
    };
}

fn shouldDisable() bool {
    if (builtin.os.tag == .windows) return false;
    return std.process.hasEnvVarConstant("LIGHTPANDA_DISABLE_CORE_DUMP");
}

// Zeroes only the soft limit; that is what the kernel consults when deciding
// whether to dump (including the piped-`core_pattern` opt-out), and keeping the
// hard limit lets the process raise it again if it ever needs to.
fn disable() !void {
    var limit = try std.posix.getrlimit(.CORE);
    limit.cur = 0;
    try std.posix.setrlimit(.CORE, limit);
}

const testing = @import("testing.zig");

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;

test "core_dump: disabled only when the env var is set" {
    _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_CORE_DUMP"));
    try testing.expectEqual(false, shouldDisable());

    _ = setenv(@constCast("LIGHTPANDA_DISABLE_CORE_DUMP"), @constCast(""), 1);
    defer _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_CORE_DUMP"));
    try testing.expectEqual(true, shouldDisable());
}

test "core_dump: disable zeroes the soft RLIMIT_CORE" {
    if (builtin.os.tag == .windows) return;

    const original = try std.posix.getrlimit(.CORE);
    defer std.posix.setrlimit(.CORE, original) catch {};

    try disable();

    const after = try std.posix.getrlimit(.CORE);
    try testing.expectEqual(@as(@TypeOf(after.cur), 0), after.cur);
    try testing.expectEqual(original.max, after.max);
}
