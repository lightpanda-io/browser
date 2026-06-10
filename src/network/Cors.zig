// Copyright (C) 2023-2025 Lightpanda (Selecy SAS)
//
// Maifee Ul Asad <maifeeulasad@gmail.com>
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

//! Cross-Origin Resource Sharing (CORS) implementation

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Result of CORS processing for a request
pub const CorsResult = struct {
    /// CORS headers to add to the response
    headers: Headers,
    /// Headers to add to Vary response header for caching
    vary: [][]u8,
    /// Optional response status code (e.g., 204 for preflight termination)
    status: ?u16 = null,

    pub fn deinit(self: *CorsResult, allocator: Allocator) void {
        for (0..self.headers.keys.len) |i| {
            allocator.free(self.headers.keys[i]);
            allocator.free(self.headers.values[i]);
        }
        allocator.free(self.headers.keys);
        allocator.free(self.headers.values);
        for (self.vary) |v| {
            allocator.free(v);
        }
        allocator.free(self.vary);
    }
};

/// A growable map of headers
pub const Headers = struct {
    keys: [][]u8,
    values: [][]u8,

    pub fn init(_: Allocator) Headers {
        return .{ .keys = &.{}, .values = &.{} };
    }

    pub fn put(self: *Headers, allocator: Allocator, key: []const u8, value: []const u8) !void {
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);

        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);

        if (self.keys.len == 0) {
            const new_keys = try allocator.alloc([]u8, 1);
            errdefer allocator.free(new_keys);
            const new_values = try allocator.alloc([]u8, 1);
            self.keys = new_keys;
            self.values = new_values;
        } else {
            self.keys = try allocator.realloc(self.keys, self.keys.len + 1);
            self.values = try allocator.realloc(self.values, self.values.len + 1);
        }
        self.keys[self.keys.len - 1] = key_copy;
        self.values[self.values.len - 1] = value_copy;
    }

    pub fn contains(self: *const Headers, key: []const u8) bool {
        for (self.keys) |k| {
            if (std.ascii.eqlIgnoreCase(k, key)) return true;
        }
        return false;
    }

    pub fn get(self: *const Headers, key: []const u8) ?[]const u8 {
        for (self.keys, 0..) |k, i| {
            if (std.ascii.eqlIgnoreCase(k, key)) return self.values[i];
        }
        return null;
    }
};

/// Origin matching result
const OriginMatch = enum { yes, no, any };

/// Callback function type for dynamic origin validation
pub const OriginsFunction = *const fn (origin: []const u8) bool;

/// Allowed origins: either a list of specific origins or a validation function
pub const Origins = union(enum) {
    list: []const []const u8,
    function: OriginsFunction,

    pub fn deinit(self: *Origins, allocator: Allocator) void {
        _ = self;
        _ = allocator;
        // Origins are treated as borrowed slices by default.
    }
};

/// CORS configuration options
pub const CorsOptions = struct {
    /// Allowed origins for cross-origin requests
    origins: Origins,
    /// Allowed HTTP methods for cross-origin requests
    methods: []const []const u8,
    /// Allowed request headers for cross-origin requests
    request_headers: []const []const u8,
    /// Response headers to expose to JavaScript
    response_headers: []const []const u8,
    /// Whether to allow credentials (cookies, auth headers)
    supports_credentials: bool,
    /// Maximum age (in seconds) for preflight caching
    max_age: ?u32,
    /// Whether to end preflight requests with 204 No Content
    end_preflight_requests: bool,

    pub fn defaultOptions() CorsOptions {
        return .{
            .origins = .{ .list = &.{} },
            .methods = &.{ "GET", "HEAD", "POST" },
            .request_headers = &.{ "Accept", "Accept-Language", "Content-Language", "Content-Type", "Range" },
            .response_headers = &.{ "Cache-Control", "Content-Language", "Content-Type", "Expires", "Last-Modified", "Pragma" },
            .supports_credentials = false,
            .max_age = null,
            .end_preflight_requests = true,
        };
    }

    pub fn deinit(self: *CorsOptions, allocator: Allocator) void {
        self.origins.deinit(allocator);
    }
};

