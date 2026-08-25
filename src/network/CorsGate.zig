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
            log.warn(.cors, "preflight blocked", .{ .url = transfer.req.url });
            transfer.failAsync(error.CorsBlocked);
            continue;
        }

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

    if (req.origin) |origin| {
        if (URL.isSameOrigin(req.url, origin)) {
            log.debug(.cors, "same origin", .{ .url = req.url, .origin = origin });
            return .allowed;
        }
    }

    const origin = req.origin orelse "null";
    try transfer.setHeader(ORIGIN, origin, .{});

    if (req.request_mode == .no_cors) {
        log.debug(.cors, "cross origin", .{
            .url = req.url,
            .origin = origin,
            .mode = "no-cors",
        });
        return .allowed;
    }

    transfer._cors_cross_origin = true;

    if (!requiresPreflight(transfer)) {
        log.debug(.cors, "cross origin", .{
            .url = req.url,
            .origin = origin,
            .preflight = false,
        });
        return .allowed;
    }

    log.debug(.cors, "cross origin", .{
        .url = req.url,
        .origin = origin,
        .preflight = true,
    });

    try self.fetchThenResume(transfer);
    return .pending;
}

const CorsPreflightContext = struct {
    gate: *CorsGate,
    arena: *lp.Arena,

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
            if (!headers_wildcard) {
                for (self.request_headers) |name| {
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
        gate.single_flight.discard(self.url);
        arena.release();
    }

    fn resolve(self: *CorsPreflightContext, allowed: bool) void {
        const gate = self.gate;
        const arena = self.arena;
        gate.flushPending(self.url, allowed);
        arena.release();
    }
};

fn fetchThenResume(self: *CorsGate, transfer: *Transfer) !void {
    const url = transfer.req.url;

    const result = try self.single_flight.enter(url, transfer, .cors);
    if (result == .queued) return;
    errdefer {
        self.single_flight.discard(url);
        transfer.unpark();
    }

    const client = transfer.client;
    const arena_pool = client.arena_pool;

    const arena = try arena_pool.acquire(.tiny, "CorsGate.CorsPreflightContext");
    errdefer arena_pool.release(arena);

    const owned_url = try arena.dupeZ(u8, transfer.req.url);

    var header_names: std.ArrayList([]const u8) = .empty;
    for (transfer.req_headers.items) |hdr| {
        if (hdr.source != .author) continue;
        if (isSafelistedHeader(hdr.name, hdr.value)) continue;
        try header_names.append(
            arena.allocator(),
            try std.ascii.allocLowerString(arena.allocator(), hdr.name),
        );
    }

    const ctx = try arena.create(CorsPreflightContext);
    ctx.* = .{
        .gate = self,
        .arena = arena,
        .url = owned_url,

        .origin = try arena.dupe(u8, transfer.req.origin orelse "null"),
        .method = transfer.req.method,
        .request_headers = header_names.items,
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
        .cookie_jar = null,
        .cookie_origin = transfer.req.cookie_origin,
        .origin = transfer.req.origin,
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
        const origin = req.origin orelse {
            log.warn(.cors, "blocked", .{ .url = req.url, .reason = "opaque origin" });
            return error.CorsBlocked;
        };

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
}
