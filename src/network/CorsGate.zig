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

const http = @import("http.zig");
const Request = @import("../browser/webapi/net/Request.zig");
const Network = @import("Network.zig");
const Robots = @import("Robots.zig");
const SingleFlight = @import("SingleFlight.zig");
const Transfer = @import("HttpClient.zig").Transfer;
const ArenaPool = @import("../ArenaPool.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub const CorsGate = @This();

network: *Network,
allocator: Allocator,
single_flight: SingleFlight,

pub const Result = enum { allowed, blocked, pending };

pub fn deinit(self: *CorsGate) void {
    self.single_flight.deinit();
}

fn isSafelistedHeader(name: []const u8) bool {
    const safelisted = [_][]const u8{
        "accept",
        "accept-language",
        "content-language",
        "content-type",
    };

    for (safelisted) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    return false;
}

fn isSafelistedContentType(ct: []const u8) bool {
    const safelisted = [_][]const u8{
        "application/x-www-form-urlencoded",
        "multipart/form-data",
        "text/plain",
    };

    const mime = blk: {
        const semi = std.mem.indexOfScalar(u8, ct, ';') orelse ct.len;
        break :blk std.mem.trim(u8, ct[0..semi], &std.ascii.whitespace);
    };

    for (safelisted) |s| if (std.ascii.eqlIgnoreCase(mime, s)) return true;
    return false;
}

pub fn needsPreflight(transfer: *Transfer) bool {
    const req = &transfer.req;

    var content_type: ?[]const u8 = null;
    var it = req.headers.iterator();
    while (it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) {
            content_type = hdr.value;
            continue;
        }

        if (!isSafelistedHeader(hdr.name)) return true;
    }

    switch (req.method) {
        .GET, .HEAD => {},
        .POST => if (content_type) |ct| if (isSafelistedContentType(ct)) return true,
        else => return true,
    }

    return false;
}

fn keyFor(arena: Allocator, transfer: *Transfer) ![]const u8 {
    const req = transfer.req;

    return try std.fmt.allocPrint(
        arena,
        "{s}-{s}-{s}",
        .{ req.cookie_origin, @tagName(req.method), req.url },
    );
}

pub fn check(self: *CorsGate, transfer: *Transfer) !Result {
    if (!needsPreflight(transfer)) return .allowed;

    const client = transfer.client;
    const arena = try client.arena_pool.acquire(.small, "CorsGate.CorsContext");
    errdefer client.arena_pool.release(arena);

    const key = try keyFor(arena, transfer);

    try self.fetchThenResume(arena, key, transfer);
    return .pending;
}

fn fetchThenResume(self: *CorsGate, arena: Allocator, key: []const u8, transfer: *Transfer) !void {
    const client = transfer.client;

    const res = try self.single_flight.enter(key, transfer, .cors);
    switch (res) {
        .queued => {
            // Joined an in-flight preflight — this context/arena was
            // never registered or handed to a fetch, release it now.
            client.arena_pool.release(arena);
            return;
        },
        .initial => {
            errdefer self.single_flight.abort(key);

            const cors_ctx = try arena.create(CorsContext);
            cors_ctx.* = .{
                .gate = self,
                .arena = arena,
                .arena_pool = client.arena_pool,
                .key = key,
            };

            log.debug(.browser, "sending cors preflight", .{ .url = transfer.req.url });

            var headers = try client.newHeaders();
            errdefer headers.deinit();

            try preflightHeaders(arena, &headers, transfer);

            const fetch_transfer = try client.newRequest(.{
                .url = transfer.req.url,
                .method = .OPTIONS,
                .internal = true,
                .resource_type = .fetch,
                .frame_id = transfer.req.frame_id,
                .loader_id = transfer.req.loader_id,
                .notification = transfer.req.notification,
                .cookie_jar = null,
                .cookie_origin = transfer.req.cookie_origin,
                .ctx = cors_ctx,
                .headers = headers,
                .header_callback = CorsContext.headerCallback,
                .done_callback = CorsContext.doneCallback,
                .error_callback = CorsContext.errorCallback,
                .shutdown_callback = CorsContext.shutdownCallback,
            }, null);

            fetch_transfer.submit() catch {};
        },
    }
}

fn preflightHeaders(arena: Allocator, headers: *http.Headers, transfer: *Transfer) !void {
    try headers.add(try std.fmt.allocPrintSentinel(
        arena,
        "Access-Control-Request-Method: {s}",
        .{@tagName(transfer.req.method)},
        0,
    ));

    // Non-safelisted request headers must be listed too, comma-separated,
    // per the Fetch spec's preflight algorithm.
    var names: std.ArrayList(u8) = .empty;
    var it = transfer.req.headers.iterator();
    var first = true;
    while (it.next()) |hdr| {
        if (isSafelistedHeader(hdr.name)) continue;
        if (!first) try names.appendSlice(arena, ", ");
        try names.appendSlice(arena, hdr.name);
        first = false;
    }
    if (names.items.len > 0) {
        try headers.add(try std.fmt.allocPrintSentinel(
            arena,
            "Access-Control-Request-Headers: {s}",
            .{names.items},
            0,
        ));
    }

    try headers.add(try std.fmt.allocPrintSentinel(
        arena,
        "Origin: {s}",
        .{transfer.req.cookie_origin},
        0,
    ));
}

const CorsContext = struct {
    gate: *CorsGate,
    arena: Allocator,
    arena_pool: *ArenaPool,
    key: []const u8,
    status: u16 = 0,

    fn headerCallback(transfer: *Transfer) anyerror!Transfer.HeaderResult {
        const self: *CorsContext = @ptrCast(@alignCast(transfer.req.ctx));
        if (transfer.res.header) |hdr| {
            log.debug(.browser, "cors preflight status", .{ .status = hdr.status, .key = self.key });
            self.status = hdr.status;
        }
        // No body needed — everything relevant is in the response headers.
        return .proceed;
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *CorsContext = @ptrCast(@alignCast(ctx_ptr));
        // TODO: validate Access-Control-Allow-Origin / -Methods / -Headers
        // against the original request rather than just checking status.
        const allowed = self.status >= 200 and self.status < 300;
        self.resolve(allowed);
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *CorsContext = @ptrCast(@alignCast(ctx_ptr));
        log.warn(.http, "cors preflight failed", .{ .err = err, .key = self.key });
        self.resolve(false);
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *CorsContext = @ptrCast(@alignCast(ctx_ptr));
        log.debug(.http, "cors preflight shutdown", .{});
        const gate = self.gate;
        const pool = self.arena_pool;
        const arena = self.arena;
        gate.single_flight.discard(self.key);
        pool.release(arena);
    }

    fn resolve(self: *CorsContext, allowed: bool) void {
        const gate = self.gate;
        const pool = self.arena_pool;
        const arena = self.arena;
        gate.flushPending(self.key, allowed);
        pool.release(arena);
    }
};

// The preflight resolved: hand every waiter back to the pipeline. Unlike
// robots, a failed/errored preflight fails CLOSED — CORS is a security
// boundary, not a courtesy.
fn flushPending(self: *CorsGate, key: []const u8, allowed: bool) void {
    var queued = self.single_flight.take(key) orelse return;
    defer queued.deinit(self.allocator);

    for (queued.items) |transfer| {
        transfer.unpark();

        if (!allowed) {
            log.warn(.http, "blocked by cors preflight", .{ .url = transfer.req.url });
            transfer.failAsync(error.CorsBlocked);
            continue;
        }

        transfer.client.resumeAfterCors(transfer) catch |e| {
            transfer.abortPipelineError(e);
        };
    }
}
