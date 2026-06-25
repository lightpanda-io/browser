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

const U = @import("../sys/url.zig");

const Allocator = std.mem.Allocator;

pub const ResolveOptions = struct {
    /// null = don't encode, "UTF-8" = standard percent encoding,
    /// other charset = encode query string using that charset with NCR fallback.
    encoding: ?[]const u8 = null,
};

pub fn resolve(
    allocator: Allocator,
    base: [:0]const u8,
    source_path: anytype,
    options: ResolveOptions,
) ![:0]const u8 {
    const path = source_path;

    var err: i32 = 0;
    const href = if (options.encoding) |encoding|
        U.url_resolve_with_encoding(base.ptr, base.len, path.ptr, path.len, encoding.ptr, encoding.len, &err)
    else
        U.url_resolve_without_encoding(base.ptr, base.len, path.ptr, path.len, &err);

    if (err != 0) {
        return error.TypeError;
    }
    defer href.deinit();

    return allocator.dupeZ(u8, href.slice());
}

/// Resolves a user-provided "address bar" URL the way curl does. Bare host like
/// `lightpanda.io` has no scheme, so it can't be parsed as an absolute URL.
pub fn resolveNavigation(allocator: Allocator, url: []const u8, options: ResolveOptions) ![:0]const u8 {
    return resolve(allocator, "", url, options) catch |err| switch (err) {
        error.TypeError => {
            const with_scheme = try std.fmt.allocPrintSentinel(allocator, "http://{s}", .{url}, 0);
            return resolve(allocator, "", with_scheme, options);
        },
        else => return err,
    };
}

const EncodeSet = enum { path, query, query_legacy, userinfo, fragment, component };

pub fn percentEncodeSegment(allocator: Allocator, segment: []const u8, comptime encode_set: EncodeSet) ![]const u8 {
    // Check if encoding is needed
    var needs_encoding = false;
    for (segment) |c| {
        if (shouldPercentEncode(c, encode_set)) {
            needs_encoding = true;
            break;
        }
    }
    if (!needs_encoding) {
        // Always dupe — the signature returns owned bytes, so a caller doing
        // `defer allocator.free(out)` mustn't crash on the no-op path.
        return allocator.dupe(u8, segment);
    }

    var buf = try std.ArrayList(u8).initCapacity(allocator, segment.len + 10);

    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        const c = segment[i];

        // For URL-canonicalization sets, preserve existing %XX sequences so
        // already-encoded inputs round-trip cleanly. The `component` set treats
        // input as opaque and re-encodes `%` itself, since the caller is
        // embedding raw user data and a literal '%' must not be misread.
        if (encode_set != .component and c == '%' and i + 2 < segment.len) {
            const end = i + 2;
            const h1 = segment[i + 1];
            const h2 = segment[end];
            if (std.ascii.isHex(h1) and std.ascii.isHex(h2)) {
                try buf.appendSlice(allocator, segment[i .. end + 1]);
                i = end;
                continue;
            }
        }

        if (shouldPercentEncode(c, encode_set)) {
            try buf.writer(allocator).print("%{X:0>2}", .{c});
        } else {
            try buf.append(allocator, c);
        }
    }

    return buf.items;
}

fn shouldPercentEncode(c: u8, comptime encode_set: EncodeSet) bool {
    return switch (c) {
        // Unreserved characters (RFC 3986)
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => false,
        // sub-delims allowed in path/query but some must be encoded in userinfo/query_legacy/component
        '!', '$', '\'', '(', ')', '*', '+', ',' => encode_set == .component,
        // '&' and ';' must be encoded for legacy encoding (to preserve NCRs like &#nnnnn;)
        // and for component encoding (so a value can't break out into a new param)
        '&', ';' => encode_set == .userinfo or encode_set == .query_legacy or encode_set == .component,
        '=' => encode_set == .userinfo or encode_set == .component,
        // Separators: userinfo and component must encode these
        '/', ':', '@' => encode_set == .userinfo or encode_set == .component,
        // '?' is allowed in queries only
        '?' => encode_set != .query and encode_set != .query_legacy,
        // '#' is allowed in fragments only
        '#' => encode_set != .fragment,
        // Everything else needs encoding (including space)
        else => true,
    };
}

