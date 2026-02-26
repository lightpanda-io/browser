// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
    encode: bool = false,
    always_dupe: bool = false,
};

// path is anytype, so that it can be used with both []const u8 and [:0]const u8
pub fn resolve(allocator: Allocator, base: [:0]const u8, path: anytype, comptime opts: ResolveOpts) ![:0]const u8 {
    const PT = @TypeOf(path);
    if (base.len == 0 or isCompleteHTTPUrl(path)) {
        if (comptime opts.always_dupe or !isNullTerminated(PT)) {
            const duped = try allocator.dupeZ(u8, path);
            return encodeURL(allocator, duped, opts);
        }
        if (comptime opts.encode) {
            return encodeURL(allocator, path, opts);
        }
        return path;
    }

    if (path.len == 0) {
        if (comptime opts.always_dupe) {
            const duped = try allocator.dupeZ(u8, base);
            return encodeURL(allocator, duped, opts);
        }
        if (comptime opts.encode) {
            return encodeURL(allocator, base, opts);
        }
        return base;
    }

    if (path[0] == '?') {
        const base_path_end = std.mem.indexOfAny(u8, base, "?#") orelse base.len;
        const result = try std.mem.joinZ(allocator, "", &.{ base[0..base_path_end], path });
        return encodeURL(allocator, result, opts);
    }
    if (path[0] == '#') {
        const base_fragment_start = std.mem.indexOfScalar(u8, base, '#') orelse base.len;
        const result = try std.mem.joinZ(allocator, "", &.{ base[0..base_fragment_start], path });
        return encodeURL(allocator, result, opts);
    }

    if (std.mem.startsWith(u8, path, "//")) {
        // network-path reference
        const index = std.mem.indexOfScalar(u8, base, ':') orelse {
            if (comptime isNullTerminated(PT)) {
                if (comptime opts.encode) {
                    return encodeURL(allocator, path, opts);
                }
                return path;
            }
            const duped = try allocator.dupeZ(u8, path);
            return encodeURL(allocator, duped, opts);
        };
        const protocol = base[0 .. index + 1];
        const result = try std.mem.joinZ(allocator, "", &.{ protocol, path });
        return encodeURL(allocator, result, opts);
    }

    const scheme_end = std.mem.indexOf(u8, base, "://");
    const authority_start = if (scheme_end) |end| end + 3 else 0;
    const path_start = std.mem.indexOfScalarPos(u8, base, authority_start, '/') orelse base.len;

    if (path[0] == '/') {
        const result = try std.mem.joinZ(allocator, "", &.{ base[0..path_start], path });
        return encodeURL(allocator, result, opts);
    }

    var normalized_base: []const u8 = base[0..path_start];
    if (path_start < base.len) {
        if (std.mem.lastIndexOfScalar(u8, base[path_start + 1 ..], '/')) |pos| {
            normalized_base = base[0 .. path_start + 1 + pos];
        }
    }

    // trailing space so that we always have space to append the null terminator
    // and so that we can compare the next two characters without needing to length check
    var out = try std.mem.join(allocator, "", &.{ normalized_base, "/", path, "  " });
    const end = out.len - 2;

    const path_marker = path_start + 1;

    // Strip out ./ and ../. This is done in-place, because doing so can
    // only ever make `out` smaller. After this, `out` cannot be freed by
    // an allocator, which is ok, because we expect allocator to be an arena.
    var in_i: usize = 0;
    var out_i: usize = 0;
    while (in_i < end) {
        if (out[in_i] == '.' and (out_i == 0 or out[out_i - 1] == '/')) {
            if (out[in_i + 1] == '/') { // always safe, because we added a whitespace
                // /./
                in_i += 2;
                continue;
            }
            if (out[in_i + 1] == '.' and out[in_i + 2] == '/') { // always safe, because we added two whitespaces
                // /../
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
            if (in_i == end - 1) {
                // ignore trailing dot
                break;
            }
        }

        const c = out[in_i];
        out[out_i] = c;
        in_i += 1;
        out_i += 1;
    }

    // we always have an extra space
    out[out_i] = 0;
    return encodeURL(allocator, out[0..out_i :0], opts);
}

fn encodeURL(allocator: Allocator, url: [:0]const u8, comptime opts: ResolveOpts) ![:0]const u8 {
    if (!comptime opts.encode) {
        return url;
    }

    const scheme_end = std.mem.indexOf(u8, url, "://");
    const authority_start = if (scheme_end) |end| end + 3 else 0;
    const path_start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse return url;

    const query_start = std.mem.indexOfScalarPos(u8, url, path_start, '?');
    const fragment_start = std.mem.indexOfScalarPos(u8, url, query_start orelse path_start, '#');

    const path_end = query_start orelse fragment_start orelse url.len;
    const query_end = if (query_start) |_| (fragment_start orelse url.len) else path_end;

    const path_to_encode = url[path_start..path_end];
    const encoded_path = try percentEncodeSegment(allocator, path_to_encode, true);

    const encoded_query = if (query_start) |qs| blk: {
        const query_to_encode = url[qs + 1 .. query_end];
        const encoded = try percentEncodeSegment(allocator, query_to_encode, false);
        break :blk encoded;
    } else null;

    const encoded_fragment = if (fragment_start) |fs| blk: {
        const fragment_to_encode = url[fs + 1 ..];
        const encoded = try percentEncodeSegment(allocator, fragment_to_encode, false);
        break :blk encoded;
    } else null;

    if (encoded_path.ptr == path_to_encode.ptr and
        (encoded_query == null or encoded_query.?.ptr == url[query_start.? + 1 .. query_end].ptr) and
        (encoded_fragment == null or encoded_fragment.?.ptr == url[fragment_start.? + 1 ..].ptr))
    {
        // nothing has changed
        return url;
    }

    var buf = try std.ArrayList(u8).initCapacity(allocator, url.len + 20);
    try buf.appendSlice(allocator, url[0..path_start]);
    try buf.appendSlice(allocator, encoded_path);
    if (encoded_query) |eq| {
        try buf.append(allocator, '?');
        try buf.appendSlice(allocator, eq);
    }
    if (encoded_fragment) |ef| {
        try buf.append(allocator, '#');
        try buf.appendSlice(allocator, ef);
    }
    try buf.append(allocator, 0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

fn percentEncodeSegment(allocator: Allocator, segment: []const u8, comptime is_path: bool) ![]const u8 {
    // Check if encoding is needed
    var needs_encoding = false;
    for (segment) |c| {
        if (shouldPercentEncode(c, is_path)) {
            needs_encoding = true;
            break;
        }
    }
    if (!needs_encoding) {
        return segment;
    }

    var buf = try std.ArrayList(u8).initCapacity(allocator, segment.len + 10);

    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        const c = segment[i];

        // Check if this is an already-encoded sequence (%XX)
        if (c == '%' and i + 2 < segment.len) {
            const end = i + 2;
            const h1 = segment[i + 1];
            const h2 = segment[end];
            if (std.ascii.isHex(h1) and std.ascii.isHex(h2)) {
                try buf.appendSlice(allocator, segment[i .. end + 1]);
                i = end;
                continue;
            }
        }

        if (shouldPercentEncode(c, is_path)) {
            try buf.writer(allocator).print("%{X:0>2}", .{c});
        } else {
            try buf.append(allocator, c);
        }
    }

    return buf.items;
}

fn shouldPercentEncode(c: u8, comptime is_path: bool) bool {
    return switch (c) {
        // Unreserved characters (RFC 3986)
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => false,
        // sub-delims allowed in both path and query
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => false,
        // Separators allowed in both path and query
        '/', ':', '@' => false,
        // Query-specific: '?' is allowed in queries but not in paths
        '?' => comptime is_path,
        // Everything else needs encoding (including space)
        else => true,
    };
}

fn isNullTerminated(comptime value: type) bool {
    return @typeInfo(value).pointer.sentinel_ptr != null;
}

pub fn isCompleteHTTPUrl(url: []const u8) bool {
    if (url.len < 3) { // Minimum is "x://"
        return false;
    }

    // very common case
    if (url[0] == '/') {
        return false;
    }

    // Check if there's a scheme (protocol) ending with ://
    const colon_pos = std.mem.indexOfScalar(u8, url, ':') orelse return false;

    // Check if it's followed by //
    if (colon_pos + 2 >= url.len or url[colon_pos + 1] != '/' or url[colon_pos + 2] != '/') {
        return false;
    }

    // Validate that everything before the colon is a valid scheme
    // A scheme must start with a letter and contain only letters, digits, +, -, .
    if (colon_pos == 0) {
        return false;
    }

    const scheme = url[0..colon_pos];
    if (!std.ascii.isAlphabetic(scheme[0])) {
        return false;
    }

    for (scheme[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
            return false;
        }
    }

    return true;
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
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return null;

    // Only HTTP and HTTPS schemes have origins
    const protocol = raw[0 .. scheme_end + 1];
    if (!std.mem.eql(u8, protocol, "http:") and !std.mem.eql(u8, protocol, "https:")) {
        return null;
    }

    var authority_start = scheme_end + 3;
    const has_user_info = if (std.mem.indexOf(u8, raw[authority_start..], "@")) |pos| blk: {
        authority_start += pos + 1;
        break :blk true;
    } else false;

    // Find end of authority (start of path/query/fragment or end of string)
    const authority_end_relative = std.mem.indexOfAny(u8, raw[authority_start..], "/?#");
    const authority_end = if (authority_end_relative) |end|
        authority_start + end
    else
        raw.len;

    // Check for port in the host:port section
    const host_part = raw[authority_start..authority_end];
    if (std.mem.lastIndexOfScalar(u8, host_part, ':')) |colon_pos_in_host| {
        const port = host_part[colon_pos_in_host + 1 ..];

        // Validate it's actually a port (all digits)
        for (port) |c| {
            if (c < '0' or c > '9') {
                // Not a port (probably IPv6)
                if (has_user_info) {
                    // Need to allocate to exclude user info
                    return try std.fmt.allocPrint(allocator, "{s}//{s}", .{ raw[0 .. scheme_end + 1], host_part });
                }
                // Can return a slice
                return raw[0..authority_end];
            }
        }

        // Check if it's a default port that should be excluded from origin
        const is_default =
            (std.mem.eql(u8, protocol, "http:") and std.mem.eql(u8, port, "80")) or
            (std.mem.eql(u8, protocol, "https:") and std.mem.eql(u8, port, "443"));

        if (is_default or has_user_info) {
            // Need to allocate to build origin without default port and/or user info
            const hostname = host_part[0..colon_pos_in_host];
            if (is_default) {
                return try std.fmt.allocPrint(allocator, "{s}//{s}", .{ protocol, hostname });
            } else {
                return try std.fmt.allocPrint(allocator, "{s}//{s}", .{ protocol, host_part });
            }
        }
    } else if (has_user_info) {
        // No port, but has user info - need to allocate
        return try std.fmt.allocPrint(allocator, "{s}//{s}", .{ raw[0 .. scheme_end + 1], host_part });
    }

    // Common case: no user info, no default port - return slice (zero allocation!)
    return raw[0..authority_end];
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
    // First '#' signifies the start of the fragment.
    const first_hash_index = std.mem.indexOfScalar(u8, first, '#') orelse first.len;
    const second_hash_index = std.mem.indexOfScalar(u8, second, '#') orelse second.len;
    return std.mem.eql(u8, first[0..first_hash_index], second[0..second_hash_index]);
}

// Helper function to build a URL from components
pub fn buildUrl(
    allocator: Allocator,
    protocol: []const u8,
    host: []const u8,
    pathname: []const u8,
    search: []const u8,
    hash: []const u8,
) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}//{s}{s}{s}{s}", .{
        protocol,
        host,
        pathname,
        search,
        hash,
    }, 0);
}

