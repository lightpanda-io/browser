//! Wrappers for ada URL parser.
//! https://github.com/ada-url/ada

const c = @cImport({
    @cInclude("ada_c.h");
});

/// Pointer type.
pub const URL = c.ada_url;
pub const URLComponents = c.ada_url_components;
pub const URLOmitted = c.ada_url_omitted;
pub const String = c.ada_string;
pub const OwnedString = c.ada_owned_string;
/// Pointer type.
pub const URLSearchParams = c.ada_url_search_params;

pub const ParseError = error{Invalid};

pub fn parse(input: []const u8) ParseError!URL {
    const url = c.ada_parse(input.ptr, input.len);
    if (!c.ada_is_valid(url)) {
        free(url);
        return error.Invalid;
    }

    return url;
}

pub fn parseWithBase(input: []const u8, base: []const u8) ParseError!URL {
    const url = c.ada_parse_with_base(input.ptr, input.len, base.ptr, base.len);
    if (!c.ada_is_valid(url)) {
        free(url);
        return error.Invalid;
    }

    return url;
}

pub inline fn getComponents(url: URL) *const URLComponents {
    return c.ada_get_components(url);
}

pub inline fn free(url: URL) void {
    return c.ada_free(url);
}

pub inline fn freeOwnedString(owned: OwnedString) void {
    return c.ada_free_owned_string(owned);
}

/// Returns true if given URL is valid (not NULL).
pub inline fn isValid(url: URL) bool {
    return c.ada_is_valid(url);
}

/// Can return an empty string.
/// Contrary to other getters, returned slice is heap allocated.
pub inline fn getOrigin(url: URL) []const u8 {
    const origin = c.ada_get_origin(url);
    return origin.data[0..origin.length];
}

/// Can return an empty string.
pub inline fn getHref(url: URL) []const u8 {
    const href = c.ada_get_href(url);
    return href.data[0..href.length];
}

/// Can return an empty string.
pub inline fn getUsername(url: URL) []const u8 {
    const username = c.ada_get_username(url);
    return username.data[0..username.length];
}

/// Can return an empty string.
pub inline fn getPassword(url: URL) []const u8 {
    const password = c.ada_get_password(url);
    return password.data[0..password.length];
}

pub inline fn getPort(url: URL) []const u8 {
    if (!c.ada_has_port(url)) {
        return "";
    }

    const port = c.ada_get_port(url);
    return port.data[0..port.length];
}

pub inline fn getHash(url: URL) []const u8 {
    const hash = c.ada_get_hash(url);
    return hash.data[0..hash.length];
}

/// Returns an empty string if not provided.
pub inline fn getHost(url: URL) []const u8 {
    const host = c.ada_get_host(url);
    if (host.data == null) {
        return "";
    }

    return host.data[0..host.length];
}

pub inline fn getHostname(url: URL) []const u8 {
    if (!c.ada_has_hostname(url)) {
        return "";
    }

    const hostname = c.ada_get_hostname(url);
    return hostname.data[0..hostname.length];
}

pub inline fn getPathname(url: URL) []const u8 {
    const pathname = c.ada_get_pathname(url);
    return pathname.data[0..pathname.length];
}

pub inline fn getSearch(url: URL) String {
    return c.ada_get_search(url);
}

pub inline fn getProtocol(url: URL) []const u8 {
    const protocol = c.ada_get_protocol(url);
    return protocol.data[0..protocol.length];
}

pub inline fn setHref(url: URL, input: []const u8) bool {
    return c.ada_set_href(url, input.ptr, input.len);
}

pub inline fn setHost(url: URL, input: []const u8) bool {
    return c.ada_set_host(url, input.ptr, input.len);
}

pub inline fn setHostname(url: URL, input: []const u8) bool {
    return c.ada_set_hostname(url, input.ptr, input.len);
}

pub inline fn setProtocol(url: URL, input: []const u8) bool {
    return c.ada_set_protocol(url, input.ptr, input.len);
}

pub inline fn setUsername(url: URL, input: []const u8) bool {
    return c.ada_set_username(url, input.ptr, input.len);
}

pub inline fn setPassword(url: URL, input: []const u8) bool {
    return c.ada_set_password(url, input.ptr, input.len);
}

pub inline fn setPort(url: URL, input: []const u8) bool {
    return c.ada_set_port(url, input.ptr, input.len);
}

pub inline fn setPathname(url: URL, input: []const u8) bool {
    return c.ada_set_pathname(url, input.ptr, input.len);
}

pub inline fn setSearch(url: URL, input: []const u8) void {
    return c.ada_set_search(url, input.ptr, input.len);
}

pub inline fn setHash(url: URL, input: []const u8) void {
    return c.ada_set_hash(url, input.ptr, input.len);
}

pub inline fn clearSearch(url: URL) void {
    return c.ada_clear_search(url);
}
