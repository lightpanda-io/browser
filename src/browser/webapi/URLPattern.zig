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

// https://urlpattern.spec.whatwg.org/

const std = @import("std");
const lp = @import("lightpanda");

const U = @import("../../sys/url.zig");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const URLPattern = @This();

_rc: lp.RC = .{},
/// Owns this struct and every compiled string; released by the finalizer.
_arena: *lp.Arena,
_protocol: Component,
_username: Component,
_password: Component,
_hostname: Component,
_port: Component,
_pathname: Component,
_search: Component,
_hash: Component,

const component_names = [_][]const u8{
    "protocol",
    "username",
    "password",
    "hostname",
    "port",
    "pathname",
    "search",
    "hash",
};

pub const Init = struct {
    baseURL: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    password: ?[]const u8 = null,
    pathname: ?[]const u8 = null,
    port: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    search: ?[]const u8 = null,
    username: ?[]const u8 = null,
};

const Input = union(enum) {
    init: Init,
    string: []const u8,
};

const OptionsOrBaseUrl = union(enum) {
    options: Options,
    base_url: []const u8,

    const Options = struct {
        ignoreCase: bool = false,
    };
};

pub fn init(input: ?Input, arg2: ?OptionsOrBaseUrl, arg3: ?OptionsOrBaseUrl.Options, exec: *const Execution) !*URLPattern {
    var base_url: ?[]const u8 = null;
    var options: OptionsOrBaseUrl.Options = .{};
    if (arg2) |a2| switch (a2) {
        .base_url => |b| base_url = b,
        .options => |o| {
            if (arg3 != null) {
                return error.TypeError;
            }
            options = o;
        },
    };
    if (arg3) |o| {
        options = o;
    }

    const local = exec.js.local.?;
    const env: Env = .{ .arena = exec.local_arena, .local = local };
    const ignore_case = options.ignoreCase;

    var pattern_init: Init = .{};
    switch (input orelse Input{ .init = .{} }) {
        .init => |i| {
            if (base_url != null) {
                return error.TypeError;
            }
            pattern_init = i;
        },
        .string => |str| {
            pattern_init = try parseConstructorString(env, str);
            if (base_url == null and pattern_init.protocol == null) {
                return error.TypeError;
            }
            pattern_init.baseURL = base_url;
        },
    }

    var processed = try processInit(env.arena, pattern_init, .pattern);
    inline for (component_names) |name| {
        if (@field(processed, name) == null) {
            @field(processed, name) = "*";
        }
    }
    if (defaultPort(processed.protocol.?)) |port| {
        if (std.mem.eql(u8, processed.port.?, port)) {
            processed.port = "";
        }
    }

    const protocol = try Component.compile(env, processed.protocol.?, canonicalizeProtocol, .default);
    const username = try Component.compile(env, processed.username.?, canonicalizeUsername, .default);
    const password = try Component.compile(env, processed.password.?, canonicalizePassword, .default);
    const hostname = if (isIpv6HostnamePattern(processed.hostname.?))
        try Component.compile(env, processed.hostname.?, canonicalizeIpv6Hostname, .hostname)
    else
        try Component.compile(env, processed.hostname.?, canonicalizeHostname, .hostname);
    const port = try Component.compile(env, processed.port.?, canonicalizePortCallback, .default);

    var compile_options: PatternOptions = .default;
    compile_options.ignore_case = ignore_case;

    var path_options: PatternOptions = .pathname;
    path_options.ignore_case = ignore_case;
    const pathname = if (try protocolMatchesSpecialScheme(&protocol, local))
        try Component.compile(env, processed.pathname.?, canonicalizePathname, path_options)
    else
        try Component.compile(env, processed.pathname.?, canonicalizeOpaquePathname, compile_options);
    const search = try Component.compile(env, processed.search.?, canonicalizeSearch, compile_options);
    const hash = try Component.compile(env, processed.hash.?, canonicalizeHash, compile_options);

    // Everything above was scratch; only the compiled components survive,
    // in an arena the pattern owns for its lifetime.
    const owned = try exec.getArena(.small, "URLPattern");
    errdefer owned.release();
    const arena = owned.allocator();
    const self = try arena.create(URLPattern);
    self.* = .{
        ._arena = owned,
        ._protocol = try protocol.dupe(arena),
        ._username = try username.dupe(arena),
        ._password = try password.dupe(arena),
        ._hostname = try hostname.dupe(arena),
        ._port = try port.dupe(arena),
        ._pathname = try pathname.dupe(arena),
        ._search = try search.dupe(arena),
        ._hash = try hash.dupe(arena),
    };
    return self;
}

pub fn deinit(self: *URLPattern, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *URLPattern) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *URLPattern, page: *Page) void {
    self._rc.release(self, page);
}

pub fn getProtocol(self: *const URLPattern) []const u8 {
    return self._protocol.pattern_string;
}

pub fn getUsername(self: *const URLPattern) []const u8 {
    return self._username.pattern_string;
}

pub fn getPassword(self: *const URLPattern) []const u8 {
    return self._password.pattern_string;
}

pub fn getHostname(self: *const URLPattern) []const u8 {
    return self._hostname.pattern_string;
}

pub fn getPort(self: *const URLPattern) []const u8 {
    return self._port.pattern_string;
}

pub fn getPathname(self: *const URLPattern) []const u8 {
    return self._pathname.pattern_string;
}

pub fn getSearch(self: *const URLPattern) []const u8 {
    return self._search.pattern_string;
}

pub fn getHash(self: *const URLPattern) []const u8 {
    return self._hash.pattern_string;
}

pub fn getHasRegExpGroups(self: *const URLPattern) bool {
    inline for (component_names) |name| {
        if (@field(self, "_" ++ name).has_regexp_groups) {
            return true;
        }
    }
    return false;
}

pub fn testFn(self: *const URLPattern, input: ?Input, base_url: ?[]const u8, exec: *const Execution) !bool {
    return (try self.match(input, base_url, exec)) != null;
}

pub fn execFn(self: *const URLPattern, input: ?Input, base_url: ?[]const u8, exec: *const Execution) !?Result {
    return self.match(input, base_url, exec);
}

pub const ComponentName = enum {
    protocol,
    username,
    password,
    hostname,
    port,
    pathname,
    search,
    hash,

    pub const js_enum_from_string = true;
};

fn getComponent(self: *const URLPattern, name: ComponentName) *const Component {
    return switch (name) {
        inline else => |n| &@field(self, "_" ++ @tagName(n)),
    };
}

// Tentative (Chromium-only, WPT urlpattern-compare.tentative): orders two
// patterns' components by specificity.
pub fn compareComponent(name: ComponentName, left: *const URLPattern, right: *const URLPattern, exec: *const Execution) !i32 {
    const env: Env = .{ .arena = exec.local_arena, .local = exec.js.local.? };
    return left.getComponent(name).compare(right.getComponent(name), env);
}

// Tentative (Chromium-only, WPT urlpattern-generate.tentative): builds a
// component value by filling the pattern's named groups from `groups`.
pub fn generate(self: *const URLPattern, name: ComponentName, groups_: ?js.Object, exec: *const Execution) ![]const u8 {
    const env: Env = .{ .arena = exec.local_arena, .local = exec.js.local.? };

    var groups: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (groups_) |obj| {
        if (!obj.isNullOrUndefined()) {
            const names = try obj.getOwnPropertyNames();
            for (0..names.len()) |i| {
                const key = try (try names.get(@intCast(i))).toStringSlice();
                const value = try (try obj.get(key)).toStringSlice();
                try groups.put(env.arena, key, value);
            }
        }
    }
    return self.getComponent(name).generate(env, &groups);
}

const ComponentResult = struct {
    input: []const u8,
    groups: js.Object,
};

