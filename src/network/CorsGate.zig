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

const URL = @import("../browser/URL.zig");
const ArenaPool = @import("../ArenaPool.zig");

const http = @import("http.zig");
const Network = @import("Network.zig");
const Transfer = @import("HttpClient.zig").Transfer;
const SingleFlight = @import("SingleFlight.zig");
const HttpClient = @import("HttpClient.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const CorsGate = @This();

network: *Network,
single_flight: SingleFlight,

pub fn deinit(self: *CorsGate) void {
    self.single_flight.deinit();
}

pub fn remove(self: *CorsGate, transfer: *Transfer) void {
    self.single_flight.remove(transfer);
}

fn flushPending(self: *CorsGate, key: []const u8, allowed: bool) void {
    var queued = self.single_flight.take(key) orelse return;
    defer queued.deinit(self.single_flight.allocator);

    for (queued.items) |transfer| {
        transfer.unpark();

        if (!allowed) {
            log.warn(.http, "blocked by cors (preflight)", .{ .url = transfer.req.url });
            transfer.failAsync(error.CorsBlocked);
            continue;
        }

        transfer.client.resumeAfterCors(transfer) catch |e| {
            transfer.abortPipelineError(e);
        };
    }
}

fn isSafelistedContentType(value: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const mime = std.mem.trim(u8, value[0..semi], &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(mime, "application/x-www-form-urlencoded") or
        std.ascii.eqlIgnoreCase(mime, "multipart/form-data") or
        std.ascii.eqlIgnoreCase(mime, "text/plain");
}

fn isSafelistedHeader(name: []const u8, value: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "accept") or
        std.ascii.eqlIgnoreCase(name, "accept-language") or
        std.ascii.eqlIgnoreCase(name, "content-language"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        return isSafelistedContentType(value);
    }
    return false;
}

fn requiresPreflight(transfer: *const Transfer) bool {
    const req = &transfer.req;

    switch (req.method) {
        .GET, .HEAD, .POST => {},
        else => return true,
    }

    for (transfer.req_headers.items) |hdr| {
        // Only authored headers can trigger a preflight
        if (hdr.source != .author) continue;
        if (!isSafelistedHeader(hdr.name, hdr.value)) return true;
    }

    return false;
}

const Result = enum { allowed, blocked, pending };

pub fn check(self: *CorsGate, transfer: *Transfer) !Result {
    const req = &transfer.req;

    if (req.origin) |origin| {
        if (URL.isSameOrigin(req.url, origin)) {
            log.debug(.cors, "same origin", .{ .url = req.url, .origin = origin });
            return .allowed;
        }
    }

    transfer._cors_cross_origin = true;

    if (!requiresPreflight(transfer)) {
        log.debug(.cors, "cross origin", .{
            .url = req.url,
            .origin = req.origin orelse "null",
            .preflight = false,
        });
        return .allowed;
    }

    log.debug(.cors, "cross origin", .{
        .url = req.url,
        .origin = req.origin orelse "null",
        .preflight = true,
    });

    _ = self;
    return .blocked;

    // try self.fetchThenResumse(transfer);
    // return .pendind;
}

pub fn validateResponse(transfer: *Transfer) !void {
    const req = &transfer.req;
    const allow_origin = HttpClient.findHeader(transfer.res.headers, "access-control-allow-origin");

    if (allow_origin == null) {
        log.warn(.cors, "blocked", .{ .url = req.url, .reason = "missing acao" });
        return error.CorsBlocked;
    }

    const wants_credentials = req.credentials != null or transfer.findRequestHeader("Cookie") != null;

    if (!std.mem.eql(u8, allow_origin.?, "*")) {
        const origin = req.origin orelse {
            log.warn(.cors, "blocked", .{ .url = req.url, .reason = "opaque origin" });
            return error.CorsBlocked;
        };
        if (!std.mem.eql(u8, allow_origin.?, origin)) {
            log.warn(.cors, "blocked", .{ .url = req.url, .reason = "origin mismatch", .allow_origin = allow_origin.?, .origin = origin });
            return error.CorsBlocked;
        }
    } else if (wants_credentials) {
        log.warn(.cors, "blocked", .{ .url = req.url, .reason = "wildcard with credentials" });
        return error.CorsBlocked;
    }

    if (wants_credentials) {
        const allow_creds = HttpClient.findHeader(transfer.res.headers, "access-control-allow-credentials");
        if (allow_creds == null or !std.mem.eql(u8, allow_creds.?, "true")) {
            log.warn(.cors, "blocked", .{ .url = req.url, .reason = "credentials not allowed" });
            return error.CorsBlocked;
        }
    }
}