pub fn isCompleteHTTPUrl(url: []const u8) bool {
    if (url.len < 3) { // Minimum is "x://"
        return false;
    }

    // very common case
    if (url[0] == '/') {
        return false;
    }

    // blob: and data: URLs are complete but don't follow scheme:// pattern
    if (std.mem.startsWith(u8, url, "blob:") or std.mem.startsWith(u8, url, "data:")) {
        return true;
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
    const protocol_end = std.mem.indexOf(u8, raw, "://");

    // Handle scheme:path URLs like about:blank (no "://")
    if (protocol_end == null) {
        const colon_pos = std.mem.indexOfScalar(u8, raw, ':') orelse return "";
        const path = raw[colon_pos + 1 ..];
        const query_or_hash = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
        return path[0..query_or_hash];
    }

    const path_start = std.mem.indexOfScalarPos(u8, raw, protocol_end.? + 3, '/') orelse raw.len;

    const query_or_hash_start = std.mem.indexOfAnyPos(u8, raw, path_start, "?#") orelse raw.len;

    if (path_start >= query_or_hash_start) {
        return "/";
    }

    return raw[path_start..query_or_hash_start];
}

pub fn getProtocol(raw: [:0]const u8) []const u8 {
    const pos = std.mem.indexOfScalarPos(u8, raw, 0, ':') orelse return "";
    return raw[0 .. pos + 1];
}

pub fn isSecure(raw: [:0]const u8) bool {
    return std.mem.startsWith(u8, raw, "https:") or std.mem.startsWith(u8, raw, "wss:");
}

pub fn getHostname(raw: [:0]const u8) []const u8 {
    const host = getHost(raw);
    const port_sep = findPortSeparator(host) orelse return host;
    return host[0..port_sep];
}

// Like getHostname, but for an origin serialization ("scheme://host[:port]"),
// which is not necessarily sentinel-terminated. Used where the document's host
// must come from its (possibly inherited) origin rather than its URL — e.g. an
// about:blank iframe whose url stays "about:blank" but whose origin is the
// parent's.
pub fn getOriginHostname(origin: []const u8) []const u8 {
    const host = getHost(origin);
    const port_sep = findPortSeparator(host) orelse return host;
    return host[0..port_sep];
}

pub fn getPort(raw: [:0]const u8) []const u8 {
    const host = getHost(raw);
    const port_sep = findPortSeparator(host) orelse return "";
    return host[port_sep + 1 ..];
}

// Finds the colon separating host from port, handling IPv6 bracket notation.
// For IPv6 like "[::1]:8080", returns position of ":" after "]".
// For IPv6 like "[::1]" (no port), returns null.
// For regular hosts, returns position of last ":" if followed by digits.
fn findPortSeparator(host: []const u8) ?usize {
    if (host.len > 0 and host[0] == '[') {
        // IPv6: find closing bracket, port separator must be after it
        const bracket_end = std.mem.indexOfScalar(u8, host, ']') orelse return null;
        if (bracket_end + 1 < host.len and host[bracket_end + 1] == ':') {
            return bracket_end + 1;
        }
        return null;
    }

    // Regular host: find last colon and verify it's followed by digits
    const pos = std.mem.lastIndexOfScalar(u8, host, ':') orelse return null;
    if (pos + 1 >= host.len) return null;

    for (host[pos + 1 ..]) |c| {
        if (c < '0' or c > '9') return null;
    }
    return pos;
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

    const auth = parseAuthority(raw) orelse return null;
    const has_user_info = auth.has_user_info;
    const authority_end = auth.host_end;

    // Check for port in the host:port section
    const host_part = auth.getHost(raw);
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
    const auth = parseAuthority(raw) orelse return null;
    if (!auth.has_user_info) return null;

    // User info is from authority_start to host_start - 1 (excluding the @)
    const scheme_end = std.mem.indexOf(u8, raw, "://").?;
    const authority_start = scheme_end + 3;
    return raw[authority_start .. auth.host_start - 1];
}

pub fn getHost(raw: []const u8) []const u8 {
    const auth = parseAuthority(raw) orelse return "";
    return auth.getHost(raw);
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

    // Check if the new value includes a port
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
    } else blk: {
        // No port in new value - preserve existing port
        const current_port = getPort(current);
        if (current_port.len > 0) {
            break :blk try std.fmt.allocPrint(allocator, "{s}:{s}", .{ value, current_port });
        }
        break :blk value;
    };

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
    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);

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

    return buildUrl(allocator, protocol, new_host, pathname, search, hash);
}

