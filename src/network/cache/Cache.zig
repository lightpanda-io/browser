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
const lp = @import("lightpanda");

const Http = @import("../http.zig");

const SqliteCache = @import("SqliteCache.zig");

pub var noop: Cache = .{ .kind = .noop };

const log = lp.log;

/// A browser-wide cache for resources across the network.
/// This mostly conforms to RFC9111 with regards to caching behavior.
pub const Cache = @This();

kind: union(enum) {
    noop: void,
    sqlite: SqliteCache,
},

pub fn init(allocator: std.mem.Allocator, config: *const lp.Config) !Cache {
    const cache_path = config.httpCacheDir() orelse {
        return .{ .kind = .noop };
    };

    const sqlite = SqliteCache.init(
        allocator,
        .{ .path = cache_path },
        config.httpCacheEntryLimit(),
    ) catch |err| {
        log.err(.cache, "failed to init", .{
            .kind = "SqliteCache",
            .path = cache_path,
            .err = err,
        });
        return err;
    };

    return .{
        .kind = .{ .sqlite = sqlite },
    };
}

pub fn deinit(self: *Cache) void {
    return switch (self.kind) {
        .noop => {},
        inline else => |*c| c.deinit(),
    };
}

pub fn active(self: *Cache) ?*Cache {
    return switch (self.kind) {
        .noop => null,
        inline else => self,
    };
}

pub fn get(self: *Cache, arena: std.mem.Allocator, req: CacheGetRequest) !CacheGetResult {
    return switch (self.kind) {
        .noop => .miss,
        inline else => |*c| c.get(arena, req),
    };
}

pub fn put(self: *Cache, req: CachePutRequest, body: []const u8) !void {
    return switch (self.kind) {
        .noop => {},
        inline else => |*c| c.put(req, body),
    };
}

pub fn evict(self: *Cache, url: []const u8) void {
    return switch (self.kind) {
        .noop => {},
        inline else => |*c| c.evict(url),
    };
}

pub fn renew(self: *Cache, arena: std.mem.Allocator, req: RenewResponse) !void {
    return switch (self.kind) {
        .noop => {},
        inline else => |*c| c.renew(arena, req),
    };
}

pub fn clear(self: *Cache) !void {
    return switch (self.kind) {
        .noop => {},
        inline else => |*c| c.clear(),
    };
}

pub fn maintenance(self: *Cache, now: u64) void {
    return switch (self.kind) {
        .noop => {},
        inline else => |*c| c.maintenance(now),
    };
}

/// RFC 9111 delta-seconds values larger than this are capped rather than
/// rejected (§1.2.2). Capping also keeps the value safely castable to i64
/// for freshness arithmetic and storage.
const max_delta_seconds: u64 = 2147483648;

pub fn parseDeltaSeconds(value: []const u8) ?u64 {
    const seconds = std.fmt.parseInt(u64, value, 10) catch |err| switch (err) {
        error.Overflow => return max_delta_seconds,
        error.InvalidCharacter => return null,
    };
    return @min(seconds, max_delta_seconds);
}

pub const CacheControl = struct {
    max_age: u64,
    must_revalidate: bool = false,
};

pub const ResponseDirectives = struct {
    no_store: bool = false,
    no_cache: bool = false,
    private: bool = false,
    public: bool = false,
    max_age: ?u64 = null,
    s_maxage: ?u64 = null,

    pub fn parse(value: []const u8) ResponseDirectives {
        var directives: ResponseDirectives = .{};

        var iter = std.mem.splitScalar(u8, value, ',');
        while (iter.next()) |part| {
            const directive = std.mem.trim(u8, part, &std.ascii.whitespace);

            // We only care about argument for max-age/s-maxage. For something like
            // `no-cache="set-cookie"` we ignore it and just treat it as "no-cache"
            // which is on the safe side.
            const name, const argument = if (std.mem.indexOfScalar(u8, directive, '=')) |i|
                .{ directive[0..i], directive[i + 1 ..] }
            else
                .{ directive, "" };

            if (std.ascii.eqlIgnoreCase(name, "no-store")) {
                directives.no_store = true;
            } else if (std.ascii.eqlIgnoreCase(name, "no-cache")) {
                directives.no_cache = true;
            } else if (std.ascii.eqlIgnoreCase(name, "private")) {
                directives.private = true;
            } else if (std.ascii.eqlIgnoreCase(name, "public")) {
                directives.public = true;
            } else if (std.ascii.eqlIgnoreCase(name, "max-age")) {
                directives.max_age = parseDeltaSeconds(argument);
            } else if (std.ascii.eqlIgnoreCase(name, "s-maxage")) {
                directives.s_maxage = parseDeltaSeconds(argument);
            }
        }

        return directives;
    }
};

