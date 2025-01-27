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

const jsruntime = @import("jsruntime");

const parser = @import("netsurf");
const apiweb = @import("apiweb.zig");
const Window = @import("html/window.zig").Window;
const storage = @import("storage/storage.zig");
const Client = @import("asyncio").Client;

const html_test = @import("html_test.zig").html;

pub const Types = jsruntime.reflect(apiweb.Interfaces);
pub const UserContext = apiweb.UserContext;
pub const IO = @import("asyncio").Wrapper(jsruntime.Loop);

var doc: *parser.DocumentHTML = undefined;

fn execJS(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    // start JS env
    try js_env.start();
    defer js_env.stop();

    var cli = Client{ .allocator = alloc };
    defer cli.deinit();

    try js_env.setUserContext(UserContext{
        .document = doc,
        .httpClient = &cli,
    });

    var storageShelf = storage.Shelf.init(alloc);
    defer storageShelf.deinit();

    // alias global as self and window
    var window = Window.create(null, null);
    try window.replaceDocument(doc);
    window.setStorageShelf(&storageShelf);
    try js_env.bindGlobal(window);

    // launch shellExec
    try jsruntime.shellExec(alloc, js_env);
}

pub fn main() !void {

    // allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    try parser.init();
    defer parser.deinit();

    // document
    const file = try std.fs.cwd().openFile("test.html", .{});
    defer file.close();

    doc = try parser.documentHTMLParse(file.reader(), "UTF-8");
    defer parser.documentHTMLClose(doc) catch |err| {
        std.debug.print("documentHTMLClose error: {s}\n", .{@errorName(err)});
    };

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // launch shell
    try jsruntime.shell(&arena, execJS, .{ .app_name = "lightpanda-shell" });
}
