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
        return error.Invalid;
    }

    return url;
}

pub fn parseWithBase(input: []const u8, base: []const u8) ParseError!URL {
    const url = c.ada_parse_with_base(input.ptr, input.len, base.ptr, base.len);
    if (!c.ada_is_valid(url)) {
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

/// Returns true if given URL is valid.
pub inline fn isValid(url: URL) bool {
    return c.ada_is_valid(url);
}

/// Creates a new `URL` from given `URL`.
pub inline fn copy(url: URL) URL {
    return c.ada_copy(url);
}

/// Can return an empty string.
/// Contrary to other getters, returned slice is heap allocated.
pub inline fn getOrigin(url: URL) []const u8 {
    const origin = c.ada_get_origin(url);
    return origin.data[0..origin.length];
}

pub inline fn getOriginNullable(url: URL) OwnedString {
    return c.ada_get_origin(url);
}

pub inline fn getHrefNullable(url: URL) String {
    return c.ada_get_href(url);
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

pub inline fn getPortNullable(url: URL) String {
    return c.ada_get_port(url);
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

pub inline fn getHashNullable(url: URL) String {
    return c.ada_get_hash(url);
}

/// `data` is null if host not provided.
pub inline fn getHostNullable(url: URL) String {
    return c.ada_get_host(url);
}

/// Returns an empty string if host not provided.
pub inline fn getHost(url: URL) []const u8 {
    const host = getHostNullable(url);
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

pub inline fn getHostnameNullable(url: URL) String {
    return c.ada_get_hostname(url);
}

pub inline fn getPathnameNullable(url: URL) String {
    return c.ada_get_pathname(url);
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

/// Sets the href for given URL.
/// Call `isInvalid` afterwards to check correctness.
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

pub const Scheme = struct {
    pub const http: u8 = 0;
    pub const not_special: u8 = 1;
    pub const https: u8 = 2;
    pub const ws: u8 = 3;
    pub const ftp: u8 = 4;
    pub const wss: u8 = 5;
    pub const file: u8 = 6;
};

/// Returns one of the constants defined in `Scheme`.
pub inline fn getSchemeType(url: URL) u8 {
    return c.ada_get_scheme_type(url);
}
