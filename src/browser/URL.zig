// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;

const ResolveOpts = struct {
    always_dupe: bool = false,
};
// path is anytype, so that it can be used with both []const u8 and [:0]const u8
pub fn resolve(allocator: Allocator, base: [:0]const u8, path: anytype, comptime opts: ResolveOpts) ![:0]const u8 {
    const PT = @TypeOf(path);
    if (base.len == 0 or isCompleteHTTPUrl(path)) {
        if (comptime opts.always_dupe or !isNullTerminated(PT)) {
            return allocator.dupeZ(u8, path);
        }
        return path;
    }

    if (path.len == 0) {
        if (comptime opts.always_dupe) {
            return allocator.dupeZ(u8, base);
        }
        return base;
    }

    if (path[0] == '?') {
        const base_path_end = std.mem.indexOfAny(u8, base, "?#") orelse base.len;
        return std.mem.joinZ(allocator, "", &.{ base[0..base_path_end], path });
    }
    if (path[0] == '#') {
        const base_fragment_start = std.mem.indexOfScalar(u8, base, '#') orelse base.len;
        return std.mem.joinZ(allocator, "", &.{ base[0..base_fragment_start], path });
    }

    if (std.mem.startsWith(u8, path, "//")) {
        // network-path reference
        const index = std.mem.indexOfScalar(u8, base, ':') orelse {
            if (comptime isNullTerminated(PT)) {
                return path;
            }
            return allocator.dupeZ(u8, path);
        };
        const protocol = base[0 .. index + 1];
        return std.mem.joinZ(allocator, "", &.{ protocol, path });
    }

    const scheme_end = std.mem.indexOf(u8, base, "://");
    const authority_start = if (scheme_end) |end| end + 3 else 0;
    const path_start = std.mem.indexOfScalarPos(u8, base, authority_start, '/') orelse base.len;

    if (path[0] == '/') {
        return std.mem.joinZ(allocator, "", &.{ base[0..path_start], path });
    }

    var normalized_base: []const u8 = base;
    if (std.mem.lastIndexOfScalar(u8, normalized_base[authority_start..], '/')) |pos| {
        normalized_base = normalized_base[0 .. pos + authority_start];
    }

    // trailing space so that we always have space to append the null terminator
    var out = try std.mem.join(allocator, "", &.{ normalized_base, "/", path, " " });
    const end = out.len - 1;

    const path_marker = path_start + 1;

    // Strip out ./ and ../. This is done in-place, because doing so can
    // only ever make `out` smaller. After this, `out` cannot be freed by
    // an allocator, which is ok, because we expect allocator to be an arena.
    var in_i: usize = 0;
    var out_i: usize = 0;
    while (in_i < end) {
        if (std.mem.startsWith(u8, out[in_i..], "./")) {
            in_i += 2;
            continue;
        }

        if (std.mem.startsWith(u8, out[in_i..], "../")) {
            std.debug.assert(out[out_i - 1] == '/');

            if (out_i > path_marker) {
                // go back before the /
                out_i -= 2;
                while (out_i > 1 and out[out_i - 1] != '/') {
                    out_i -= 1;
                }
            } else {
                // if out_i == path_marker, than we've reached the start of
                // the path. We can't ../ any more. E.g.:
                //    http://www.example.com/../hello.
                // You might think that's an error, but, at least with
                //     new URL('../hello', 'http://www.example.com/')
                // it just ignores the extra ../
            }
            in_i += 3;
            continue;
        }

        out[out_i] = out[in_i];
        in_i += 1;
        out_i += 1;
    }

    // we always have an extra space
    out[out_i] = 0;
    return out[0..out_i :0];
}

fn isNullTerminated(comptime value: type) bool {
    return @typeInfo(value).pointer.sentinel_ptr != null;
}

pub fn isCompleteHTTPUrl(url: []const u8) bool {
    if (url.len < 6) {
        return false;
    }

    // very common case
    if (url[0] == '/') {
        return false;
    }

    return std.ascii.startsWithIgnoreCase(url, "https://") or
        std.ascii.startsWithIgnoreCase(url, "http://") or
        std.ascii.startsWithIgnoreCase(url, "ftp://");
}

pub fn getUsername(raw: [:0]const u8) []const u8 {
    const user_info = getUserInfo(raw) orelse return "";
    const pos = std.mem.indexOfScalarPos(u8, user_info, 0, ':') orelse return user_info;
    return user_info[0..pos];
}

