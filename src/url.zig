const std = @import("std");

const Allocator = std.mem.Allocator;
const WebApiURL = @import("browser/url/url.zig").URL;

const ada = @import("ada");

pub const stitch = URL.stitch;

pub const URL = struct {
    /// Internal ada structure.
    internal: ada.URL,

    pub const ParseError = ada.ParseError;

    /// Creates a new URL by parsing given `input`.
    /// `input` will be duped; so it can be freed after a call to this function.
    /// If `input` does not contain a scheme, `fallback_scheme` be used instead.
    /// `fallback_scheme` is `https` if not provided.
    pub fn parse(input: []const u8, fallback_scheme: ?[]const u8) ParseError!URL {
        // Try parsing directly; if it fails, we might have to provide a base.
        const internal = ada.parse(input) catch blk: {
            break :blk try ada.parseWithBase(fallback_scheme orelse "https", input);
        };

        return .{ .internal = internal };
    }

    pub fn parseWithBase(input: []const u8, base: []const u8) ParseError!URL {
        const internal = try ada.parseWithBase(input, base);
        return .{ .internal = internal };
    }

    /// Uses the same URL to parse in-place.
    /// Assumes `internal` is valid.
    pub fn reparse(self: URL, str: []const u8) ParseError!URL {
        std.debug.assert(self.internal != null);

        _ = ada.setHref(self.internal, str);
        if (!ada.isValid(self.internal)) {
            return error.Invalid;
        }

        return self;
    }

    /// Deinitializes internal url.
    pub fn deinit(self: URL) void {
        std.debug.assert(self.internal != null);
        ada.free(self.internal);
    }

    /// Returns true if `internal` is initialized.
    pub fn isValid(self: URL) bool {
        return ada.isValid(self.internal);
    }

    pub fn setHost(self: URL, host_str: []const u8) error{InvalidHost}!void {
        const is_set = ada.setHost(self.internal, host_str);
        if (!is_set) return error.InvalidHost;
    }

    pub fn setPort(self: URL, port_str: []const u8) error{InvalidPort}!void {
        const is_set = ada.setPort(self.internal, port_str);
        if (!is_set) return error.InvalidPort;
    }

    pub fn getPort(self: URL) []const u8 {
        const port = ada.getPortNullable(self.internal);
        return port.data[0..port.length];
    }

    /// Above, in `parse`, we error if a host doesn't exist
    /// In other words, we can't have a URL with a null host.
    pub fn host(self: URL) []const u8 {
        const str = ada.getHostNullable(self.internal);
        if (str.data == null) {
            return "";
        }

        return str.data[0..str.length];
    }

    pub fn getHref(self: URL) []const u8 {
        const href = ada.getHrefNullable(self.internal);
        if (href.data == null) {
            return "";
        }

        return href.data[0..href.length];
    }

    pub fn getHostname(self: URL) []const u8 {
        const hostname = ada.getHostnameNullable(self.internal);
        return hostname.data[0..hostname.length];
    }

    pub fn setHostname(self: URL, hostname_str: []const u8) error{InvalidHostname}!void {
        const is_set = ada.setHostname(self.internal, hostname_str);
        if (!is_set) return error.InvalidHostname;
    }

    pub fn getFragment(self: URL) ?[]const u8 {
        // Ada calls it "hash" instead of "fragment".
        const hash = ada.getHashNullable(self.internal);
        if (hash.data == null) return null;

        return hash.data[0..hash.length];
    }

    pub fn getProtocol(self: URL) []const u8 {
        return ada.getProtocol(self.internal);
    }

    pub fn setProtocol(self: URL, protocol_str: []const u8) error{InvalidProtocol}!void {
        const is_set = ada.setProtocol(self.internal, protocol_str);
        if (!is_set) return error.InvalidProtocol;
    }

    pub fn getScheme(self: URL) []const u8 {
        const proto = self.getProtocol();
        std.debug.assert(proto[proto.len - 1] == ':');

        return proto.ptr[0 .. proto.len - 1];
    }

    /// Returns the path.
    pub fn getPath(self: URL) []const u8 {
        const pathname = ada.getPathnameNullable(self.internal);
        // Return a slash if path is null.
        if (pathname.data == null) {
            return "/";
        }

        return pathname.data[0..pathname.length];
    }

    /// Returns true if the URL's protocol is secure.
    pub fn isSecure(self: URL) bool {
        const scheme = ada.getSchemeType(self.internal);
        return scheme == ada.Scheme.https or scheme == ada.Scheme.wss;
    }

    pub fn writeToStream(self: URL, writer: anytype) !void {
        return writer.writeAll(self.getHref());
    }

    /// Returns the origin string; caller owns the memory.
    pub fn getOrigin(self: URL, allocator: Allocator) ![]const u8 {
        const s = ada.getOriginNullable(self.internal);
        if (s.data == null) {
            return "";
        }
        defer ada.freeOwnedString(.{ .data = s.data, .length = s.length });

        return allocator.dupe(u8, s.data[0..s.length]);
    }

    // TODO: Skip unnecessary allocation by writing url parts directly to stream.
    pub fn origin(self: URL, writer: *std.Io.Writer) !void {
        // Ada manages its own memory for origin.
        // Here we write it to stream and free it afterwards.
        const s = ada.getOriginNullable(self.internal);
        if (s.data == null) {
            return;
        }
        defer ada.freeOwnedString(.{ .data = s.data, .length = s.length });

        return writer.writeAll(s.data[0..s.length]);
    }

    pub fn format(self: URL, writer: *std.Io.Writer) !void {
        return self.writeToStream(writer);
    }

    /// Converts `URL` to `WebApiURL`.
    pub fn toWebApi(self: URL, allocator: Allocator) !WebApiURL {
        return WebApiURL.constructFromInternal(allocator, self.internal);
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
