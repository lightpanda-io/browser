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

const App = @import("../App.zig");
const Config = @import("../Config.zig");

const libcurl = @import("../sys/libcurl.zig");

const http = @import("http.zig");
const IpFilter = @import("IpFilter.zig");
const RobotStore = @import("Robots.zig").RobotStore;
const WebBotAuth = @import("WebBotAuth.zig");
const RateLimiter = @import("RateLimiter.zig");
const Certificates = @import("Certificates.zig");

const Cache = @import("cache/Cache.zig");
const AdBlocker = @import("adblock/AdBlocker.zig");

const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

const Network = @This();

cache: Cache,
allocator: Allocator,
config: *const Config,
robot_store: RobotStore,
web_bot_auth: ?WebBotAuth,
rate_limiter: ?RateLimiter,
certificates: Certificates,
adblocker: ?AdBlocker,

connections: []http.Connection,
available: DoublyLinkedList = .{},
conn_mutex: std.Io.Mutex = .init,

ws_pool: std.heap.MemoryPool(http.Connection),
ws_count: usize = 0,
ws_max: u8,
ws_mutex: std.Io.Mutex = .init,

/// Optional IP filter for blocking requests to private/internal networks (--block-private-networks).
ip_filter: ?*IpFilter = null,

pub fn init(app: *App) !Network {
    libcurl.curl_global_init(.{ .ssl = true }, null) catch |err| {
        lp.assert(false, "curl global init", .{ .err = err });
    };
    errdefer libcurl.curl_global_cleanup();

    const config = app.config;
    const allocator = app.allocator;

    const certificates = try Certificates.init(allocator, config);
    errdefer certificates.deinit();

    // IP filter for blocking requests to private/internal networks.
    const block_private = config.blockPrivateNetworks();
    const cidrs: ?IpFilter.Cidrs = blk: {
        const s = config.blockCidrs() orelse break :blk null;
        break :blk try IpFilter.parseCidrList(allocator, s);
    };
    const has_cidrs = if (cidrs) |c| c.v4.len > 0 or c.v6.len > 0 or c.allow_v4.len > 0 or c.allow_v6.len > 0 else false;
    const ip_filter: ?*IpFilter = blk: {
        if (!block_private and !has_cidrs) break :blk null;
        const f = try allocator.create(IpFilter);
        f.* = IpFilter.init(block_private, cidrs);
        break :blk f;
    };
    errdefer if (ip_filter) |f| {
        f.deinit(allocator);
        allocator.destroy(f);
    };

    const count: usize = config.httpMaxConcurrent();
    const connections = try allocator.alloc(http.Connection, count);
    errdefer allocator.free(connections);

    var available: DoublyLinkedList = .{};
    for (0..count) |i| {
        connections[i] = try http.Connection.init(certificates, config, ip_filter);
        available.append(&connections[i].node);
    }

    const web_bot_auth = if (config.webBotAuth()) |wba_cfg|
        try WebBotAuth.fromConfig(allocator, &wba_cfg)
    else
        null;
    errdefer if (web_bot_auth) |wba| wba.deinit(allocator);

    var adblocker = try AdBlocker.fromConfig(allocator, config);
    errdefer if (adblocker) |*blocker| blocker.deinit();

    var cache = try Cache.init(allocator, config);
    errdefer cache.deinit();

    return .{
        .config = config,
        .allocator = allocator,
        .certificates = certificates,

        .available = available,
        .connections = connections,

        .cache = cache,
        .robot_store = RobotStore.init(allocator),
        .web_bot_auth = web_bot_auth,
        .rate_limiter = if (config.httpNavDelay()) |ms| RateLimiter.init(allocator, ms, config.httpNavBurst()) else null,
        .adblocker = adblocker,

        .ws_pool = .empty,
        .ws_max = config.wsMaxConcurrent(),

        .ip_filter = ip_filter,
    };
}

pub fn deinit(self: *Network) void {
    self.certificates.deinit();

    for (self.connections) |*conn| {
        conn.deinit();
    }
    self.allocator.free(self.connections);

    self.ws_pool.deinit(self.allocator);

    self.robot_store.deinit();
    if (self.rate_limiter) |*rl| {
        rl.deinit();
    }
    if (self.web_bot_auth) |wba| {
        wba.deinit(self.allocator);
    }

    if (self.adblocker) |*blocker| blocker.deinit();

    self.cache.deinit();

    if (self.ip_filter) |f| {
        f.deinit(self.allocator);
        self.allocator.destroy(f);
    }

    libcurl.curl_global_cleanup();
}

pub fn getConnection(self: *Network) ?*http.Connection {
    self.conn_mutex.lockUncancelable(lp.io);
    defer self.conn_mutex.unlock(lp.io);

    const node = self.available.popFirst() orelse return null;
    return @fieldParentPtr("node", node);
}

pub fn releaseConnection(self: *Network, conn: *http.Connection) void {
    switch (conn.transport) {
        .websocket => {
            conn.deinit();
            self.ws_mutex.lockUncancelable(lp.io);
            defer self.ws_mutex.unlock(lp.io);
            self.ws_pool.destroy(conn);
            self.ws_count -= 1;
        },
        else => {
            conn.reset(self.config, self.certificates, self.ip_filter) catch |err| {
                lp.assert(false, "couldn't reset curl easy", .{ .err = err });
            };
            self.conn_mutex.lockUncancelable(lp.io);
            defer self.conn_mutex.unlock(lp.io);
            self.available.append(&conn.node);
        },
    }
}

pub fn newConnection(self: *Network) ?*http.Connection {
    const conn = blk: {
        self.ws_mutex.lockUncancelable(lp.io);
        defer self.ws_mutex.unlock(lp.io);

        if (self.ws_count >= self.ws_max) {
            return null;
        }

        const c = self.ws_pool.create(self.allocator) catch return null;
        self.ws_count += 1;
        break :blk c;
    };

    // don't do this under lock
    conn.* = http.Connection.init(self.certificates, self.config, self.ip_filter) catch {
        self.ws_mutex.lockUncancelable(lp.io);
        defer self.ws_mutex.unlock(lp.io);
        self.ws_pool.destroy(conn);
        self.ws_count -= 1;

        return null;
    };

    return conn;
}

pub fn HostHashMap(comptime V: type) type {
    return std.HashMapUnmanaged([]const u8, V, HostContext, 80);
}

// Case-insensitive host key for host-keyed map
const HostContext = struct {
    pub fn hash(_: HostContext, value: []const u8) u64 {
        var key = value;
        var buf: [128]u8 = undefined;
        var h = std.hash.Wyhash.init(value.len);

        while (key.len >= 128) {
            const lower = std.ascii.lowerString(buf[0..], key[0..128]);
            h.update(lower);
            key = key[128..];
        }

        if (key.len > 0) {
            const lower = std.ascii.lowerString(buf[0..key.len], key);
            h.update(lower);
        }

        return h.final();
    }

    pub fn eql(_: HostContext, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};
