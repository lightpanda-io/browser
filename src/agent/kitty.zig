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

//! Kitty graphics protocol: probe the terminal for support and transmit a
//! PNG for immediate display. Spoken by kitty, ghostty, WezTerm and Konsole.

const std = @import("std");
const lp = @import("lightpanda");
const tty = @import("tty.zig");

const apc = "\x1b_G";
const st = "\x1b\\";

/// A 1x1 RGB graphics query followed by Device Attributes. A terminal that
/// speaks the protocol answers the query first; every terminal answers DA,
/// which marks the end of the reply so nothing is left in stdin for the line
/// editor. Multiplexers that don't pass graphics through (tmux) answer DA
/// themselves, so they read as unsupported.
const probe = apc ++ "i=31,s=1,v=1,a=q,t=d,f=24;AAAA" ++ st ++ "\x1b[c";

/// One round trip to the terminal, up to 100ms when it never answers;
/// callers cache the result. Stdout being a tty is the caller's check.
pub fn detect() bool {
    if (!(std.Io.File.stdin().isTty(lp.io) catch false)) return false;
    var raw = tty.Raw.enable() catch return false;
    defer raw.restore();

    if (std.c.write(std.posix.STDOUT_FILENO, probe.ptr, probe.len) != probe.len) return false;

    var buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[len..]) catch return false;
        if (n == 0) break;
        len += n;
        if (endsDeviceAttributes(buf[0..len])) break;
    }
    return supported(buf[0..len]);
}

fn supported(reply: []const u8) bool {
    return std.mem.find(u8, reply, apc) != null;
}

/// DA1 replies `ESC [ ? Ps ; … c`.
fn endsDeviceAttributes(reply: []const u8) bool {
    const start = std.mem.findLast(u8, reply, "\x1b[?") orelse return false;
    return std.mem.findScalarPos(u8, reply, start, 'c') != null;
}

pub const Cells = struct {
    cols: u16,
    rows: u16,
};

/// Keeps the aspect ratio and never upscales. Terminals that don't report
/// their pixel size get the usual 1:2 cell.
pub fn fit(width: u32, height: u32, ws: std.posix.winsize, max_rows: u16) Cells {
    const cell_w: f32 = if (ws.xpixel > 0) @as(f32, @floatFromInt(ws.xpixel)) / @as(f32, @floatFromInt(ws.col)) else 8;
    const cell_h: f32 = if (ws.ypixel > 0) @as(f32, @floatFromInt(ws.ypixel)) / @as(f32, @floatFromInt(ws.row)) else 16;
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const box_w = @as(f32, @floatFromInt(ws.col)) * cell_w;
    const box_h = @as(f32, @floatFromInt(max_rows)) * cell_h;
    const scale = @min(1.0, box_w / w, box_h / h);
    return .{
        .cols = @ceil(@max(1.0, w * scale / cell_w)),
        .rows = @ceil(@max(1.0, h * scale / cell_h)),
    };
}

/// The protocol caps a chunk's payload at 4096 bytes; a multiple of 4 keeps
/// base64 groups whole.
const chunk_len = 4096;

/// `q=2` silences the terminal's acknowledgement, which would otherwise land
/// in stdin.
pub fn write(writer: *std.Io.Writer, png_base64: []const u8, cells: Cells) std.Io.Writer.Error!void {
    try writer.print(apc ++ "a=T,f=100,q=2,c={d},r={d},", .{ cells.cols, cells.rows });
    var rest = png_base64;
    while (true) {
        const n = @min(rest.len, chunk_len);
        const more = rest.len > n;
        try writer.print("m={d};", .{@intFromBool(more)});
        try writer.writeAll(rest[0..n]);
        try writer.writeAll(st);
        if (!more) break;
        rest = rest[n..];
        try writer.writeAll(apc);
    }
    try writer.writeByte('\n');
}

const testing = std.testing;

test "kitty: probe reply parsing" {
    try testing.expect(supported("\x1b_Gi=31;OK\x1b\\\x1b[?62;c"));
    try testing.expect(supported("\x1b_Gi=31;EINVAL:bad\x1b\\\x1b[?1;2c"));
    try testing.expect(!supported("\x1b[?1;2c"));
    try testing.expect(!supported(""));

    try testing.expect(endsDeviceAttributes("\x1b_Gi=31;OK\x1b\\\x1b[?62;c"));
    try testing.expect(endsDeviceAttributes("\x1b[?1;2c"));
    try testing.expect(!endsDeviceAttributes("\x1b_Gi=31;OK\x1b\\"));
    try testing.expect(!endsDeviceAttributes("\x1b_Gi=31;OK\x1b\\\x1b[?62;"));
}

test "kitty.fit: fills the width without upscaling" {
    const ws: std.posix.winsize = .{ .row = 50, .col = 100, .xpixel = 1000, .ypixel = 1000 };
    // 10x20 cells; a 1280x720 image spans the 1000px width at 720*1000/1280 px tall.
    try testing.expectEqual(Cells{ .cols = 100, .rows = 29 }, fit(1280, 720, ws, 48));
    // A small image keeps its size: 300x100 px → 30x5 cells.
    try testing.expectEqual(Cells{ .cols = 30, .rows = 5 }, fit(300, 100, ws, 48));
}

test "kitty.fit: caps the rows and falls back to 8x16 cells" {
    const ws: std.posix.winsize = .{ .row = 50, .col = 100, .xpixel = 1000, .ypixel = 1000 };
    // 1280x4096 into 1000x480 px → scale 480/4096, 150x480 px → 15x24 cells.
    try testing.expectEqual(Cells{ .cols = 15, .rows = 24 }, fit(1280, 4096, ws, 24));

    const unsized: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    // 640x384 px box; 1280x720 → scale 0.5, 640x360 px → 80x23 cells.
    try testing.expectEqual(Cells{ .cols = 80, .rows = 23 }, fit(1280, 720, unsized, 24));
}

test "kitty.write: chunks the payload at 4096 bytes" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, "AAAA", .{ .cols = 3, .rows = 2 });
    try testing.expectEqualStrings("\x1b_Ga=T,f=100,q=2,c=3,r=2,m=0;AAAA\x1b\\\n", aw.written());

    aw.clearRetainingCapacity();
    const payload = [_]u8{'A'} ** (chunk_len * 2 + 4);
    try write(&aw.writer, &payload, .{ .cols = 80, .rows = 24 });
    const out = aw.written();
    const head = "\x1b_Ga=T,f=100,q=2,c=80,r=24,m=1;";
    try testing.expectEqualStrings(head, out[0..head.len]);
    var chunks = std.mem.splitSequence(u8, out, "\x1b\\");
    try testing.expectEqual(head.len + chunk_len, chunks.next().?.len);
    try testing.expectEqual("\x1b_Gm=1;".len + chunk_len, chunks.next().?.len);
    try testing.expectEqualStrings("\x1b_Gm=0;AAAA", chunks.next().?);
    try testing.expectEqualStrings("\n", chunks.next().?);
    try testing.expectEqual(null, chunks.next());
}