pub const CacheGetRequest = struct {
    url: []const u8,
    timestamp: u64,
    request_headers: []const Http.Header,
};

pub const CachePutRequest = struct {
    url: [:0]const u8,
    content_type: []const u8,

    status: u16,
    stored_at: u64,
    age_at_store: u64,

    cache_control: CacheControl,
    /// Response Headers
    headers: []const Http.Header,
    /// These are Request Headers used by Vary.
    vary_headers: []const Http.Header,

    // Validators for conditional requests.
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,

    pub fn format(self: CachePutRequest, writer: *std.Io.Writer) !void {
        try writer.print("url={s} | status={d} | content_type={s} | max_age={d} | etag={s} | last-modified={s} | vary=[", .{
            self.url,
            self.status,
            self.content_type,
            self.cache_control.max_age,
            self.etag orelse "null",
            self.last_modified orelse "null",
        });

        // Logging all headers gets pretty verbose...
        // so we just log the Vary ones that matter for caching.

        if (self.vary_headers.len > 0) {
            for (self.vary_headers, 0..) |hdr, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("{s}: {s}", .{ hdr.name, hdr.value });
            }
        }
        try writer.print("]", .{});
    }
};

pub const RenewResponse = struct {
    url: []const u8,
    timestamp: u64,
    headers: []const Http.Header,

    // What a revalidation response tells us about the cache entry (a null
    // value means: we were told nothing, keep what we have)
    pub const Directive = struct {
        timestamp: u64,
        age_at_store: u64,
        max_age: ?u64,
        must_revalidate: ?bool,
        content_type: ?[]const u8,
        etag: ?[]const u8,
        last_modified: ?[]const u8,
    };

    pub fn directive(self: RenewResponse) Directive {
        const response: ResponseHeaders = .parse(self.headers);
        const cache_control = explicitFreshness(self.timestamp, response.directives, response.expires, response.date);

        return .{
            .timestamp = self.timestamp,
            .age_at_store = if (response.age) |a| parseDeltaSeconds(a) orelse 0 else 0,
            .max_age = if (cache_control) |cc| cc.max_age else null,
            .must_revalidate = if (cache_control) |cc| cc.must_revalidate else null,
            .content_type = response.content_type,
            .etag = response.etag,
            .last_modified = response.last_modified,
        };
    }
};

const CachedData = union(enum) {
    buffer: []const u8,

    pub fn deinit(self: CachedData) void {
        switch (self) {
            .buffer => {},
        }
    }

    pub fn format(self: CachedData, writer: *std.Io.Writer) !void {
        switch (self) {
            .buffer => |buf| try writer.print("buffer({d} bytes)", .{buf.len}),
        }
    }
};

pub const CacheGetResult = union(enum) {
    // Fresh / Usable as is.
    hit: CachedResponse,
    /// Stale but has proper revalidators. Caller should make a conditional request and then
    /// renew or put depending on Response.
    revalidate: CachedResponse,
    /// Cache Miss.
    miss,
    /// Stale entry with no revalidators. Must call `evict()` and should be treated as a miss.
    stale,
};

pub const CachedResponse = struct {
    status: u16,
    content_type: []const u8,
    etag: ?[]const u8,
    last_modified: ?[]const u8,
    headers: []const Http.Header,
    data: CachedData,

    pub fn format(self: *const CachedResponse, writer: *std.Io.Writer) !void {
        try writer.print("status={d} | content_type={s} | etag={s} | last-modified={s} | ", .{
            self.status,
            self.content_type,
            self.etag orelse "null",
            self.last_modified orelse "null",
        });
        try self.data.format(writer);
    }
};

