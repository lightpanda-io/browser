const std = @import("std");

const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const WebApiURL = @import("browser/url/url.zig").URL;

pub const stitch = URL.stitch;

pub const URL = struct {
    uri: Uri,
    raw: []const u8,

    pub const empty = URL{ .uri = .{ .scheme = "" }, .raw = "" };
    pub const about_blank = URL{ .uri = .{ .scheme = "" }, .raw = "about:blank" };

    // We assume str will last as long as the URL
    // In some cases, this is safe to do, because we know the URL is short lived.
    // In most cases though, we assume the caller will just dupe the string URL
    // into an arena
    pub fn parse(str: []const u8, default_scheme: ?[]const u8) !URL {
        var uri = Uri.parse(str) catch try Uri.parseAfterScheme(default_scheme orelse "https", str);

        // special case, url scheme is about, like about:blank.
        // Use an empty string as host.
        if (std.mem.eql(u8, uri.scheme, "about")) {
            uri.host = .{ .percent_encoded = "" };
        }

        if (uri.host == null) {
            return error.MissingHost;
        }

        std.debug.assert(uri.host.? == .percent_encoded);

        return .{
            .uri = uri,
            .raw = str,
        };
    }

    pub fn fromURI(arena: Allocator, uri: *const Uri) !URL {
        // This is embarrassing.
        var buf: std.ArrayListUnmanaged(u8) = .{};
        try uri.writeToStream(.{
            .scheme = true,
            .authentication = true,
            .authority = true,
            .path = true,
            .query = true,
            .fragment = true,
        }, buf.writer(arena));

        return parse(buf.items, null);
    }

    // Above, in `parse`, we error if a host doesn't exist
    // In other words, we can't have a URL with a null host.
    pub fn host(self: *const URL) []const u8 {
        return self.uri.host.?.percent_encoded;
    }

    pub fn port(self: *const URL) ?u16 {
        return self.uri.port;
    }

    pub fn scheme(self: *const URL) []const u8 {
        return self.uri.scheme;
    }

    pub fn origin(self: *const URL, writer: *std.Io.Writer) !void {
        return self.uri.writeToStream(writer, .{ .scheme = true, .authority = true });
    }

    pub fn format(self: *const URL, writer: *std.Io.Writer) !void {
        return writer.writeAll(self.raw);
    }

    pub fn toWebApi(self: *const URL, allocator: Allocator) !WebApiURL {
        return WebApiURL.init(allocator, self.uri);
    }

    /// Properly stitches two URL fragments together.
    ///
    /// For URLs with a path, it will replace the last entry with the src.
    /// For URLs without a path, it will add src as the path.
    pub fn stitch(
        allocator: Allocator,
        path: []const u8,
        base: []const u8,
        comptime opts: StitchOpts,
    ) !StitchReturn(opts) {
        if (base.len == 0 or isComleteHTTPUrl(path)) {
            return simpleStitch(allocator, path, opts);
        }

        if (path.len == 0) {
            return simpleStitch(allocator, base, opts);
        }

        if (std.mem.startsWith(u8, path, "//")) {
            // network-path reference
            const index = std.mem.indexOfScalar(u8, base, ':') orelse {
                return simpleStitch(allocator, path, opts);
            };

            const protocol = base[0..index];
            if (comptime opts.null_terminated) {
                return std.fmt.allocPrintSentinel(allocator, "{s}:{s}", .{ protocol, path }, 0);
            }
            return std.fmt.allocPrint(allocator, "{s}:{s}", .{ protocol, path });
        }

        // Quick hack because domains have to be at least 3 characters.
        // Given https://a.b  this will point to 'a'
        // Given http://a.b  this will point '.'
        // Either way, we just care about this value to find the start of the path
        const protocol_end: usize = if (isComleteHTTPUrl(base)) 8 else 0;

        if (path[0] == '/') {
            const pos = std.mem.indexOfScalarPos(u8, base, protocol_end, '/') orelse base.len;
            if (comptime opts.null_terminated) {
                return std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ base[0..pos], path }, 0);
            }
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ base[0..pos], path });
        }

        var normalized_base = base;
        if (std.mem.lastIndexOfScalar(u8, base[protocol_end..], '/')) |pos| {
            normalized_base = base[0 .. pos + protocol_end];
        }

        // that extra spacelets us handle opts.null_terminated. If we end up
        // not trimming anything, it ensures that we have 1 extra byte to store
        // our null terminator.
        var out = try std.fmt.allocPrint(allocator, "{s}/{s}" ++ if (comptime opts.null_terminated) " " else "", .{
            normalized_base,
            path,
        });

        const end = if (comptime opts.null_terminated) out.len - 1 else out.len;

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

                out_i -= 2;
                while (out_i > 1 and out[out_i - 1] != '/') {
                    out_i -= 1;
                }
                // <= to deal with the hack-ish protocol_end which will be off-by-one between http and https
                if (out_i <= protocol_end) return error.InvalidURL;
                in_i += 3;
                continue;
            }
            out[out_i] = out[in_i];
            in_i += 1;
            out_i += 1;
        }

        if (comptime opts.null_terminated) {
            // we always have an extra space
            out[out_i] = 0;
            return out[0..out_i :0];
        }
        return out[0..out_i];
    }

    pub fn concatQueryString(arena: Allocator, url: []const u8, query_string: []const u8) ![]const u8 {
        std.debug.assert(url.len != 0);

        if (query_string.len == 0) {
            return url;
        }

        var buf: std.ArrayListUnmanaged(u8) = .empty;

        // the most space well need is the url + ('?' or '&') + the query_string
        try buf.ensureTotalCapacity(arena, url.len + 1 + query_string.len);
        buf.appendSliceAssumeCapacity(url);

        if (std.mem.indexOfScalar(u8, url, '?')) |index| {
            const last_index = url.len - 1;
            if (index != last_index and url[last_index] != '&') {
                buf.appendAssumeCapacity('&');
            }
        } else {
            buf.appendAssumeCapacity('?');
        }
        buf.appendSliceAssumeCapacity(query_string);
        return buf.items;
    }
};

