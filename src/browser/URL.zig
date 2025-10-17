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
