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
    defer arena.release();

    const content = std.Io.Dir.cwd().readFileAlloc(lp.io, path, arena.allocator(), .limited(1024 * 1024)) catch |err| {
        switch (err) {
            error.FileNotFound => log.debug(.app, "Cookie.readFile", .{ .path = path, .note = "file not found" }),
            else => log.err(.app, "Cookie.readFile", .{ .path = path, .err = err }),
        }
        return;
    };

    const jar = &session.cookie_jar;

    // The file is either a CDP-style JSON array or the Netscape format. Sniff which one it is.
    const head = std.mem.trimStart(u8, content, &std.ascii.whitespace);
    if (head.len == 0) {
        log.debug(.app, "Cookie.parseFile", .{ .path = path, .note = "empty file" });
        return;
    }
    if (head[0] != '[' and head[0] != '{') {
        const loaded = try NetscapeFormat.parse(jar, content);
        log.info(.app, "Cookie.loadFromFile", .{ .path = path, .count = loaded });
        return;
    }

    const json_cookies = std.json.parseFromSliceLeaky([]const JsonCookie, arena.allocator(), content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.err(.app, "Cookie.parseFile", .{ .path = path, .err = err });
        return;
    };

    const now = lp.datetime.timestamp(.real);

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
            .same_site = parseJsonSameSite(jc.sameSite),
        };

        jar.add(cookie, now, true) catch |err| {
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

    const file = try std.Io.Dir.cwd().createFile(lp.io, path, .{});
    defer file.close(lp.io);

    var buf: [8192]u8 = undefined;
    var writer = file.writer(lp.io, &buf);
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
            .sameSite = @tagName(c.same_site),
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
    sameSite: ?[]const u8 = null,
};

fn parseJsonSameSite(value: ?[]const u8) Cookie.SameSite {
    const same_site = value orelse return .none;
    if (std.ascii.eqlIgnoreCase(same_site, "strict")) return .strict;
    if (std.ascii.eqlIgnoreCase(same_site, "lax")) return .lax;
    if (std.ascii.eqlIgnoreCase(same_site, "none")) return .none;
    return .none;
}