const StitchOpts = struct {
    alloc: AllocWhen = .always,
    null_terminated: bool = false,

    const AllocWhen = enum {
        always,
        if_needed,
    };
};

fn StitchReturn(comptime opts: StitchOpts) type {
    return if (opts.null_terminated) [:0]const u8 else []const u8;
}

fn simpleStitch(allocator: Allocator, url: []const u8, comptime opts: StitchOpts) !StitchReturn(opts) {
    if (comptime opts.null_terminated) {
        return allocator.dupeZ(u8, url);
    }

    if (comptime opts.alloc == .always) {
        return allocator.dupe(u8, url);
    }

    return url;
}

fn isComleteHTTPUrl(url: []const u8) bool {
    if (url.len < 8) {
        return false;
    }

    if (!std.ascii.startsWithIgnoreCase(url, "http")) {
        return false;
    }

    var pos: usize = 4;
    if (url[4] == 's' or url[4] == 'S') {
        pos = 5;
    }
    return std.mem.startsWith(u8, url[pos..], "://");
}

const testing = @import("testing.zig");
test "URL: isComleteHTTPUrl" {
    try testing.expectEqual(true, isComleteHTTPUrl("http://lightpanda.io/about"));
    try testing.expectEqual(true, isComleteHTTPUrl("HttP://lightpanda.io/about"));
    try testing.expectEqual(true, isComleteHTTPUrl("httpS://lightpanda.io/about"));
    try testing.expectEqual(true, isComleteHTTPUrl("HTTPs://lightpanda.io/about"));

    try testing.expectEqual(false, isComleteHTTPUrl("/lightpanda.io"));
    try testing.expectEqual(false, isComleteHTTPUrl("../../about"));
    try testing.expectEqual(false, isComleteHTTPUrl("about"));
    try testing.expectEqual(false, isComleteHTTPUrl("//lightpanda.io"));
    try testing.expectEqual(false, isComleteHTTPUrl("//lightpanda.io/about"));
}