// Cache-related headers (for storing a new one and/or renewing)
const ResponseHeaders = struct {
    directives: ResponseDirectives = .{},
    content_type: ?[]const u8 = null,
    date: ?[]const u8 = null,
    expires: ?[]const u8 = null,
    vary: ?[]const u8 = null,
    age: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    has_set_cookie: bool = false,
    has_authorization: bool = false,

    fn parse(headers: []const Http.Header) ResponseHeaders {
        var self: ResponseHeaders = .{};

        for (headers) |h| {
            switch (h.name.len) {
                3 => if (std.ascii.eqlIgnoreCase(h.name, "Age")) {
                    self.age = h.value;
                },
                4 => {
                    if (std.ascii.eqlIgnoreCase(h.name, "Date")) {
                        self.date = h.value;
                    } else if (std.ascii.eqlIgnoreCase(h.name, "ETag")) {
                        self.etag = h.value;
                    } else if (std.ascii.eqlIgnoreCase(h.name, "Vary")) {
                        self.vary = h.value;
                    }
                },
                7 => if (std.ascii.eqlIgnoreCase(h.name, "Expires")) {
                    self.expires = h.value;
                },
                10 => if (std.ascii.eqlIgnoreCase(h.name, "Set-Cookie")) {
                    self.has_set_cookie = true;
                },
                12 => if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
                    self.content_type = h.value;
                },
                13 => {
                    if (std.ascii.eqlIgnoreCase(h.name, "Cache-Control")) {
                        self.directives = .parse(h.value);
                    } else if (std.ascii.eqlIgnoreCase(h.name, "Last-Modified")) {
                        self.last_modified = h.value;
                    } else if (std.ascii.eqlIgnoreCase(h.name, "Authorization")) {
                        self.has_authorization = true;
                    }
                },
                else => {},
            }
        }

        return self;
    }
};

const CacheCandidate = struct {
    timestamp: u64,
    url: [:0]const u8,
    status: u16,
    content_type: ?[]const u8, // from ResponseHead, can be truncated
    headers: []const Http.Header,
    request_headers: []const Http.Header, // needed for vary headers
};

fn explicitFreshness(timestamp: u64, directives: ResponseDirectives, expires_: ?[]const u8, date: ?[]const u8) ?CacheControl {
    if (directives.no_cache) {
        // Storable, but every use has to revalidate first.
        return .{ .max_age = directives.max_age orelse 0, .must_revalidate = true };
    }

    // The value Chrome/Firefox would use...
    const lifetime = directives.max_age orelse expiresLifetime(timestamp, expires_, date);

    // ... but our store is shared across session, so we also behave like a
    // shared cache, a shared cache that the user can't purge (like their own CDN)
    // So, we'll consider s-maxage, but it can only shorten the value
    const max_age = lifetime orelse directives.s_maxage orelse return null;
    return .{ .max_age = @min(max_age, directives.s_maxage orelse max_age) };
}

fn expiresLifetime(timestamp: u64, expires_: ?[]const u8, date: ?[]const u8) ?u64 {
    const expires = expires_ orelse return null;

    // an unparsable value is considered expired
    const expires_at = parseHttpDate(expires) orelse return 0;
    const sent_at = if (date) |d| parseHttpDate(d) orelse @as(i64, @intCast(timestamp)) else @as(i64, @intCast(timestamp));
    if (expires_at <= sent_at) {
        return 0;
    }
    return @min(@as(u64, @intCast(expires_at - sent_at)), max_delta_seconds);
}