/// Netscape cookie file format parser with `#HttpOnly_` addition from curl.
/// https://docs.cyotek.com/cyowcopy/1.10/netscapecookieformat.html
/// https://curl.se/docs/http-cookies.html
pub const NetscapeFormat = struct {
    /// Parses and loads cookies in Netscape format.
    /// Returns number of cookies loaded.
    pub fn parse(jar: *Cookie.Jar, slice: []const u8) !usize {
        const now = lp.datetime.timestamp(.real);
        var loaded: usize = 0;

        var line_iterator = std.mem.splitScalar(u8, slice, '\n');
        iterate_lines: while (line_iterator.next()) |line| {
            if (line.len == 0) {
                continue :iterate_lines;
            }
            // Remove CR if there's one.
            var s = if (line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            // Skip if nothing left.
            if (s.len == 0) {
                continue :iterate_lines;
            }

            // Computed here since this doesn't have it's own column.
            var is_http_only = false;
            if (s[0] == '#') {
                // Is it continued with `HttpOnly_`?
                is_http_only =
                    s.len >= 10 and
                    @as(u64, @bitCast(s[1..9].*)) == @as(u64, @bitCast(@as([]const u8, "HttpOnly")[0..8].*)) and
                    s[9] == '_';
                // Regular comment; skip the line.
                if (!is_http_only) {
                    continue :iterate_lines;
                }
                // Advance.
                s = s[10..];
            }

            var fields: struct {
                domain: []const u8 = undefined,
                include_subdomains: bool = false,
                /// null means "/".
                path: ?[]const u8 = null,
                secure: bool = false,
                expires_at: f64 = 0,
                name: []const u8 = undefined,
                value: []const u8 = "",
            } = .{};

            // Iterate over columns.
            var column_index: usize = 0;
            var column_iterator = std.mem.splitScalar(u8, s, '\t');
            while (column_iterator.next()) |column| {
                defer column_index += 1;

                switch (column_index) {
                    0 => fields.domain = column,
                    1 => fields.include_subdomains = parseBool(column) catch continue :iterate_lines,
                    2 => {
                        // If this is a boolean, we have to set `secure` field here instead.
                        const secure = parseBool(column) catch {
                            // Not a boolean, set path.
                            fields.path = column;
                            continue;
                        };
                        fields.secure = secure;
                        // Parsed secure early, we have to advance once more.
                        column_index += 1;
                    },
                    3 => fields.secure = parseBool(column) catch continue :iterate_lines,
                    4 => fields.expires_at = std.fmt.parseFloat(f64, column) catch continue :iterate_lines,
                    5 => fields.name = column,
                    6 => fields.value = column,
                    // Indicates we got columns more than we expected.
                    else => continue :iterate_lines,
                }
            }

            // We need at least 6 columns filled (value can be empty).
            if (column_index < 6) {
                continue :iterate_lines;
            }

            var cookie_arena = std.heap.ArenaAllocator.init(jar.allocator);
            errdefer cookie_arena.deinit();

            const allocator = cookie_arena.allocator();
            const name = try allocator.dupe(u8, fields.name);
            const value = try allocator.dupe(u8, fields.value);
            const _path = if (fields.path) |path| try allocator.dupe(u8, path) else "/";
            // The domain column's leading dot and the `include_subdomains`
            // column can disagree. curl strips the dot on read and re-derives
            // it from the column, and `Cookie.matchesHost` keys tail-matching
            // off that dot, so the column is what decides it here.
            const bare_domain = if (fields.domain.len > 0 and fields.domain[0] == '.') fields.domain[1..] else fields.domain;
            const domain = if (fields.include_subdomains)
                try std.fmt.allocPrint(allocator, ".{s}", .{bare_domain})
            else
                try allocator.dupe(u8, bare_domain);

            // Bake a cookie.
            const cookie = Cookie{
                .arena = cookie_arena,
                .name = name,
                .value = value,
                .domain = domain,
                .path = _path,
                .expires = fields.expires_at,
                .secure = fields.secure,
                .http_only = is_http_only,
                .same_site = .none,
            };

            jar.add(cookie, now, true) catch |err| {
                log.warn(.app, "invalid cookie", .{ .name = fields.name, .err = err });
                continue :iterate_lines;
            };
            loaded += 1;
        }

        return loaded;
    }

    fn parseBool(s: []const u8) error{Invalid}!bool {
        if (std.ascii.eqlIgnoreCase(s, "false")) {
            return false;
        }
        if (std.ascii.eqlIgnoreCase(s, "true")) {
            return true;
        }
        return error.Invalid;
    }
};

test "cookies: netscape include_subdomains drives the domain's leading dot" {
    var jar = Cookie.Jar.init(std.testing.allocator, null);
    defer jar.deinit();

    // The domain column and the flag disagree on two of these four lines; the
    // flag wins either way. Expiry is far future so nothing is dropped as stale.
    const content =
        "# Netscape HTTP Cookie File\n" ++
        "example.com\tTRUE\t/\tFALSE\t4102444800\ta\t1\n" ++
        ".example.com\tTRUE\t/\tFALSE\t4102444800\tb\t2\n" ++
        "example.com\tFALSE\t/\tFALSE\t4102444800\tc\t3\n" ++
        ".example.com\tFALSE\t/\tFALSE\t4102444800\td\t4\n";

    try std.testing.expectEqual(@as(usize, 4), try NetscapeFormat.parse(&jar, content));
    try std.testing.expectEqualStrings(".example.com", jar.cookies.items[0].domain);
    try std.testing.expectEqualStrings(".example.com", jar.cookies.items[1].domain);
    try std.testing.expectEqualStrings("example.com", jar.cookies.items[2].domain);
    try std.testing.expectEqualStrings("example.com", jar.cookies.items[3].domain);

    // That dot is what `Cookie.matchesHost` keys tail-matching off.
    try std.testing.expect(jar.cookies.items[0].matchesHost("www.example.com"));
    try std.testing.expect(jar.cookies.items[2].matchesHost("www.example.com") == false);
    try std.testing.expect(jar.cookies.items[2].matchesHost("example.com"));
}

test "cookies: netscape #HttpOnly_ prefix sets http_only" {
    var jar = Cookie.Jar.init(std.testing.allocator, null);
    defer jar.deinit();

    // curl writes the prefix ahead of the domain column and strips it before
    // reading the columns, so it composes with the include_subdomains dot.
    const content =
        "#HttpOnly_example.com\tFALSE\t/\tFALSE\t4102444800\ta\t1\n" ++
        "#HttpOnly_.example.com\tTRUE\t/\tFALSE\t4102444800\tb\t2\n" ++
        "example.com\tFALSE\t/\tFALSE\t4102444800\tc\t3\n";

    try std.testing.expectEqual(@as(usize, 3), try NetscapeFormat.parse(&jar, content));

    try std.testing.expect(jar.cookies.items[0].http_only);
    try std.testing.expectEqualStrings("example.com", jar.cookies.items[0].domain);

    try std.testing.expect(jar.cookies.items[1].http_only);
    try std.testing.expectEqualStrings(".example.com", jar.cookies.items[1].domain);

    try std.testing.expect(jar.cookies.items[2].http_only == false);
}

test "cookies: netscape treats #HttpOnly_ near-misses as comments" {
    var jar = Cookie.Jar.init(std.testing.allocator, null);
    defer jar.deinit();

    // Every line here is a comment. curl's check is a case-sensitive
    // `strncmp(lineptr, "#HttpOnly_", 10)`, so none of these are the prefix,
    // and a bare prefix with no columns after it has nothing to load.
    const content =
        "# Netscape HTTP Cookie File\n" ++
        "#\n" ++
        "# HttpOnly_example.com\tFALSE\t/\tFALSE\t4102444800\ta\t1\n" ++
        "#HttpOnlyX example.com\tFALSE\t/\tFALSE\t4102444800\tb\t2\n" ++
        "#httponly_example.com\tFALSE\t/\tFALSE\t4102444800\tc\t3\n" ++
        "#HttpOnly_\n";

    try std.testing.expectEqual(@as(usize, 0), try NetscapeFormat.parse(&jar, content));
    try std.testing.expectEqual(@as(usize, 0), jar.cookies.items.len);
}

test "cookies: load JSON accepts CDP SameSite casing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(
        []const JsonCookie,
        arena.allocator(),
        "[{\"name\":\"sid\",\"value\":\"1\",\"domain\":\"example.com\",\"sameSite\":\"Lax\"}]",
        .{ .ignore_unknown_fields = true },
    );

    try std.testing.expectEqual(Cookie.SameSite.lax, parseJsonSameSite(parsed[0].sameSite));
}
