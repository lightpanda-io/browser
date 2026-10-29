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

const http = @import("../network/http.zig");
const HttpClient = @import("../network/HttpClient.zig");

const log = lp.log;

const PageStatus = @This();

pub const Unsupported = enum {
    webgl,
    canvas2d,
};

pub const Skipped = enum {
    iframe,
    worker,
    image,
    stylesheet,
    beacon,
};

// The sub-resources the page itself asks for, and which we load.
pub const Loaded = enum {
    script,
    fetch,
    xhr,
};

js_errors: u32 = 0,
skipped: Counts(Skipped) = .{},
unsupported: Counts(Unsupported) = .{},
// Sub-resource loads that got a status >= 400 or a network error. Aborts and
// requests we refused ourselves (robots, --block-urls, adblock) aren't the
// site failing, so they don't count.
failed: Counts(Loaded) = .{},
// The 403s and 429s among `failed`: a bot wall or rate limit on the page's
// own API calls often leaves the document itself a 200.
blocked: Counts(Loaded) = .{},
// The first recognized bot challenge on a sub-resource.
resource_challenge: ?HttpClient.BotChallenge = null,
// Globals that uncaught ReferenceErrors named. Most of what a page needs and
// we lack shows up here first, before any call we could count: a page that
// dies at `createImageBitmap()` never reaches getContext. Deduped and capped;
// the names are whatever V8 put in the message, site bugs included.
missing_globals: MissingGlobals = .{},

// Missing globals that stand for a feature we already count, so the common
// cases stay a one-field check. Only globals we don't register.
const global_features = std.StaticStringMap(Unsupported).initComptime(.{
    .{ "ImageBitmap", .canvas2d },
    .{ "createImageBitmap", .canvas2d },
    .{ "WebGL2RenderingContext", .webgl },
});

// A bit of a hack. Say we want to report that canvas was used, but some sites
// will try to create an ImageBitmap first and fail there. We do have a
// unknownObjectPropertyCallback in bridge, but that gets called on the global
// before v8 tries to resolve it itself, so it's very noisy and full of site
// and framework-specific globals. Instead, we try to parse an uncaught error.
// (which has its own issues, what if the site catches it, but presumably, the
// site catches it because it can handle it).
pub fn noteException(self: *PageStatus, message: []const u8) void {
    const prefix = "ReferenceError: ";
    const suffix = " is not defined";
    if (message.len <= prefix.len + suffix.len) {
        return;
    }

    if (std.mem.startsWith(u8, message, prefix) == false) {
        return;
    }
    if (std.mem.endsWith(u8, message, suffix) == false) {
        return;
    }

    const name = message[prefix.len .. message.len - suffix.len];
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) == false and c != '_' and c != '$') return;
    }
    if (self.missing_globals.add(name) == false) return;

    log.info(.not_implemented, "missing global", .{ .name = name });
    if (global_features.get(name)) |feature| {
        self.noteUnsupported(feature);
    }
}

pub fn noteUnsupported(self: *PageStatus, what: Unsupported) void {
    if (self.unsupported.incr(what) == 1) {
        log.info(.not_implemented, "unsupported feature used", .{ .feature = what });
    }
}

pub fn noteSkipped(self: *PageStatus, what: Skipped) void {
    if (self.skipped.incr(what) != 1) {
        return;
    }

    const level: log.Level = switch (what) {
        .iframe, .worker => .warn,
        .image, .stylesheet, .beacon => .debug,
    };

    switch (what) {
        inline else => |w| log.log(.disabled, level, "resource skipped", .{ .resource = w, .hint = "enable via --load-resources " ++ @tagName(w) }),
    }
}

// A sub-resource's final response headers.
pub fn noteResponse(self: *PageStatus, what: Loaded, transfer: *const HttpClient.Transfer) void {
    const status = transfer.responseStatus() orelse return;

    // Before the status check: AWS WAF challenges with a 202.
    if (self.resource_challenge == null) {
        if (transfer.botChallenge()) |challenge| {
            self.resource_challenge = challenge;
            log.warn(.http, "sub-resource bot challenge", .{ .challenge = challenge, .resource = what, .url = transfer.req.url });
        }
    }

    if (status < 400) {
        return;
    }
    _ = self.failed.incr(what);

    if (status == 403 or status == 429) {
        if (self.blocked.incr(what) == 1) {
            log.info(.http, "sub-resource blocked", .{ .resource = what, .status = status, .url = transfer.req.url });
        }
    }
}

// A sub-resource load that ended without a usable response. Callers only
// report errors that came before any response headers, which noteResponse
// has already counted.
pub fn noteError(self: *PageStatus, what: Loaded, err: anyerror) void {
    if (err == error.UrlBlocked) {
        return;
    }
    switch (http.errorReason(err)) {
        .aborted, .robots_blocked => return,
        else => _ = self.failed.incr(what),
    }
}