pub fn tryCache(arena: std.mem.Allocator, candidate: CacheCandidate) !?CachePutRequest {
    const url = candidate.url;
    const status = candidate.status;
    const response: ResponseHeaders = .parse(candidate.headers);

    if (status == 206 or (status >= 300 and status < 400)) {
        // TODO
        // Could be cached, but HttpClient doesn't handle this correctly, it
        // just writes the response instead of actually processing it.
        log.debug(.cache, "no store", .{ .url = url, .code = status, .reason = "status" });
        return null;
    }

    if (response.has_set_cookie) {
        log.debug(.cache, "no store", .{ .url = url, .reason = "has_cookies" });
        return null;
    }

    if (response.has_authorization) {
        log.debug(.cache, "no store", .{ .url = url, .reason = "has_authorization" });
        return null;
    }

    if (response.vary) |v| if (std.mem.eql(u8, v, "*")) {
        log.debug(.cache, "no store", .{ .url = url, .vary = v, .reason = "vary" });
        return null;
    };

    const cc: CacheControl = blk: {
        const directives = response.directives;
        // "private" bars shared cache, which is how our caching works - tied
        // to the app while the cookie jar is on the Session. Safer not to cache.
        if (directives.no_store or directives.private) {
            break :blk null;
        }
        const timestamp = candidate.timestamp;
        if (explicitFreshness(timestamp, directives, response.expires, response.date)) |cc| {
            if (cc.max_age == 0 and cc.must_revalidate == false) {
                // Already stale on arrival, with nothing to revalidate it against.
                break :blk null;
            }
            break :blk cc;
        }

        if (heuristicallyCacheable(status) == false and directives.public == false) {
            // Need a cacheable status and a public cache to use heuristic caching
            break :blk null;
        }
        // also need a last_modified
        const last_modified = response.last_modified orelse break :blk null;
        const lifetime = heuristicLifetime(last_modified, timestamp);
        break :blk if (lifetime == 0) null else CacheControl{ .max_age = lifetime };
    } orelse {
        log.debug(.cache, "no store", .{
            .url = url,
            .reason = "not fresh",
            .expires = response.expires orelse "null",
            .last_modified = response.last_modified orelse "null",
        });
        return null;
    };

    // get() treats must_revalidate as always-expired, so without validators
    // the entry could never be served, only purged.
    if (cc.must_revalidate and response.etag == null and response.last_modified == null) {
        log.debug(.cache, "no store", .{ .url = url, .reason = "must_revalidate without validators" });
        return null;
    }

    return .{
        .url = try arena.dupeZ(u8, url),
        .content_type = if (candidate.content_type) |ct| try arena.dupe(u8, ct) else "application/octet-stream",
        .status = status,
        .stored_at = candidate.timestamp,
        .age_at_store = if (response.age) |a| parseDeltaSeconds(a) orelse 0 else 0,
        .cache_control = cc,
        .headers = candidate.headers,
        .vary_headers = try varyHeaders(arena, response.vary, candidate.request_headers),
        .etag = if (response.etag) |e| try arena.dupe(u8, e) else null,
        .last_modified = if (response.last_modified) |lm| try arena.dupe(u8, lm) else null,
    };
}

fn heuristicallyCacheable(status: u16) bool {
    return switch (status) {
        // tryCache discards 206 and redirects, so skip them early here
        200, 203, 204, 404, 405, 410, 414, 501 => true,
        else => false,
    };
}

/// RFC 9111 §4.2.2 suggests 10% of the interval since Last-Modified. The cap
/// keeps a document that has not changed in years from being held forever.
fn heuristicLifetime(last_modified: []const u8, now: u64) u64 {
    const modified_at = parseHttpDate(last_modified) orelse return 0;
    const now_seconds: i64 = @intCast(now);
    if (modified_at >= now_seconds) {
        return 0;
    }
    const heuristic_max_age: u64 = 86400;
    return @min(@as(u64, @intCast(now_seconds - modified_at)) / 10, heuristic_max_age);
}

fn parseHttpDate(value: []const u8) ?i64 {
    const date_time = lp.datetime.DateTime.parse(value, .rfc822) catch return null;
    return date_time.unix(.seconds);
}

/// The request headers the Vary list names, which a later lookup has to match
/// against. Names and values stay borrowed from the caller's headers.
fn varyHeaders(arena: std.mem.Allocator, vary: ?[]const u8, request_headers: []const Http.Header) ![]const Http.Header {
    const vary_value = vary orelse return &.{};

    var headers: std.ArrayList(Http.Header) = .empty;
    for (request_headers) |hdr| {
        var iter = std.mem.splitScalar(u8, vary_value, ',');
        while (iter.next()) |part| {
            const name = std.mem.trim(u8, part, &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(hdr.name, name)) {
                try headers.append(arena, hdr);
            }
        }
    }
    return headers.items;
}