test "URL: stitch" {
    defer testing.reset();

    const Case = struct {
        base: []const u8,
        path: []const u8,
        expected: []const u8,
    };

    const cases = [_]Case{ .{
        .base = "https://lightpanda.io/xyz/abc/123",
        .path = "something.js",
        .expected = "https://lightpanda.io/xyz/abc/something.js",
    }, .{
        .base = "https://lightpanda.io/xyz/abc/123",
        .path = "/something.js",
        .expected = "https://lightpanda.io/something.js",
    }, .{
        .base = "https://lightpanda.io/",
        .path = "something.js",
        .expected = "https://lightpanda.io/something.js",
    }, .{
        .base = "https://lightpanda.io/",
        .path = "/something.js",
        .expected = "https://lightpanda.io/something.js",
    }, .{
        .base = "https://lightpanda.io",
        .path = "something.js",
        .expected = "https://lightpanda.io/something.js",
    }, .{
        .base = "https://lightpanda.io",
        .path = "abc/something.js",
        .expected = "https://lightpanda.io/abc/something.js",
    }, .{
        .base = "https://lightpanda.io/nested",
        .path = "abc/something.js",
        .expected = "https://lightpanda.io/abc/something.js",
    }, .{
        .base = "https://lightpanda.io/nested/",
        .path = "abc/something.js",
        .expected = "https://lightpanda.io/nested/abc/something.js",
    }, .{
        .base = "https://lightpanda.io/nested/",
        .path = "/abc/something.js",
        .expected = "https://lightpanda.io/abc/something.js",
    }, .{
        .base = "https://lightpanda.io/nested/",
        .path = "http://www.github.com/lightpanda-io/",
        .expected = "http://www.github.com/lightpanda-io/",
    }, .{
        .base = "https://lightpanda.io/nested/",
        .path = "",
        .expected = "https://lightpanda.io/nested/",
    }, .{
        .base = "https://lightpanda.io/abc/aaa",
        .path = "./hello/./world",
        .expected = "https://lightpanda.io/abc/hello/world",
    }, .{
        .base = "https://lightpanda.io/abc/aaa/",
        .path = "../hello",
        .expected = "https://lightpanda.io/abc/hello",
    }, .{
        .base = "https://lightpanda.io/abc/aaa",
        .path = "../hello",
        .expected = "https://lightpanda.io/hello",
    }, .{
        .base = "https://lightpanda.io/abc/aaa/",
        .path = "./.././.././hello",
        .expected = "https://lightpanda.io/hello",
    }, .{
        .base = "some/page",
        .path = "hello",
        .expected = "some/hello",
    }, .{
        .base = "some/page/",
        .path = "hello",
        .expected = "some/page/hello",
    }, .{
        .base = "some/page/other",
        .path = ".././hello",
        .expected = "some/hello",
    }, .{
        .path = "//static.lightpanda.io/hello.js",
        .base = "https://lightpanda.io/about/",
        .expected = "https://static.lightpanda.io/hello.js",
    } };

    for (cases) |case| {
        const result = try stitch(testing.arena_allocator, case.path, case.base, .{});
        try testing.expectString(case.expected, result);
    }

    try testing.expectError(
        error.InvalidURL,
        stitch(testing.arena_allocator, "../hello", "https://lightpanda.io/", .{}),
    );
    try testing.expectError(
        error.InvalidURL,
        stitch(testing.arena_allocator, "../hello", "http://lightpanda.io/", .{}),
    );
}

