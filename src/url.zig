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

    pub fn origin(self: *const URL, writer: anytype) !void {
        return self.uri.writeToStream(.{ .scheme = true, .authority = true }, writer);
    }

    pub fn resolve(self: *const URL, arena: Allocator, url: []const u8) !URL {
        var buf = try arena.alloc(u8, 4096);
        const new_uri = try self.uri.resolve_inplace(url, &buf);
        return fromURI(arena, &new_uri);
    }

    pub fn format(self: *const URL, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.writeAll(self.raw);
    }

    pub fn toWebApi(self: *const URL, allocator: Allocator) !WebApiURL {
        return WebApiURL.init(allocator, self.uri);
    }

    const StitchOpts = struct {
        alloc: AllocWhen = .always,

        const AllocWhen = enum {
            always,
            if_needed,
        };
    };

    /// Properly stitches two URL fragments together.
    ///
    /// For URLs with a path, it will replace the last entry with the src.
    /// For URLs without a path, it will add src as the path.
    pub fn stitch(
        allocator: Allocator,
        src: []const u8,
        base: []const u8,
        opts: StitchOpts,
    ) ![]const u8 {
        if (base.len == 0 or isURL(src)) {
            if (opts.alloc == .always) {
                return allocator.dupe(u8, src);
            }
            return src;
        }

        var normalized_src = src;
        while (std.mem.startsWith(u8, normalized_src, "./")) {
            normalized_src = normalized_src[2..];
        }

        if (normalized_src.len == 0) {
            if (opts.alloc == .always) {
                return allocator.dupe(u8, base);
            }
            return base;
        }

        const protocol_end: usize = blk: {
            if (std.mem.indexOf(u8, base, "://")) |protocol_index| {
                break :blk protocol_index + 3;
            } else {
                break :blk 0;
            }
        };

        if (normalized_src[0] == '/') {
            if (std.mem.indexOfScalarPos(u8, base, protocol_end, '/')) |pos| {
                return std.fmt.allocPrint(allocator, "{s}{s}", .{ base[0..pos], normalized_src });
            }
            // not sure what to do here...error? Just let it fallthrough for now.
        }

        if (std.mem.lastIndexOfScalar(u8, base[protocol_end..], '/')) |index| {
            const last_slash_pos = index + protocol_end;
            if (last_slash_pos == base.len - 1) {
                return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, normalized_src });
            }
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base[0..last_slash_pos], normalized_src });
        }
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, normalized_src });
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

fn isURL(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "://")) {
        return true;
    }

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
test "URL: isURL" {
    try testing.expectEqual(true, isURL("://lightpanda.io"));
    try testing.expectEqual(true, isURL("://lightpanda.io/about"));
    try testing.expectEqual(true, isURL("http://lightpanda.io/about"));
    try testing.expectEqual(true, isURL("HttP://lightpanda.io/about"));
    try testing.expectEqual(true, isURL("httpS://lightpanda.io/about"));
    try testing.expectEqual(true, isURL("HTTPs://lightpanda.io/about"));

    try testing.expectEqual(false, isURL("/lightpanda.io"));
    try testing.expectEqual(false, isURL("../../about"));
    try testing.expectEqual(false, isURL("about"));
}

test "URL: resolve size" {
    const base = "https://www.lightpande.io";
    const url = try URL.parse(base, null);

    var url_string: [511]u8 = undefined; // Currently this is the largest url we support, it is however recommmended to at least support 2000 characters
    @memset(&url_string, 'a');

    var buf: [8192]u8 = undefined; // This is approximately the required size to support the current largest supported URL
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const out_url = try url.resolve(fba.allocator(), &url_string);

    try std.testing.expectEqualStrings(out_url.raw[0..25], base);
    try std.testing.expectEqual(out_url.raw[25], '/');
    try std.testing.expectEqualStrings(out_url.raw[26..], &url_string);
}

test "URL: Stitching Base & Src URLs (Basic)" {
    const allocator = testing.allocator;

    const base = "https://lightpanda.io/xyz/abc/123";
    const src = "something.js";
    const result = try URL.stitch(allocator, src, base, .{});
    defer allocator.free(result);
    try testing.expectString("https://lightpanda.io/xyz/abc/something.js", result);
}

test "URL: Stitching Base & Src URLs (Just Ending Slash)" {
    const allocator = testing.allocator;

    const base = "https://lightpanda.io/";
    const src = "something.js";
    const result = try URL.stitch(allocator, src, base, .{});
    defer allocator.free(result);
    try testing.expectString("https://lightpanda.io/something.js", result);
}

test "URL: Stitching Base & Src URLs with leading slash" {
    const allocator = testing.allocator;

    const base = "https://lightpanda.io/";
    const src = "/something.js";
    const result = try URL.stitch(allocator, src, base, .{});
    defer allocator.free(result);
    try testing.expectString("https://lightpanda.io/something.js", result);
}

test "URL: Stitching Base & Src URLs (No Ending Slash)" {
    const allocator = testing.allocator;

    const base = "https://lightpanda.io";
    const src = "something.js";
    const result = try URL.stitch(allocator, src, base, .{});
    defer allocator.free(result);
    try testing.expectString("https://lightpanda.io/something.js", result);
}

test "URL: Stitching Base with absolute src" {
    const allocator = testing.allocator;

    const base = "https://lightpanda.io/hello";
    const src = "/abc/something.js";
    const result = try URL.stitch(allocator, src, base, .{});
    defer allocator.free(result);
    try testing.expectString("https://lightpanda.io/abc/something.js", result);
}

test "URL: Stiching Base & Src URLs (Both Local)" {
    const allocator = testing.allocator;

    const base = "./abcdef/123.js";
    const src = "something.js";
    const result = try URL.stitch(allocator, src, base, .{});
    defer allocator.free(result);
    try testing.expectString("./abcdef/something.js", result);
}

test "URL: Stiching src as full path" {
    const allocator = testing.allocator;

    const base = "https://www.lightpanda.io/";
    const src = "https://lightpanda.io/something.js";
    const result = try URL.stitch(allocator, src, base, .{ .alloc = .if_needed });
    try testing.expectString("https://lightpanda.io/something.js", result);
}

test "URL: Stitching Base & Src URLs (empty src)" {
    const allocator = testing.allocator;

    const base = "https://lightpanda.io/xyz/abc/123";
    const src = "";
    const result = try URL.stitch(allocator, src, base, .{});
    defer allocator.free(result);
    try testing.expectString("https://lightpanda.io/xyz/abc/123", result);
}

test "URL: Stitching dotslash" {
    const allocator = testing.allocator;

    const base = "https://lightpanda.io/hello/";
    const src = "./something.js";
    const result = try URL.stitch(allocator, src, base, .{});
    defer allocator.free(result);
    try testing.expectString("https://lightpanda.io/hello/something.js", result);
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
