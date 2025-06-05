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
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .setCacheDisabled => return cmd.sendResult(null, .{}),
        .setExtraHTTPHeaders => return setExtraHTTPHeaders(cmd),
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
    const original_len = request.headers.items.len;
    try request.headers.ensureTotalCapacity(arena, original_len + cdp.extra_headers.items.len);
    outer: for (cdp.extra_headers.items) |extra| {
        for (request.headers.items[0..original_len]) |*existing_header| {
            if (std.mem.eql(u8, existing_header.name, extra.name)) {
                // If the header already exists, we overwrite it
                log.debug(.cdp, "request header overwritten", .{ .name = extra.name });
                existing_header.value = extra.value;
                continue :outer;
            }
        }
        request.headers.appendAssumeCapacity(extra);
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

    try testing.expectEqual(ctx.cdp_.?.browser_context.?.cdp.extra_headers.items.len, 1);
}
