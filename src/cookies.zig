// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;

const Cookie = @import("browser/webapi/storage/Cookie.zig");
const log = @import("log.zig");

/// Load cookies from a JSON file into the cookie jar.
/// The file format is an array of objects with: name, value, domain, path,
/// expires (optional, float), secure (optional, bool), httpOnly (optional, bool).
/// This matches the CDP Network.Cookie format used by Puppeteer and Playwright.
pub fn loadFromFile(jar: *Cookie.Jar, path: []const u8) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return, // No file yet, nothing to load
        else => {
            log.err(.app, "failed to open cookies file", .{ .path = path, .err = err });
            return err;
        },
    };
    defer file.close();

    const content = file.readToEndAlloc(jar.allocator, 1024 * 1024) catch |err| {
        log.err(.app, "failed to read cookies file", .{ .path = path, .err = err });
        return err;
    };
    defer jar.allocator.free(content);

    const parsed = std.json.parseFromSlice([]const JsonCookie, jar.allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.err(.app, "failed to parse cookies JSON", .{ .path = path, .err = err });
        return err;
    };
    defer parsed.deinit();

    var loaded: usize = 0;
    for (parsed.value) |jc| {
        var arena = std.heap.ArenaAllocator.init(jar.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const cookie = Cookie{
            .arena = arena,
            .name = try a.dupe(u8, jc.name),
            .value = try a.dupe(u8, jc.value),
            .domain = try a.dupe(u8, jc.domain),
            .path = try a.dupe(u8, jc.path orelse "/"),
            .expires = jc.expires,
            .secure = jc.secure orelse false,
            .http_only = jc.httpOnly orelse false,
            .same_site = .none,
        };

        jar.add(cookie, std.time.timestamp()) catch |err| {
            cookie.deinit();
            log.warn(.app, "skipping cookie", .{ .name = jc.name, .err = err });
            continue;
        };
        loaded += 1;
    }

    log.info(.app, "loaded cookies from file", .{ .path = path, .count = loaded });
}

/// Save all cookies from the jar to a JSON file.
pub fn saveToFile(jar: *Cookie.Jar, path: []const u8) !void {
    jar.removeExpired(null);

    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var writer = file.writer(&buf);
    const w = &writer.interface;

    try w.writeAll("[");
    for (jar.cookies.items, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\n  ");
        try std.json.stringify(JsonCookie{
            .name = c.name,
            .value = c.value,
            .domain = c.domain,
            .path = c.path,
            .expires = c.expires,
            .secure = c.secure,
            .httpOnly = c.http_only,
        }, .{}, w);
    }
    if (jar.cookies.items.len > 0) {
        try w.writeAll("\n");
    }
    try w.writeAll("]\n");
    try writer.end();

    log.info(.app, "saved cookies to file", .{ .path = path, .count = jar.cookies.items.len });
}

const JsonCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: ?[]const u8 = "/",
    expires: ?f64 = null,
    secure: ?bool = null,
    httpOnly: ?bool = null,
};