test "URL: stitch null terminated" {
    defer testing.reset();

    const Case = struct {
        base: []const u8,
        path: []const u8,
        expected: []const u8,
    };

    const cases = [_]Case{
        .{
            .base = "https://lightpanda.io/xyz/abc/123",
            .path = "something.js",
            .expected = "https://lightpanda.io/xyz/abc/something.js",
        },
        .{
            .base = "https://lightpanda.io/xyz/abc/123",
            .path = "/something.js",
            .expected = "https://lightpanda.io/something.js",
        },
        .{
            .base = "https://lightpanda.io/",
            .path = "something.js",
            .expected = "https://lightpanda.io/something.js",
        },
        .{
            .base = "https://lightpanda.io/",
            .path = "/something.js",
            .expected = "https://lightpanda.io/something.js",
        },
        .{
            .base = "https://lightpanda.io",
            .path = "something.js",
            .expected = "https://lightpanda.io/something.js",
        },
        .{
            .base = "https://lightpanda.io",
            .path = "abc/something.js",
            .expected = "https://lightpanda.io/abc/something.js",
        },
        .{
            .base = "https://lightpanda.io/nested",
            .path = "abc/something.js",
            .expected = "https://lightpanda.io/abc/something.js",
        },
        .{
            .base = "https://lightpanda.io/nested/",
            .path = "abc/something.js",
            .expected = "https://lightpanda.io/nested/abc/something.js",
        },
        .{
            .base = "https://lightpanda.io/nested/",
            .path = "/abc/something.js",
            .expected = "https://lightpanda.io/abc/something.js",
        },
        .{
            .base = "https://lightpanda.io/nested/",
            .path = "http://www.github.com/lightpanda-io/",
            .expected = "http://www.github.com/lightpanda-io/",
        },
        .{
            .base = "https://lightpanda.io/nested/",
            .path = "",
            .expected = "https://lightpanda.io/nested/",
        },
        .{
            .base = "https://lightpanda.io/abc/aaa",
            .path = "./hello/./world",
            .expected = "https://lightpanda.io/abc/hello/world",
        },
        .{
            .base = "https://lightpanda.io/abc/aaa/",
            .path = "../hello",
            .expected = "https://lightpanda.io/abc/hello",
        },
        .{
            .base = "https://lightpanda.io/abc/aaa",
            .path = "../hello",
            .expected = "https://lightpanda.io/hello",
        },
        .{
            .base = "https://lightpanda.io/abc/aaa/",
            .path = "./.././.././hello",
            .expected = "https://lightpanda.io/hello",
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
    };

    for (cases) |case| {
        const result = try stitch(testing.arena_allocator, case.path, case.base, .{ .null_terminated = true });
        try testing.expectString(case.expected, result);
    }

    try testing.expectError(
        error.InvalidURL,
        stitch(testing.arena_allocator, "../hello", "https://lightpanda.io/", .{ .null_terminated = true }),
    );
    try testing.expectError(
        error.InvalidURL,
        stitch(testing.arena_allocator, "../hello", "http://lightpanda.io/", .{ .null_terminated = true }),
    );
}

test "URL: concatQueryString" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    {
        const url = try URL.concatQueryString(arena, "https://www.lightpanda.io/", "");
        try testing.expectEqual("https://www.lightpanda.io/", url);
    }

    {
        const url = try URL.concatQueryString(arena, "https://www.lightpanda.io/index?", "");
        try testing.expectEqual("https://www.lightpanda.io/index?", url);
    }

    {
        const url = try URL.concatQueryString(arena, "https://www.lightpanda.io/index?", "a=b");
        try testing.expectEqual("https://www.lightpanda.io/index?a=b", url);
    }

    {
        const url = try URL.concatQueryString(arena, "https://www.lightpanda.io/index?1=2", "a=b");
        try testing.expectEqual("https://www.lightpanda.io/index?1=2&a=b", url);
    }

    {
        const url = try URL.concatQueryString(arena, "https://www.lightpanda.io/index?1=2&", "a=b");
        try testing.expectEqual("https://www.lightpanda.io/index?1=2&a=b", url);
    }
}
