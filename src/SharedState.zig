// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const log = @import("log.zig");
const Http = @import("http/Http.zig");
const HttpClient = @import("http/Client.zig");
const CurlShare = @import("http/CurlShare.zig");
const Snapshot = @import("browser/js/Snapshot.zig");
const Platform = @import("browser/js/Platform.zig");
const Notification = @import("Notification.zig");
const App = @import("App.zig");

const c = Http.c;

/// SharedState holds all state shared between CDP sessions (read-only after init).
/// Each SessionThread gets a reference to this and can create its own resources
/// (like HttpClient) that use the shared components.
const SharedState = @This();

platform: Platform,           // V8 platform (process-wide)
snapshot: Snapshot,           // V8 startup snapshot
ca_blob: ?c.curl_blob,        // TLS certificates
http_opts: Http.Opts,         // HTTP configuration
curl_share: *CurlShare,       // Shared HTTP resources (DNS, TLS, connections)
notification: *Notification,  // Global notification hub
allocator: Allocator,         // Thread-safe allocator
arena: ArenaAllocator,        // Arena for shared resources
owns_v8_resources: bool,      // Track whether V8 resources are owned or borrowed from App

pub const Config = struct {
    max_sessions: u32 = 10,                           // Max concurrent CDP connections
    session_memory_limit: usize = 64 * 1024 * 1024,   // 64MB per session
    run_mode: App.RunMode,
    tls_verify_host: bool = true,
    http_proxy: ?[:0]const u8 = null,
    proxy_bearer_token: ?[:0]const u8 = null,
    http_timeout_ms: ?u31 = null,
    http_connect_timeout_ms: ?u31 = null,
    http_max_host_open: ?u8 = null,
    http_max_concurrent: ?u8 = null,
    user_agent: [:0]const u8,
};

pub fn init(allocator: Allocator, config: Config) !*SharedState {
    const self = try allocator.create(SharedState);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.arena = ArenaAllocator.init(allocator);
    errdefer self.arena.deinit();

    // Initialize V8 platform (process-wide singleton)
    self.platform = try Platform.init();
    errdefer self.platform.deinit();

    // Load V8 startup snapshot
    self.snapshot = try Snapshot.load();
    errdefer self.snapshot.deinit();

    self.owns_v8_resources = true;

    // Initialize notification hub
    self.notification = try Notification.init(allocator, null);
    errdefer self.notification.deinit();

    // Build HTTP options
    const arena_alloc = self.arena.allocator();
    var adjusted_opts = Http.Opts{
        .max_host_open = config.http_max_host_open orelse 4,
        .max_concurrent = config.http_max_concurrent orelse 10,
        .timeout_ms = config.http_timeout_ms orelse 5000,
        .connect_timeout_ms = config.http_connect_timeout_ms orelse 0,
        .http_proxy = config.http_proxy,
        .tls_verify_host = config.tls_verify_host,
        .proxy_bearer_token = config.proxy_bearer_token,
        .user_agent = config.user_agent,
    };

    if (config.proxy_bearer_token) |bt| {
        adjusted_opts.proxy_bearer_token = try std.fmt.allocPrintSentinel(arena_alloc, "Proxy-Authorization: Bearer {s}", .{bt}, 0);
    }
    self.http_opts = adjusted_opts;

    // Load TLS certificates
    if (config.tls_verify_host) {
        self.ca_blob = try loadCerts(allocator, arena_alloc);
    } else {
        self.ca_blob = null;
    }

    // Initialize curl share handle for shared resources
    self.curl_share = try CurlShare.init(allocator);
    errdefer self.curl_share.deinit();

    return self;
}