const testing = @import("../../testing.zig");
test "Cache: ResponseDirectives.parse" {
    try testing.expectEqual(300, ResponseDirectives.parse("max-age=300").max_age);
    try testing.expectEqual(300, ResponseDirectives.parse("Max-Age=300").max_age);
    try testing.expectEqual(300, ResponseDirectives.parse("MAX-AGE=300").max_age);
    try testing.expectEqual(300, ResponseDirectives.parse("public, max-age=300").max_age);
    try testing.expectEqual(300, ResponseDirectives.parse("  max-age=300  ").max_age);

    // kept apart, explicitFreshness decides how they combine
    try testing.expectEqual(
        ResponseDirectives{ .max_age = 300, .s_maxage = 600 },
        ResponseDirectives.parse("max-age=300, S-MaxAge=600"),
    );
    try testing.expectEqual(ResponseDirectives{ .s_maxage = 600 }, ResponseDirectives.parse("s-maxage=600"));
    try testing.expectEqual(null, ResponseDirectives.parse("s-maxage=abc").s_maxage);

    try testing.expectEqual(true, ResponseDirectives.parse("no-store").no_store);
    try testing.expectEqual(true, ResponseDirectives.parse("max-age=300, no-store").no_store);
    try testing.expectEqual(true, ResponseDirectives.parse("no-cache").no_cache);
    try testing.expectEqual(true, ResponseDirectives.parse("no-cache=\"set-cookie\"").no_cache);
    try testing.expectEqual(true, ResponseDirectives.parse("public").public);

    try testing.expectEqual(
        ResponseDirectives{ .private = true, .max_age = 300 },
        ResponseDirectives.parse("Private, max-age=300"),
    );

    try testing.expectEqual(ResponseDirectives{}, ResponseDirectives.parse(""));
    try testing.expectEqual(null, ResponseDirectives.parse("max-age=abc").max_age);
    try testing.expectEqual(null, ResponseDirectives.parse("max-age=").max_age);

    // values longer than 8 digits must not be truncated
    try testing.expectEqual(315360000, ResponseDirectives.parse("max-age=315360000").max_age);

    // delta-seconds too large to represent are capped at 2^31 (RFC 9111 §1.2.2)
    try testing.expectEqual(max_delta_seconds, ResponseDirectives.parse("max-age=2147483649").max_age);
    try testing.expectEqual(max_delta_seconds, ResponseDirectives.parse("max-age=9999999999999999999").max_age);
    try testing.expectEqual(max_delta_seconds, ResponseDirectives.parse("max-age=99999999999999999999999").max_age);
}

// 2026-09-21T07:00:00Z, so that the HTTP-dates below land on either side of it.
const test_now: u64 = 1789974000;

/// Spells a response out as the header list `tryCache` reads it from.
const TestResponse = struct {
    status: u16 = 200,
    cache_control: ?[]const u8 = null,
    expires: ?[]const u8 = null,
    date: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,

    fn run(self: TestResponse, arena: std.mem.Allocator) !?CachePutRequest {
        var headers: std.ArrayList(Http.Header) = .empty;
        inline for (.{
            .{ "Cache-Control", self.cache_control },
            .{ "Expires", self.expires },
            .{ "Date", self.date },
            .{ "ETag", self.etag },
            .{ "Last-Modified", self.last_modified },
        }) |field| {
            if (field[1]) |value| {
                try headers.append(arena, .{ .name = field[0], .value = value });
            }
        }

        return tryCache(arena, .{
            .timestamp = test_now,
            .url = "https://example.com",
            .status = self.status,
            .content_type = "text/html",
            .headers = headers.items,
            .request_headers = &.{},
        });
    }
};