pub const Result = struct {
    inputs: js.Value,
    protocol: ComponentResult,
    username: ComponentResult,
    password: ComponentResult,
    hostname: ComponentResult,
    port: ComponentResult,
    pathname: ComponentResult,
    search: ComponentResult,
    hash: ComponentResult,
};

fn match(self: *const URLPattern, input: ?Input, base_url: ?[]const u8, exec: *const Execution) !?Result {
    const local = exec.js.local.?;
    const arena = exec.local_arena;

    var values: Init = .{};
    var inputs: js.Array = undefined;

    switch (input orelse Input{ .init = .{} }) {
        .init => |dict_init| {
            if (base_url != null) {
                return error.TypeError;
            }
            values = processInit(arena, dict_init, .url) catch |err| switch (err) {
                error.TypeError => return null,
                else => return err,
            };

            // The IDL conversion yields a fresh dictionary; that, not the
            // caller's object, is what ends up in result.inputs.
            const dict = local.newObject();
            inline for (@typeInfo(Init).@"struct".fields) |f| {
                if (@field(dict_init, f.name)) |v| {
                    _ = try dict.set(f.name, v, .{});
                }
            }
            inputs = local.newArray(1);
            _ = try inputs.set(0, dict, .{});
        },
        .string => |str| {
            inputs = local.newArray(if (base_url == null) 1 else 2);
            _ = try inputs.set(0, str, .{});
            if (base_url) |b| {
                _ = try inputs.set(1, b, .{});
            }

            var err: i32 = 0;
            const url = (if (base_url) |b|
                U.url_parse_with_base(b.ptr, b.len, str.ptr, str.len, &err)
            else
                U.url_parse(str.ptr, str.len, &err)) orelse return null;
            defer U.url_free(url);

            values = .{
                .protocol = try arena.dupe(u8, urlScheme(url)),
                .username = try arena.dupe(u8, urlUsername(url)),
                .password = try arena.dupe(u8, urlPassword(url)),
                .hostname = try arena.dupe(u8, urlHost(url)),
                .port = try urlPort(arena, url),
                .pathname = try arena.dupe(u8, urlPath(url)),
                .search = try arena.dupe(u8, urlQuery(url)),
                .hash = try arena.dupe(u8, urlFragment(url)),
            };
        },
    }

    var result: Result = undefined;
    result.inputs = inputs.toValue();
    inline for (component_names) |name| {
        const component: *const Component = &@field(self, "_" ++ name);
        const value = @field(values, name) orelse "";
        const exec_result = (try component.exec(local, value)) orelse return null;

        const groups = local.newObject();
        var key_buf: [16]u8 = undefined;
        for (component.group_names, 1..) |group_name, i| {
            const key = std.fmt.bufPrint(&key_buf, "{d}", .{i}) catch unreachable;
            _ = try groups.set(group_name, try exec_result.get(key), .{});
        }
        @field(result, name) = .{ .input = value, .groups = groups };
    }
    return result;
}

const ConstructorParser = struct {
    env: Env,
    input: []const u8,
    tokens: []const Token,
    result: Init = .{},
    component_start: usize = 0,
    token_index: usize = 0,
    token_increment: usize = 1,
    group_depth: usize = 0,
    hostname_ipv6_bracket_depth: usize = 0,
    protocol_matches_special_scheme: bool = false,
    state: State = .init,

    const State = enum {
        init,
        protocol,
        authority,
        username,
        password,
        hostname,
        port,
        pathname,
        search,
        hash,
        done,
    };

    fn run(self: *ConstructorParser) Error!Init {
        while (self.token_index < self.tokens.len) {
            self.token_increment = 1;
            if (self.tokens[self.token_index].type == .end) {
                if (self.state == .init) {
                    // No protocol terminator: a relative pattern, starting at
                    // whichever of pathname / search / hash comes first.
                    self.rewind();
                    if (self.isHashPrefix()) {
                        try self.changeState(.hash, 1);
                    } else if (self.isSearchPrefix()) {
                        try self.changeState(.search, 1);
                    } else {
                        try self.changeState(.pathname, 0);
                    }
                    self.token_index += self.token_increment;
                    continue;
                }
                if (self.state == .authority) {
                    // No "@" found, so no credentials.
                    self.rewindAndSetState(.hostname);
                    self.token_index += self.token_increment;
                    continue;
                }
                try self.changeState(.done, 0);
                break;
            }

            if (self.isGroupOpen()) {
                self.group_depth += 1;
                self.token_index += self.token_increment;
                continue;
            }
            if (self.group_depth > 0) {
                if (self.isGroupClose()) {
                    self.group_depth -= 1;
                } else {
                    self.token_index += self.token_increment;
                    continue;
                }
            }

            switch (self.state) {
                .init => if (self.isProtocolSuffix()) {
                    self.rewindAndSetState(.protocol);
                },
                .protocol => if (self.isProtocolSuffix()) {
                    try self.computeProtocolMatchesSpecialScheme();
                    var next_state: State = .pathname;
                    var skip: usize = 1;
                    if (self.nextIsAuthoritySlashes()) {
                        next_state = .authority;
                        skip = 3;
                    } else if (self.protocol_matches_special_scheme) {
                        next_state = .authority;
                    }
                    try self.changeState(next_state, skip);
                },
                .authority => {
                    if (self.isIdentityTerminator()) {
                        self.rewindAndSetState(.username);
                    } else if (self.isPathnameStart() or self.isSearchPrefix() or self.isHashPrefix()) {
                        self.rewindAndSetState(.hostname);
                    }
                },
                .username => {
                    if (self.isPasswordPrefix()) {
                        try self.changeState(.password, 1);
                    } else if (self.isIdentityTerminator()) {
                        try self.changeState(.hostname, 1);
                    }
                },
                .password => if (self.isIdentityTerminator()) {
                    try self.changeState(.hostname, 1);
                },
                .hostname => {
                    if (self.isIpv6Open()) {
                        self.hostname_ipv6_bracket_depth += 1;
                    } else if (self.isIpv6Close()) {
                        self.hostname_ipv6_bracket_depth -|= 1;
                    } else if (self.isPortPrefix() and self.hostname_ipv6_bracket_depth == 0) {
                        try self.changeState(.port, 1);
                    } else if (self.isPathnameStart()) {
                        try self.changeState(.pathname, 0);
                    } else if (self.isSearchPrefix()) {
                        try self.changeState(.search, 1);
                    } else if (self.isHashPrefix()) {
                        try self.changeState(.hash, 1);
                    }
                },
                .port => {
                    if (self.isPathnameStart()) {
                        try self.changeState(.pathname, 0);
                    } else if (self.isSearchPrefix()) {
                        try self.changeState(.search, 1);
                    } else if (self.isHashPrefix()) {
                        try self.changeState(.hash, 1);
                    }
                },
                .pathname => {
                    if (self.isSearchPrefix()) {
                        try self.changeState(.search, 1);
                    } else if (self.isHashPrefix()) {
                        try self.changeState(.hash, 1);
                    }
                },
                .search => if (self.isHashPrefix()) {
                    try self.changeState(.hash, 1);
                },
                .hash => {},
                .done => unreachable,
            }
            self.token_index += self.token_increment;
        }

        // An explicit hostname without a port means the default port, not any
        // port ("https://example.com/*" must not match ":8443").
        if (self.result.hostname != null and self.result.port == null) {
            self.result.port = "";
        }
        return self.result;
    }

    fn setResult(self: *ConstructorParser, state: State, value: []const u8) void {
        switch (state) {
            .protocol => self.result.protocol = value,
            .username => self.result.username = value,
            .password => self.result.password = value,
            .hostname => self.result.hostname = value,
            .port => self.result.port = value,
            .pathname => self.result.pathname = value,
            .search => self.result.search = value,
            .hash => self.result.hash = value,
            .init, .authority, .done => unreachable,
        }
    }

    fn changeState(self: *ConstructorParser, new_state: State, skip: usize) Error!void {
        const state = self.state;
        if (state != .init and state != .authority and state != .done) {
            self.setResult(state, self.makeComponentString());
        }
        if (state != .init and new_state != .done) {
            const before_hostname = state == .protocol or state == .authority or state == .username or state == .password;
            const before_pathname = before_hostname or state == .hostname or state == .port;
            const before_search = before_pathname or state == .pathname;
            const after_hostname = new_state == .port or new_state == .pathname or new_state == .search or new_state == .hash;
            const after_pathname = new_state == .search or new_state == .hash;
            const after_search = new_state == .hash;

            if (before_hostname and after_hostname and self.result.hostname == null) {
                self.result.hostname = "";
            }
            if (before_pathname and after_pathname and self.result.pathname == null) {
                self.result.pathname = if (self.protocol_matches_special_scheme) "/" else "";
            }
            if (before_search and after_search and self.result.search == null) {
                self.result.search = "";
            }
        }
        self.state = new_state;
        self.token_index += skip;
        self.component_start = self.token_index;
        self.token_increment = 0;
    }

    fn rewind(self: *ConstructorParser) void {
        self.token_index = self.component_start;
        self.token_increment = 0;
    }

    fn rewindAndSetState(self: *ConstructorParser, state: State) void {
        self.rewind();
        self.state = state;
    }

    fn safeToken(self: *const ConstructorParser, index: usize) Token {
        if (index < self.tokens.len) {
            return self.tokens[index];
        }
        const last = self.tokens[self.tokens.len - 1];
        std.debug.assert(last.type == .end);
        return last;
    }

    fn isNonSpecialPatternChar(self: *const ConstructorParser, index: usize, value: u8) bool {
        const token = self.safeToken(index);
        if (token.value.len != 1 or token.value[0] != value) {
            return false;
        }
        return token.type == .char or token.type == .escaped_char or token.type == .invalid_char;
    }

    fn isProtocolSuffix(self: *const ConstructorParser) bool {
        return self.isNonSpecialPatternChar(self.token_index, ':');
    }

    fn nextIsAuthoritySlashes(self: *const ConstructorParser) bool {
        return self.isNonSpecialPatternChar(self.token_index + 1, '/') and self.isNonSpecialPatternChar(self.token_index + 2, '/');
    }

    fn isIdentityTerminator(self: *const ConstructorParser) bool {
        return self.isNonSpecialPatternChar(self.token_index, '@');
    }

    fn isPasswordPrefix(self: *const ConstructorParser) bool {
        return self.isNonSpecialPatternChar(self.token_index, ':');
    }

    fn isPortPrefix(self: *const ConstructorParser) bool {
        return self.isNonSpecialPatternChar(self.token_index, ':');
    }

    fn isPathnameStart(self: *const ConstructorParser) bool {
        return self.isNonSpecialPatternChar(self.token_index, '/');
    }

    fn isSearchPrefix(self: *const ConstructorParser) bool {
        if (self.isNonSpecialPatternChar(self.token_index, '?')) {
            return true;
        }
        const token = self.tokens[self.token_index];
        if (token.value.len != 1 or token.value[0] != '?') {
            return false;
        }
        // A "?" right after a group is that group's optional modifier.
        if (self.token_index == 0) {
            return true;
        }
        return switch (self.safeToken(self.token_index - 1).type) {
            .name, .regexp, .close, .asterisk => false,
            else => true,
        };
    }

    fn isHashPrefix(self: *const ConstructorParser) bool {
        return self.isNonSpecialPatternChar(self.token_index, '#');
    }

    fn isGroupOpen(self: *const ConstructorParser) bool {
        return self.tokens[self.token_index].type == .open;
    }

    fn isGroupClose(self: *const ConstructorParser) bool {
        return self.tokens[self.token_index].type == .close;
    }

    fn isIpv6Open(self: *const ConstructorParser) bool {
        return self.isNonSpecialPatternChar(self.token_index, '[');
    }

    fn isIpv6Close(self: *const ConstructorParser) bool {
        return self.isNonSpecialPatternChar(self.token_index, ']');
    }

    fn makeComponentString(self: *const ConstructorParser) []const u8 {
        std.debug.assert(self.token_index < self.tokens.len);
        const start = self.safeToken(self.component_start).index;
        const end = self.tokens[self.token_index].index;
        return self.input[start..end];
    }

    // The protocol has to be compiled eagerly: whether it can match a special
    // scheme decides whether an authority is expected and whether the
    // pathname defaults to "/".
    fn computeProtocolMatchesSpecialScheme(self: *ConstructorParser) Error!void {
        const component = try Component.compile(self.env, self.makeComponentString(), canonicalizeProtocol, .default);
        self.protocol_matches_special_scheme = try protocolMatchesSpecialScheme(&component, self.env.local);
    }
};

