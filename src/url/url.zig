const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

pub const Interfaces = generate.Tuple(.{
    URL,
    URLSearchParams,
});

// https://url.spec.whatwg.org/#url
//
// TODO we could avoid many of these getter string allocation in two differents
// way:
//
// 1. We can eventually get the slice of scheme *with* the following char in
// the underlying string. But I don't know if it's possible and how to do that.
// I mean, if the rawuri contains `https://foo.bar`, uri.scheme is a slice
// containing only `https`. I want `https:` so, in theory, I don't need to
// allocate data, I should be able to retrieve the scheme + the following `:`
// from rawuri.
//
// 2. The other way would bu to copy the `std.Uri` code to ahve a dedicated
// parser including the characters we want for the web API.
pub const URL = struct {
    rawuri: []const u8,
    uri: std.Uri,

    pub const mem_guarantied = true;

    pub fn constructor(alloc: std.mem.Allocator, url: []const u8, base: ?[]const u8) !URL {
        const raw = try std.mem.concat(alloc, u8, &[_][]const u8{ url, base orelse "" });
        errdefer alloc.free(raw);

        const uri = std.Uri.parse(raw) catch {
            return error.TypeError;
        };

        return .{
            .rawuri = raw,
            .uri = uri,
        };
    }

    pub fn deinit(self: *URL, alloc: std.mem.Allocator) void {
        alloc.free(self.rawuri);
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_href(self: URL, alloc: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        try self.uri.writeToStream(.{
            .scheme = true,
            .authentication = true,
            .authority = true,
            .path = true,
            .query = true,
            .fragment = true,
        }, buf.writer());
        return try buf.toOwnedSlice();
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_protocol(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        return try std.mem.concat(alloc, u8, &[_][]const u8{ self.uri.scheme, ":" });
    }

    pub fn get_username(self: *URL) []const u8 {
        return self.uri.user orelse "";
    }

    pub fn get_password(self: *URL) []const u8 {
        return self.uri.password orelse "";
    }

    pub fn get_host(self: *URL) []const u8 {
        return self.uri.host orelse "";
    }

    pub fn get_hostname(self: *URL) []const u8 {
        return self.uri.host orelse "";
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_port(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        if (self.uri.port == null) return try alloc.dupe(u8, "");

        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        try std.fmt.formatInt(self.uri.port.?, 10, .lower, .{}, buf.writer());
        return try buf.toOwnedSlice();
    }

    pub fn get_pathname(self: *URL) []const u8 {
        if (self.uri.path.len == 0) return "/";
        return self.uri.path;
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_search(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        if (self.uri.query == null) return try alloc.dupe(u8, "");

        return try std.mem.concat(alloc, u8, &[_][]const u8{ "?", self.uri.query.? });
    }

    // the caller must free the returned string.
    // TODO return a disposable string
    // https://github.com/lightpanda-io/jsruntime-lib/issues/195
    pub fn get_hash(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        if (self.uri.fragment == null) return try alloc.dupe(u8, "");

        return try std.mem.concat(alloc, u8, &[_][]const u8{ "#", self.uri.fragment.? });
    }

    pub fn _toJSON(self: *URL, alloc: std.mem.Allocator) ![]const u8 {
        return try self.get_href(alloc);
    }
};

// https://url.spec.whatwg.org/#interface-urlsearchparams
pub const URLSearchParams = struct {
    pub const mem_guarantied = true;
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var url = [_]Case{
        .{ .src = "var url = new URL('https://foo.bar/path?query#fragment')", .ex = "undefined" },
        .{ .src = "url.href", .ex = "https://foo.bar/path?query#fragment" },
        .{ .src = "url.protocol", .ex = "https:" },
        .{ .src = "url.username", .ex = "" },
        .{ .src = "url.password", .ex = "" },
        .{ .src = "url.host", .ex = "foo.bar" },
        .{ .src = "url.hostname", .ex = "foo.bar" },
        .{ .src = "url.port", .ex = "" },
        .{ .src = "url.pathname", .ex = "/path" },
        .{ .src = "url.search", .ex = "?query" },
        .{ .src = "url.hash", .ex = "#fragment" },
    };
    try checkCases(js_env, &url);
}
