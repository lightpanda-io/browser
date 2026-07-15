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

//! Interactive numbered-choice picker for stdin/stderr prompts (provider
//! selection, /save mode, …). Self-contained raw-terminal handling; runs
//! before — or without — the isocline REPL.

const std = @import("std");
const ansi = @import("ansi.zig");

pub fn interactiveTty() bool {
    return std.posix.isatty(std.posix.STDIN_FILENO) and std.posix.isatty(std.posix.STDERR_FILENO);
}

/// Numbered TTY picker. `default` (if set) marks that row "(default)" and
/// makes Enter start on that index. Up/Down moves the active row; Enter
/// selects it. Numbered input still works for users who prefer typing.
pub fn promptNumberedChoice(header: []const u8, items: []const [:0]const u8, default: ?usize) !usize {
    if (items.len == 0) return error.NoChoice;
    const valid_default: ?usize = if (default) |d| if (d < items.len) d else null else null;
    if (interactiveTty()) {
        return promptInteractiveChoice(header, items, valid_default) catch |err| switch (err) {
            error.NotInteractive => try promptNumberedChoiceLine(header, items, valid_default),
            else => err,
        };
    }
    return promptNumberedChoiceLine(header, items, valid_default);
}

/// Line-oriented fallback. Errors with NoChoice after 3 invalid attempts.
fn promptNumberedChoiceLine(header: []const u8, items: []const [:0]const u8, default: ?usize) !usize {
    var stdin_buf: [128]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buf);

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        std.debug.print("{s}\n", .{header});
        for (items, 0..) |item, idx| {
            const marker: []const u8 = if (default) |d| (if (d == idx) " (default)" else "") else "";
            std.debug.print("  {d:>3}) {s}{s}\n", .{ idx + 1, item, marker });
        }
        std.debug.print("> ", .{});

        const line = stdin.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream, error.StreamTooLong, error.ReadFailed => return error.UserCancelled,
        };
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) {
            if (default) |d| return d;
            std.debug.print("Invalid input — type a number.\n", .{});
            continue;
        }
        const choice = std.fmt.parseInt(usize, trimmed, 10) catch {
            const hint: []const u8 = if (default != null) " (or press Enter for default)" else "";
            std.debug.print("Invalid input — type a number{s}.\n", .{hint});
            continue;
        };
        if (choice >= 1 and choice <= items.len) return choice - 1;
        std.debug.print("Out of range.\n", .{});
    }
    return error.NoChoice;
}

const ChoiceInput = enum { up, down, enter, cancel, ignore };

const ChoiceState = struct {
    selected: usize,

    fn init(default: ?usize) ChoiceState {
        return .{ .selected = default orelse 0 };
    }

    fn apply(self: *ChoiceState, input: ChoiceInput, item_count: usize) ?usize {
        switch (input) {
            .up => self.selected = if (self.selected == 0) item_count - 1 else self.selected - 1,
            .down => self.selected = (self.selected + 1) % item_count,
            .enter => return self.selected,
            .cancel, .ignore => {},
        }
        return null;
    }
};

const RawTerminal = struct {
    original: std.posix.termios,

    fn enable() !RawTerminal {
        if (!interactiveTty()) return error.NotInteractive;
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
        // Under the kitty "disambiguate" flag that `Terminal.readLine` pushes
        // (`\x1b[>1u`), cursor keys arrive as CSI-u the byte reader can't
        // parse; push flag 0 to force legacy arrow encoding. restore() pops
        // back to the REPL's flag.
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[>0u") catch {};
        return .{ .original = original };
    }

    fn restore(self: *const RawTerminal) void {
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[<u") catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
    }
};

fn promptInteractiveChoice(header: []const u8, items: []const [:0]const u8, default: ?usize) !usize {
    var raw: RawTerminal = try .enable();
    defer raw.restore();

    var state: ChoiceState = .init(default);
    const line_count = items.len + 2;
    var first_render = true;
    while (true) {
        renderChoice(header, items, default, state.selected, first_render);
        first_render = false;

        const input = readChoiceInput() catch return error.UserCancelled;
        if (input == .cancel) {
            clearChoiceRender(line_count);
            return error.UserCancelled;
        }
        if (state.apply(input, items.len)) |idx| {
            clearChoiceRender(line_count);
            std.debug.print("{s} {s}\r\n", .{ header, items[idx] });
            return idx;
        }
    }
}

fn clearChoiceRender(line_count: usize) void {
    moveChoiceRenderStart(line_count);
    for (0..line_count) |i| {
        std.debug.print(ansi.clear_line, .{});
        if (i + 1 < line_count) std.debug.print("\r\n", .{});
    }
    moveChoiceRenderStart(line_count);
}

fn moveChoiceRenderStart(line_count: usize) void {
    if (line_count > 1) {
        std.debug.print("\x1b[{d}F", .{line_count - 1});
    } else {
        std.debug.print("\r", .{});
    }
}

fn renderChoice(header: []const u8, items: []const [:0]const u8, default: ?usize, selected: usize, first_render: bool) void {
    if (!first_render) moveChoiceRenderStart(items.len + 2);
    std.debug.print(ansi.clear_line ++ "{s}\r\n", .{header});
    for (items, 0..) |item, idx| {
        const on_row = idx == selected;
        const marker: []const u8 = if (on_row) ">" else " ";
        const style: []const u8 = if (on_row) ansi.bold ++ ansi.teal else "";
        const reset: []const u8 = if (on_row) ansi.reset else "";
        const default_marker: []const u8 = if (default) |d| (if (d == idx) " (default)" else "") else "";
        std.debug.print(ansi.clear_line ++ "  {s} {s}{s}{s}{s}\r\n", .{ marker, style, item, default_marker, reset });
    }
    std.debug.print(ansi.clear_line ++ "{s}Use Up/Down then Enter. Esc cancels.{s}", .{ ansi.dim, ansi.reset });
}

fn readChoiceInput() !ChoiceInput {
    while (true) {
        const ch = try readChoiceByte() orelse continue;
        return switch (ch) {
            3, 4, 27 => esc: {
                if (ch != 27) break :esc .cancel;
                const b1 = try readChoiceByte() orelse break :esc .cancel;
                if (b1 != '[' and b1 != 'O') break :esc .cancel;
                const b2 = try readChoiceByte() orelse break :esc .cancel;
                break :esc switch (b2) {
                    'A' => .up,
                    'B' => .down,
                    else => .ignore,
                };
            },
            '\r', '\n' => .enter,
            else => .ignore,
        };
    }
}

fn readChoiceByte() !?u8 {
    var buf: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| switch (err) {
        error.WouldBlock => return null,
        error.InputOutput => return error.ReadFailed,
        else => return err,
    };
    if (n == 0) return null;
    return buf[0];
}

test "ChoiceState: arrows wrap and enter selects highlighted item" {
    var state: ChoiceState = .init(null);
    try std.testing.expectEqual(@as(usize, 0), state.selected);

    try std.testing.expectEqual(@as(?usize, null), state.apply(.up, 3));
    try std.testing.expectEqual(@as(usize, 2), state.selected);

    try std.testing.expectEqual(@as(?usize, null), state.apply(.down, 3));
    try std.testing.expectEqual(@as(usize, 0), state.selected);

    try std.testing.expectEqual(@as(?usize, 0), state.apply(.enter, 3));
}

test "ChoiceState: starts on default and enter returns it" {
    var state: ChoiceState = .init(2);
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    try std.testing.expectEqual(@as(?usize, 2), state.apply(.enter, 3));
}