fn parseConstructorString(env: Env, input: []const u8) Error!Init {
    var parser: ConstructorParser = .{
        .env = env,
        .input = input,
        .tokens = try tokenize(env, input, .lenient),
    };
    return parser.run();
}

const special_schemes = [_][]const u8{ "http", "https", "ws", "wss", "ftp", "file" };

fn isSpecialScheme(scheme: []const u8) bool {
    for (special_schemes) |s| {
        if (std.mem.eql(u8, s, scheme)) {
            return true;
        }
    }
    return false;
}

const default_ports = std.StaticStringMap([]const u8).initComptime(.{
    .{ "http", "80" },
    .{ "https", "443" },
    .{ "ws", "80" },
    .{ "wss", "443" },
    .{ "ftp", "21" },
});

fn defaultPort(scheme: []const u8) ?[]const u8 {
    return default_ports.get(scheme);
}

fn protocolMatchesSpecialScheme(component: *const Component, local: *const js.Local) Error!bool {
    const re = component.regExp(local) catch return error.JsException;
    for (special_schemes) |scheme| {
        if (re.match(scheme) catch return error.JsException) {
            return true;
        }
    }
    return false;
}

fn isIpv6HostnamePattern(input: []const u8) bool {
    if (input.len < 2) {
        return false;
    }
    if (input[0] == '[') {
        return true;
    }
    return (input[0] == '{' or input[0] == '\\') and input[1] == '[';
}

const InitType = enum { pattern, url };