pub fn setPathname(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const host = getHost(current);
    const search = getSearch(current);
    const hash = getHash(current);

    const encoded = try percentEncodeSegment(allocator, value, .path);

    // Add / prefix if not present and value is not empty
    const pathname = if (encoded.len > 0 and encoded[0] != '/')
        try std.fmt.allocPrint(allocator, "/{s}", .{encoded})
    else
        encoded;

    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setSearch(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const host = getHost(current);
    const pathname = getPathname(current);
    const hash = getHash(current);

    const encoded = try percentEncodeSegment(allocator, value, .query);

    // Add ? prefix if not present and value is not empty
    const search = if (encoded.len > 0 and value[0] != '?')
        try std.fmt.allocPrint(allocator, "?{s}", .{encoded})
    else
        encoded;

    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setHash(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const host = getHost(current);
    const pathname = getPathname(current);
    const search = getSearch(current);

    const encoded = try percentEncodeSegment(allocator, value, .fragment);

    // Add # prefix if not present and value is not empty
    const hash = if (encoded.len > 0 and encoded[0] != '#')
        try std.fmt.allocPrint(allocator, "#{s}", .{encoded})
    else
        encoded;

    return buildUrl(allocator, protocol, host, pathname, search, hash);
}

pub fn setUsername(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const host = getHost(current);
    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);
    const password = getPassword(current);

    const encoded_username = try percentEncodeSegment(allocator, value, .userinfo);
    return buildUrlWithUserInfo(allocator, protocol, encoded_username, password, host, pathname, search, hash);
}

pub fn setPassword(current: [:0]const u8, value: []const u8, allocator: Allocator) ![:0]const u8 {
    const protocol = getProtocol(current);
    const host = getHost(current);
    const pathname = getPathname(current);
    const search = getSearch(current);
    const hash = getHash(current);
    const username = getUsername(current);

    const encoded_password = try percentEncodeSegment(allocator, value, .userinfo);
    return buildUrlWithUserInfo(allocator, protocol, username, encoded_password, host, pathname, search, hash);
}

fn buildUrlWithUserInfo(
    allocator: Allocator,
    protocol: []const u8,
    username: []const u8,
    password: []const u8,
    host: []const u8,
    pathname: []const u8,
    search: []const u8,
    hash: []const u8,
) ![:0]const u8 {
    if (username.len == 0 and password.len == 0) {
        return buildUrl(allocator, protocol, host, pathname, search, hash);
    } else if (password.len == 0) {
        return std.fmt.allocPrintSentinel(allocator, "{s}//{s}@{s}{s}{s}{s}", .{
            protocol,
            username,
            host,
            pathname,
            search,
            hash,
        }, 0);
    } else {
        return std.fmt.allocPrintSentinel(allocator, "{s}//{s}:{s}@{s}{s}{s}{s}", .{
            protocol,
            username,
            password,
            host,
            pathname,
            search,
            hash,
        }, 0);
    }
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

pub fn unescape(arena: Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '%') == null) {
        return input;
    }

    var result = try std.ArrayList(u8).initCapacity(arena, input.len);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch {
                result.appendAssumeCapacity(input[i]);
                i += 1;
                continue;
            };
            result.appendAssumeCapacity(byte);
            i += 3;
        } else {
            result.appendAssumeCapacity(input[i]);
            i += 1;
        }
    }

    return result.items;
}

const AuthorityInfo = struct {
    host_start: usize,
    host_end: usize,
    has_user_info: bool,

    fn getHost(self: AuthorityInfo, raw: []const u8) []const u8 {
        return raw[self.host_start..self.host_end];
    }
};