/// Request headers as a simple map
pub const RequestHeaders = struct {
    /// Header values (lowercase keys)
    values: std.StringHashMap([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) RequestHeaders {
        return .{ .allocator = allocator, .values = std.StringHashMap([]const u8).init(allocator) };
    }

    pub fn deinit(self: *RequestHeaders) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.values.deinit();
    }

    pub fn put(self: *RequestHeaders, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        for (key_copy) |*c| c.* = std.ascii.toLower(c.*);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        try self.values.put(key_copy, value_copy);
    }

    pub fn getOrigin(self: *const RequestHeaders) ?[]const u8 {
        return self.values.get("origin");
    }

    pub fn getAccessControlRequestMethod(self: *const RequestHeaders) ?[]const u8 {
        return self.values.get("access-control-request-method");
    }

    pub fn getAccessControlRequestHeaders(self: *const RequestHeaders) ?[]const u8 {
        return self.values.get("access-control-request-headers");
    }
};

/// Parse HTTP headers from a raw string
pub fn parseHeaders(allocator: Allocator, raw: []const u8) !RequestHeaders {
    var headers = RequestHeaders.init(allocator);
    errdefer headers.deinit();

    var line_start: usize = 0;
    while (line_start < raw.len) {
        const cr = std.mem.indexOfScalarPos(u8, raw, line_start, '\r');
        const lf = std.mem.indexOfScalarPos(u8, raw, line_start, '\n');
        var line_end: usize = raw.len;
        if (cr) |c| line_end = c;
        if (lf) |l| {
            if (l < line_end) line_end = l;
        }
        const line = raw[line_start..line_end];
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try headers.put(name, value);

        line_start = line_end;
        while (line_start < raw.len and (raw[line_start] == '\r' or raw[line_start] == '\n')) {
            line_start += 1;
        }
    }

    return headers;
}

fn checkOriginMatch(origin: []const u8, origins: *const Origins) OriginMatch {
    switch (origins.*) {
        .list => |list| {
            if (list.len == 0) return .any;
            for (list) |allowed| {
                if (std.mem.eql(u8, origin, allowed)) return .yes;
            }
            return .no;
        },
        .function => |func| return if (func(origin)) .yes else .no,
    }
}

pub fn isSimpleRequestHeader(header: []const u8) bool {
    return std.ascii.eqlIgnoreCase(header, "Accept") or
        std.ascii.eqlIgnoreCase(header, "Accept-Language") or
        std.ascii.eqlIgnoreCase(header, "Content-Language") or
        std.ascii.eqlIgnoreCase(header, "Content-Type") or
        std.ascii.eqlIgnoreCase(header, "Range");
}

pub fn isSimpleContentType(content_type: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    const base_type = std.mem.trim(u8, content_type[0..colon], " \t");
    return std.ascii.eqlIgnoreCase(base_type, "application/x-www-form-urlencoded") or
        std.ascii.eqlIgnoreCase(base_type, "multipart/form-data") or
        std.ascii.eqlIgnoreCase(base_type, "text/plain");
}

pub fn isSimpleMethod(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "GET") or
        std.ascii.eqlIgnoreCase(method, "HEAD") or
        std.ascii.eqlIgnoreCase(method, "POST");
}

pub fn isSimpleRequest(method: []const u8, headers: *const RequestHeaders) bool {
    if (!isSimpleMethod(method)) return false;

    if (std.ascii.eqlIgnoreCase(method, "POST")) {
        if (headers.values.get("content-type")) |ct| {
            if (!isSimpleContentType(ct)) return false;
        }
    }

    var it = headers.values.iterator();
    while (it.next()) |entry| {
        if (!isSimpleRequestHeader(entry.key_ptr.*) and !std.ascii.eqlIgnoreCase(entry.key_ptr.*, "origin")) {
            return false;
        }
    }

    return true;
}

