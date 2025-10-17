const std = @import("std");
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const URLSearchParams = @import("net/URLSearchParams.zig");

const Allocator = std.mem.Allocator;

const URL = @This();

_raw: [:0]const u8,
_arena: ?Allocator = null,
_search_params: ?*URLSearchParams = null,

// convenience
pub const resolve = @import("../URL.zig").resolve;

pub fn init(url: [:0]const u8, base_: ?[:0]const u8, page: *Page) !*URL {
    const url_is_absolute = @import("../URL.zig").isCompleteHTTPUrl(url);

    const base = if (base_) |b| blk: {
        // If URL is absolute, base is ignored (but we still use page.url internally)
        if (url_is_absolute) {
            break :blk page.url;
        }
        // For relative URLs, base must be a valid absolute URL
        if (!@import("../URL.zig").isCompleteHTTPUrl(b)) {
            return error.TypeError;
        }
        break :blk b;
    } else if (!url_is_absolute) {
        return error.TypeError;
    } else page.url;

    const arena = page.arena;
    const raw = try resolve(arena, base, url, .{ .always_dupe = true });

    return page._factory.create(URL{
        ._raw = raw,
        ._arena = arena,
    });
}

pub fn getUsername(self: *const URL) []const u8 {
    const user_info = self.getUserInfo() orelse return "";
    const pos = std.mem.indexOfScalarPos(u8, user_info, 0, ':') orelse return user_info;
    return user_info[0..pos];
}

pub fn getPassword(self: *const URL) []const u8 {
    const user_info = self.getUserInfo() orelse return "";
    const pos = std.mem.indexOfScalarPos(u8, user_info, 0, ':') orelse return "";
    return user_info[pos + 1 ..];
}

pub fn getPathname(self: *const URL) []const u8 {
    const raw = self._raw;
    const protocol_end = std.mem.indexOf(u8, raw, "://") orelse 0;
    const path_start = std.mem.indexOfScalarPos(u8, raw, if (protocol_end > 0) protocol_end + 3 else 0, '/') orelse raw.len;

    const query_or_hash_start = std.mem.indexOfAnyPos(u8, raw, path_start, "?#") orelse raw.len;

    if (path_start >= query_or_hash_start) {
        if (std.mem.indexOf(u8, raw, "://") != null) return "/";
        return "";
    }

    return raw[path_start..query_or_hash_start];
}

pub fn getProtocol(self: *const URL) []const u8 {
    const raw = self._raw;
    const pos = std.mem.indexOfScalarPos(u8, raw, 0, ':') orelse return "";
    return raw[0 .. pos + 1];
}

pub fn getHostname(self: *const URL) []const u8 {
    const host = self.getHost();
    const pos = std.mem.lastIndexOfScalar(u8, host, ':') orelse return host;
    return host[0..pos];
}

pub fn getPort(self: *const URL) []const u8 {
    const host = self.getHost();
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

pub fn getOrigin(self: *const URL, page: *const Page) ![]const u8 {
    const port = self.getPort();
    const protocol = self.getProtocol();
    const hostname = self.getHostname();

    const p = std.meta.stringToEnum(KnownProtocol, self.getProtocol()) orelse {
        // yes, a null string, that's what the spec wants
        return "null";
    };

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
        return std.fmt.allocPrint(page.call_arena, "{s}//{s}:{s}", .{ protocol, hostname, port });
    }
    return std.fmt.allocPrint(page.call_arena, "{s}//{s}", .{ protocol, hostname });
}

pub fn getSearch(self: *const URL) []const u8 {
    const raw = self._raw;
    const pos = std.mem.indexOfScalarPos(u8, raw, 0, '?') orelse return "";
    const query_part = raw[pos..];

    if (std.mem.indexOfScalarPos(u8, query_part, 0, '#')) |fragment_start| {
        return query_part[0..fragment_start];
    }

    return query_part;
}

pub fn getHash(self: *const URL) []const u8 {
    const raw = self._raw;
    const start = std.mem.indexOfScalarPos(u8, raw, 0, '#') orelse return "";
    return raw[start..];
}

pub fn getSearchParams(self: *URL, page: *Page) !*URLSearchParams {
    if (self._search_params) |sp| {
        return sp;
    }

    // Get current search string (without the '?')
    const search = self.getSearch();
    const search_value = if (search.len > 0) search[1..] else "";

    const params = try URLSearchParams.init(.{ .query_string = search_value }, page);
    self._search_params = params;
    return params;
}

pub fn toString(self: *const URL, page: *const Page) ![:0]const u8 {
    const sp = self._search_params orelse {
        return self._raw;
    };

    // Rebuild URL from searchParams
    const raw = self._raw;

    // Find the base (everything before ? or #)
    const base_end = std.mem.indexOfAnyPos(u8, raw, 0, "?#") orelse raw.len;
    const base = raw[0..base_end];

    // Get the hash if it exists
    const hash = self.getHash();

    // Build the new URL string
    var buf = std.Io.Writer.Allocating.init(page.call_arena);
    try buf.writer.writeAll(base);

    // Only add ? if there are params
    if (sp.getSize() > 0) {
        try buf.writer.writeByte('?');
        try sp.toString(&buf.writer);
    }

    try buf.writer.writeAll(hash);
    try buf.writer.writeByte(0);

    return buf.written()[0 .. buf.written().len - 1 :0];
}

fn getUserInfo(self: *const URL) ?[]const u8 {
    const raw = self._raw;
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

fn getHost(self: *const URL) []const u8 {
    const raw = self._raw;
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return "";

    var authority_start = scheme_end + 3;
    if (std.mem.indexOf(u8, raw[authority_start..], "@")) |pos| {
        authority_start += pos + 1;
    }

    const authority = raw[authority_start..];
    const path_start = std.mem.indexOfAny(u8, authority, "/?#") orelse return authority;
    return authority[0..path_start];
}

const KnownProtocol = enum {
    @"http:",
    @"https:",
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(URL);

    pub const Meta = struct {
        pub const name = "URL";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const constructor = bridge.constructor(URL.init, .{});
    pub const toString = bridge.function(URL.toString, .{});
    pub const toJSON = bridge.function(URL.toString, .{});
    pub const href = bridge.accessor(URL.toString, null, .{});
    pub const search = bridge.accessor(URL.getSearch, null, .{});
    pub const hash = bridge.accessor(URL.getHash, null, .{});
    pub const pathname = bridge.accessor(URL.getPathname, null, .{});
    pub const username = bridge.accessor(URL.getUsername, null, .{});
    pub const password = bridge.accessor(URL.getPassword, null, .{});
    pub const hostname = bridge.accessor(URL.getHostname, null, .{});
    pub const port = bridge.accessor(URL.getPort, null, .{});
    pub const origin = bridge.accessor(URL.getOrigin, null, .{});
    pub const protocol = bridge.accessor(URL.getProtocol, null, .{});
    pub const searchParams = bridge.accessor(URL.getSearchParams, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: URL" {
    try testing.htmlRunner("url.html", .{});
}