fn processInit(arena: Allocator, in: Init, comptime typ: InitType) Error!Init {
    var result: Init = .{};
    if (typ == .url) {
        // match() seeds every component with the empty string.
        inline for (component_names) |name| {
            @field(result, name) = "";
        }
    }

    var base: ?*U.Url = null;
    defer if (base) |b| U.url_free(b);

    if (in.baseURL) |base_str| {
        var err: i32 = 0;
        const b = U.url_parse(base_str.ptr, base_str.len, &err) orelse return error.TypeError;
        base = b;

        // A base component is only inherited when the init supplies nothing
        // at least as specific: protocol > hostname > port > pathname >
        // search > hash, and protocol > hostname > port > username > password.
        const has_protocol = in.protocol != null;
        const has_hostname = has_protocol or in.hostname != null;
        const has_port = has_hostname or in.port != null;
        const has_username = has_port or in.username != null;
        const has_password = has_username or in.password != null;
        const has_pathname = has_port or in.pathname != null;
        const has_search = has_pathname or in.search != null;
        const has_hash = has_search or in.hash != null;

        if (!has_protocol) {
            result.protocol = try processBaseUrlString(arena, urlScheme(b), typ);
        }
        if (typ != .pattern and !has_username) {
            result.username = try processBaseUrlString(arena, urlUsername(b), typ);
        }
        if (typ != .pattern and !has_password) {
            result.password = try processBaseUrlString(arena, urlPassword(b), typ);
        }
        if (!has_hostname) {
            result.hostname = try processBaseUrlString(arena, urlHost(b), typ);
        }
        if (!has_port) {
            result.port = try urlPort(arena, b);
        }
        if (!has_pathname) {
            result.pathname = try processBaseUrlString(arena, urlPath(b), typ);
        }
        if (!has_search) {
            result.search = try processBaseUrlString(arena, urlQuery(b), typ);
        }
        if (!has_hash) {
            result.hash = try processBaseUrlString(arena, urlFragment(b), typ);
        }
    }

    if (in.protocol) |protocol| {
        const stripped = if (std.mem.endsWith(u8, protocol, ":")) protocol[0 .. protocol.len - 1] else protocol;
        result.protocol = if (typ == .pattern) stripped else try canonicalizeProtocol(arena, stripped);
    }
    if (in.username) |username| {
        result.username = if (typ == .pattern) username else try canonicalizeUsername(arena, username);
    }
    if (in.password) |password| {
        result.password = if (typ == .pattern) password else try canonicalizePassword(arena, password);
    }
    if (in.hostname) |hostname| {
        result.hostname = if (typ == .pattern) hostname else try canonicalizeHostname(arena, hostname);
    }
    const result_protocol = result.protocol orelse "";
    if (in.port) |port| {
        result.port = if (typ == .pattern) port else try canonicalizePort(arena, port, result_protocol);
    }
    if (in.pathname) |init_pathname| {
        var pathname = init_pathname;
        if (base) |b| {
            if (!urlHasOpaquePath(b) and !isAbsolutePathname(pathname, typ)) {
                const base_path = try processBaseUrlString(arena, urlPath(b), typ);
                if (std.mem.lastIndexOfScalar(u8, base_path, '/')) |slash| {
                    pathname = try std.mem.concat(arena, u8, &.{ base_path[0 .. slash + 1], pathname });
                }
            }
        }
        if (typ == .pattern) {
            result.pathname = pathname;
        } else if (isSpecialScheme(result_protocol) or result_protocol.len == 0) {
            result.pathname = try canonicalizePathname(arena, pathname);
        } else {
            result.pathname = try canonicalizeOpaquePathname(arena, pathname);
        }
    }
    if (in.search) |search| {
        const stripped = if (std.mem.startsWith(u8, search, "?")) search[1..] else search;
        result.search = if (typ == .pattern) stripped else try canonicalizeSearch(arena, stripped);
    }
    if (in.hash) |hash| {
        const stripped = if (std.mem.startsWith(u8, hash, "#")) hash[1..] else hash;
        result.hash = if (typ == .pattern) stripped else try canonicalizeHash(arena, stripped);
    }
    return result;
}

fn processBaseUrlString(arena: Allocator, input: []const u8, comptime typ: InitType) Error![]const u8 {
    if (typ == .pattern) {
        return escapePatternAlloc(arena, input);
    }
    return arena.dupe(u8, input);
}

fn isAbsolutePathname(input: []const u8, comptime typ: InitType) bool {
    if (input.len == 0) {
        return false;
    }
    if (input[0] == '/') {
        return true;
    }
    if (typ == .url or input.len < 2) {
        return false;
    }
    return (input[0] == '\\' or input[0] == '{') and input[1] == '/';
}

// == URL record accessors (borrowed from the rust-url object) ==

fn urlScheme(url: *const U.Url) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U.url_get_scheme(url, &out, &len);
    return out[0..len];
}

fn urlUsername(url: *const U.Url) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U.url_get_username(url, &out, &len);
    return out[0..len];
}

fn urlPassword(url: *const U.Url) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    if (U.url_get_password(url, &out, &len) != 0) {
        return "";
    }
    return out[0..len];
}

fn urlHost(url: *const U.Url) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    if (U.url_get_hostname(url, &out, &len) != 0) {
        return "";
    }
    return out[0..len];
}

fn urlPort(arena: Allocator, url: *const U.Url) Error![]const u8 {
    const port = U.urlGetPort(url) orelse return "";
    return std.fmt.allocPrint(arena, "{d}", .{port});
}

fn urlPath(url: *const U.Url) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    U.url_get_path(url, &out, &len);
    return out[0..len];
}

fn urlQuery(url: *const U.Url) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    if (U.url_get_query(url, &out, &len) != 0) {
        return "";
    }
    return out[0..len];
}

fn urlFragment(url: *const U.Url) []const u8 {
    var out: [*]const u8 = undefined;
    var len: usize = 0;
    if (U.url_get_fragment(url, &out, &len) != 0) {
        return "";
    }
    return out[0..len];
}

// An opaque path is the only kind that serializes without a leading "/";
// the empty path is ambiguous but behaves the same either way for our one
// caller (no "/" to split on).
fn urlHasOpaquePath(url: *const U.Url) bool {
    const path = urlPath(url);
    return path.len > 0 and path[0] != '/';
}

fn dummyUrl() *U.Url {
    const dummy = "https://dummy.invalid/";
    var err: i32 = 0;
    return U.url_parse(dummy.ptr, dummy.len, &err) orelse unreachable;
}

// == Canonicalization (spec §3.1) ==
//
// Each takes an already-split component value (or a fixed-text piece of a
// pattern) and returns what a parsed URL would carry for it. Hostname and
// pathname go through rust-url; the rest is plain percent-encoding.

fn canonicalizeProtocol(arena: Allocator, value: []const u8) Error![]const u8 {
    if (value.len == 0) {
        return value;
    }
    const probe = try std.mem.concat(arena, u8, &.{ value, "://dummy.invalid/" });
    var err: i32 = 0;
    const url = U.url_parse(probe.ptr, probe.len, &err) orelse return error.TypeError;
    defer U.url_free(url);
    return arena.dupe(u8, urlScheme(url));
}

fn canonicalizeUsername(arena: Allocator, value: []const u8) Error![]const u8 {
    return percentEncode(arena, value, inUserinfoSet);
}

fn canonicalizePassword(arena: Allocator, value: []const u8) Error![]const u8 {
    return percentEncode(arena, value, inUserinfoSet);
}

fn canonicalizeHostname(arena: Allocator, value: []const u8) Error![]const u8 {
    if (value.len == 0) {
        return value;
    }
    // The hostname-state parse fails on a ":" outside an IPv6 literal (URL
    // §4.4 hostname state), which the shim's setter tolerates.
    var inside_brackets = false;
    for (value) |c| {
        switch (c) {
            '[' => inside_brackets = true,
            ']' => inside_brackets = false,
            ':' => if (!inside_brackets) return error.TypeError,
            else => {},
        }
    }
    const url = dummyUrl();
    defer U.url_free(url);
    if (U.url_set_hostname(url, value.ptr, value.len) != 0) {
        return error.TypeError;
    }
    return arena.dupe(u8, urlHost(url));
}

fn canonicalizeIpv6Hostname(arena: Allocator, value: []const u8) Error![]const u8 {
    const result = try arena.alloc(u8, value.len);
    for (value, result) |c, *out| {
        switch (c) {
            '0'...'9', 'a'...'f', '[', ']', ':' => out.* = c,
            'A'...'F' => out.* = std.ascii.toLower(c),
            else => return error.TypeError,
        }
    }
    return result;
}

fn canonicalizePortCallback(arena: Allocator, value: []const u8) Error![]const u8 {
    return canonicalizePort(arena, value, null);
}

fn canonicalizePort(arena: Allocator, value: []const u8, protocol: ?[]const u8) Error![]const u8 {
    if (value.len == 0) {
        return value;
    }
    // Port-state parse with a state override: tabs/newlines are dropped, the
    // leading digit run is the port and anything after it is ignored; no
    // digits at all, or overflow, is a failure.
    var port: u32 = 0;
    var digits: usize = 0;
    for (value) |c| {
        switch (c) {
            '\t', '\n', '\r' => continue,
            '0'...'9' => {
                port = port * 10 + (c - '0');
                if (port > std.math.maxInt(u16)) {
                    return error.TypeError;
                }
                digits += 1;
            },
            else => break,
        }
    }
    if (digits == 0) {
        return error.TypeError;
    }
    const serialized = try std.fmt.allocPrint(arena, "{d}", .{port});
    if (protocol) |p| {
        if (defaultPort(p)) |default| {
            if (std.mem.eql(u8, default, serialized)) {
                return "";
            }
        }
    }
    return serialized;
}

