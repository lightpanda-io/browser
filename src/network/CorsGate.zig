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

const http = @import("http.zig");
const Transfer = @import("HttpClient.zig").Transfer;
const SingleFlight = @import("SingleFlight.zig");
const HttpClient = @import("HttpClient.zig");

const log = lp.log;

const CorsGate = @This();

single_flight: SingleFlight,

// CORS Request Headers
const ORIGIN = "origin";
const ACCESS_CONTROL_REQUEST_METHOD = "access-control-request-method";
const ACCESS_CONTROL_REQUEST_HEADERS = "access-control-request-headers";

// CORS Response Headers
const ACCESS_CONTROL_ALLOW_ORIGIN = "access-control-allow-origin";
const ACCESS_CONTROL_ALLOW_METHODS = "access-control-allow-methods";
const ACCESS_CONTROL_ALLOW_HEADERS = "access-control-allow-headers";
const ACCESS_CONTROL_ALLOW_CREDENTIALS = "access-control-allow-credentials";

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
            lp.metrics.cors_preflight.incr(.blocked);
            log.warn(.cors, "preflight blocked", .{ .url = transfer.req.url });
            transfer.failAsync(error.CorsBlocked);
            continue;
        }

        lp.metrics.cors_preflight.incr(.allowed);
        transfer.client.resumeAfterCors(transfer) catch |e| {
            transfer.abortPipelineError(e);
        };
    }
}

fn isSafelistedMethod(value: http.Method) bool {
    return switch (value) {
        .GET, .HEAD, .POST => true,
        else => false,
    };
}

fn isCorsUnsafeByte(c: u8) bool {
    return switch (c) {
        0...0x08,
        0x0A...0x1F,
        '"',
        '(',
        ')',
        ':',
        '<',
        '>',
        '?',
        '@',
        '[',
        '\\',
        ']',
        '{',
        '}',
        => true,
        0x7F => true,
        else => false,
    };
}

fn hasNoCorsUnsafeBytes(value: []const u8) bool {
    for (value) |c| if (isCorsUnsafeByte(c)) return false;
    return true;
}

