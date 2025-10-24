//! Wrappers for ada URL parser.
//! https://github.com/ada-url/ada

const c = @cImport({
    @cInclude("ada_c.h");
});

pub const URLComponents = c.ada_url_components;
pub const URLOmitted = c.ada_url_omitted;
pub const String = c.ada_string;
pub const OwnedString = c.ada_owned_string;
/// Pointer types.
pub const URL = c.ada_url;
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

pub inline fn canParse(input: []const u8) bool {
    return c.ada_can_parse(input.ptr, input.len);
}

pub inline fn canParseWithBase(input: []const u8, base: []const u8) bool {
    return c.ada_can_parse_with_base(input.ptr, input.len, base.ptr, base.len);
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

/// Contrary to other getters, this heap allocates.
pub inline fn getOriginNullable(url: URL) OwnedString {
    return c.ada_get_origin(url);
}

pub inline fn getHrefNullable(url: URL) String {
    return c.ada_get_href(url);
}

pub inline fn getUsernameNullable(url: URL) String {
    return c.ada_get_username(url);
}

pub inline fn getPasswordNullable(url: URL) String {
    return c.ada_get_password(url);
}

pub inline fn getSearchNullable(url: URL) String {
    return c.ada_get_search(url);
}

pub inline fn getPortNullable(url: URL) String {
    return c.ada_get_port(url);
}

pub inline fn getHashNullable(url: URL) String {
    return c.ada_get_hash(url);
}

pub inline fn getHostNullable(url: URL) String {
    return c.ada_get_host(url);
}

pub inline fn getHostnameNullable(url: URL) String {
    return c.ada_get_hostname(url);
}

pub inline fn getPathnameNullable(url: URL) String {
    return c.ada_get_pathname(url);
}

pub inline fn getProtocolNullable(url: URL) String {
    return c.ada_get_protocol(url);
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

pub inline fn clearHash(url: URL) void {
    return c.ada_clear_hash(url);
}

pub inline fn clearSearch(url: URL) void {
    return c.ada_clear_search(url);
}

pub inline fn clearPort(url: URL) void {
    return c.ada_clear_port(url);
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
