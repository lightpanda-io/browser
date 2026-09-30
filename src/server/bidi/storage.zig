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

// Cookies: the storage module, and the core the HTTP session's /cookie
// commands share with it. There's one cookie jar per user context and no
// partitioning by site, so a partition resolves to the current user context.

const std = @import("std");
const lp = @import("lightpanda");

const Cookie = @import("../../browser/webapi/storage/Cookie.zig");

const BiDi = @import("BiDi.zig");
const browsing_context = @import("browsing_context.zig");

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *BiDi.Command, action: []const u8) !void {
    const command = std.meta.stringToEnum(enum {
        getCookies,
        setCookie,
        deleteCookies,
    }, action) orelse return error.UnknownCommand;

    switch (command) {
        .getCookies => return getCookies(cmd),
        .setCookie => return setCookie(cmd),
        .deleteCookies => return deleteCookies(cmd),
    }
}

// A cookie as a driver hands it over.
pub const Spec = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    expiry: ?u64 = null, // seconds since the epoch, null for a session cookie
    same_site: ?Cookie.SameSite = null, // null: unspecified, Lax by default
};

pub fn add(jar: *Cookie.Jar, spec: Spec, url: ?[:0]const u8) !void {
    const cookie: Cookie = blk: {
        if (isValidPart(spec.name, "=;") == false or isValidPart(spec.value, ";") == false) {
            return error.UnableToSetCookie;
        }
        if (spec.same_site == .none and spec.secure == false) {
            // the store refuses SameSite=None without Secure, as Set-Cookie does
            return error.UnableToSetCookie;
        }

        var arena = std.heap.ArenaAllocator.init(jar.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        // Allocate before the struct literal copies `arena` into the result.
        const name = try a.dupe(u8, spec.name);
        const value = try a.dupe(u8, spec.value);
        const domain = Cookie.parseDomain(a, url, spec.domain) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidDomain,
        };
        const path = Cookie.parsePath(a, null, spec.path) catch return error.OutOfMemory;

        break :blk .{
            .arena = arena,
            .name = name,
            .value = value,
            .domain = domain,
            .path = path,
            .expires = if (spec.expiry) |expiry| @floatFromInt(expiry) else null,
            .secure = spec.secure,
            .http_only = spec.http_only,
            .same_site = spec.same_site orelse .lax,
            .same_site_default = spec.same_site == null,
        };
    };

    jar.add(cookie, lp.datetime.timestamp(.real), true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnableToSetCookie,
    };
}

// What Cookie.parse accepts, minus the separators a Cookie header would
// read differently.
fn isValidPart(part: []const u8, comptime separators: []const u8) bool {
    for (part) |c| {
        if ((c < 32 and c != '\t') or c > 126) {
            return false;
        }
        if (std.mem.indexOfScalar(u8, separators, c) != null) {
            return false;
        }
    }
    return true;
}

// The cookies a navigation to `url` would carry, HttpOnly ones included:
// what the HTTP session's cookie commands see and delete. Optionally, only
// those called `name`.
pub const Associated = struct {
    url: Cookie.PreparedUri,
    name: ?[]const u8,

    pub fn init(url: [:0]const u8, name: ?[]const u8) Associated {
        return .{ .url = .init(url), .name = name };
    }

    pub fn has(self: *const Associated, cookie: *const Cookie) bool {
        if (self.name) |name| {
            if (std.mem.eql(u8, name, cookie.name) == false) {
                return false;
            }
        }
        return cookie.appliesTo(&self.url, .{ .same_site = true, .is_http = true, .kind = .navigation });
    }
};

// Removes the cookies `matches` accepts, `context` being its first argument.
pub fn remove(jar: *Cookie.Jar, context: anytype, comptime matches: fn (@TypeOf(context), *const Cookie) bool) void {
    const cookies = &jar.cookies;
    var i = cookies.items.len;
    while (i > 0) {
        i -= 1;
        if (matches(context, &cookies.items[i])) {
            cookies.swapRemove(i).deinit();
        }
    }
}

