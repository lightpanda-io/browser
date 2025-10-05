//! Wrappers for ada URL parser.
//! https://github.com/ada-url/ada

const c = @cImport({
    @cInclude("ada_c.h");
});

/// Pointer type.
pub const URL = c.ada_url;
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

pub inline fn free(url: URL) void {
    return c.ada_free(url);
}

pub inline fn freeOwnedString(owned: OwnedString) void {
    return c.ada_free_owned_string(owned);
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
    const port = c.ada_get_port(url);
    return port.data[0..port.length];
}

pub inline fn getHash(url: URL) []const u8 {
    const hash = c.ada_get_hash(url);
    return hash.data[0..hash.length];
}

pub inline fn getHost(url: URL) []const u8 {
    const host = c.ada_get_host(url);
    return host.data[0..host.length];
}

pub inline fn getHostname(url: URL) []const u8 {
    const hostname = c.ada_get_hostname(url);
    return hostname.data[0..hostname.length];
}

pub inline fn getPathname(url: URL) []const u8 {
    const pathname = c.ada_get_pathname(url);
    return pathname.data[0..pathname.length];
}

pub inline fn getSearch(url: URL) []const u8 {
    const search = c.ada_get_search(url);
    return search.data[0..search.length];
}

pub inline fn getProtocol(url: URL) []const u8 {
    const protocol = c.ada_get_protocol(url);
    return protocol.data[0..protocol.length];
}
