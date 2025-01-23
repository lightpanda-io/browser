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

const FileLoader = @import("fileloader.zig").FileLoader;

const parser = @import("netsurf");

const jsruntime = @import("jsruntime");
const Loop = jsruntime.Loop;
const Env = jsruntime.Env;
const Window = @import("../html/window.zig").Window;
const storage = @import("../storage/storage.zig");
const Client = @import("asyncio").Client;

const Types = @import("../main_wpt.zig").Types;
const UserContext = @import("../main_wpt.zig").UserContext;

const polyfill = @import("../polyfill/polyfill.zig");

// runWPT parses the given HTML file, starts a js env and run the first script
// tags containing javascript sources.
// It loads first the js libs files.
pub fn run(arena: *std.heap.ArenaAllocator, comptime dir: []const u8, f: []const u8, loader: *FileLoader) !Res {
    const alloc = arena.allocator();
    try parser.init();
    defer parser.deinit();

    // document
    const file = try std.fs.cwd().openFile(f, .{});
    defer file.close();

    const html_doc = try parser.documentHTMLParse(file.reader(), "UTF-8");

    const dirname = fspath.dirname(f[dir.len..]) orelse unreachable;

    // create JS env
    var loop = try Loop.init(alloc);
    defer loop.deinit();

    var cli = Client{ .allocator = alloc };
    defer cli.deinit();

    var js_env: Env = undefined;
    Env.init(&js_env, alloc, &loop, UserContext{
        .document = html_doc,
        .httpClient = &cli,
    });
    defer js_env.deinit();

    var storageShelf = storage.Shelf.init(alloc);
    defer storageShelf.deinit();

    // load user-defined types in JS env
    var js_types: [Types.len]usize = undefined;
    try js_env.load(&js_types);

    // start JS env
    try js_env.start();
    defer js_env.stop();

    // load polyfills
    try polyfill.load(alloc, js_env);

    // display console logs
    defer {
        const res = evalJS(js_env, alloc, "console.join('\\n');", "console") catch unreachable;
        defer res.deinit(alloc);

        if (res.msg != null and res.msg.?.len > 0) {
            std.debug.print("-- CONSOLE LOG\n{s}\n--\n", .{res.msg.?});
        }
    }

    // setup global env vars.
    var window = Window.create(null, null);
    try window.replaceDocument(html_doc);
    window.setStorageShelf(&storageShelf);
    try js_env.bindGlobal(&window);

    const init =
        \\console = [];
        \\console.log = function () {
        \\  console.push(...arguments);
        \\};
        \\console.debug = function () {
        \\  console.push("debug", ...arguments);
        \\};
    ;
    var res = try evalJS(js_env, alloc, init, "init");
    if (!res.ok) return res;
    res.deinit(alloc);

    // loop hover the scripts.
    const doc = parser.documentHTMLToDocument(html_doc);
    const scripts = try parser.documentGetElementsByTagName(doc, "script");
    const slen = try parser.nodeListLength(scripts);
    for (0..slen) |i| {
        const s = (try parser.nodeListItem(scripts, @intCast(i))).?;

        // If the script contains an src attribute, load it.
        if (try parser.elementGetAttribute(@as(*parser.Element, @ptrCast(s)), "src")) |src| {
            var path = src;
            if (!std.mem.startsWith(u8, src, "/")) {
                // no need to free path, thanks to the arena.
                path = try fspath.join(alloc, &.{ "/", dirname, path });
            }

            res = try evalJS(js_env, alloc, try loader.get(path), src);
            if (!res.ok) return res;
            res.deinit(alloc);
        }

        // If the script as a source text, execute it.
        const src = try parser.nodeTextContent(s) orelse continue;
        res = try evalJS(js_env, alloc, src, "");
        if (!res.ok) return res;
        res.deinit(alloc);
    }

    // Mark tests as ready to run.
    const loadevt = try parser.eventCreate();
    defer parser.eventDestroy(loadevt);

    try parser.eventInit(loadevt, "load", .{});
    _ = try parser.eventTargetDispatchEvent(
        parser.toEventTarget(Window, &window),
        loadevt,
    );

    // wait for all async executions
    var try_catch: jsruntime.TryCatch = undefined;
    try_catch.init(js_env);
    defer try_catch.deinit();
    js_env.wait() catch {
        return .{
            .ok = false,
            .msg = try try_catch.err(alloc, js_env),
        };
    };

    // Check the final test status.
    res = try evalJS(js_env, alloc, "report.status;", "teststatus");
    if (!res.ok) return res;
    res.deinit(alloc);

    // return the detailed result.
    return try evalJS(js_env, alloc, "report.log", "teststatus");
}

pub const Res = struct {
    ok: bool,
    msg: ?[]const u8,

    pub fn deinit(res: Res, alloc: std.mem.Allocator) void {
        if (res.msg) |msg| {
            alloc.free(msg);
        }
    }
};

fn evalJS(env: jsruntime.Env, alloc: std.mem.Allocator, script: []const u8, name: ?[]const u8) !Res {
    var try_catch: jsruntime.TryCatch = undefined;
    try_catch.init(env);
    defer try_catch.deinit();

    const v = env.exec(script, name) catch {
        return .{
            .ok = false,
            .msg = try try_catch.err(alloc, env),
        };
    };

    return .{
        .ok = true,
        .msg = try v.toString(alloc, env),
    };
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