pub fn processCors(
    allocator: Allocator,
    options: *const CorsOptions,
    method: []const u8,
    headers: *const RequestHeaders,
) !CorsResult {
    var result = CorsResult{ .headers = Headers.init(allocator), .vary = &.{} };
    errdefer result.deinit(allocator);

    const origin = headers.getOrigin() orelse return result;

    const origin_match = checkOriginMatch(origin, &options.origins);
    if (origin_match == .no) return result;

    if (origin_match != .no) {
        const new_vary = if (result.vary.len == 0)
            try allocator.alloc([]u8, 1)
        else
            try allocator.realloc(result.vary, result.vary.len + 1);
        new_vary[new_vary.len - 1] = try allocator.dupe(u8, "Origin");
        result.vary = new_vary;
    }

    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) {
        const ac_request_method = headers.getAccessControlRequestMethod() orelse return result;

        var method_allowed = false;
        for (options.methods) |allowed| {
            if (std.ascii.eqlIgnoreCase(ac_request_method, allowed)) {
                method_allowed = true;
                break;
            }
        }
        if (!method_allowed) {
            if (options.end_preflight_requests) result.status = 204;
            return result;
        }

        if (headers.getAccessControlRequestHeaders()) |raw| {
            var start: usize = 0;
            while (start < raw.len) {
                const comma = std.mem.indexOfScalarPos(u8, raw, start, ',') orelse raw.len;
                const request_header = std.mem.trim(u8, raw[start..comma], " \t");

                if (request_header.len > 0 and
                    !std.ascii.eqlIgnoreCase(request_header, "origin") and
                    !isSimpleRequestHeader(request_header))
                {
                    var header_allowed = false;
                    for (options.request_headers) |allowed| {
                        if (std.ascii.eqlIgnoreCase(request_header, allowed)) {
                            header_allowed = true;
                            break;
                        }
                    }
                    if (!header_allowed) {
                        if (options.end_preflight_requests) result.status = 204;
                        return result;
                    }
                }

                if (comma == raw.len) break;
                start = comma + 1;
            }
        }

        try setCorsResponseHeaders(allocator, &result, options, origin);
        try setPreflightResponseHeaders(allocator, &result, options);

        if (options.max_age) |max_age| {
            var max_age_str: [16]u8 = undefined;
            const max_age_formatted = try std.fmt.bufPrint(&max_age_str, "{d}", .{max_age});
            try result.headers.put(allocator, "Access-Control-Max-Age", max_age_formatted);
        }

        if (options.end_preflight_requests) result.status = 204;
        return result;
    }

    try setCorsResponseHeaders(allocator, &result, options, origin);

    if (try buildExposeHeadersValue(allocator, options.response_headers)) |exposed_value| {
        defer allocator.free(exposed_value);
        try result.headers.put(allocator, "Access-Control-Expose-Headers", exposed_value);
    }

    return result;
}

fn setCorsResponseHeaders(
    allocator: Allocator,
    result: *CorsResult,
    options: *const CorsOptions,
    origin: []const u8,
) !void {
    if (options.supports_credentials) {
        try result.headers.put(allocator, "Access-Control-Allow-Origin", origin);
        try result.headers.put(allocator, "Access-Control-Allow-Credentials", "true");
    } else {
        switch (options.origins) {
            .list => |origins| {
                if (origins.len == 0) {
                    try result.headers.put(allocator, "Access-Control-Allow-Origin", "*");
                } else {
                    try result.headers.put(allocator, "Access-Control-Allow-Origin", origin);
                }
            },
            .function => {
                try result.headers.put(allocator, "Access-Control-Allow-Origin", origin);
            },
        }
    }
}

fn setPreflightResponseHeaders(
    allocator: Allocator,
    result: *CorsResult,
    options: *const CorsOptions,
) !void {
    const methods_value = try std.mem.join(allocator, ", ", options.methods);
    defer allocator.free(methods_value);
    try result.headers.put(allocator, "Access-Control-Allow-Methods", methods_value);

    const headers_value = try std.mem.join(allocator, ", ", options.request_headers);
    defer allocator.free(headers_value);
    try result.headers.put(allocator, "Access-Control-Allow-Headers", headers_value);
}

fn isSimpleResponseHeader(header: []const u8) bool {
    return std.ascii.eqlIgnoreCase(header, "Cache-Control") or
        std.ascii.eqlIgnoreCase(header, "Content-Language") or
        std.ascii.eqlIgnoreCase(header, "Content-Type") or
        std.ascii.eqlIgnoreCase(header, "Expires") or
        std.ascii.eqlIgnoreCase(header, "Last-Modified") or
        std.ascii.eqlIgnoreCase(header, "Pragma");
}