pub fn setProtocol(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const host = getHost(current);
    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);

    // Add : suffix if not present
    const protocol = if (value.len > 0 and value[value.len - 1] != ':')
        try std.fmt.allocPrint(allocator, "{s}:", .{value})
    else
        value;

    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setHost(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);

    // Check if the host includes a port
    const colon_pos = std.mem.lastIndexOfScalar(u8, value, ':');
    const clean_host = if (colon_pos) |pos| blk: {
        const port_str = value[pos + 1 ..];
        // Remove default ports
        if (std.mem.eql(u8, protocol, "https:") and std.mem.eql(u8, port_str, "443")) {
            break :blk value[0..pos];
        }
        if (std.mem.eql(u8, protocol, "http:") and std.mem.eql(u8, port_str, "80")) {
            break :blk value[0..pos];
        }
        break :blk value;
    } else value;

    return buildUrl(allocator, protocol, clean_host, pathname, search, hash);
}

pub fn setHostname(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const current_port = getPort(current);
    const new_host = if (current_port.len > 0)
        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ value, current_port })
    else
        value;

    return setHost(current, new_host, allocator);
}

pub fn setPort(current: [:0]const u8, value: ?[]const u8, allocator: Allocator) ![:0]const u8 {
    const hostname = getHostname(current);
    const protocol = getProtocol(current);

    // Handle null or default ports
    const new_host = if (value) |port_str| blk: {
        if (port_str.len == 0) {
            break :blk hostname;
        }
        // Check if this is a default port for the protocol
        if (std.mem.eql(u8, protocol, "https:") and std.mem.eql(u8, port_str, "443")) {
            break :blk hostname;
        }
        if (std.mem.eql(u8, protocol, "http:") and std.mem.eql(u8, port_str, "80")) {
            break :blk hostname;
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}:{s}", .{ hostname, port_str });
    } else hostname;

    return setHost(current, new_host, allocator);
}