// Parses the authority component of a URL, correctly handling userinfo.
// Returns null if the URL doesn't have a valid scheme (no "://").
// SECURITY: Only looks for @ within the authority portion (before /?#)
// to prevent path-based @ injection attacks.
fn parseAuthority(raw: []const u8) ?AuthorityInfo {
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return null;
    const authority_start = scheme_end + 3;

    // Find end of authority FIRST (start of path/query/fragment,
    // a NUL/CR/LF/TAB, or end of string).
    const authority_end = if (std.mem.indexOfAny(u8, raw[authority_start..], "/?#\x00\r\n\t")) |end|
        authority_start + end
    else
        raw.len;

    // Only look for @ within the authority portion, not in path/query/fragment
    const authority_portion = raw[authority_start..authority_end];
    if (std.mem.indexOf(u8, authority_portion, "@")) |pos| {
        return .{
            .host_start = authority_start + pos + 1,
            .host_end = authority_end,
            .has_user_info = true,
        };
    }

    return .{
        .host_start = authority_start,
        .host_end = authority_end,
        .has_user_info = false,
    };
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
        expected_error: bool = false,
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
            .base = "http://127.0.0.1:8123/#/login",
            .path = "api/users/login",
            .expected = "http://127.0.0.1:8123/api/users/login",
        },
        .{
            .base = "https://example/app/page?next=/foo/bar",
            .path = "api/users/login",
            .expected = "https://example/app/api/users/login",
        },
        .{
            .base = "https://example/app/page#/foo/bar",
            .path = "api/users/login",
            .expected = "https://example/app/api/users/login",
        },
        .{
            .base = "https://example?next=/foo/bar",
            .path = "api/users/login",
            .expected = "https://example/api/users/login",
        },
        .{
            .base = "https://example#/foo/bar",
            .path = "api/users/login",
            .expected = "https://example/api/users/login",
        },
        .{
            .base = "https://example?next=/foo/bar",
            .path = "/api/users/login",
            .expected = "https://example/api/users/login",
        },
        .{
            .base = "https://example/app/page?next=/foo/bar",
            .path = "../api/users/login",
            .expected = "https://example/api/users/login",
        },
        .{
            .base = "https://example/app/page#/foo/bar",
            .path = "../api/users/login",
            .expected = "https://example/api/users/login",
        },
        .{
            .base = "https://example/app/dir/?next=/foo/bar",
            .path = "../api/users/login",
            .expected = "https://example/app/api/users/login",
        },
        .{
            .base = "https://example/app/dir/#/foo/bar",
            .path = "../api/users/login",
            .expected = "https://example/app/api/users/login",
        },
        .{
            .base = "https://example/app/page?next=/foo/bar",
            .path = "?q=/api/users/login",
            .expected = "https://example/app/page?q=/api/users/login",
        },
        .{
            .base = "https://example/app/page#/foo/bar",
            .path = "#/api/users/login",
            .expected = "https://example/app/page#/api/users/login",
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
        // A base must itself be a valid absolute URL; schemeless bases are
        // rejected, matching `new URL(path, base)`.
        .{
            .base = "some/page",
            .path = "hello",
            .expected = "",
            .expected_error = true,
        },
        .{
            .base = "some/page/",
            .path = "hello",
            .expected = "",
            .expected_error = true,
        },
        .{
            .base = "some/page/other",
            .path = ".././hello",
            .expected = "",
            .expected_error = true,
        },
        .{
            .base = "https://www.example.com/hello/world",
            .path = "//example/about",
            .expected = "https://example/about",
        },
        // "http:" alone is not a valid base (special scheme without a host).
        .{
            .base = "http:",
            .path = "//example.com/over/9000",
            .expected = "",
            .expected_error = true,
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
        .{
            .base = "https://example.com/a/b/c/",
            .path = "..",
            .expected = "https://example.com/a/b/",
        },
        .{
            .base = "https://example.com/a/b/c",
            .path = "..",
            .expected = "https://example.com/a/",
        },
        .{
            .base = "https://example.com/js/app.mjs",
            .path = "/test/..",
            .expected = "https://example.com/",
        },
        .{
            .base = "https://example.com/js/app.mjs",
            .path = "/a/b/../c",
            .expected = "https://example.com/a/c",
        },
        .{
            .base = "https://example.com/js/app.mjs",
            .path = "/../../foo/bar",
            .expected = "https://example.com/foo/bar",
        },
        .{
            .base = "https://example.com/js/app.mjs",
            .path = "/../foo/../bar",
            .expected = "https://example.com/bar",
        },
    };

    for (cases) |case| {
        if (case.expected_error) {
            const result = resolve(testing.arena_allocator, case.base, case.path, .{});
            try testing.expectError(error.TypeError, result);
        } else {
            const result = try resolve(testing.arena_allocator, case.base, case.path, .{});
            try testing.expectString(case.expected, result);
        }
    }
}

