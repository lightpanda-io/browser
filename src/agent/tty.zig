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

//! Raw mode and size queries on the controlling terminal, for the
//! interactive pieces that run outside isocline's line editor.

const std = @import("std");

/// A read returns as soon as a byte arrives, or empty after 100ms.
pub const Raw = struct {
    original: std.posix.termios,

    pub fn enable() !Raw {
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 1;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        return .{ .original = original };
    }

    pub fn restore(self: *const Raw) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
    }
};

/// The size of the terminal behind `fd`. Null when it isn't a tty, the ioctl
/// fails, or the kernel reports 0 columns (some pseudo-ttys leave the field
/// unset). Cheap enough to call per render frame; picks up resizes without
/// SIGWINCH plumbing.
pub fn windowSize(fd: std.posix.fd_t) ?std.posix.winsize {
    var ws: std.posix.winsize = undefined;
    // bitcast via c_uint: on archs where `_IOR` sets the direction bit
    // (MIPS/PPC/SPARC), `IOCGWINSZ` exceeds i32 range, so a plain @intCast
    // panics; the bitcast preserves the bit pattern.
    const req: c_int = @bitCast(@as(c_uint, std.posix.T.IOCGWINSZ));
    if (std.c.ioctl(fd, req, &ws) != 0 or ws.col == 0) return null;
    return ws;
}
