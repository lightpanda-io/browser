// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const Notification = @import("../../notification.zig").Notification;
const log = @import("../../log.zig");

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        setCacheDisabled,
        setExtraHTTPHeaders,
        deleteCookies,
        setCookies,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .setCacheDisabled => return cmd.sendResult(null, .{}),
        .setExtraHTTPHeaders => return setExtraHTTPHeaders(cmd),
        .deleteCookies => return deleteCookies(cmd),
        .setCookies => return setCookies(cmd),
    }
}

fn enable(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.networkEnable();
    return cmd.sendResult(null, .{});
}

fn disable(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.networkDisable();
    return cmd.sendResult(null, .{});
}

fn setExtraHTTPHeaders(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        headers: std.json.ArrayHashMap([]const u8),
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // Copy the headers onto the browser context arena
    const arena = bc.arena;
    const extra_headers = &bc.cdp.extra_headers;

    extra_headers.clearRetainingCapacity();
    try extra_headers.ensureTotalCapacity(arena, params.headers.map.count());
    var it = params.headers.map.iterator();
    while (it.next()) |header| {
        extra_headers.appendAssumeCapacity(.{ .name = try arena.dupe(u8, header.key_ptr.*), .value = try arena.dupe(u8, header.value_ptr.*) });
    }

    return cmd.sendResult(null, .{});
}

const CookiePartitionKey = struct {
    topLevelSite: []const u8,
    hasCrossSiteAncestor: bool,
};

const Cookie = @import("../../browser/storage/storage.zig").Cookie;
const CookieJar = @import("../../browser/storage/storage.zig").CookieJar;

fn cookieMatches(cookie: *const Cookie, name: []const u8, domain: ?[]const u8, path: ?[]const u8) bool {
    if (!std.mem.eql(u8, cookie.name, name)) return false;

    if (domain) |domain_| {
        if (!std.mem.eql(u8, cookie.domain, domain_)) return false;
    }
    if (path) |path_| {
        if (!std.mem.eql(u8, cookie.path, path_)) return false;
    }

    return true;
}

fn deleteCookies(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        name: []const u8,
        url: ?[]const u8 = null,
        domain: ?[]const u8 = null,
        path: ?[]const u8 = null,
        // partitionKey: ?CookiePartitionKey,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const cookies = &bc.session.cookie_jar.cookies;

    var index = cookies.items.len;
    while (index > 0) {
        index -= 1;
        const cookie = &cookies.items[index];
        const domain = try percentEncodedDomain(cmd.arena, params.url, params.domain);
        // TBD does chrome take the path from the url as default? (unlike setCookies)
        if (cookieMatches(cookie, params.name, domain, params.path)) {
            cookies.swapRemove(index).deinit();
        }
    }
    return cmd.sendResult(null, .{});
}

const SameSite = enum {
    Strict,
    Lax,
    None,
};
const CookiePriority = enum {
    Low,
    Medium,
    High,
};
const CookieSourceScheme = enum {
    Unset,
    NonSecure,
    Secure,
};

fn isHostChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        ':' => true,
        '[', ']' => true,
        else => false,
    };
}

// Note: Chrome does not apply rules like removing a leading `.` from the domain.
fn percentEncodedDomain(allocator: Allocator, default_url: ?[]const u8, domain: ?[]const u8) !?[]const u8 {
    if (domain) |domain_| {
        return try allocator.dupe(u8, domain_);
    } else if (default_url) |url| {
        const uri = std.Uri.parse(url) catch return error.InvalidParams;

        switch (uri.host orelse return error.InvalidParams) {
            .raw => |str| {
                var list = std.ArrayList(u8).init(allocator);
                try list.ensureTotalCapacity(str.len); // Expect no precents needed
                try std.Uri.Component.percentEncode(list.writer(), str, isHostChar);
                return list.items; // @memory retains memory used before growing
            },
            .percent_encoded => |str| {
                return try allocator.dupe(u8, str);
            },
        }
    } else return null;
}