fn buildExposeHeadersValue(allocator: Allocator, response_headers: []const []const u8) !?[]u8 {
    var count: usize = 0;
    var total_len: usize = 0;

    for (response_headers) |header| {
        if (isSimpleResponseHeader(header)) continue;
        if (count > 0) total_len += 2;
        total_len += header.len;
        count += 1;
    }

    if (count == 0) return null;

    var out = try allocator.alloc(u8, total_len);
    var at: usize = 0;
    var written: usize = 0;

    for (response_headers) |header| {
        if (isSimpleResponseHeader(header)) continue;
        if (written > 0) {
            out[at] = ',';
            out[at + 1] = ' ';
            at += 2;
        }
        @memcpy(out[at .. at + header.len], header);
        at += header.len;
        written += 1;
    }

    return out;
}

/// Validate response headers for client-side CORS checks
pub fn isResponseAllowed(
    allow_origin: ?[]const u8,
    allow_credentials: bool,
    request_origin: []const u8,
    request_credentials: bool,
) bool {
    const ao = allow_origin orelse return false;

    if (request_credentials) {
        if (!allow_credentials) return false;
        if (std.ascii.eqlIgnoreCase(ao, "*")) return false;
        return std.mem.eql(u8, ao, request_origin);
    }

    if (std.ascii.eqlIgnoreCase(ao, "*")) return true;
    return std.mem.eql(u8, ao, request_origin);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseHeaders: basic headers" {
    const raw = "Host: example.com\r\nContent-Type: application/json\r\n\r\n";
    var headers = try parseHeaders(testing.allocator, raw);
    defer headers.deinit();

    try testing.expectEqualStrings("example.com", headers.values.get("host").?);
    try testing.expectEqualStrings("application/json", headers.values.get("content-type").?);
    try testing.expect(headers.values.get("accept") == null);
}

test "isSimpleMethod: valid methods" {
    try testing.expect(isSimpleMethod("GET"));
    try testing.expect(isSimpleMethod("HEAD"));
    try testing.expect(isSimpleMethod("POST"));
    try testing.expect(isSimpleMethod("get"));
    try testing.expect(isSimpleMethod("post"));
}

test "isSimpleContentType: valid types" {
    try testing.expect(isSimpleContentType("application/x-www-form-urlencoded"));
    try testing.expect(isSimpleContentType("multipart/form-data"));
    try testing.expect(isSimpleContentType("text/plain"));
    try testing.expect(isSimpleContentType("application/x-www-form-urlencoded; charset=utf-8"));
}

test "isSimpleRequestHeader: valid headers" {
    try testing.expect(isSimpleRequestHeader("Accept"));
    try testing.expect(isSimpleRequestHeader("Accept-Language"));
    try testing.expect(isSimpleRequestHeader("Content-Language"));
    try testing.expect(isSimpleRequestHeader("Content-Type"));
    try testing.expect(isSimpleRequestHeader("Range"));
}

test "processCors: simple GET with wildcard origin" {
    var options = CorsOptions.defaultOptions();
    defer options.deinit(testing.allocator);

    var headers = RequestHeaders.init(testing.allocator);
    defer headers.deinit();
    try headers.put("origin", "https://example.com");

    var result = try processCors(testing.allocator, &options, "GET", &headers);
    defer result.deinit(testing.allocator);

    try testing.expectEqualStrings("*", result.headers.get("Access-Control-Allow-Origin").?);
    try testing.expectEqual(null, result.status);
}

test "processCors: preflight request" {
    var options = CorsOptions.defaultOptions();
    options.max_age = 86400;
    defer options.deinit(testing.allocator);

    var headers = RequestHeaders.init(testing.allocator);
    defer headers.deinit();
    try headers.put("origin", "https://example.com");
    try headers.put("access-control-request-method", "POST");
    try headers.put("access-control-request-headers", "Content-Type");

    var result = try processCors(testing.allocator, &options, "OPTIONS", &headers);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(204, result.status);
    try testing.expect(result.headers.contains("Access-Control-Allow-Origin"));
    try testing.expect(result.headers.contains("Access-Control-Allow-Methods"));
    try testing.expect(result.headers.contains("Access-Control-Allow-Headers"));
    try testing.expect(result.headers.contains("Access-Control-Max-Age"));
}

test "isResponseAllowed: credentials" {
    try testing.expect(isResponseAllowed("https://example.com", true, "https://example.com", true));
    try testing.expect(!isResponseAllowed("*", true, "https://example.com", true));
    try testing.expect(!isResponseAllowed("https://example.com", false, "https://example.com", true));
}