fn canonicalizePathname(arena: Allocator, value: []const u8) Error![]const u8 {
    if (value.len == 0) {
        return value;
    }
    // Pieces of a pathname (pattern prefixes/suffixes) mustn't gain a slash
    // from the parser, so we supply one — plus a "-" so a leading "." can't
    // pair with it into a dot segment — and strip both afterwards.
    const leading_slash = value[0] == '/';
    const modified = if (leading_slash) value else try std.mem.concat(arena, u8, &.{ "/-", value });

    const url = dummyUrl();
    defer U.url_free(url);
    if (U.url_set_path(url, modified.ptr, modified.len) != 0) {
        return error.TypeError;
    }
    const result = try arena.dupe(u8, urlPath(url));
    if (leading_slash) {
        return result;
    }
    return if (result.len >= 2) result[2..] else "";
}

fn canonicalizeOpaquePathname(arena: Allocator, value: []const u8) Error![]const u8 {
    return percentEncode(arena, value, inC0ControlSet);
}

fn canonicalizeSearch(arena: Allocator, value: []const u8) Error![]const u8 {
    return percentEncode(arena, value, inSpecialQuerySet);
}

fn canonicalizeHash(arena: Allocator, value: []const u8) Error![]const u8 {
    return percentEncode(arena, value, inFragmentSet);
}

fn percentEncode(arena: Allocator, value: []const u8, comptime inSet: fn (u8) bool) Error![]const u8 {
    var needed: usize = 0;
    for (value) |c| {
        if (inSet(c)) {
            needed += 1;
        }
    }
    if (needed == 0) {
        return value;
    }
    const hex = "0123456789ABCDEF";
    var out = try arena.alloc(u8, value.len + needed * 2);
    var i: usize = 0;
    for (value) |c| {
        if (inSet(c)) {
            out[i] = '%';
            out[i + 1] = hex[c >> 4];
            out[i + 2] = hex[c & 0x0F];
            i += 3;
        } else {
            out[i] = c;
            i += 1;
        }
    }
    return out;
}

// https://url.spec.whatwg.org/#percent-encoded-bytes
fn inC0ControlSet(c: u8) bool {
    return c < 0x20 or c > 0x7E;
}

fn inFragmentSet(c: u8) bool {
    return inC0ControlSet(c) or switch (c) {
        ' ', '"', '<', '>', '`' => true,
        else => false,
    };
}

fn inQuerySet(c: u8) bool {
    return inC0ControlSet(c) or switch (c) {
        ' ', '"', '#', '<', '>' => true,
        else => false,
    };
}

fn inSpecialQuerySet(c: u8) bool {
    return inQuerySet(c) or c == '\'';
}

fn inPathSet(c: u8) bool {
    return inQuerySet(c) or switch (c) {
        '?', '^', '`', '{', '}' => true,
        else => false,
    };
}

fn inUserinfoSet(c: u8) bool {
    return inPathSet(c) or switch (c) {
        '/', ':', ';', '=', '@', '[', '\\', ']', '|' => true,
        else => false,
    };
}

// == Pattern strings (spec §2) ==
//
// Tokenizer, part-list parser, and the regexp / canonical pattern string
// generators. Matching is delegated to V8's RegExp, as the spec's own algorithm
// is written in terms of RegExpBuiltinExec. Positions are byte offsets into
// the UTF-8 input rather than the spec's code point indices; every consumer
// of a position is in this file, so the two are interchangeable.

const Error = error{ TypeError, OutOfMemory, JsException, WriteFailed };

const PatternOptions = struct {
    delimiter: ?u8,
    prefix: ?u8,
    ignore_case: bool = false,

    pub const default: PatternOptions = .{ .delimiter = null, .prefix = null };
    pub const hostname: PatternOptions = .{ .delimiter = '.', .prefix = null };
    pub const pathname: PatternOptions = .{ .delimiter = '/', .prefix = '/' };
};

/// Spec "encoding callback": validates + canonicalizes a fixed-text piece of a
/// pattern for its component (percent-encoding, IDNA, ...).
const EncodingCallback = *const fn (arena: Allocator, value: []const u8) Error![]const u8;

/// Scratch allocator plus the JS local needed to (a) validate generated
/// regexps and (b) classify non-ASCII identifier code points.
const Env = struct {
    arena: Allocator,
    local: *const js.Local,

    /// Byte length of the longest valid group name at the start of `s`
    /// (ECMAScript IdentifierStart then IdentifierPart*). Zero when `s`
    /// doesn't start with a valid name.
    fn nameLen(self: Env, s: []const u8) Error!usize {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c >= 0x80) {
                return self.nameLenUnicode(s);
            }
            if (!isAsciiNameChar(c, i == 0)) {
                break;
            }
        }
        return i;
    }

    // Slow path: the name contains a non-ASCII code point, so classification
    // needs the Unicode ID_Start / ID_Continue tables. V8 has them; a RegExp
    // over the remaining input tells us where the identifier ends.
    fn nameLenUnicode(self: Env, s: []const u8) Error!usize {
        const re = js.RegExp.init(self.local, "^[\\p{ID_Start}$_][\\p{ID_Continue}$\\u200C\\u200D]*", js.RegExp.Flag.unicode) catch return error.JsException;
        const result = (re.exec(s) catch return error.JsException) orelse return 0;
        const matched = result.get("0") catch return error.JsException;
        const str = matched.isString() orelse return 0;
        return str.len();
    }

    /// Spec "is a valid name code point" for the code point at the start of
    /// `s`.
    fn isValidNameCodePoint(self: Env, s: []const u8, first: bool) Error!bool {
        if (s.len == 0) {
            return false;
        }
        if (s[0] < 0x80) {
            return isAsciiNameChar(s[0], first);
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(s[0]) catch return false;
        if (cp_len > s.len) {
            return false;
        }
        const source = if (first) "^[\\p{ID_Start}$_]" else "^[\\p{ID_Continue}$\\u200C\\u200D]";
        const re = js.RegExp.init(self.local, source, js.RegExp.Flag.unicode) catch return error.JsException;
        return re.match(s[0..cp_len]) catch return error.JsException;
    }
};

fn isAsciiNameChar(c: u8, first: bool) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '_', '$' => true,
        '0'...'9' => !first,
        else => false,
    };
}

const Token = struct {
    type: Type,
    /// Byte offset of the token's first code point in the input.
    index: usize,
    value: []const u8,

    pub const Type = enum {
        open,
        close,
        regexp,
        name,
        char,
        escaped_char,
        other_modifier,
        asterisk,
        end,
        invalid_char,
    };
};

const TokenizePolicy = enum { strict, lenient };