// A cookie in the HTTP session's shape.
pub const HttpCookie = struct {
    cookie: *const Cookie,

    pub fn jsonStringify(self: HttpCookie, jws: anytype) !void {
        const cookie = self.cookie;
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(cookie.name);
        try jws.objectField("value");
        try jws.write(cookie.value);
        try jws.objectField("path");
        try jws.write(cookie.path);
        try jws.objectField("domain");
        try jws.write(cookie.domain);
        try jws.objectField("secure");
        try jws.write(cookie.secure);
        try jws.objectField("httpOnly");
        try jws.write(cookie.http_only);
        if (cookie.expires) |expires| {
            try jws.objectField("expiry");
            try jws.write(@as(i64, @intFromFloat(expires)));
        }
        try jws.objectField("sameSite");
        try jws.write(switch (cookie.same_site) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        });
        try jws.endObject();
    }
};

// A network.Cookie.
const BiDiCookie = struct {
    cookie: *const Cookie,

    pub fn jsonStringify(self: BiDiCookie, jws: anytype) !void {
        const cookie = self.cookie;
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(cookie.name);
        try jws.objectField("value");
        try jws.write(.{ .type = "string", .value = cookie.value });
        try jws.objectField("domain");
        try jws.write(cookie.domain);
        try jws.objectField("path");
        try jws.write(cookie.path);
        try jws.objectField("size");
        try jws.write(cookie.name.len + cookie.value.len);
        try jws.objectField("httpOnly");
        try jws.write(cookie.http_only);
        try jws.objectField("secure");
        try jws.write(cookie.secure);
        try jws.objectField("sameSite");
        try jws.write(@tagName(sameSite(cookie)));
        if (cookie.expires) |expires| {
            try jws.objectField("expiry");
            try jws.write(@as(i64, @intFromFloat(expires)));
        }
        try jws.endObject();
    }
};

const SameSite = enum { strict, lax, none, default };

fn sameSite(cookie: *const Cookie) SameSite {
    if (cookie.same_site_default) {
        return .default;
    }
    return switch (cookie.same_site) {
        inline else => |tag| @field(SameSite, @tagName(tag)),
    };
}

// network.BytesValue
const BytesValue = struct {
    type: enum { string, base64 },
    value: []const u8,

    fn decode(self: BytesValue, arena: Allocator) ![]const u8 {
        switch (self.type) {
            .string => return self.value,
            .base64 => {
                const decoder = std.base64.standard.Decoder;
                const buf = try arena.alloc(u8, try decoder.calcSizeForSlice(self.value));
                try decoder.decode(buf, self.value);
                return buf;
            },
        }
    }
};

const PartitionDescriptor = struct {
    type: enum { context, storageKey },
    context: ?[]const u8 = null,
    userContext: ?[]const u8 = null,
    sourceOrigin: ?[]const u8 = null,
};

// The partition key of the user context `partition` names. Answers the
// command and returns null when it names something we don't have.
fn resolvePartition(cmd: *BiDi.Command, partition: ?PartitionDescriptor) !?[]const u8 {
    const bidi = cmd.bidi;
    const current = bidi.user_context.id();

    const p = partition orelse return try requireUserContext(cmd, "default");
    switch (p.type) {
        .context => {
            const context = p.context orelse {
                try cmd.sendError("invalid argument", "partition.context is required");
                return null;
            };
            _ = (try browsing_context.requireContext(cmd, context)) orelse return null;
            return current;
        },
        .storageKey => return try requireUserContext(cmd, p.userContext orelse "default"),
    }
}

fn requireUserContext(cmd: *BiDi.Command, id: []const u8) !?[]const u8 {
    const current = cmd.bidi.user_context.id();
    if (std.mem.eql(u8, id, current)) {
        return current;
    }
    if (std.mem.eql(u8, id, "default")) {
        // replaced by the one createUserContext made, which has the jar
        try cmd.sendError("unsupported operation", "only the current user context's cookies are reachable");
        return null;
    }
    try cmd.sendError("no such user context", "unknown user context");
    return null;
}