pub fn getPassword(raw: [:0]const u8) []const u8 {
    const user_info = getUserInfo(raw) orelse return "";
    const pos = std.mem.indexOfScalarPos(u8, user_info, 0, ':') orelse return "";
    return user_info[pos + 1 ..];
}

pub fn getPathname(raw: [:0]const u8) []const u8 {
    const protocol_end = std.mem.indexOf(u8, raw, "://") orelse 0;
    const path_start = std.mem.indexOfScalarPos(u8, raw, if (protocol_end > 0) protocol_end + 3 else 0, '/') orelse raw.len;

    const query_or_hash_start = std.mem.indexOfAnyPos(u8, raw, path_start, "?#") orelse raw.len;

    if (path_start >= query_or_hash_start) {
        if (std.mem.indexOf(u8, raw, "://") != null) return "/";
        return "";
    }

    return raw[path_start..query_or_hash_start];
}

pub fn getProtocol(raw: [:0]const u8) []const u8 {
    const pos = std.mem.indexOfScalarPos(u8, raw, 0, ':') orelse return "";
    return raw[0 .. pos + 1];
}

pub fn isHTTPS(raw: [:0]const u8) bool {
    return std.mem.startsWith(u8, raw, "https:");
}

pub fn getHostname(raw: [:0]const u8) []const u8 {
    const host = getHost(raw);
    const pos = std.mem.lastIndexOfScalar(u8, host, ':') orelse return host;
    return host[0..pos];
}

pub fn getPort(raw: [:0]const u8) []const u8 {
    const host = getHost(raw);
    const pos = std.mem.lastIndexOfScalar(u8, host, ':') orelse return "";

    if (pos + 1 >= host.len) {
        return "";
    }

    for (host[pos + 1 ..]) |c| {
        if (c < '0' or c > '9') {
            return "";
        }
    }

    return host[pos + 1 ..];
}

pub fn getSearch(raw: [:0]const u8) []const u8 {
    const pos = std.mem.indexOfScalarPos(u8, raw, 0, '?') orelse return "";
    const query_part = raw[pos..];

    if (std.mem.indexOfScalarPos(u8, query_part, 0, '#')) |fragment_start| {
        return query_part[0..fragment_start];
    }

    return query_part;
}

pub fn getHash(raw: [:0]const u8) []const u8 {
    const start = std.mem.indexOfScalarPos(u8, raw, 0, '#') orelse return "";
    return raw[start..];
}

pub fn getOrigin(allocator: Allocator, raw: [:0]const u8) !?[]const u8 {
    const port = getPort(raw);
    const protocol = getProtocol(raw);
    const hostname = getHostname(raw);

    const p = std.meta.stringToEnum(KnownProtocol, getProtocol(raw)) orelse return null;

    const include_port = blk: {
        if (port.len == 0) {
            break :blk false;
        }
        if (p == .@"https:" and std.mem.eql(u8, port, "443")) {
            break :blk false;
        }
        if (p == .@"http:" and std.mem.eql(u8, port, "80")) {
            break :blk false;
        }
        break :blk true;
    };

    if (include_port) {
        return try std.fmt.allocPrint(allocator, "{s}//{s}:{s}", .{ protocol, hostname, port });
    }
    return try std.fmt.allocPrint(allocator, "{s}//{s}", .{ protocol, hostname });
}

fn getUserInfo(raw: [:0]const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return null;
    const authority_start = scheme_end + 3;

    const pos = std.mem.indexOfScalar(u8, raw[authority_start..], '@') orelse return null;
    const path_start = std.mem.indexOfScalarPos(u8, raw, authority_start, '/') orelse raw.len;

    const full_pos = authority_start + pos;
    if (full_pos < path_start) {
        return raw[authority_start..full_pos];
    }

    return null;
}

pub fn getHost(raw: [:0]const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return "";

    var authority_start = scheme_end + 3;
    if (std.mem.indexOf(u8, raw[authority_start..], "@")) |pos| {
        authority_start += pos + 1;
    }

    const authority = raw[authority_start..];
    const path_start = std.mem.indexOfAny(u8, authority, "/?#") orelse return authority;
    return authority[0..path_start];
}

// Returns true if these two URLs point to the same document.
pub fn eqlDocument(first: [:0]const u8, second: [:0]const u8) bool {
    if (!std.mem.eql(u8, getHost(first), getHost(second))) return false;
    if (!std.mem.eql(u8, getPort(first), getPort(second))) return false;
    if (!std.mem.eql(u8, getPathname(first), getPathname(second))) return false;
    if (!std.mem.eql(u8, getSearch(first), getSearch(second))) return false;
    if (!std.mem.eql(u8, getHash(first), getHash(second))) return false;

    return true;
}