test "URL: resolve strips tab and newline from input" {
    defer testing.reset();

    const Case = struct {
        base: [:0]const u8,
        path: [:0]const u8,
        expected: [:0]const u8,
    };

    const cases = [_]Case{
        // Control char inside the host of an absolute URL.
        .{ .base = "https://x/", .path = "https://exa\tmple.com/p", .expected = "https://example.com/p" },
        .{ .base = "https://x/", .path = "https://example.com/\n\rp", .expected = "https://example.com/p" },
        // Leading control char (first == 0).
        .{ .base = "https://example/", .path = "\tfoo.js", .expected = "https://example/foo.js" },
        // Consecutive control chars.
        .{ .base = "https://example/", .path = "a\t\r\nb.js", .expected = "https://example/ab.js" },
        // Control chars spread through the path.
        .{ .base = "https://example/", .path = "a\tb\nc\rd.js", .expected = "https://example/abcd.js" },
        // Trailing control char.
        .{ .base = "https://example/", .path = "foo.js\n", .expected = "https://example/foo.js" },
        // All-strippable relative path collapses to the base.
        .{ .base = "https://example/dir/", .path = "\t\r\n", .expected = "https://example/dir/" },
        // No control chars: unchanged (the fast path).
        .{ .base = "https://example/", .path = "clean.js", .expected = "https://example/clean.js" },
    };

    for (cases) |case| {
        const result = try resolve(testing.arena_allocator, case.base, case.path, .{});
        try testing.expectString(case.expected, result);
    }
}