pub const MissingGlobals = struct {
    const max = 8;
    const max_len = 48;

    _count: u8 = 0,
    _lens: [max]u8 = @splat(0),
    _names: [max][max_len]u8 = undefined,

    pub fn get(self: *const MissingGlobals, i: usize) []const u8 {
        return self._names[i][0..self._lens[i]];
    }

    pub fn count(self: *const MissingGlobals) usize {
        return self._count;
    }

    fn add(self: *MissingGlobals, name: []const u8) bool {
        if (name.len > max_len) {
            // too long to store
            return false;
        }
        for (0..self._count) |i| {
            if (std.mem.eql(u8, self.get(i), name)) {
                // already present
                return false;
            }
        }
        if (self._count == max) {
            // our list is full
            return false;
        }
        @memcpy(self._names[self._count][0..name.len], name);
        self._lens[self._count] = @intCast(name.len);
        self._count += 1;
        return true;
    }

    pub fn jsonStringify(self: *const MissingGlobals, w: anytype) !void {
        try w.beginArray();
        for (0..self._count) |i| {
            try w.write(self.get(i));
        }
        try w.endArray();
    }
};

fn Counts(comptime E: type) type {
    return struct {
        _values: std.EnumArray(E, u32) = .initFill(0),

        const Self = @This();

        pub fn get(self: *const Self, tag: E) u32 {
            return self._values.get(tag);
        }

        pub fn total(self: *const Self) u32 {
            var sum: u32 = 0;
            for (self._values.values) |v| sum += v;
            return sum;
        }

        fn incr(self: *Self, tag: E) u32 {
            const ptr = self._values.getPtr(tag);
            ptr.* += 1;
            return ptr.*;
        }

        pub fn jsonStringify(self: *const Self, w: anytype) !void {
            try w.beginObject();
            inline for (comptime std.enums.values(E)) |tag| {
                try w.objectField(@tagName(tag));
                try w.write(self._values.get(tag));
            }
            try w.endObject();
        }
    };
}

const testing = @import("../testing.zig");
test "PageStatus: missing globals from uncaught ReferenceErrors" {
    testing.expectLog(&.{ .page_error, .page_error, .page_error, .page_error, .page_error });
    const page = try testing.pageTest("page_missing_global.html", .{});
    defer page.close();

    const status = &page.frame().?.page.status;
    try testing.expectEqual(5, status.js_errors);
    try testing.expectEqual(1, status.unsupported.get(.canvas2d));
    try testing.expectEqual(1, status.unsupported.get(.webgl));

    const json = try std.json.Stringify.valueAlloc(testing.allocator, status.missing_globals, .{});
    defer testing.allocator.free(json);
    try testing.expectEqual("[\"createImageBitmap\",\"someUndefinedThing\",\"WebGL2RenderingContext\"]", json);
}

test "PageStatus: failed and blocked sub-resources" {
    testing.expectLog(&.{.http});
    const page = try testing.pageTest("page_subresource_status.html", .{ .wait_until_done = true });
    defer page.close();

    const status = &page.frame().?.page.status;
    try testing.expectEqual(1, status.failed.get(.script));
    try testing.expectEqual(0, status.blocked.get(.script));

    // 403, 429 and the unreachable host; the 204 and the abort don't count.
    try testing.expectEqual(3, status.failed.get(.fetch));
    try testing.expectEqual(2, status.blocked.get(.fetch));

    try testing.expectEqual(1, status.failed.get(.xhr));
    try testing.expectEqual(0, status.blocked.get(.xhr));

    try testing.expectEqual(.vercel, status.resource_challenge.?);
}

test "PageStatus: noteException only takes well-formed ReferenceErrors" {
    var status: PageStatus = .{};
    status.noteException("TypeError: Path2D is not defined");
    status.noteException("ReferenceError: is not defined");
    status.noteException("ReferenceError: a b is not defined");
    status.noteException("ReferenceError: x is not defined, really");
    try testing.expectEqual(0, status.missing_globals.count());

    status.noteException("ReferenceError: $_ok1 is not defined");
    status.noteException("ReferenceError: $_ok1 is not defined");
    try testing.expectEqual(1, status.missing_globals.count());
    try testing.expectEqual("$_ok1", status.missing_globals.get(0));

    // Capped: the ninth distinct name is dropped, the first eight kept.
    inline for (0..9) |i| {
        status.noteException(std.fmt.comptimePrint("ReferenceError: g{d} is not defined", .{i}));
    }
    try testing.expectEqual(8, status.missing_globals.count());
    try testing.expectEqual("g6", status.missing_globals.get(7));
}

test "PageStatus: counts serialize as an object with every tag" {
    testing.expectLog(&.{.disabled});

    var status: PageStatus = .{};
    status.noteUnsupported(.webgl);
    status.noteUnsupported(.webgl);
    status.noteSkipped(.iframe);

    try testing.expectEqual(2, status.unsupported.get(.webgl));
    try testing.expectEqual(0, status.unsupported.get(.canvas2d));

    const json = try std.json.Stringify.valueAlloc(testing.arena_allocator, status.unsupported, .{});
    try testing.expectEqual("{\"webgl\":2,\"canvas2d\":0}", json);

    const skipped = try std.json.Stringify.valueAlloc(testing.arena_allocator, status.skipped, .{});
    try testing.expectEqual("{\"iframe\":1,\"worker\":0,\"image\":0,\"stylesheet\":0,\"beacon\":0}", skipped);
}
