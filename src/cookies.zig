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
const lp = @import("lightpanda");

const Session = @import("browser/Session.zig");
const Cookie = @import("browser/webapi/storage/Cookie.zig");

const log = lp.log;

/// Load cookies from a JSON file into the cookie jar.
/// The file format is an array of objects with: name, value, domain, path,
/// expires (optional, float), secure (optional, bool), httpOnly (optional, bool).
/// This matches the CDP Network.Cookie format used by Puppeteer and Playwright.
pub fn loadFromFile(session: *Session, path: []const u8) void {
    _loadFromFile(session, path) catch |err| {
        log.err(.app, "Cookie.loadFromFile", .{ .err = err, .path = path });
    };
}

fn _loadFromFile(session: *Session, path: []const u8) !void {
    const arena = try session.getArena(.medium, "Cookies.loadFromFile");
    defer session.releaseArena(arena);

    const content = std.fs.cwd().readFileAlloc(arena, path, 1024 * 1024) catch |err| {
        switch (err) {
            error.FileNotFound => log.debug(.app, "Cookie.readFile", .{ .path = path, .note = "file not found" }),
            else => log.err(.app, "Cookie.readFile", .{ .path = path, .err = err }),
        }
        return;
    };

    const json_cookies = std.json.parseFromSliceLeaky([]const JsonCookie, arena, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.err(.app, "Cookie.parseFile", .{ .path = path, .err = err });
        return;
    };

    const jar = &session.cookie_jar;
    const now = std.time.timestamp();

    var loaded: usize = 0;
    for (json_cookies) |jc| {
        var cookie_arena = std.heap.ArenaAllocator.init(jar.allocator);
        errdefer cookie_arena.deinit();

        const a = cookie_arena.allocator();
        const name = try a.dupe(u8, jc.name);
        const value = try a.dupe(u8, jc.value);
        const domain = try a.dupe(u8, jc.domain);
        const cookie_path = if (jc.path) |p| try a.dupe(u8, p) else "/";

        const cookie = Cookie{
            .arena = cookie_arena,
            .name = name,
            .value = value,
            .domain = domain,
            .path = cookie_path,
            .expires = jc.expires,
            .secure = jc.secure orelse false,
            .http_only = jc.httpOnly orelse false,
            .same_site = jc.sameSite,
        };

        jar.add(cookie, now, true) catch |err| {
            cookie.deinit();
            log.warn(.app, "invalid cookie", .{ .name = jc.name, .err = err });
            continue;
        };
        loaded += 1;
    }

    log.info(.app, "Cookie.loadFromFile", .{ .path = path, .count = loaded });
}

/// Save all cookies from the jar to a JSON file.
pub fn saveToFile(jar: *Cookie.Jar, path: []const u8) void {
    _saveToFile(jar, path) catch |err| {
        log.err(.app, "Cookie.saveToFile", .{ .path = path, .err = err });
    };
}

fn _saveToFile(jar: *Cookie.Jar, path: []const u8) !void {
    jar.removeExpired(null);

    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var writer = file.writer(&buf);
    const w = &writer.interface;

    try w.writeByte('[');
    for (jar.cookies.items, 0..) |c, i| {
        if (i > 0) {
            try w.writeByte(',');
        }

        try w.writeAll("\n  ");
        try std.json.Stringify.value(JsonCookie{
            .name = c.name,
            .value = c.value,
            .domain = c.domain,
            .path = c.path,
            .expires = c.expires,
            .secure = c.secure,
            .httpOnly = c.http_only,
            .sameSite = c.same_site,
        }, .{}, w);
    }

    if (jar.cookies.items.len > 0) {
        try w.writeByte('\n');
    }
    try w.writeAll("]\n");
    try writer.end();

    log.info(.app, "Cookie.saveToFile", .{ .path = path, .count = jar.cookies.items.len });
}

const JsonCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: ?[]const u8 = "/",
    expires: ?f64 = null,
    secure: ?bool = null,
    httpOnly: ?bool = null,
    sameSite: Cookie.SameSite = .none,
};