fn isSafelistedContentType(value: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const mime = std.mem.trim(u8, value[0..semi], &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(mime, "application/x-www-form-urlencoded") or
        std.ascii.eqlIgnoreCase(mime, "multipart/form-data") or
        std.ascii.eqlIgnoreCase(mime, "text/plain");
}

fn isSafelistedLanguageValue(value: []const u8) bool {
    for (value) |c| {
        const ok = switch (c) {
            '0'...'9',
            'A'...'Z',
            'a'...'z',
            ' ',
            '*',
            ',',
            '-',
            '.',
            ';',
            '=',
            => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

// https://fetch.spec.whatwg.org/#cors-safelisted-request-header
fn isSafelistedHeader(name: []const u8, value: []const u8) bool {
    if (value.len > 128) return false;

    if (std.ascii.eqlIgnoreCase(name, "accept")) {
        return hasNoCorsUnsafeBytes(value);
    }

    if (std.ascii.eqlIgnoreCase(name, "accept-language") or
        std.ascii.eqlIgnoreCase(name, "content-language"))
    {
        return isSafelistedLanguageValue(value);
    }

    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        return isSafelistedContentType(value) and
            hasNoCorsUnsafeBytes(value);
    }

    return false;
}

fn requiresPreflight(transfer: *const Transfer) bool {
    const req = &transfer.req;

    if (!isSafelistedMethod(req.method)) {
        return true;
    }

    for (transfer.req_headers.items) |hdr| {
        // Only authored headers can trigger a preflight
        if (hdr.source != .author) continue;
        if (!isSafelistedHeader(hdr.name, hdr.value)) return true;
    }

    return false;
}

const Result = enum { allowed, pending };

pub fn check(self: *CorsGate, transfer: *Transfer) !Result {
    const req = &transfer.req;

    if (!transfer._cors_origin_tainted) {
        if (req.origin) |origin| {
            if (URL.isSameOrigin(req.url, origin)) {
                log.debug(.cors, "same origin", .{ .url = req.url, .origin = origin });
                lp.metrics.cors_check.incr(.same_origin);
                return .allowed;
            }
        }
    }

    const origin = transfer.effectiveOrigin();
    transfer._cors_cross_origin = true;

    // https://fetch.spec.whatwg.org/#append-a-request-origin-header
    //
    // If the request is no cors, we only add the origin if it is not HEAD or GET.
    // TODO: Should use referrer policy.
    if (req.request_mode != .no_cors or (req.method != .HEAD and req.method != .GET)) {
        try transfer.setHeader("Origin", origin, .{});
    }

    if (req.request_mode == .no_cors) {
        log.debug(.cors, "cross origin", .{
            .url = req.url,
            .origin = origin,
            .mode = "no-cors",
        });
        lp.metrics.cors_check.incr(.no_cors);
        return .allowed;
    }

    if (!requiresPreflight(transfer)) {
        log.debug(.cors, "cross origin", .{
            .url = req.url,
            .origin = origin,
            .preflight = false,
        });
        lp.metrics.cors_check.incr(.simple);
        return .allowed;
    }

    log.debug(.cors, "cross origin", .{
        .url = req.url,
        .origin = origin,
        .preflight = true,
    });
    lp.metrics.cors_check.incr(.preflight);

    try self.fetchThenResume(transfer);
    return .pending;
}

const CorsKey = struct {
    url: []const u8,
    origin: []const u8,
    method: http.Method,
    wants_credentials: bool,
    // lowercased and sorted.
    authored_headers: []const []const u8,

    fn build(self: CorsKey, arena: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;

        try buf.appendSlice(arena, self.url);
        try buf.append(arena, 0);
        try buf.appendSlice(arena, self.origin);
        try buf.append(arena, 0);
        try buf.appendSlice(arena, @tagName(self.method));
        try buf.append(arena, 0);
        try buf.append(arena, if (self.wants_credentials) 1 else 0);
        try buf.append(arena, 0);

        for (self.authored_headers) |h| {
            try buf.appendSlice(arena, h);
            try buf.append(arena, 0);
        }

        return buf.items;
    }
};

const CorsPreflightContext = struct {
    gate: *CorsGate,
    arena: *lp.Arena,

    key: []const u8,
    url: [:0]const u8,
    origin: []const u8,
    method: http.Method,
    request_headers: []const []const u8,
    wants_credentials: bool,

    allowed: bool = false,

    fn validateHeaders(
        self: *CorsPreflightContext,
        acao: ?[]const u8,
        acam: ?[]const u8,
        acah: ?[]const u8,
        acac: ?[]const u8,
    ) bool {
        // Access-Control-Allow-Origin
        const allow_origin = acao orelse {
            log.debug(.cors, "preflight blocked", .{ .url = self.url, .reason = "missing acao" });
            return false;
        };

        const is_wildcard_origin = std.mem.eql(u8, allow_origin, "*");

        if (is_wildcard_origin and self.wants_credentials) {
            log.debug(.cors, "preflight blocked", .{ .url = self.url, .reason = "wildcard origin with credentials" });
            return false;
        }

        if (!is_wildcard_origin and !std.mem.eql(u8, allow_origin, self.origin)) {
            log.debug(.cors, "preflight blocked", .{
                .url = self.url,
                .reason = "origin mismatch",
                .allow_origin = allow_origin,
                .origin = self.origin,
            });
            return false;
        }

        // Access-Control-Allow-Credentials
        if (self.wants_credentials) {
            const allow_credentials = acac orelse {
                log.debug(.cors, "preflight blocked", .{ .url = self.url, .reason = "missing acac" });
                return false;
            };

            if (!std.mem.eql(u8, allow_credentials, "true")) {
                log.debug(.cors, "preflight blocked", .{ .url = self.url, .reason = "credentials not allowed", .allow_credentials = acac });
                return false;
            }
        }

        if (!isSafelistedMethod(self.method)) {
            // Access-Control-Allow-Methods
            const allow_methods = acam orelse {
                log.debug(.cors, "preflight blocked", .{ .url = self.url, .reason = "missing acam" });
                return false;
            };

            const methods_wildcard = std.mem.eql(u8, allow_methods, "*") and !self.wants_credentials;
            if (!methods_wildcard and !methodAllowed(allow_methods, self.method)) {
                log.debug(.cors, "preflight blocked", .{
                    .url = self.url,
                    .reason = "method not allowed",
                    .allow_methods = allow_methods,
                    .method = @tagName(self.method),
                });
                return false;
            }
        }

        // Access-Control-Allow-Headers
        if (self.request_headers.len > 0) {
            const allow_headers = acah orelse {
                log.debug(.cors, "preflight blocked", .{ .url = self.url, .reason = "missing acah" });
                return false;
            };

            const headers_wildcard = std.mem.eql(u8, allow_headers, "*") and !self.wants_credentials;

            for (self.request_headers) |name| {
                const is_authorization = std.ascii.eqlIgnoreCase(name, "authorization");
                if (headers_wildcard and !is_authorization) continue;

                if (!headerAllowed(allow_headers, name)) {
                    log.debug(.cors, "preflight blocked", .{
                        .url = self.url,
                        .reason = "header not allowed",
                        .allow_headers = allow_headers,
                        .header = name,
                    });
                    return false;
                }
            }
        }

        return true;
    }

    fn methodAllowed(list: []const u8, method: http.Method) bool {
        const method_name = @tagName(method);
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |raw| {
            const token = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (std.mem.eql(u8, token, method_name)) return true;
        }
        return false;
    }

    fn headerAllowed(list: []const u8, name: []const u8) bool {
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |raw| {
            const tok = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (std.ascii.eqlIgnoreCase(tok, name)) return true;
        }
        return false;
    }

    fn headerCallback(transfer: *Transfer) anyerror!Transfer.HeaderResult {
        const self: *CorsPreflightContext = @ptrCast(@alignCast(transfer.req.ctx));

        // Must be 2xx
        if (transfer.responseStatus()) |status| {
            switch (status) {
                200...299 => {},
                else => |s| {
                    log.debug(.cors, "preflight blocked", .{ .url = self.url, .status = s });
                    self.allowed = false;
                    return .proceed;
                },
            }
        }

        var acao: ?[]const u8 = null;
        var acam: ?[]const u8 = null;
        var acah: ?[]const u8 = null;
        var acac: ?[]const u8 = null;

        var iter = transfer.responseHeaderIterator();
        while (iter.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(ACCESS_CONTROL_ALLOW_ORIGIN, hdr.name)) {
                acao = hdr.value;
            } else if (std.ascii.eqlIgnoreCase(ACCESS_CONTROL_ALLOW_METHODS, hdr.name)) {
                acam = hdr.value;
            } else if (std.ascii.eqlIgnoreCase(ACCESS_CONTROL_ALLOW_HEADERS, hdr.name)) {
                acah = hdr.value;
            } else if (std.ascii.eqlIgnoreCase(ACCESS_CONTROL_ALLOW_CREDENTIALS, hdr.name)) {
                acac = hdr.value;
            }
        }

        self.allowed = self.validateHeaders(acao, acam, acah, acac);
        return .proceed;
    }

    fn doneCallback(ctx_ptr: *anyopaque) anyerror!void {
        const self: *CorsPreflightContext = @ptrCast(@alignCast(ctx_ptr));
        self.resolve(self.allowed);
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *CorsPreflightContext = @ptrCast(@alignCast(ctx_ptr));
        log.warn(.cors, "preflight error", .{ .url = self.url, .err = err });

        self.resolve(false);
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *CorsPreflightContext = @ptrCast(@alignCast(ctx_ptr));
        log.debug(.cors, "preflight shutdown", .{ .url = self.url });

        const gate = self.gate;
        const arena = self.arena;
        gate.single_flight.discard(self.key);
        arena.release();
    }

    fn resolve(self: *CorsPreflightContext, allowed: bool) void {
        const gate = self.gate;
        const arena = self.arena;
        gate.flushPending(self.key, allowed);
        arena.release();
    }
};

fn fetchThenResume(self: *CorsGate, transfer: *Transfer) !void {
    const url = transfer.req.url;
    const origin = transfer.req.origin orelse "null";

    var header_names: std.ArrayList([]const u8) = .empty;
    for (transfer.req_headers.items) |hdr| {
        if (hdr.source != .author) continue;
        if (isSafelistedHeader(hdr.name, hdr.value)) continue;
        try header_names.append(
            transfer.arena.allocator(),
            try std.ascii.allocLowerString(transfer.arena.allocator(), hdr.name),
        );
    }
    std.mem.sort([]const u8, header_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const cors_key = CorsKey{
        .url = url,
        .origin = origin,
        .method = transfer.req.method,
        .wants_credentials = transfer.req.credentials_mode == .include,
        .authored_headers = header_names.items,
    };
    const key = try cors_key.build(transfer.arena.allocator());

    const result = try self.single_flight.enter(key, transfer, .cors);
    if (result == .queued) return;
    errdefer {
        self.single_flight.discard(key);
        transfer.unpark();
    }

    const client = transfer.client;
    const arena_pool = client.arena_pool;

    const arena = try arena_pool.acquire(.tiny, "CorsGate.CorsPreflightContext");
    errdefer arena_pool.release(arena);

    const owned_url = try arena.dupeZ(u8, transfer.req.url);
    const owned_key = try arena.dupe(u8, key);
    const owned_origin = try arena.dupe(u8, origin);

    const owned_header_names = try arena.alloc([]const u8, header_names.items.len);
    for (header_names.items, 0..) |name, i| {
        owned_header_names[i] = try arena.dupe(u8, name);
    }

    const ctx = try arena.create(CorsPreflightContext);
    ctx.* = .{
        .gate = self,
        .arena = arena,

        .key = owned_key,
        .url = owned_url,
        .origin = owned_origin,
        .method = transfer.req.method,
        .request_headers = owned_header_names,
        .wants_credentials = transfer.req.credentials_mode == .include,
    };

    const fetch_transfer = try client.newRequest(.{
        .url = owned_url,
        .method = .OPTIONS,
        .internal = true,
        .resource_type = .fetch,
        .frame_id = transfer.req.frame_id,
        .document_frame_id = transfer.req.document_frame_id,
        .loader_id = transfer.req.loader_id,
        .notification = transfer.req.notification,
        .origin = transfer.req.origin,
        .credentials_mode = .omit,
        .request_mode = .no_cors,
        .ctx = ctx,
        .header_callback = CorsPreflightContext.headerCallback,
        .done_callback = CorsPreflightContext.doneCallback,
        .error_callback = CorsPreflightContext.errorCallback,
        .shutdown_callback = CorsPreflightContext.shutdownCallback,
    }, null);
    errdefer fetch_transfer.deinit();

    // Origin
    try fetch_transfer.setHeader(
        ORIGIN,
        transfer.req.origin orelse "null",
        .{},
    );

    // Access-Control-Allow-Methods
    try fetch_transfer.setHeader(
        ACCESS_CONTROL_REQUEST_METHOD,
        @tagName(transfer.req.method),
        .{},
    );

    // Access-Control-Allow-Headers
    if (header_names.items.len > 0) {
        const request_headers_value = try std.mem.join(arena.allocator(), ",", header_names.items);
        try fetch_transfer.setHeader(
            ACCESS_CONTROL_REQUEST_HEADERS,
            request_headers_value,
            .{},
        );
    }

    fetch_transfer.submit() catch {};
}

pub fn validateResponse(transfer: *Transfer) !void {
    const req = &transfer.req;
    errdefer lp.metrics.cors_response.incr(.blocked);

    const allow_origin = HttpClient.findHeader(transfer.res.headers, ACCESS_CONTROL_ALLOW_ORIGIN) orelse {
        log.warn(.cors, "blocked", .{ .url = req.url, .reason = "missing acao" });
        return error.CorsBlocked;
    };

    const wants_credentials = req.credentials_mode == .include;
    const is_wildcard_origin = std.mem.eql(u8, allow_origin, "*");

    if (is_wildcard_origin and wants_credentials) {
        log.warn(.cors, "blocked", .{ .url = req.url, .reason = "wildcard origin with credentials" });
        return error.CorsBlocked;
    }

    if (!is_wildcard_origin) {
        const origin = transfer.effectiveOrigin();
        if (!std.mem.eql(u8, allow_origin, origin)) {
            log.warn(.cors, "blocked", .{
                .url = req.url,
                .reason = "origin mismatch",
                .allow_origin = allow_origin,
                .origin = origin,
            });
            return error.CorsBlocked;
        }
    }

    if (wants_credentials) {
        const allow_creds = HttpClient.findHeader(transfer.res.headers, ACCESS_CONTROL_ALLOW_CREDENTIALS) orelse {
            log.warn(.cors, "blocked", .{ .url = req.url, .reason = "missing acac" });
            return error.CorsBlocked;
        };

        if (!std.mem.eql(u8, allow_creds, "true")) {
            log.warn(.cors, "blocked", .{ .url = req.url, .reason = "credentials not allowed", .allow_credentials = allow_creds });
            return error.CorsBlocked;
        }
    }

    lp.metrics.cors_response.incr(.allowed);
}