const KnownProtocol = enum {
    @"http:",
    @"https:",
};

const testing = @import("../testing.zig");
test "URL: isCompleteHTTPUrl" {
    try testing.expectEqual(true, isCompleteHTTPUrl("http://example.com/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("HttP://example.com/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("httpS://example.com/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("HTTPs://example.com/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("ftp://example.com/about"));

    try testing.expectEqual(false, isCompleteHTTPUrl("/example.com"));
    try testing.expectEqual(false, isCompleteHTTPUrl("../../about"));
    try testing.expectEqual(false, isCompleteHTTPUrl("about"));
}

// TODO: uncomment
// test "URL: resolve regression (#1093)" {
//     defer testing.reset();

//     const Case = struct {
//         base: []const u8,
//         path: []const u8,
//         expected: []const u8,
//     };

//     const cases = [_]Case{
//         .{
//             .base = "https://alas.aws.amazon.com/alas2.html",
//             .path = "../static/bootstrap.min.css",
//             .expected = "https://alas.aws.amazon.com/static/bootstrap.min.css",
//         },
//     };

//     for (cases) |case| {
//         const result = try resolve(testing.arena_allocator, case.path, case.base, .{});
//         try testing.expectString(case.expected, result);
//     }
// }

test "URL: resolve" {
    defer testing.reset();

    const Case = struct {
        base: [:0]const u8,
        path: [:0]const u8,
        expected: [:0]const u8,
    };

    const cases = [_]Case{
        .{
            .base = "https://example/xyz/abc/123",
            .path = "something.js",
            .expected = "https://example/xyz/abc/something.js",
        },
        .{
            .base = "https://example/xyz/abc/123",
            .path = "/something.js",
            .expected = "https://example/something.js",
        },
        .{
            .base = "https://example/",
            .path = "something.js",
            .expected = "https://example/something.js",
        },
        .{
            .base = "https://example/",
            .path = "/something.js",
            .expected = "https://example/something.js",
        },
        .{
            .base = "https://example",
            .path = "something.js",
            .expected = "https://example/something.js",
        },
        .{
            .base = "https://example",
            .path = "abc/something.js",
            .expected = "https://example/abc/something.js",
        },
        .{
            .base = "https://example/nested",
            .path = "abc/something.js",
            .expected = "https://example/abc/something.js",
        },
        .{
            .base = "https://example/nested/",
            .path = "abc/something.js",
            .expected = "https://example/nested/abc/something.js",
        },
        .{
            .base = "https://example/nested/",
            .path = "/abc/something.js",
            .expected = "https://example/abc/something.js",
        },
        .{
            .base = "https://example/nested/",
            .path = "http://www.github.com/example/",
            .expected = "http://www.github.com/example/",
        },
        .{
            .base = "https://example/nested/",
            .path = "",
            .expected = "https://example/nested/",
        },
        .{
            .base = "https://example/abc/aaa",
            .path = "./hello/./world",
            .expected = "https://example/abc/hello/world",
        },
        .{
            .base = "https://example/abc/aaa/",
            .path = "../hello",
            .expected = "https://example/abc/hello",
        },
        .{
            .base = "https://example/abc/aaa",
            .path = "../hello",
            .expected = "https://example/hello",
        },
        .{
            .base = "https://example/abc/aaa/",
            .path = "./.././.././hello",
            .expected = "https://example/hello",
        },
        .{
            .base = "some/page",
            .path = "hello",
            .expected = "some/hello",
        },
        .{
            .base = "some/page/",
            .path = "hello",
            .expected = "some/page/hello",
        },
        .{
            .base = "some/page/other",
            .path = ".././hello",
            .expected = "some/hello",
        },
        .{
            .base = "https://www.example.com/hello/world",
            .path = "//example/about",
            .expected = "https://example/about",
        },
        .{
            .base = "http:",
            .path = "//example.com/over/9000",
            .expected = "http://example.com/over/9000",
        },
        .{
            .base = "https://example.com/",
            .path = "../hello",
            .expected = "https://example.com/hello",
        },
        .{
            .base = "https://www.example.com/hello/world/",
            .path = "../../../../example/about",
            .expected = "https://www.example.com/example/about",
        },
    };

    for (cases) |case| {
        const result = try resolve(testing.arena_allocator, case.base, case.path, .{});
        try testing.expectString(case.expected, result);
    }
}
