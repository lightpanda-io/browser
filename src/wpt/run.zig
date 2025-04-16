// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const fspath = std.fs.path;
const Allocator = std.mem.Allocator;

const Env = @import("../browser/env.zig").Env;
const FileLoader = @import("fileloader.zig").FileLoader;
const Window = @import("../browser/html/window.zig").Window;

const parser = @import("../browser/netsurf.zig");
const polyfill = @import("../browser/polyfill/polyfill.zig");

// runWPT parses the given HTML file, starts a js env and run the first script
// tags containing javascript sources.
// It loads first the js libs files.
pub fn run(arena: Allocator, comptime dir: []const u8, f: []const u8, loader: *FileLoader, msg_out: *?[]const u8) ![]const u8 {
    // document
    const html = blk: {
        const file = try std.fs.cwd().openFile(f, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(arena, 16 * 1024);
    };

    const dirname = fspath.dirname(f[dir.len..]) orelse unreachable;

    var runner = try @import("../testing.zig").jsRunner(arena, .{
        .html = html,
    });
    defer runner.deinit();
    try polyfill.load(arena, runner.executor);

    // display console logs
    defer {
        const res = runner.eval("console.join('\\n');") catch unreachable;
        const log = res.toString(arena) catch unreachable;
        if (log.len > 0) {
            std.debug.print("-- CONSOLE LOG\n{s}\n--\n", .{log});
        }
    }

    try runner.exec(
        \\  console = [];
        \\  console.log = function () {
        \\    console.push(...arguments);
        \\  };
        \\  console.debug = function () {
        \\    console.push("debug", ...arguments);
        \\  };
    );

    // loop over the scripts.
    const doc = parser.documentHTMLToDocument(runner.state.document.?);
    const scripts = try parser.documentGetElementsByTagName(doc, "script");
    const slen = try parser.nodeListLength(scripts);
    for (0..slen) |i| {
        const s = (try parser.nodeListItem(scripts, @intCast(i))).?;

        // If the script contains an src attribute, load it.
        if (try parser.elementGetAttribute(@as(*parser.Element, @ptrCast(s)), "src")) |src| {
            var path = src;
            if (!std.mem.startsWith(u8, src, "/")) {
                // no need to free path, thanks to the arena.
                path = try fspath.join(arena, &.{ "/", dirname, path });
            }
            try runner.exec(try loader.get(path));
        }

        // If the script as a source text, execute it.
        const src = try parser.nodeTextContent(s) orelse continue;
        try runner.exec(src);
    }

    // Mark tests as ready to run.
    const loadevt = try parser.eventCreate();
    defer parser.eventDestroy(loadevt);

    try parser.eventInit(loadevt, "load", .{});
    _ = try parser.eventTargetDispatchEvent(
        parser.toEventTarget(@TypeOf(runner.window), &runner.window),
        loadevt,
    );

    // wait for all async executions
    {
        var try_catch: Env.TryCatch = undefined;
        try_catch.init(runner.executor);
        defer try_catch.deinit();
        runner.loop.run() catch |err| {
            if (try try_catch.err(arena)) |msg| {
                msg_out.* = msg;
            }
            return err;
        };
    }

    // Check the final test status.
    try runner.exec("report.status;");

    // return the detailed result.
    const res = try runner.eval("report.log");
    return res.toString(arena);
}

// browse the path to find the tests list.
pub fn find(allocator: std.mem.Allocator, comptime path: []const u8, list: *std.ArrayList([]const u8)) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true, .no_follow = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        if (!std.mem.endsWith(u8, entry.basename, ".html") and !std.mem.endsWith(u8, entry.basename, ".htm")) {
            continue;
        }

        try list.append(try fspath.join(allocator, &.{ path, entry.path }));
    }
}