const Tokenizer = struct {
    env: Env,
    input: []const u8,
    policy: TokenizePolicy,
    tokens: std.ArrayList(Token) = .empty,
    index: usize = 0,

    fn add(self: *Tokenizer, typ: Token.Type, next: usize, value: []const u8) Error!void {
        try self.tokens.append(self.env.arena, .{ .type = typ, .index = self.index, .value = value });
        self.index = next;
    }

    // Every tokenizing error in the spec resolves to the same recovery: the
    // offending code point (always a single ASCII byte here) becomes an
    // "invalid-char" token and scanning resumes right after it.
    fn fail(self: *Tokenizer) Error!void {
        if (self.policy == .strict) {
            return error.TypeError;
        }
        const i = self.index;
        try self.add(.invalid_char, i + 1, self.input[i .. i + 1]);
    }

    fn cpLen(self: *const Tokenizer, at: usize) usize {
        const n = std.unicode.utf8ByteSequenceLength(self.input[at]) catch 1;
        return @min(n, self.input.len - at);
    }

    fn run(self: *Tokenizer) Error![]Token {
        const input = self.input;
        while (self.index < input.len) {
            const i = self.index;
            const c = input[i];
            switch (c) {
                '*' => try self.add(.asterisk, i + 1, input[i .. i + 1]),
                '+', '?' => try self.add(.other_modifier, i + 1, input[i .. i + 1]),
                '{' => try self.add(.open, i + 1, input[i .. i + 1]),
                '}' => try self.add(.close, i + 1, input[i .. i + 1]),
                '\\' => {
                    if (i == input.len - 1) {
                        try self.fail();
                        continue;
                    }
                    const start = i + 1;
                    const end = start + self.cpLen(start);
                    try self.add(.escaped_char, end, input[start..end]);
                },
                ':' => {
                    const start = i + 1;
                    const n = try self.env.nameLen(input[start..]);
                    if (n == 0) {
                        try self.fail();
                        continue;
                    }
                    try self.add(.name, start + n, input[start .. start + n]);
                },
                '(' => try self.regexp(),
                else => {
                    const end = i + self.cpLen(i);
                    try self.add(.char, end, input[i..end]);
                },
            }
        }
        try self.add(.end, input.len, "");
        return self.tokens.items;
    }

    fn regexp(self: *Tokenizer) Error!void {
        const input = self.input;
        const start = self.index + 1;
        var pos = start;
        var depth: usize = 1;
        while (pos < input.len) {
            const c = input[pos];
            if (c >= 0x80) {
                return self.fail();
            }
            if (pos == start and c == '?') {
                return self.fail();
            }
            if (c == '\\') {
                if (pos == input.len - 1 or input[pos + 1] >= 0x80) {
                    return self.fail();
                }
                pos += 2;
                continue;
            }
            if (c == ')') {
                depth -= 1;
                if (depth == 0) {
                    pos += 1;
                    break;
                }
            } else if (c == '(') {
                depth += 1;
                // Only non-capturing / lookaround groups may nest.
                if (pos == input.len - 1 or input[pos + 1] != '?') {
                    return self.fail();
                }
            }
            pos += 1;
        }
        if (depth != 0) {
            return self.fail();
        }
        const len = pos - start - 1;
        if (len == 0) {
            return self.fail();
        }
        try self.add(.regexp, pos, input[start .. start + len]);
    }
};

fn tokenize(env: Env, input: []const u8, policy: TokenizePolicy) Error![]Token {
    var tokenizer: Tokenizer = .{ .env = env, .input = input, .policy = policy };
    return tokenizer.run();
}

const Part = struct {
    type: Type,
    value: []const u8,
    modifier: Modifier,
    name: []const u8 = "",
    prefix: []const u8 = "",
    suffix: []const u8 = "",

    pub const Type = enum {
        fixed_text,
        regexp,
        segment_wildcard,
        full_wildcard,

        fn specificity(self: Type) u8 {
            return switch (self) {
                .full_wildcard => 0,
                .segment_wildcard => 1,
                .regexp => 2,
                .fixed_text => 3,
            };
        }
    };
    pub const Modifier = enum {
        none,
        optional,
        zero_or_more,
        one_or_more,

        fn specificity(self: Modifier) u8 {
            return switch (self) {
                .zero_or_more => 0,
                .optional => 1,
                .one_or_more => 2,
                .none => 3,
            };
        }

        fn str(self: Modifier) []const u8 {
            return switch (self) {
                .none => "",
                .optional => "?",
                .zero_or_more => "*",
                .one_or_more => "+",
            };
        }
    };
};

const full_wildcard_regexp = ".*";

fn segmentWildcardRegexp(arena: Allocator, options: PatternOptions) Error![]const u8 {
    const delimiter = options.delimiter orelse return "[^]+?";
    var buf = std.Io.Writer.Allocating.init(arena);
    try buf.writer.writeAll("[^");
    try escapeRegexp(&buf.writer, &.{delimiter});
    try buf.writer.writeAll("]+?");
    return buf.written();
}

const Parser = struct {
    env: Env,
    tokens: []const Token,
    options: PatternOptions,
    encoding: EncodingCallback,
    segment_wildcard_regexp: []const u8,
    parts: std.ArrayList(Part) = .empty,
    pending_fixed_value: std.ArrayList(u8) = .empty,
    index: usize = 0,
    next_numeric_name: usize = 0,

    fn run(self: *Parser) Error![]Part {
        while (self.index < self.tokens.len) {
            const char_token = self.tryConsume(.char);
            const name_token = self.tryConsume(.name);
            const regexp_or_wildcard = self.tryConsumeRegexpOrWildcard(name_token);
            if (name_token != null or regexp_or_wildcard != null) {
                var prefix: []const u8 = if (char_token) |t| t.value else "";
                if (prefix.len != 0 and !self.isPrefixCodePoint(prefix)) {
                    try self.pending_fixed_value.appendSlice(self.env.arena, prefix);
                    prefix = "";
                }
                try self.maybeAddPartFromPending();
                const modifier_token = self.tryConsumeModifier();
                try self.addPart(prefix, name_token, regexp_or_wildcard, "", modifier_token);
                continue;
            }

            if (char_token orelse self.tryConsume(.escaped_char)) |fixed| {
                try self.pending_fixed_value.appendSlice(self.env.arena, fixed.value);
                continue;
            }

            if (self.tryConsume(.open) != null) {
                const prefix = try self.consumeText();
                const group_name = self.tryConsume(.name);
                const group_regexp = self.tryConsumeRegexpOrWildcard(group_name);
                const suffix = try self.consumeText();
                _ = try self.consumeRequired(.close);
                const modifier_token = self.tryConsumeModifier();
                try self.addPart(prefix, group_name, group_regexp, suffix, modifier_token);
                continue;
            }

            try self.maybeAddPartFromPending();
            _ = try self.consumeRequired(.end);
        }
        return self.parts.items;
    }

    fn isPrefixCodePoint(self: *const Parser, s: []const u8) bool {
        const prefix = self.options.prefix orelse return false;
        return s.len == 1 and s[0] == prefix;
    }

    fn tryConsume(self: *Parser, typ: Token.Type) ?Token {
        const token = self.tokens[self.index];
        if (token.type != typ) {
            return null;
        }
        self.index += 1;
        return token;
    }

    fn tryConsumeModifier(self: *Parser) ?Token {
        return self.tryConsume(.other_modifier) orelse self.tryConsume(.asterisk);
    }

    fn tryConsumeRegexpOrWildcard(self: *Parser, name_token: ?Token) ?Token {
        const token = self.tryConsume(.regexp);
        if (name_token == null and token == null) {
            return self.tryConsume(.asterisk);
        }
        return token;
    }

    fn consumeRequired(self: *Parser, typ: Token.Type) Error!Token {
        return self.tryConsume(typ) orelse error.TypeError;
    }

    fn consumeText(self: *Parser) Error![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        while (self.tryConsume(.char) orelse self.tryConsume(.escaped_char)) |token| {
            try result.appendSlice(self.env.arena, token.value);
        }
        return result.items;
    }

    fn maybeAddPartFromPending(self: *Parser) Error!void {
        if (self.pending_fixed_value.items.len == 0) {
            return;
        }
        const encoded = try self.encoding(self.env.arena, self.pending_fixed_value.items);
        self.pending_fixed_value = .empty;
        try self.parts.append(self.env.arena, .{ .type = .fixed_text, .value = encoded, .modifier = .none });
    }

    fn addPart(self: *Parser, prefix: []const u8, name_token: ?Token, regexp_or_wildcard: ?Token, suffix: []const u8, modifier_token: ?Token) Error!void {
        var modifier: Part.Modifier = .none;
        if (modifier_token) |t| {
            modifier = switch (t.value[0]) {
                '?' => .optional,
                '*' => .zero_or_more,
                '+' => .one_or_more,
                else => .none,
            };
        }

        if (name_token == null and regexp_or_wildcard == null) {
            if (modifier == .none) {
                // "{foo}": plain text, merges with surrounding fixed text.
                try self.pending_fixed_value.appendSlice(self.env.arena, prefix);
                return;
            }
            // "{foo}?": the modifier keeps it a part of its own.
            try self.maybeAddPartFromPending();
            if (prefix.len == 0) {
                return;
            }
            const encoded = try self.encoding(self.env.arena, prefix);
            try self.parts.append(self.env.arena, .{ .type = .fixed_text, .value = encoded, .modifier = modifier });
            return;
        }
        try self.maybeAddPartFromPending();

        var regexp_value: []const u8 = undefined;
        if (regexp_or_wildcard) |t| {
            regexp_value = if (t.type == .asterisk) full_wildcard_regexp else t.value;
        } else {
            regexp_value = self.segment_wildcard_regexp;
        }

        // Normalize through the regexp so that "([^/]+?)" is the same part as
        // ":name" and "(.*)" the same as "*".
        var typ: Part.Type = .regexp;
        if (std.mem.eql(u8, regexp_value, self.segment_wildcard_regexp)) {
            typ = .segment_wildcard;
            regexp_value = "";
        } else if (std.mem.eql(u8, regexp_value, full_wildcard_regexp)) {
            typ = .full_wildcard;
            regexp_value = "";
        }

        var name: []const u8 = "";
        if (name_token) |t| {
            name = t.value;
        } else if (regexp_or_wildcard != null) {
            name = try std.fmt.allocPrint(self.env.arena, "{d}", .{self.next_numeric_name});
            self.next_numeric_name += 1;
        }
        for (self.parts.items) |part| {
            if (std.mem.eql(u8, part.name, name)) {
                return error.TypeError;
            }
        }

        try self.parts.append(self.env.arena, .{
            .type = typ,
            .value = regexp_value,
            .modifier = modifier,
            .name = name,
            .prefix = try self.encoding(self.env.arena, prefix),
            .suffix = try self.encoding(self.env.arena, suffix),
        });
    }
};