test "URL: resolve validates ASCII punycode (xn--) labels" {
    defer testing.reset();

    // Valid punycode is left untouched.
    const ok = try resolve(testing.arena_allocator, "https://example.com/", "https://xn--rksmrgs-5wao1o.se/x", .{});
    try testing.expectString("https://xn--rksmrgs-5wao1o.se/x", ok);

    // Malformed punycode must be rejected rather than passed through verbatim.
    try testing.expectError(error.TypeError, resolve(testing.arena_allocator, "https://example.com/", "https://xn--0.pt/x", .{}));
    try testing.expectError(error.TypeError, resolve(testing.arena_allocator, "https://example.com/", "https://xn--a.pt/x", .{}));
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
        // Brackets are not in the WHATWG path percent-encode set
        .{
            .base = "https://example.com/",
            .path = "file[1].html",
            .expected = "https://example.com/file[1].html",
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
        // Pipe is not in the WHATWG path percent-encode set
        .{
            .base = "https://example.com/",
            .path = "file|pipe.html",
            .expected = "https://example.com/file|pipe.html",
        },
        // Backslash is a path separator in special URLs
        .{
            .base = "https://example.com/",
            .path = "file\\backslash.html",
            .expected = "https://example.com/file/backslash.html",
        },
        // Note: the current URL spec percent-encodes '^' in paths, but
        // rust-url does not (yet); harmless divergence locked in here.
        .{
            .base = "https://example.com/",
            .path = "file^caret.html",
            .expected = "https://example.com/file^caret.html",
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
            .base = "https://example.com/dir/frame.html",
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
        const result = try resolve(testing.arena_allocator, case.base, case.path, .{ .encoding = "UTF-8" });
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

test "URL: unescape" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    {
        const result = try unescape(arena, "hello world");
        try testing.expectEqual("hello world", result);
    }

    {
        const result = try unescape(arena, "hello%20world");
        try testing.expectEqual("hello world", result);
    }

    {
        const result = try unescape(arena, "%48%65%6c%6c%6f");
        try testing.expectEqual("Hello", result);
    }

    {
        const result = try unescape(arena, "%48%65%6C%6C%6F");
        try testing.expectEqual("Hello", result);
    }

    {
        const result = try unescape(arena, "a%3Db");
        try testing.expectEqual("a=b", result);
    }

    {
        const result = try unescape(arena, "a%3DB");
        try testing.expectEqual("a=B", result);
    }

    {
        const result = try unescape(arena, "ZDIgPSAndHdvJzs%3D");
        try testing.expectEqual("ZDIgPSAndHdvJzs=", result);
    }

    {
        const result = try unescape(arena, "%5a%44%4d%67%50%53%41%6e%64%47%68%79%5a%57%55%6e%4f%77%3D%3D");
        try testing.expectEqual("ZDMgPSAndGhyZWUnOw==", result);
    }

    {
        const result = try unescape(arena, "hello%2world");
        try testing.expectEqual("hello%2world", result);
    }

    {
        const result = try unescape(arena, "hello%ZZworld");
        try testing.expectEqual("hello%ZZworld", result);
    }

    {
        const result = try unescape(arena, "hello%");
        try testing.expectEqual("hello%", result);
    }

    {
        const result = try unescape(arena, "hello%2");
        try testing.expectEqual("hello%2", result);
    }
}

test "URL: getHost" {
    try testing.expectEqualSlices(u8, "example.com:8080", getHost("https://example.com:8080/path"));
    try testing.expectEqualSlices(u8, "example.com", getHost("https://example.com/path"));
    try testing.expectEqualSlices(u8, "example.com:443", getHost("https://example.com:443/"));
    try testing.expectEqualSlices(u8, "example.com", getHost("https://user:pass@example.com/page"));
    try testing.expectEqualSlices(u8, "example.com:8080", getHost("https://user:pass@example.com:8080/page"));
    try testing.expectEqualSlices(u8, "", getHost("not-a-url"));

    // SECURITY: @ in path must NOT be treated as userinfo separator
    try testing.expectEqualSlices(u8, "evil.example.com", getHost("http://evil.example.com/@victim.example.com/"));
    try testing.expectEqualSlices(u8, "evil.example.com", getHost("https://evil.example.com/path/@victim.example.com"));

    try testing.expectEqual("evil.example.com:8521", getHost("http://evil.example.com:8521\x00@victim.example.com:8520/"));
    try testing.expectEqual("evil.example.com", getHost("http://evil.example.com\x00@victim.example.com/"));
    try testing.expectEqual("evil.example.com", getHost("http://evil.example.com\r@victim.example.com/"));
    try testing.expectEqual("evil.example.com", getHost("http://evil.example.com\n@victim.example.com/"));
    try testing.expectEqual("evil.example.com", getHost("http://evil.example.com\t@victim.example.com/"));

    // IPv6 addresses
    try testing.expectEqualSlices(u8, "[::1]:8080", getHost("http://[::1]:8080/path"));
    try testing.expectEqualSlices(u8, "[::1]", getHost("http://[::1]/path"));
    try testing.expectEqualSlices(u8, "[2001:db8::1]", getHost("https://[2001:db8::1]/"));
}

test "URL: getHostname" {
    // Regular hosts
    try testing.expectEqualSlices(u8, "example.com", getHostname("https://example.com:8080/path"));
    try testing.expectEqualSlices(u8, "example.com", getHostname("https://example.com/path"));

    // IPv6 with port
    try testing.expectEqualSlices(u8, "[::1]", getHostname("http://[::1]:8080/path"));

    // IPv6 without port - must return full bracket notation
    try testing.expectEqualSlices(u8, "[::1]", getHostname("http://[::1]/path"));
    try testing.expectEqualSlices(u8, "[2001:db8::1]", getHostname("https://[2001:db8::1]/"));
}

test "URL: getPort" {
    // Regular hosts
    try testing.expectEqualSlices(u8, "8080", getPort("https://example.com:8080/path"));
    try testing.expectEqualSlices(u8, "", getPort("https://example.com/path"));

    // IPv6 with port
    try testing.expectEqualSlices(u8, "8080", getPort("http://[::1]:8080/path"));
    try testing.expectEqualSlices(u8, "3000", getPort("http://[2001:db8::1]:3000/"));

    // IPv6 without port - colons inside brackets must not be treated as port separator
    try testing.expectEqualSlices(u8, "", getPort("http://[::1]/path"));
    try testing.expectEqualSlices(u8, "", getPort("https://[2001:db8::1]/"));
}

test "URL: setPathname percent-encodes" {
    // Use arena allocator to match production usage (setPathname makes intermediate allocations)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Spaces must be encoded as %20
    const result1 = try setPathname("http://a/", "c d", allocator);
    try testing.expectEqualSlices(u8, "http://a/c%20d", result1);

    // Already-encoded sequences must not be double-encoded
    const result2 = try setPathname("https://example.com/path", "/already%20encoded", allocator);
    try testing.expectEqualSlices(u8, "https://example.com/already%20encoded", result2);

    // Query and hash must be preserved
    const result3 = try setPathname("https://example.com/path?a=b#hash", "/new path", allocator);
    try testing.expectEqualSlices(u8, "https://example.com/new%20path?a=b#hash", result3);
}

test "URL: getOrigin" {
    defer testing.reset();

    const Case = struct {
        url: [:0]const u8,
        expected: ?[]const u8,
    };

    const cases = [_]Case{
        // Basic HTTP/HTTPS origins
        .{ .url = "http://example.com/path", .expected = "http://example.com" },
        .{ .url = "https://example.com/path", .expected = "https://example.com" },
        .{ .url = "https://example.com:8080/path", .expected = "https://example.com:8080" },

        // Default ports should be stripped
        .{ .url = "http://example.com:80/path", .expected = "http://example.com" },
        .{ .url = "https://example.com:443/path", .expected = "https://example.com" },

        // User info should be stripped from origin
        .{ .url = "http://user:pass@example.com/path", .expected = "http://example.com" },
        .{ .url = "https://user@example.com:8080/path", .expected = "https://example.com:8080" },

        // Non-HTTP schemes return null
        .{ .url = "ftp://example.com/path", .expected = null },
        .{ .url = "file:///path/to/file", .expected = null },
        .{ .url = "about:blank", .expected = null },

        // Query and fragment should not affect origin
        .{ .url = "https://example.com?query=1", .expected = "https://example.com" },
        .{ .url = "https://example.com#fragment", .expected = "https://example.com" },
        .{ .url = "https://example.com/path?q=1#frag", .expected = "https://example.com" },

        // SECURITY: @ in path must NOT be treated as userinfo separator
        // This would be a Same-Origin Policy bypass if mishandled
        .{ .url = "http://evil.example.com/@victim.example.com/", .expected = "http://evil.example.com" },
        .{ .url = "https://evil.example.com/path/@victim.example.com/steal", .expected = "https://evil.example.com" },
        .{ .url = "http://evil.example.com/@victim.example.com:443/", .expected = "http://evil.example.com" },

        // SECURITY: Null byte injection.
        .{ .url = "http://attacker:8521\x00@victim:8520/", .expected = "http://attacker:8521" },
        .{ .url = "http://attacker.com\x00@victim.com/", .expected = "http://attacker.com" },
        .{ .url = "http://attacker.com/\x00@victim.com/", .expected = "http://attacker.com" },

        // SECURITY: CR / LF / TAB are stripped by the WHATWG URL parser, so a
        // userinfo "@" hidden behind one must not change the origin here either.
        .{ .url = "http://attacker.com\r@victim.com/", .expected = "http://attacker.com" },
        .{ .url = "http://attacker.com\n@victim.com/", .expected = "http://attacker.com" },
        .{ .url = "http://attacker.com\t@victim.com/", .expected = "http://attacker.com" },

        // @ in query/fragment must also not affect origin
        .{ .url = "https://example.com/path?user=foo@bar.com", .expected = "https://example.com" },
        .{ .url = "https://example.com/path#user@host", .expected = "https://example.com" },
    };

    for (cases) |case| {
        const result = try getOrigin(testing.arena_allocator, case.url);
        if (case.expected) |expected| {
            try testing.expectString(expected, result.?);
        } else {
            try testing.expectEqual(null, result);
        }
    }
}

test "URL: resolve path scheme" {
    const Case = struct {
        base: [:0]const u8,
        path: [:0]const u8,
        expected: [:0]const u8,
        expected_error: bool = false,
    };

    const cases = [_]Case{
        //same schemes and path as relative path (one slash)
        .{
            .base = "https://www.example.com/example",
            .path = "https:/about",
            .expected = "https://www.example.com/about",
        },
        //same schemes and path as relative path (without slash)
        .{
            .base = "https://www.example.com/example",
            .path = "https:about",
            .expected = "https://www.example.com/about",
        },
        //same schemes and path as absolute path (two slashes)
        .{
            .base = "https://www.example.com/example",
            .path = "https://about",
            .expected = "https://about/",
        },
        //different schemes and path as absolute (without slash)
        .{
            .base = "https://www.example.com/example",
            .path = "http:about",
            .expected = "http://about/",
        },
        //different schemes and path as absolute (with one slash)
        .{
            .base = "https://www.example.com/example",
            .path = "http:/about",
            .expected = "http://about/",
        },
        //different schemes and path as absolute (with two slashes)
        .{
            .base = "https://www.example.com/example",
            .path = "http://about",
            .expected = "http://about/",
        },
        //same schemes and path as absolute (with more slashes)
        .{
            .base = "https://site/",
            .path = "https://path",
            .expected = "https://path/",
        },
        //path scheme is not special and path as absolute (without additional slashes)
        .{
            .base = "http://localhost/",
            .path = "data:test",
            .expected = "data:test",
        },
        //different schemes and path as absolute (pathscheme=ws)
        .{
            .base = "https://www.example.com/example",
            .path = "ws://about",
            .expected = "ws://about/",
        },
        //different schemes and path as absolute (path scheme=wss)
        .{
            .base = "https://www.example.com/example",
            .path = "wss://about",
            .expected = "wss://about/",
        },
        //different schemes and path as absolute (path scheme=ftp)
        .{
            .base = "https://www.example.com/example",
            .path = "ftp://about",
            .expected = "ftp://about/",
        },
        //different schemes and path as absolute (path scheme=file)
        .{
            .base = "https://www.example.com/example",
            .path = "file://path/to/file",
            .expected = "file://path/to/file",
        },
        //different schemes and path as absolute (path scheme=file, host is empty)
        .{
            .base = "https://www.example.com/example",
            .path = "file:/path/to/file",
            .expected = "file:///path/to/file",
        },
        //different schemes and path as absolute (path scheme=file, host is empty)
        .{
            .base = "https://www.example.com/example",
            .path = "file:/",
            .expected = "file:///",
        },
        //different schemes without :// and normalize "file" scheme, absolute path
        .{
            .base = "https://www.example.com/example",
            .path = "file:path/to/file",
            .expected = "file:///path/to/file",
        },
        //same schemes without :// in path and rest starts with scheme:/, relative path
        .{
            .base = "https://www.example.com/example",
            .path = "https:/file:/relative/path/",
            .expected = "https://www.example.com/file:/relative/path/",
        },
        //same schemes without :// in path and rest starts with scheme://, relative path
        .{
            .base = "https://www.example.com/example",
            .path = "https:/http://relative/path/",
            .expected = "https://www.example.com/http://relative/path/",
        },
        //same schemes without :// in path , relative state
        .{
            .base = "http://www.example.com/example",
            .path = "http:relative:path",
            .expected = "http://www.example.com/relative:path",
        },
        //repeat different schemes in path
        .{
            .base = "http://www.example.com/example",
            .path = "http:http:/relative/path/",
            .expected = "http://www.example.com/http:/relative/path/",
        },
        //repeat different schemes in path
        .{
            .base = "http://www.example.com/example",
            .path = "http:https://relative:path",
            .expected = "http://www.example.com/https://relative:path",
        },
        //NOT required :// for blob scheme
        .{
            .base = "http://www.example.com/example",
            .path = "blob:other",
            .expected = "blob:other",
        },
        //NOT required :// for NON-special schemes and can contains "+" or "-" or "." in scheme
        .{
            .base = "http://www.example.com/example",
            .path = "custom+foo:other",
            .expected = "custom+foo:other",
        },
        //NOT required :// for NON-special schemes
        .{
            .base = "http://www.example.com/example",
            .path = "blob:",
            .expected = "blob:",
        },
        //NOT required :// for special scheme equal base scheme
        .{
            .base = "http://www.example.com/example",
            .path = "http:",
            .expected = "http://www.example.com/example",
        },
        //required :// for special scheme, so throw error.InvalidURL
        .{
            .base = "http://www.example.com/example",
            .path = "https:",
            .expected = "",
            .expected_error = true,
        },
        //incorrect symbols in path scheme
        .{
            .base = "https://site",
            .path = "http?://host/some",
            .expected = "https://site/http?://host/some",
        },
    };

    for (cases) |case| {
        if (case.expected_error) {
            const result = resolve(testing.arena_allocator, case.base, case.path, .{});
            try testing.expectError(error.TypeError, result);
        } else {
            const result = try resolve(testing.arena_allocator, case.base, case.path, .{});
            try testing.expectString(case.expected, result);
        }
    }
}

test "URL: resolveNavigation defaults a schemeless host to http (curl-like)" {
    defer testing.reset();

    const Case = struct {
        url: [:0]const u8,
        expected: [:0]const u8,
    };

    const cases = [_]Case{
        // Schemeless input (the regression): assume http://, like curl.
        .{ .url = "lightpanda.io", .expected = "http://lightpanda.io/" },
        .{ .url = "example.com/path?q=1", .expected = "http://example.com/path?q=1" },
        // An explicit scheme is preserved, not double-prefixed.
        .{ .url = "https://example.com/x", .expected = "https://example.com/x" },
        .{ .url = "http://example.com/", .expected = "http://example.com/" },
        // Non-http absolute URLs still parse as-is.
        .{ .url = "about:blank", .expected = "about:blank" },
    };

    for (cases) |case| {
        const result = try resolveNavigation(testing.arena_allocator, case.url, .{});
        try testing.expectString(case.expected, result);
    }
}
