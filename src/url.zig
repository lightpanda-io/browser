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
        if (base.len == 0 or isCompleteHTTPUrl(path)) {
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
        const protocol_end: usize = if (isCompleteHTTPUrl(base)) 8 else 0;

        var root = base;
        if (std.mem.indexOfScalar(u8, base[protocol_end..], '/')) |pos| {
            root = base[0 .. pos + protocol_end];
        }

        if (path[0] == '/') {
            if (comptime opts.null_terminated) {
                return std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ root, path }, 0);
            }
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ root, path });
        }

        var old_path = std.mem.trimStart(u8, base[root.len..], "/");
        if (std.mem.lastIndexOfScalar(u8, old_path, '/')) |pos| {
            old_path = old_path[0..pos];
        } else {
            old_path = "";
        }

        // We preallocate all of the space possibly needed.
        // This is the root, old_path, new path, 3 slashes and perhaps a null terminated slot.
        var out = try allocator.alloc(u8, root.len + old_path.len + path.len + 3 + if (comptime opts.null_terminated) 1 else 0);
        var end: usize = 0;
        @memmove(out[0..root.len], root);
        end += root.len;
        out[root.len] = '/';
        end += 1;
        // If we don't have an old path, do nothing here.
        if (old_path.len > 0) {
            @memmove(out[end .. end + old_path.len], old_path);
            end += old_path.len;
            out[end] = '/';
            end += 1;
        }
        @memmove(out[end .. end + path.len], path);
        end += path.len;

        var read: usize = root.len;
        var write: usize = root.len;

        // Strip out ./ and ../. This is done in-place, because doing so can
        // only ever make `out` smaller. After this, `out` cannot be freed by
        // an allocator, which is ok, because we expect allocator to be an arena.
        while (read < end) {
            if (std.mem.startsWith(u8, out[read..], "./")) {
                read += 2;
                continue;
            }

            if (std.mem.startsWith(u8, out[read..], "../")) {
                if (write > root.len + 1) {
                    const search_range = out[root.len .. write - 1];
                    if (std.mem.lastIndexOfScalar(u8, search_range, '/')) |pos| {
                        write = root.len + pos + 1;
                    } else {
                        write = root.len + 1;
                    }
                }

                read += 3;
                continue;
            }

            out[write] = out[read];
            write += 1;
            read += 1;
        }

        if (comptime opts.null_terminated) {
            // we always have an extra space
            out[write] = 0;
            return out[0..write :0];
        }

        return out[0..write];
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

fn isCompleteHTTPUrl(url: []const u8) bool {
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
test "URL: isCompleteHTTPUrl" {
    try testing.expectEqual(true, isCompleteHTTPUrl("http://lightpanda.io/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("HttP://lightpanda.io/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("httpS://lightpanda.io/about"));
    try testing.expectEqual(true, isCompleteHTTPUrl("HTTPs://lightpanda.io/about"));

    try testing.expectEqual(false, isCompleteHTTPUrl("/lightpanda.io"));
    try testing.expectEqual(false, isCompleteHTTPUrl("../../about"));
    try testing.expectEqual(false, isCompleteHTTPUrl("about"));
    try testing.expectEqual(false, isCompleteHTTPUrl("//lightpanda.io"));
    try testing.expectEqual(false, isCompleteHTTPUrl("//lightpanda.io/about"));
}

test "URL: stitch" {
    defer testing.reset();

    const Case = struct {
        base: []const u8,
        path: []const u8,
        expected: []const u8,
    };

    const cases = [_]Case{
        .{
            .base = "https://lightpanda.io/xyz/abc/123",
            .path = "something1.js",
            .expected = "https://lightpanda.io/xyz/abc/something1.js",
        },
        .{
            .base = "https://lightpanda.io/xyz/abc/123",
            .path = "/something2.js",
            .expected = "https://lightpanda.io/something2.js",
        },
        .{
            .base = "https://lightpanda.io/",
            .path = "something3.js",
            .expected = "https://lightpanda.io/something3.js",
        },
        .{
            .base = "https://lightpanda.io/",
            .path = "/something4.js",
            .expected = "https://lightpanda.io/something4.js",
        },
        .{
            .base = "https://lightpanda.io",
            .path = "something5.js",
            .expected = "https://lightpanda.io/something5.js",
        },
        .{
            .base = "https://lightpanda.io",
            .path = "abc/something6.js",
            .expected = "https://lightpanda.io/abc/something6.js",
        },
        .{
            .base = "https://lightpanda.io/nested",
            .path = "abc/something7.js",
            .expected = "https://lightpanda.io/abc/something7.js",
        },
        .{
            .base = "https://lightpanda.io/nested/",
            .path = "abc/something8.js",
            .expected = "https://lightpanda.io/nested/abc/something8.js",
        },
        .{
            .base = "https://lightpanda.io/nested/",
            .path = "/abc/something9.js",
            .expected = "https://lightpanda.io/abc/something9.js",
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
        .{
            .path = "//static.lightpanda.io/hello.js",
            .base = "https://lightpanda.io/about/",
            .expected = "https://static.lightpanda.io/hello.js",
        },
    };

    for (cases) |case| {
        const result = try stitch(testing.arena_allocator, case.path, case.base, .{});
        try testing.expectString(case.expected, result);
    }
}

test "URL: stitch regression (#1093)" {
    defer testing.reset();

    const Case = struct {
        base: []const u8,
        path: []const u8,
        expected: []const u8,
    };

    const cases = [_]Case{
        .{
            .base = "https://alas.aws.amazon.com/alas2.html",
            .path = "../static/bootstrap.min.css",
            .expected = "https://alas.aws.amazon.com/static/bootstrap.min.css",
        },
    };

    for (cases) |case| {
        const result = try stitch(testing.arena_allocator, case.path, case.base, .{});
        try testing.expectString(case.expected, result);
    }
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
            .path = "something1.js",
            .expected = "https://lightpanda.io/xyz/abc/something1.js",
        },
        .{
            .base = "https://lightpanda.io/xyz/abc/123",
            .path = "/something2.js",
            .expected = "https://lightpanda.io/something2.js",
        },
        .{
            .base = "https://lightpanda.io/",
            .path = "something3.js",
            .expected = "https://lightpanda.io/something3.js",
        },
        .{
            .base = "https://lightpanda.io/",
            .path = "/something4.js",
            .expected = "https://lightpanda.io/something4.js",
        },
        .{
            .base = "https://lightpanda.io",
            .path = "something5.js",
            .expected = "https://lightpanda.io/something5.js",
        },
        .{
            .base = "https://lightpanda.io",
            .path = "abc/something6.js",
            .expected = "https://lightpanda.io/abc/something6.js",
        },
        .{
            .base = "https://lightpanda.io/nested",
            .path = "abc/something7.js",
            .expected = "https://lightpanda.io/abc/something7.js",
        },
        .{
            .base = "https://lightpanda.io/nested/",
            .path = "abc/something8.js",
            .expected = "https://lightpanda.io/nested/abc/something8.js",
        },
        .{
            .base = "https://lightpanda.io/nested/",
            .path = "/abc/something9.js",
            .expected = "https://lightpanda.io/abc/something9.js",
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
        .{
            .path = "//static.lightpanda.io/hello.js",
            .base = "https://lightpanda.io/about/",
            .expected = "https://static.lightpanda.io/hello.js",
        },
    };

    for (cases) |case| {
        const result = try stitch(testing.arena_allocator, case.path, case.base, .{ .null_terminated = true });
        try testing.expectString(case.expected, result);
    }
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