pub fn setPathname(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const host = getHost(current);
    const search = getSearch(current);
    const hash = getHash(current);

    // Add / prefix if not present and value is not empty
    const pathname = if (value.len > 0 and value[0] != '/')
        try std.fmt.allocPrint(allocator, "/{s}", .{value})
    else
        value;

    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setSearch(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const host = getHost(current);
    const pathname = getPathname(current);
    const hash = getHash(current);

    // Add ? prefix if not present and value is not empty
    const search = if (value.len > 0 and value[0] != '?')
        try std.fmt.allocPrint(allocator, "?{s}", .{value})
    else
        value;

    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setHash(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const host = getHost(current);
    const pathname = getPathname(current);
    const search = getSearch(current);

    // Add # prefix if not present and value is not empty
    const hash = if (value.len > 0 and value[0] != '#')
        try std.fmt.allocPrint(allocator, "#{s}", .{value})
    else
        value;

    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn concatQueryString(arena: Allocator, url: []const u8, query_string: []const u8) ![:0]const u8 {
    if (query_string.len == 0) {
        return arena.dupeZ(u8, url);
    }

    var buf: std.ArrayList(u8) = .empty;

    // the most space well need is the url + ('?' or '&') + the query_string + null terminator
    try buf.ensureTotalCapacity(arena, url.len + 2 + query_string.len);
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
    buf.appendAssumeCapacity(0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

pub fn getRobotsUrl(arena: Allocator, url: [:0]const u8) ![:0]const u8 {
    const origin = try getOrigin(arena, url) orelse return error.NoOrigin;
    return try std.fmt.allocPrintSentinel(
        arena,
        "{s}/robots.txt",
        .{origin},
        0,
    );
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

test "URL: resolve regression (#1093)" {
    defer testing.reset();

    const Case = struct {
        base: [:0]const u8,
        path: [:0]const u8,
        expected: [:0]const u8,
    };

    const cases = [_]Case{
        .{
            .base = "https://alas.aws.amazon.com/alas2.html",
            .path = "../static/bootstrap.min.css",
            .expected = "https://alas.aws.amazon.com/static/bootstrap.min.css",
        },
    };

    for (cases) |case| {
        const result = try resolve(testing.arena_allocator, case.base, case.path, .{});
        try testing.expectString(case.expected, result);
    }
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
            .base = "https://example/dir",
            .path = "abc../test",
            .expected = "https://example/abc../test",
        },
        .{
            .base = "https://example/dir",
            .path = "abc.",
            .expected = "https://example/abc.",
        },
        .{
            .base = "https://example/dir",
            .path = "abc/.",
            .expected = "https://example/abc/",
        },
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

test "URL: resolve with encoding" {
    defer testing.reset();

    const Case = struct {
        base: [:0]const u8,
        path: [:0]const u8,
        expected: [:0]const u8,
    };

    const cases = [_]Case{
        // Spaces should be encoded as %20, but ! is allowed
        .{
            .base = "https://example.com/dir/",
            .path = "over 9000!",
            .expected = "https://example.com/dir/over%209000!",
        },
        .{
            .base = "https://example.com/",
            .path = "hello world.html",
            .expected = "https://example.com/hello%20world.html",
        },
        // Multiple spaces
        .{
            .base = "https://example.com/",
            .path = "path with  multiple   spaces",
            .expected = "https://example.com/path%20with%20%20multiple%20%20%20spaces",
        },
        // Special characters that need encoding
        .{
            .base = "https://example.com/",
            .path = "file[1].html",
            .expected = "https://example.com/file%5B1%5D.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file{name}.html",
            .expected = "https://example.com/file%7Bname%7D.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file<test>.html",
            .expected = "https://example.com/file%3Ctest%3E.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file\"quote\".html",
            .expected = "https://example.com/file%22quote%22.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file|pipe.html",
            .expected = "https://example.com/file%7Cpipe.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file\\backslash.html",
            .expected = "https://example.com/file%5Cbackslash.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file^caret.html",
            .expected = "https://example.com/file%5Ecaret.html",
        },
        .{
            .base = "https://example.com/",
            .path = "file`backtick`.html",
            .expected = "https://example.com/file%60backtick%60.html",
        },
        // Characters that should NOT be encoded
        .{
            .base = "https://example.com/",
            .path = "path-with_under~tilde.html",
            .expected = "https://example.com/path-with_under~tilde.html",
        },
        .{
            .base = "https://example.com/",
            .path = "path/with/slashes",
            .expected = "https://example.com/path/with/slashes",
        },
        .{
            .base = "https://example.com/",
            .path = "sub-delims!$&'()*+,;=.html",
            .expected = "https://example.com/sub-delims!$&'()*+,;=.html",
        },
        // Already encoded characters should not be double-encoded
        .{
            .base = "https://example.com/",
            .path = "already%20encoded",
            .expected = "https://example.com/already%20encoded",
        },
        .{
            .base = "https://example.com/",
            .path = "file%5B1%5D.html",
            .expected = "https://example.com/file%5B1%5D.html",
        },
        // Mix of encoded and unencoded
        .{
            .base = "https://example.com/",
            .path = "part%20encoded and not",
            .expected = "https://example.com/part%20encoded%20and%20not",
        },
        // Query strings and fragments ARE encoded
        .{
            .base = "https://example.com/",
            .path = "file name.html?query=value with spaces",
            .expected = "https://example.com/file%20name.html?query=value%20with%20spaces",
        },
        .{
            .base = "https://example.com/",
            .path = "file name.html#anchor with spaces",
            .expected = "https://example.com/file%20name.html#anchor%20with%20spaces",
        },
        .{
            .base = "https://example.com/",
            .path = "file.html?hello=world !",
            .expected = "https://example.com/file.html?hello=world%20!",
        },
        // Query structural characters should NOT be encoded
        .{
            .base = "https://example.com/",
            .path = "file.html?a=1&b=2",
            .expected = "https://example.com/file.html?a=1&b=2",
        },
        // Relative paths with encoding
        .{
            .base = "https://example.com/dir/page.html",
            .path = "../other dir/file.html",
            .expected = "https://example.com/other%20dir/file.html",
        },
        .{
            .base = "https://example.com/dir/",
            .path = "./sub dir/file.html",
            .expected = "https://example.com/dir/sub%20dir/file.html",
        },
        // Absolute paths with encoding
        .{
            .base = "https://example.com/some/path",
            .path = "/absolute path/file.html",
            .expected = "https://example.com/absolute%20path/file.html",
        },
        // Unicode/high bytes (though ideally these should be UTF-8 encoded first)
        .{
            .base = "https://example.com/",
            .path = "café",
            .expected = "https://example.com/caf%C3%A9",
        },
        // Empty path
        .{
            .base = "https://example.com/",
            .path = "",
            .expected = "https://example.com/",
        },
        // Complete URL as path (should not be encoded)
        .{
            .base = "https://example.com/",
            .path = "https://other.com/path with spaces",
            .expected = "https://other.com/path%20with%20spaces",
        },
    };

    for (cases) |case| {
        const result = try resolve(testing.arena_allocator, case.base, case.path, .{ .encode = true });
        try testing.expectString(case.expected, result);
    }
}

test "URL: eqlDocument" {
    defer testing.reset();
    {
        const url = "https://lightpanda.io/about";
        try testing.expectEqual(true, eqlDocument(url, url));
    }
    {
        const url1 = "https://lightpanda.io/about";
        const url2 = "http://lightpanda.io/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io/about";
        const url2 = "https://example.com/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io:8080/about";
        const url2 = "https://lightpanda.io:9090/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io/about";
        const url2 = "https://lightpanda.io/contact";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io/about?foo=bar";
        const url2 = "https://lightpanda.io/about?baz=qux";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io/about#section1";
        const url2 = "https://lightpanda.io/about#section2";
        try testing.expectEqual(true, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io/about";
        const url2 = "https://lightpanda.io/about/";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io/about?foo=bar";
        const url2 = "https://lightpanda.io/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io/about";
        const url2 = "https://lightpanda.io/about?foo=bar";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io/about?foo=bar";
        const url2 = "https://lightpanda.io/about?foo=bar";
        try testing.expectEqual(true, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://lightpanda.io/about?";
        const url2 = "https://lightpanda.io/about";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
    {
        const url1 = "https://duckduckgo.com/";
        const url2 = "https://duckduckgo.com/?q=lightpanda";
        try testing.expectEqual(false, eqlDocument(url1, url2));
    }
}

test "URL: concatQueryString" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    {
        const url = try concatQueryString(arena, "https://www.lightpanda.io/", "");
        try testing.expectEqual("https://www.lightpanda.io/", url);
    }

    {
        const url = try concatQueryString(arena, "https://www.lightpanda.io/index?", "");
        try testing.expectEqual("https://www.lightpanda.io/index?", url);
    }

    {
        const url = try concatQueryString(arena, "https://www.lightpanda.io/index?", "a=b");
        try testing.expectEqual("https://www.lightpanda.io/index?a=b", url);
    }

    {
        const url = try concatQueryString(arena, "https://www.lightpanda.io/index?1=2", "a=b");
        try testing.expectEqual("https://www.lightpanda.io/index?1=2&a=b", url);
    }

    {
        const url = try concatQueryString(arena, "https://www.lightpanda.io/index?1=2&", "a=b");
        try testing.expectEqual("https://www.lightpanda.io/index?1=2&a=b", url);
    }
}

test "URL: getRobotsUrl" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    {
        const url = try getRobotsUrl(arena, "https://www.lightpanda.io");
        try testing.expectEqual("https://www.lightpanda.io/robots.txt", url);
    }

    {
        const url = try getRobotsUrl(arena, "https://www.lightpanda.io/some/path");
        try testing.expectString("https://www.lightpanda.io/robots.txt", url);
    }

    {
        const url = try getRobotsUrl(arena, "https://www.lightpanda.io:8080/page");
        try testing.expectString("https://www.lightpanda.io:8080/robots.txt", url);
    }
    {
        const url = try getRobotsUrl(arena, "http://example.com/deep/nested/path?query=value#fragment");
        try testing.expectString("http://example.com/robots.txt", url);
    }
    {
        const url = try getRobotsUrl(arena, "https://user:pass@example.com/page");
        try testing.expectString("https://example.com/robots.txt", url);
    }
}