fn parse(env: Env, input: []const u8, options: PatternOptions, encoding: EncodingCallback) Error![]Part {
    var parser: Parser = .{
        .env = env,
        .tokens = try tokenize(env, input, .strict),
        .options = options,
        .encoding = encoding,
        .segment_wildcard_regexp = try segmentWildcardRegexp(env.arena, options),
    };
    return parser.run();
}

const Generated = struct {
    source: []const u8,
    names: []const []const u8,
};

fn generateRegexp(arena: Allocator, parts: []const Part, options: PatternOptions) Error!Generated {
    var buf = std.Io.Writer.Allocating.init(arena);
    const w = &buf.writer;
    var names: std.ArrayList([]const u8) = .empty;

    const segment_wildcard = try segmentWildcardRegexp(arena, options);

    try w.writeByte('^');
    for (parts) |part| {
        if (part.type == .fixed_text) {
            if (part.modifier == .none) {
                try escapeRegexp(w, part.value);
            } else {
                try w.writeAll("(?:");
                try escapeRegexp(w, part.value);
                try w.writeByte(')');
                try w.writeAll(part.modifier.str());
            }
            continue;
        }

        std.debug.assert(part.name.len != 0);
        try names.append(arena, part.name);

        const regexp_value = switch (part.type) {
            .segment_wildcard => segment_wildcard,
            .full_wildcard => full_wildcard_regexp,
            else => part.value,
        };

        if (part.prefix.len == 0 and part.suffix.len == 0) {
            if (part.modifier == .none or part.modifier == .optional) {
                try w.print("({s}){s}", .{ regexp_value, part.modifier.str() });
            } else {
                try w.print("((?:{s}){s})", .{ regexp_value, part.modifier.str() });
            }
            continue;
        }

        if (part.modifier == .none or part.modifier == .optional) {
            try w.writeAll("(?:");
            try escapeRegexp(w, part.prefix);
            try w.print("({s})", .{regexp_value});
            try escapeRegexp(w, part.suffix);
            try w.writeByte(')');
            try w.writeAll(part.modifier.str());
            continue;
        }

        // Repeating with prefix/suffix: the separator only appears between
        // repetitions, never before the first or after the last.
        try w.writeAll("(?:");
        try escapeRegexp(w, part.prefix);
        try w.print("((?:{s})(?:", .{regexp_value});
        try escapeRegexp(w, part.suffix);
        try escapeRegexp(w, part.prefix);
        try w.print("(?:{s}))*)", .{regexp_value});
        try escapeRegexp(w, part.suffix);
        try w.writeByte(')');
        if (part.modifier == .zero_or_more) {
            try w.writeByte('?');
        }
    }
    try w.writeByte('$');

    return .{ .source = buf.written(), .names = names.items };
}

fn generatePatternString(env: Env, parts: []const Part, options: PatternOptions) Error![]const u8 {
    var buf = std.Io.Writer.Allocating.init(env.arena);
    const w = &buf.writer;

    for (parts, 0..) |part, i| {
        const previous: ?Part = if (i > 0) parts[i - 1] else null;
        const next: ?Part = if (i + 1 < parts.len) parts[i + 1] else null;

        if (part.type == .fixed_text) {
            if (part.modifier == .none) {
                try escapePattern(w, part.value);
                continue;
            }
            try w.writeByte('{');
            try escapePattern(w, part.value);
            try w.writeByte('}');
            try w.writeAll(part.modifier.str());
            continue;
        }

        const custom_name = !std.ascii.isDigit(part.name[0]);
        var needs_grouping = part.suffix.len != 0 or (part.prefix.len != 0 and !isPrefixCodePoint(options, part.prefix));

        // ":foo" directly followed by something that would extend the name
        // has to be written "{:foo}...".
        if (!needs_grouping and custom_name and part.type == .segment_wildcard and part.modifier == .none) {
            if (next) |n| {
                if (n.prefix.len == 0 and n.suffix.len == 0) {
                    if (n.type == .fixed_text) {
                        needs_grouping = try env.isValidNameCodePoint(n.value, false);
                    } else {
                        needs_grouping = std.ascii.isDigit(n.name[0]);
                    }
                }
            }
        }

        // A group right after fixed text ending in the prefix code point
        // ("/foo/" + ":bar") must be grouped or the "/" would be re-parsed as
        // the group's own optional prefix.
        if (!needs_grouping and part.prefix.len == 0) {
            if (previous) |p| {
                if (p.type == .fixed_text and options.prefix != null and p.value.len > 0 and p.value[p.value.len - 1] == options.prefix.?) {
                    needs_grouping = true;
                }
            }
        }

        if (needs_grouping) {
            try w.writeByte('{');
        }
        try escapePattern(w, part.prefix);
        if (custom_name) {
            try w.writeByte(':');
            try w.writeAll(part.name);
        }
        switch (part.type) {
            .regexp => try w.print("({s})", .{part.value}),
            .segment_wildcard => if (!custom_name) {
                try w.print("({s})", .{try segmentWildcardRegexp(env.arena, options)});
            },
            .full_wildcard => {
                const bare = previous == null or previous.?.type == .fixed_text or previous.?.modifier != .none or needs_grouping or part.prefix.len != 0;
                if (!custom_name and bare) {
                    try w.writeByte('*');
                } else {
                    try w.print("({s})", .{full_wildcard_regexp});
                }
            },
            .fixed_text => unreachable,
        }
        if (part.type == .segment_wildcard and custom_name and part.suffix.len != 0 and try env.isValidNameCodePoint(part.suffix, false)) {
            try w.writeByte('\\');
        }
        try escapePattern(w, part.suffix);
        if (needs_grouping) {
            try w.writeByte('}');
        }
        try w.writeAll(part.modifier.str());
    }
    return buf.written();
}

