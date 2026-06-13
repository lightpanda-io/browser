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

//! The agent REPL's startup banner: a pre-colored braille panda logo with the
//! title and command hints laid out beside it. Sized at comptime to fit 80
//! columns so it never has to measure the terminal.

const std = @import("std");
const lp = @import("lightpanda");
const Terminal = @import("Terminal.zig");

// A pre-colored (truecolor braille) panda. Each line carries its own ANSI and
// resets at the end, so it prints as-is; non-empty lines are the visible rows.
const logo =
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀\x1b[0m\n" ++
    "⠀⠀⠀⠀⠀⠀⠀\x1b[38;2;247;247;239m⣀⣴⣶⣿⣿⣿⣿⣿⣿⣶⣦⣀⠀⠀⠀⠀⠀\x1b[0m\n" ++
    "⠀⠀⠀⠀\x1b[38;2;247;247;239m⢀⣴⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣆⠀⠀⠀\x1b[0m\n" ++
    "⠀⠀⠀\x1b[38;2;247;247;239m⢠⣾⣿⣿⣿⣿⠉⠈⣉⣭⣭⣥⣤⡀⣿⣿⣿⣿⣷⡀⠀\x1b[0m\n" ++
    "⠀⠀\x1b[38;2;247;247;239m⢀⣿⠿⠟⠛⠛⠛⢠⣾⣿⠟⠛⢿⣿⠛⢎⢿⣿⣿⣿⣷⡀\x1b[0m\n" ++
    "⠀⠀\x1b[38;2;247;247;239m⢸⣀⠀⠀⠀⠀⠀⣿⣿⣿⠀⢠⣼⡿⠾⣺⢸⣿⣿⣿⣿⡇\x1b[0m\n" ++
    "⠀⠀\x1b[38;2;247;247;239m⢸⣿⣿⣷⣶⣤⡀⠹⣿⣿⣿⣿⣟⣗⣐⠟⠸⣿⣿⣿⣿⡇\x1b[0m\n" ++
    "⠀⠀\x1b[38;2;247;247;239m⠸⣿⣿⣿⣿⡿⠓⠀⠈⠛⠻⠿⠟⠛⠁⠀⠀⠘⣿⣿⣿⠇\x1b[0m\n" ++
    "⠀⠀\x1b[38;2;8;132;177m⢀⣼⣿⣿⣿⣶⣶\x1b[38;2;247;247;239m⣼⣶⡇⠀⠀⠀⠀⠀⢀⠀⠀⠘⣿⠏⠀\x1b[0m\n" ++
    "⠀\x1b[38;2;106;196;229m⣰⣿⣿⣿⣿⣿⣿⣿\x1b[38;2;8;132;177m⣿⣿⣿⣷⣦⣄⣀⠀⠀\x1b[38;2;247;247;239m⠑⢤⣤⢏\x1b[38;2;8;132;177m⣀⡀\x1b[0m\n" ++
    "\x1b[38;2;106;196;229m⠊⠉⠀⠀⠀⠀⠀⠀⠀⠉⠙⠻⢯\x1b[38;2;8;132;177m⡛⠿⢿⣿⣿⣿⡾⠿⠛⠉⠀\x1b[0m\n" ++
    "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀\x1b[0m";
const logo_cols = 24; // braille cells per row
const logo_rows = blk: {
    @setEvalBranchQuota(20000);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, logo, '\n');
    while (it.next()) |line| {
        if (line.len != 0) n += 1;
    }
    break :blk n;
};
const welcome_gap = "   ";

/// Banner text. Kept narrow enough that logo + gap + widest line fits in 80
/// columns (asserted at comptime below), so the banner always shows in full
/// without measuring the terminal or shedding the logo.
const banner_tagline_llm = "Control the browser with natural language";
const banner_tagline_basic = "Basic REPL (--no-llm) — commands only";
const banner_setup = "Set an API key, then run /provider <name>";
const banner_hints = [_][]const u8{
    "/goto <url> to navigate",
    "/save to generate a reproducible script",
    "/help to list commands   /quit to exit",
    "! to run JavaScript on the current page",
};

comptime {
    // Excludes the version line: it's build-environment-controlled (nightly tags
    // add a commit count + hash), so asserting it would break the build over an
    // input this file doesn't own.
    const fixed = [_][]const u8{
        "Lightpanda Agent",
        banner_tagline_llm,
        banner_tagline_basic,
        banner_setup,
    } ++ banner_hints;
    var maxw: usize = 0;
    for (fixed) |s| maxw = @max(maxw, std.unicode.utf8CountCodepoints(s) catch s.len);
    if (logo_cols + welcome_gap.len + maxw > 79) @compileError("welcome banner exceeds 79 columns");
}

/// Prints the welcome banner: the logo on the left with the title and command
/// hints beside it, vertically centered. `llm_active` picks the tagline.
pub fn print(llm_active: bool) void {
    const a = Terminal.ansi;

    var version_buf: [192]u8 = undefined;
    const version: []const u8 = std.fmt.bufPrint(&version_buf, a.dim ++ "{s}" ++ a.reset, .{lp.build_config.version}) catch "";

    var lines: [9][]const u8 = undefined;
    var n: usize = 0;
    lines[n] = a.bold ++ "Lightpanda Agent" ++ a.reset;
    n += 1;
    lines[n] = version;
    n += 1;
    lines[n] = "";
    n += 1;
    if (llm_active) {
        lines[n] = a.italic ++ banner_tagline_llm ++ a.reset;
        n += 1;
    } else {
        lines[n] = a.italic ++ banner_tagline_basic ++ a.reset;
        n += 1;
        lines[n] = a.dim ++ banner_setup ++ a.reset;
        n += 1;
    }
    inline for (banner_hints) |t| {
        lines[n] = a.dim ++ t ++ a.reset;
        n += 1;
    }
    const text = lines[0..n];

    const start = (logo_rows - text.len) / 2;
    std.debug.print("\n", .{});
    var row: usize = 0;
    var it = std.mem.splitScalar(u8, logo, '\n');
    while (it.next()) |logo_line| {
        if (logo_line.len == 0) continue;
        std.debug.print("{s}", .{logo_line});
        if (row >= start and row - start < text.len) {
            const line = text[row - start];
            if (line.len != 0) std.debug.print("{s}{s}", .{ welcome_gap, line });
        }
        std.debug.print("\n", .{});
        row += 1;
    }
}