// storage.CookieFilter: a cookie matches when every field given is equal.
const Filter = struct {
    name: ?[]const u8 = null,
    value: ?BytesValue = null,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    size: ?u64 = null,
    httpOnly: ?bool = null,
    secure: ?bool = null,
    sameSite: ?SameSite = null,
    expiry: ?u64 = null,

    // so that `matches` compares strings
    fn decode(self: *Filter, arena: Allocator) !void {
        if (self.value) |value| {
            self.value = .{ .type = .string, .value = try value.decode(arena) };
        }
    }

    fn matches(self: *const Filter, cookie: *const Cookie) bool {
        if (self.name) |name| if (std.mem.eql(u8, name, cookie.name) == false) return false;
        if (self.value) |value| if (std.mem.eql(u8, value.value, cookie.value) == false) return false;
        if (self.domain) |domain| if (std.mem.eql(u8, domain, cookie.domain) == false) return false;
        if (self.path) |path| if (std.mem.eql(u8, path, cookie.path) == false) return false;
        if (self.size) |size| if (size != cookie.name.len + cookie.value.len) return false;
        if (self.httpOnly) |http_only| if (http_only != cookie.http_only) return false;
        if (self.secure) |secure| if (secure != cookie.secure) return false;
        if (self.sameSite) |same_site| if (same_site != sameSite(cookie)) return false;
        if (self.expiry) |expiry| {
            const expires = cookie.expires orelse return false;
            if (@as(f64, @floatFromInt(expiry)) != expires) return false;
        }
        return true;
    }
};

fn getCookies(cmd: *BiDi.Command) !void {
    const p = try cmd.params(struct {
        filter: Filter = .{},
        partition: ?PartitionDescriptor = null,
    });
    const user_context = (try resolvePartition(cmd, p.partition)) orelse return;

    var filter = p.filter;
    filter.decode(cmd.arena) catch return cmd.sendError("invalid argument", "invalid filter.value");

    const jar = &cmd.bidi.user_context.session.cookie_jar;
    jar.removeExpired(null);

    var cookies: std.ArrayList(BiDiCookie) = .empty;
    for (jar.cookies.items) |*cookie| {
        if (filter.matches(cookie)) {
            try cookies.append(cmd.arena, .{ .cookie = cookie });
        }
    }
    return cmd.sendResult(.{
        .cookies = cookies.items,
        .partitionKey = .{ .userContext = user_context },
    });
}

fn setCookie(cmd: *BiDi.Command) !void {
    const p = try cmd.params(struct {
        cookie: struct {
            name: []const u8,
            value: BytesValue,
            domain: []const u8,
            path: ?[]const u8 = null,
            httpOnly: bool = false,
            secure: bool = false,
            sameSite: ?SameSite = null,
            expiry: ?u64 = null,
        },
        partition: ?PartitionDescriptor = null,
    });
    const user_context = (try resolvePartition(cmd, p.partition)) orelse return;

    const c = p.cookie;
    const value = c.value.decode(cmd.arena) catch return cmd.sendError("invalid argument", "invalid cookie.value");
    const spec: Spec = .{
        .name = c.name,
        .value = value,
        .domain = c.domain,
        .path = c.path,
        .secure = c.secure,
        .http_only = c.httpOnly,
        .expiry = c.expiry,
        .same_site = if (c.sameSite) |same_site| switch (same_site) {
            .default => null,
            inline else => |tag| @field(Cookie.SameSite, @tagName(tag)),
        } else null,
    };

    add(&cmd.bidi.user_context.session.cookie_jar, spec, null) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidDomain, error.UnableToSetCookie => return cmd.sendError("unable to set cookie", @errorName(err)),
    };
    return cmd.sendResult(.{ .partitionKey = .{ .userContext = user_context } });
}

fn deleteCookies(cmd: *BiDi.Command) !void {
    const p = try cmd.params(struct {
        filter: Filter = .{},
        partition: ?PartitionDescriptor = null,
    });
    const user_context = (try resolvePartition(cmd, p.partition)) orelse return;

    var filter = p.filter;
    filter.decode(cmd.arena) catch return cmd.sendError("invalid argument", "invalid filter.value");

    remove(&cmd.bidi.user_context.session.cookie_jar, &filter, Filter.matches);
    return cmd.sendResult(.{ .partitionKey = .{ .userContext = user_context } });
}