fn isPrefixCodePoint(options: PatternOptions, s: []const u8) bool {
    const prefix = options.prefix orelse return false;
    return s.len == 1 and s[0] == prefix;
}

fn escapeRegexp(w: *std.Io.Writer, input: []const u8) Error!void {
    for (input) |c| {
        switch (c) {
            '.', '+', '*', '?', '^', '$', '{', '}', '(', ')', '[', ']', '|', '/', '\\' => try w.writeByte('\\'),
            else => {},
        }
        try w.writeByte(c);
    }
}

fn escapePattern(w: *std.Io.Writer, input: []const u8) Error!void {
    for (input) |c| {
        switch (c) {
            '+', '*', '?', ':', '{', '}', '(', ')', '\\' => try w.writeByte('\\'),
            else => {},
        }
        try w.writeByte(c);
    }
}

fn escapePatternAlloc(arena: Allocator, input: []const u8) Error![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);
    try escapePattern(&buf.writer, input);
    return buf.written();
}

/// A compiled component: the normalized pattern string exposed by the
/// getters, and the regexp source that matching runs through V8. The RegExp
/// itself is recreated per match — V8's compilation cache makes that cheap and
/// spares us a tracked global per component.
const Component = struct {
    pattern_string: []const u8,
    regexp_source: []const u8,
    options: PatternOptions,
    encoding: EncodingCallback,
    group_names: []const []const u8,
    has_regexp_groups: bool,

    fn compile(env: Env, input: []const u8, encoding: EncodingCallback, options: PatternOptions) Error!Component {
        const parts = try parse(env, input, options, encoding);
        const generated = try generateRegexp(env.arena, parts, options);

        var component: Component = .{
            .pattern_string = try generatePatternString(env, parts, options),
            .regexp_source = generated.source,
            .options = options,
            .encoding = encoding,
            .group_names = generated.names,
            .has_regexp_groups = false,
        };
        for (parts) |part| {
            if (part.type == .regexp) {
                component.has_regexp_groups = true;
                break;
            }
        }

        // A user-supplied "(regexp)" group can be anything; the spec wants an
        // invalid one reported now, as a TypeError, rather than at match time.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(env.local);
        defer try_catch.deinit();
        _ = component.regExp(env.local) catch return error.TypeError;

        return component;
    }

    fn regExp(self: *const Component, local: *const js.Local) !js.RegExp {
        var flags = js.RegExp.Flag.unicode_sets;
        if (self.options.ignore_case) {
            flags |= js.RegExp.Flag.ignore_case;
        }
        return js.RegExp.init(local, self.regexp_source, flags);
    }

    /// Runs the component against `input`; null when it doesn't match.
    fn exec(self: *const Component, local: *const js.Local, input: []const u8) !?js.Object {
        const re = try self.regExp(local);
        return re.exec(input);
    }

    /// Copies the compiled data out of the compile-time scratch arena.
    fn dupe(self: *const Component, arena: Allocator) !Component {
        const names = try arena.alloc([]const u8, self.group_names.len);
        for (self.group_names, names) |src, *dst| {
            dst.* = try arena.dupe(u8, src);
        }
        return .{
            .pattern_string = try arena.dupe(u8, self.pattern_string),
            .regexp_source = try arena.dupe(u8, self.regexp_source),
            .options = self.options,
            .encoding = self.encoding,
            .group_names = names,
            .has_regexp_groups = self.has_regexp_groups,
        };
    }

    // The part list isn't retained; the canonical pattern string round-trips
    // to it, and its fixed text is already encoded, so re-parse with an
    // identity callback.
    fn partList(self: *const Component, env: Env) Error![]Part {
        return parse(env, self.pattern_string, self.options, identityEncoding);
    }

    // Chromium's URLPattern.compareComponent ordering: more specific is
    // greater. Part type fixed > regexp > segment wildcard > full wildcard,
    // then modifier none > one-or-more > optional > zero-or-more, then the
    // prefix / value / suffix text bytewise. A shorter list is compared
    // against an empty fixed part so "/foo/" > "/foo/*".
    fn compare(left: *const Component, right: *const Component, env: Env) Error!i32 {
        const lhs = try left.partList(env);
        const rhs = try right.partList(env);
        const empty: Part = .{ .type = .fixed_text, .value = "", .modifier = .none };
        for (0..@max(lhs.len, rhs.len)) |i| {
            const l = if (i < lhs.len) lhs[i] else empty;
            const r = if (i < rhs.len) rhs[i] else empty;
            const order = comparePart(l, r);
            if (order != 0 or i >= lhs.len or i >= rhs.len) {
                return order;
            }
        }
        return 0;
    }

    fn comparePart(l: Part, r: Part) i32 {
        if (l.type != r.type) {
            return if (l.type.specificity() < r.type.specificity()) -1 else 1;
        }
        if (l.modifier != r.modifier) {
            return if (l.modifier.specificity() < r.modifier.specificity()) -1 else 1;
        }
        inline for (.{ "prefix", "value", "suffix" }) |field| {
            switch (std.mem.order(u8, @field(l, field), @field(r, field))) {
                .lt => return -1,
                .gt => return 1,
                .eq => {},
            }
        }
        return 0;
    }

    // Chromium's URLPattern.prototype.generate: substitute named segment
    // wildcards from `groups`; anything else that isn't plain fixed text
    // (modifiers, regexps, full wildcards, numeric names) is unsupported.
    fn generate(self: *const Component, env: Env, groups: *const std.StringHashMapUnmanaged([]const u8)) Error![]const u8 {
        var buf = std.Io.Writer.Allocating.init(env.arena);
        const w = &buf.writer;
        for (try self.partList(env)) |part| {
            if (part.modifier != .none) {
                return error.TypeError;
            }
            switch (part.type) {
                .fixed_text => try w.writeAll(part.value),
                .segment_wildcard => {
                    if (std.ascii.isDigit(part.name[0])) {
                        return error.TypeError;
                    }
                    const raw = groups.get(part.name) orelse return error.TypeError;
                    const value = try self.encoding(env.arena, raw);
                    if (self.options.delimiter) |delimiter| {
                        if (std.mem.indexOfScalar(u8, value, delimiter) != null) {
                            return error.TypeError;
                        }
                    }
                    try w.writeAll(part.prefix);
                    try w.writeAll(value);
                    try w.writeAll(part.suffix);
                },
                .regexp, .full_wildcard => return error.TypeError,
            }
        }
        return buf.written();
    }
};

fn identityEncoding(_: Allocator, value: []const u8) Error![]const u8 {
    return value;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(URLPattern);

    pub const Meta = struct {
        pub const name = "URLPattern";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(URLPattern.init, .{});
    pub const protocol = bridge.accessor(URLPattern.getProtocol, null, .{});
    pub const username = bridge.accessor(URLPattern.getUsername, null, .{});
    pub const password = bridge.accessor(URLPattern.getPassword, null, .{});
    pub const hostname = bridge.accessor(URLPattern.getHostname, null, .{});
    pub const port = bridge.accessor(URLPattern.getPort, null, .{});
    pub const pathname = bridge.accessor(URLPattern.getPathname, null, .{});
    pub const search = bridge.accessor(URLPattern.getSearch, null, .{});
    pub const hash = bridge.accessor(URLPattern.getHash, null, .{});
    pub const hasRegExpGroups = bridge.accessor(URLPattern.getHasRegExpGroups, null, .{});
    pub const @"test" = bridge.function(URLPattern.testFn, .{});
    pub const exec = bridge.function(URLPattern.execFn, .{});
    pub const compareComponent = bridge.function(URLPattern.compareComponent, .{ .static = true });
    pub const generate = bridge.function(URLPattern.generate, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: URLPattern" {
    try testing.htmlRunner("urlpattern.html", .{});
}