/// Create SharedState by borrowing V8 resources from an existing App.
/// Use this when App is already initialized (e.g., in tests).
pub fn initFromApp(app: *App, allocator: Allocator) !*SharedState {
    const self = try allocator.create(SharedState);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.arena = ArenaAllocator.init(allocator);
    errdefer self.arena.deinit();

    // Borrow V8 resources from App (don't initialize new ones)
    self.platform = app.platform;
    self.snapshot = app.snapshot;
    self.owns_v8_resources = false;

    // Initialize notification hub
    self.notification = try Notification.init(allocator, app.notification);
    errdefer self.notification.deinit();

    // Build HTTP options from App config
    const config = app.config;
    const arena_alloc = self.arena.allocator();
    var adjusted_opts = Http.Opts{
        .max_host_open = config.http_max_host_open orelse 4,
        .max_concurrent = config.http_max_concurrent orelse 10,
        .timeout_ms = config.http_timeout_ms orelse 5000,
        .connect_timeout_ms = config.http_connect_timeout_ms orelse 0,
        .http_proxy = config.http_proxy,
        .tls_verify_host = config.tls_verify_host,
        .proxy_bearer_token = config.proxy_bearer_token,
        .user_agent = config.user_agent,
    };

    if (config.proxy_bearer_token) |bt| {
        adjusted_opts.proxy_bearer_token = try std.fmt.allocPrintSentinel(arena_alloc, "Proxy-Authorization: Bearer {s}", .{bt}, 0);
    }
    self.http_opts = adjusted_opts;

    // Load TLS certificates
    if (config.tls_verify_host) {
        self.ca_blob = try loadCerts(allocator, arena_alloc);
    } else {
        self.ca_blob = null;
    }

    // Initialize curl share handle for shared resources
    self.curl_share = try CurlShare.init(allocator);
    errdefer self.curl_share.deinit();

    return self;
}

pub fn deinit(self: *SharedState) void {
    const allocator = self.allocator;

    self.notification.deinit();
    self.curl_share.deinit();

    // Only cleanup V8 resources if we own them
    if (self.owns_v8_resources) {
        self.snapshot.deinit();
        self.platform.deinit();
    }

    self.arena.deinit();

    allocator.destroy(self);
}

/// Create a new HTTP client for a session thread.
/// The client will use the shared curl_share for DNS, TLS, and connection pooling.
pub fn createHttpClient(self: *SharedState, session_allocator: Allocator) !*HttpClient {
    return HttpClient.init(
        session_allocator,
        self.ca_blob,
        self.http_opts,
        self.curl_share.getHandle(),
    );
}

// Adapted from Http.zig
fn loadCerts(allocator: Allocator, arena: Allocator) !c.curl_blob {
    var bundle: std.crypto.Certificate.Bundle = .{};
    try bundle.rescan(allocator);
    defer bundle.deinit(allocator);

    const bytes = bundle.bytes.items;
    if (bytes.len == 0) {
        log.warn(.app, "No system certificates", .{});
        return .{
            .len = 0,
            .flags = 0,
            .data = bytes.ptr,
        };
    }

    const encoder = std.base64.standard.Encoder;
    var arr: std.ArrayListUnmanaged(u8) = .empty;

    const encoded_size = encoder.calcSize(bytes.len);
    const buffer_size = encoded_size +
        (bundle.map.count() * 75) +
        (encoded_size / 64);
    try arr.ensureTotalCapacity(arena, buffer_size);
    var writer = arr.writer(arena);

    var it = bundle.map.valueIterator();
    while (it.next()) |index| {
        const cert = try std.crypto.Certificate.der.Element.parse(bytes, index.*);

        try writer.writeAll("-----BEGIN CERTIFICATE-----\n");
        var line_writer = LineWriter{ .inner = writer };
        try encoder.encodeWriter(&line_writer, bytes[index.*..cert.slice.end]);
        try writer.writeAll("\n-----END CERTIFICATE-----\n");
    }

    return .{
        .len = arr.items.len,
        .data = arr.items.ptr,
        .flags = 0,
    };
}

const LineWriter = struct {
    col: usize = 0,
    inner: std.ArrayListUnmanaged(u8).Writer,

    pub fn writeAll(self: *LineWriter, data: []const u8) !void {
        var lwriter = self.inner;

        var col = self.col;
        const len = 64 - col;

        var remain = data;
        if (remain.len > len) {
            col = 0;
            try lwriter.writeAll(data[0..len]);
            try lwriter.writeByte('\n');
            remain = data[len..];
        }

        while (remain.len > 64) {
            try lwriter.writeAll(remain[0..64]);
            try lwriter.writeByte('\n');
            remain = data[len..];
        }
        try lwriter.writeAll(remain);
        self.col = col + remain.len;
    }
};