const testing = @import("testing.zig");
test "bidi.storage: cookies" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const context_id = try ctx.createContext(.{});

    try ctx.processMessage(.{
        .id = 1,
        .method = "storage.setCookie",
        .params = .{ .cookie = .{
            .name = "a",
            .value = .{ .type = "string", .value = "1" },
            .domain = "example.com",
            .path = "/app",
            .httpOnly = true,
            .expiry = 4102444800,
        } },
    });
    try ctx.expectSentResult(.{ .partitionKey = .{ .userContext = "default" } }, .{ .id = 1 });

    // base64 value, explicit partition
    try ctx.processMessage(.{
        .id = 2,
        .method = "storage.setCookie",
        .params = .{
            .cookie = .{ .name = "b", .value = .{ .type = "base64", .value = "Mg==" }, .domain = "other.com", .sameSite = "strict" },
            .partition = .{ .type = "context", .context = context_id },
        },
    });
    try ctx.expectSentResult(.{ .partitionKey = .{ .userContext = "default" } }, .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "storage.getCookies", .params = struct {}{} });
    try ctx.expectSentResult(.{
        .cookies = .{
            .{ .name = "a", .value = .{ .type = "string", .value = "1" }, .domain = ".example.com", .path = "/app", .size = 2, .httpOnly = true, .secure = false, .sameSite = "default", .expiry = 4102444800 },
            .{ .name = "b", .value = .{ .type = "string", .value = "2" }, .domain = ".other.com", .path = "/", .sameSite = "strict" },
        },
        .partitionKey = .{ .userContext = "default" },
    }, .{ .id = 3 });

    try ctx.processMessage(.{ .id = 4, .method = "storage.getCookies", .params = .{ .filter = .{ .value = .{ .type = "base64", .value = "Mg==" } } } });
    try ctx.expectSentResult(.{ .cookies = .{.{ .name = "b" }} }, .{ .id = 4 });

    try ctx.processMessage(.{ .id = 5, .method = "storage.deleteCookies", .params = .{ .filter = .{ .name = "a" } } });
    try ctx.expectSentResult(.{ .partitionKey = .{ .userContext = "default" } }, .{ .id = 5 });
    try testing.expectEqual(1, ctx.bidi().user_context.session.cookie_jar.cookies.items.len);
    try testing.expectEqual("b", ctx.bidi().user_context.session.cookie_jar.cookies.items[0].name);

    // SameSite=None needs Secure
    try ctx.processMessage(.{
        .id = 6,
        .method = "storage.setCookie",
        .params = .{ .cookie = .{ .name = "c", .value = .{ .type = "string", .value = "3" }, .domain = "example.com", .sameSite = "none" } },
    });
    try ctx.expectSentError("unable to set cookie", null, .{ .id = 6 });

    // a separator in the name, a public suffix for a domain
    try ctx.processMessage(.{
        .id = 7,
        .method = "storage.setCookie",
        .params = .{ .cookie = .{ .name = "c;d", .value = .{ .type = "string", .value = "3" }, .domain = "example.com" } },
    });
    try ctx.expectSentError("unable to set cookie", null, .{ .id = 7 });
    try ctx.processMessage(.{
        .id = 8,
        .method = "storage.setCookie",
        .params = .{ .cookie = .{ .name = "c", .value = .{ .type = "string", .value = "3" }, .domain = "com" } },
    });
    try ctx.expectSentError("unable to set cookie", null, .{ .id = 8 });

    try ctx.processMessage(.{ .id = 9, .method = "storage.getCookies", .params = .{ .partition = .{ .type = "context", .context = "nope" } } });
    try ctx.expectSentError("no such frame", null, .{ .id = 9 });
    try ctx.processMessage(.{ .id = 10, .method = "storage.getCookies", .params = .{ .partition = .{ .type = "storageKey", .userContext = "nope" } } });
    try ctx.expectSentError("no such user context", null, .{ .id = 10 });

    // clears the rest
    try ctx.processMessage(.{ .id = 11, .method = "storage.deleteCookies", .params = struct {}{} });
    try ctx.expectSentResult(.{ .partitionKey = .{ .userContext = "default" } }, .{ .id = 11 });
    try testing.expectEqual(0, ctx.bidi().user_context.session.cookie_jar.cookies.items.len);
}