fn setCookies(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        cookies: []const struct {
            name: []const u8,
            value: []const u8,
            url: ?[]const u8 = null,
            domain: ?[]const u8 = null,
            path: ?[]const u8 = null,
            secure: bool = false, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
            httpOnly: bool = false, // default: https://www.rfc-editor.org/rfc/rfc6265#section-5.3
            sameSite: SameSite = .None, // default: https://datatracker.ietf.org/doc/html/draft-west-first-party-cookies
            expires: ?i64 = null, // -1? says google
            priority: CookiePriority = .Medium, // default: https://datatracker.ietf.org/doc/html/draft-west-cookie-priority-00
            sameParty: ?bool = null,
            sourceScheme: ?CookieSourceScheme = null,
            // sourcePort: Temporary ability and it will be removed from CDP
            partitionKey: ?CookiePartitionKey = null,
        },
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    for (params.cookies) |param| {
        if (param.priority != .Medium or param.sameParty != null or param.sourceScheme != null or param.partitionKey != null) {
            return error.NotYetImplementedParams;
        }
        if (param.name.len == 0) return error.InvalidParams;
        if (param.value.len == 0) return error.InvalidParams;

        var arena = std.heap.ArenaAllocator.init(bc.session.cookie_jar.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        // NOTE: The param.url can affect the default domain, path, source port, and source scheme.
        const domain = try percentEncodedDomain(a, param.url, param.domain) orelse return error.InvalidParams;

        const cookie = Cookie{
            .arena = arena,
            .name = try a.dupe(u8, param.name),
            .value = try a.dupe(u8, param.value),
            .path = if (param.path) |path| try a.dupe(u8, path) else "/", // Chrome does not actually take the path from the url and just defaults to "/".
            .domain = domain,
            .expires = param.expires,
            .secure = param.secure,
            .http_only = param.httpOnly,
            .same_site = switch (param.sameSite) {
                .Strict => .strict,
                .Lax => .lax,
                .None => .none,
            },
        };
        try bc.session.cookie_jar.add(cookie, std.time.timestamp());
    }

    return cmd.sendResult(null, .{});
}

// Upsert a header into the headers array.
// returns true if the header was added, false if it was updated
fn putAssumeCapacity(headers: *std.ArrayListUnmanaged(std.http.Header), extra: std.http.Header) bool {
    for (headers.items) |*header| {
        if (std.mem.eql(u8, header.name, extra.name)) {
            header.value = extra.value;
            return false;
        }
    }
    headers.appendAssumeCapacity(extra);
    return true;
}

pub fn httpRequestFail(arena: Allocator, bc: anytype, request: *const Notification.RequestFail) !void {
    // It's possible that the request failed because we aborted when the client
    // sent Target.closeTarget. In that case, bc.session_id will be cleared
    // already, and we can skip sending these messages to the client.
    const session_id = bc.session_id orelse return;

    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a page.
    std.debug.assert(bc.session.page != null);

    // We're missing a bunch of fields, but, for now, this seems like enough
    try bc.cdp.sendEvent("Network.loadingFailed", .{
        .requestId = try std.fmt.allocPrint(arena, "REQ-{d}", .{request.id}),
        // Seems to be what chrome answers with. I assume it depends on the type of error?
        .type = "Ping",
        .errorText = request.err,
        .canceled = false,
    }, .{ .session_id = session_id });
}

pub fn httpRequestStart(arena: Allocator, bc: anytype, request: *const Notification.RequestStart) !void {
    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a page.
    std.debug.assert(bc.session.page != null);

    var cdp = bc.cdp;

    // all unreachable because we _have_ to have a page.
    const session_id = bc.session_id orelse unreachable;
    const target_id = bc.target_id orelse unreachable;
    const page = bc.session.currentPage() orelse unreachable;

    // Modify request with extra CDP headers
    try request.headers.ensureTotalCapacity(request.arena, request.headers.items.len + cdp.extra_headers.items.len);
    for (cdp.extra_headers.items) |extra| {
        const new = putAssumeCapacity(request.headers, extra);
        if (!new) log.debug(.cdp, "request header overwritten", .{ .name = extra.name });
    }

    const document_url = try urlToString(arena, &page.url.uri, .{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .path = true,
        .query = true,
    });

    const request_url = try urlToString(arena, request.url, .{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .path = true,
        .query = true,
    });

    const request_fragment = try urlToString(arena, request.url, .{
        .fragment = true,
    });

    var headers: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try headers.ensureTotalCapacity(arena, request.headers.items.len);
    for (request.headers.items) |header| {
        headers.putAssumeCapacity(header.name, header.value);
    }

    // We're missing a bunch of fields, but, for now, this seems like enough
    try cdp.sendEvent("Network.requestWillBeSent", .{
        .requestId = try std.fmt.allocPrint(arena, "REQ-{d}", .{request.id}),
        .frameId = target_id,
        .loaderId = bc.loader_id,
        .documentUrl = document_url,
        .request = .{
            .url = request_url,
            .urlFragment = request_fragment,
            .method = @tagName(request.method),
            .hasPostData = request.has_body,
            .headers = std.json.ArrayHashMap([]const u8){ .map = headers },
        },
    }, .{ .session_id = session_id });
}

pub fn httpRequestComplete(arena: Allocator, bc: anytype, request: *const Notification.RequestComplete) !void {
    // Isn't possible to do a network request within a Browser (which our
    // notification is tied to), without a page.
    std.debug.assert(bc.session.page != null);

    var cdp = bc.cdp;

    // all unreachable because we _have_ to have a page.
    const session_id = bc.session_id orelse unreachable;
    const target_id = bc.target_id orelse unreachable;

    const url = try urlToString(arena, request.url, .{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .path = true,
        .query = true,
    });

    var headers: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try headers.ensureTotalCapacity(arena, request.headers.len);
    for (request.headers) |header| {
        headers.putAssumeCapacity(header.name, header.value);
    }

    // We're missing a bunch of fields, but, for now, this seems like enough
    try cdp.sendEvent("Network.responseReceived", .{
        .requestId = try std.fmt.allocPrint(arena, "REQ-{d}", .{request.id}),
        .loaderId = bc.loader_id,
        .response = .{
            .url = url,
            .status = request.status,
            .headers = std.json.ArrayHashMap([]const u8){ .map = headers },
        },
        .frameId = target_id,
    }, .{ .session_id = session_id });
}

fn urlToString(arena: Allocator, url: *const std.Uri, opts: std.Uri.WriteToStreamOptions) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try url.writeToStream(opts, buf.writer(arena));
    return buf.items;
}

const testing = @import("../testing.zig");
test "cdp.network setExtraHTTPHeaders" {
    var ctx = testing.context();
    defer ctx.deinit();

    // _ = try ctx.loadBrowserContext(.{ .id = "NID-A", .session_id = "NESI-A" });
    try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .url = "about/blank" } });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{ .foo = "bar" } },
    });

    try ctx.processMessage(.{
        .id = 4,
        .method = "Network.setExtraHTTPHeaders",
        .params = .{ .headers = .{ .food = "bars" } },
    });

    const bc = ctx.cdp().browser_context.?;
    try testing.expectEqual(bc.cdp.extra_headers.items.len, 1);

    try ctx.processMessage(.{ .id = 5, .method = "Target.attachToTarget", .params = .{ .targetId = bc.target_id.? } });
    try testing.expectEqual(bc.cdp.extra_headers.items.len, 0);
}