test "Cache: tryCache freshness" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { max_age: ?u64, response: TestResponse }{
        // nothing to go on
        .{ .max_age = null, .response = .{} },

        .{ .max_age = 300, .response = .{ .cache_control = "max-age=300" } },
        .{ .max_age = null, .response = .{ .cache_control = "max-age=0" } },
        .{ .max_age = null, .response = .{ .cache_control = "no-store, max-age=300" } },

        // Expires is relative to Date when the response carries one
        .{ .max_age = 3600, .response = .{
            .expires = "Mon, 21 Sep 2026 08:00:00 GMT",
            .date = "Mon, 21 Sep 2026 07:00:00 GMT",
        } },
        .{ .max_age = 3600, .response = .{ .expires = "Mon, 21 Sep 2026 08:00:00 GMT" } },

        // a past Expires, and an unparsable one, are both already expired
        .{ .max_age = null, .response = .{ .expires = "Mon, 21 Sep 2026 06:00:00 GMT" } },
        .{ .max_age = null, .response = .{ .expires = "0" } },

        // a broken Expires must not fall back to the Last-Modified heuristic
        .{ .max_age = null, .response = .{
            .expires = "0",
            .last_modified = "Mon, 21 Sep 2026 04:13:20 GMT",
        } },

        // Cache-Control wins over Expires
        .{ .max_age = 300, .response = .{
            .cache_control = "max-age=300",
            .expires = "Mon, 21 Sep 2026 06:00:00 GMT",
        } },

        // s-maxage can shorten the browser lifetime, never extend it
        .{ .max_age = 300, .response = .{ .cache_control = "max-age=300, s-maxage=600" } },
        .{ .max_age = 60, .response = .{ .cache_control = "max-age=300, s-maxage=60" } },
        .{ .max_age = null, .response = .{ .cache_control = "max-age=300, s-maxage=0" } },
        .{ .max_age = 60, .response = .{
            .cache_control = "s-maxage=60",
            .expires = "Mon, 21 Sep 2026 08:00:00 GMT",
        } },
        .{ .max_age = null, .response = .{
            .cache_control = "s-maxage=600",
            .expires = "Mon, 21 Sep 2026 06:00:00 GMT",
        } },

        // on its own, s-maxage beats the Last-Modified heuristic
        .{ .max_age = 600, .response = .{ .cache_control = "s-maxage=600" } },
        .{ .max_age = 600, .response = .{
            .cache_control = "s-maxage=600",
            .last_modified = "Mon, 21 Sep 2026 04:13:20 GMT",
        } },
    };

    for (cases, 0..) |c, i| {
        const result = try c.response.run(arena.allocator());
        testing.expectEqual(c.max_age, if (result) |r| r.cache_control.max_age else null) catch |err| {
            testing.print("case {d}\n", .{i});
            return err;
        };
    }
}

test "Cache: tryCache heuristic freshness" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // 10% of the 10000 seconds since it was last modified
    const modified = "Mon, 21 Sep 2026 04:13:20 GMT";

    const result = try (TestResponse{ .last_modified = modified }).run(arena.allocator());
    try testing.expectEqual(1000, result.?.cache_control.max_age);
    try testing.expectEqual(false, result.?.cache_control.must_revalidate);

    // a status with no heuristic of its own, unless the origin said `public`
    const unknown_status = try (TestResponse{ .status = 299, .last_modified = modified }).run(arena.allocator());
    try testing.expectEqual(null, unknown_status);

    const public_unknown_status = try (TestResponse{
        .status = 299,
        .cache_control = "public",
        .last_modified = modified,
    }).run(arena.allocator());
    try testing.expectEqual(1000, public_unknown_status.?.cache_control.max_age);

    // never stored, however fresh they claim to be
    for ([_]u16{ 206, 301, 304 }) |status| {
        const result_ = try (TestResponse{ .status = status, .cache_control = "max-age=300" }).run(arena.allocator());
        try testing.expectEqual(null, result_);
    }
}

test "Cache: tryCache must_revalidate without validators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const no_validators = try (TestResponse{ .cache_control = "no-cache, max-age=300" }).run(arena.allocator());
    try testing.expectEqual(null, no_validators);

    const with_etag = try (TestResponse{
        .cache_control = "no-cache, max-age=300",
        .etag = "\"abc\"",
    }).run(arena.allocator());
    try testing.expectEqual(true, with_etag.?.cache_control.must_revalidate);
}

test "Cache: tryCache vary headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const request_headers = [_]Http.Header{
        .{ .name = "Accept-Encoding", .value = "gzip" },
        .{ .name = "User-Agent", .value = "lightpanda" },
    };

    const stored = try tryCache(arena.allocator(), .{
        .timestamp = test_now,
        .url = "https://example.com",
        .status = 200,
        .content_type = "text/html",
        .headers = &.{
            .{ .name = "Cache-Control", .value = "max-age=300" },
            .{ .name = "Vary", .value = "accept-encoding, accept-language" },
        },
        .request_headers = &request_headers,
    });

    try testing.expectEqual(1, stored.?.vary_headers.len);
    try testing.expectString("Accept-Encoding", stored.?.vary_headers[0].name);
    try testing.expectString("gzip", stored.?.vary_headers[0].value);

    // Vary: * is never stored
    const wildcard = try tryCache(arena.allocator(), .{
        .timestamp = test_now,
        .url = "https://example.com",
        .status = 200,
        .content_type = "text/html",
        .headers = &.{
            .{ .name = "Cache-Control", .value = "max-age=300" },
            .{ .name = "Vary", .value = "*" },
        },
        .request_headers = &request_headers,
    });
    try testing.expectEqual(null, wildcard);
}
