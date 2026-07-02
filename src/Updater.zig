// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const json = std.json;
const SemanticVersion = std.SemanticVersion;
const Allocator = std.mem.Allocator;
const lp = @import("lightpanda");

const Network = @import("network/Network.zig");
const http = @import("network/http.zig");
const libcurl = @import("sys/libcurl.zig");
const Config = @import("Config.zig");
const log = @import("log.zig");

/// Where to find versions JSON.
const VersionsUrl: [:0]const u8 = "https://get.lightpanda.io/versions.json";

pub const Channel = enum(u1) { stable, nightly };

/// Sole purpose of this client is to do updates; hence, its very minimal.
const Updater = @This();
arena: std.heap.ArenaAllocator,
ca_blob: libcurl.CurlBlob,
/// Connection where client does all of its network I/O.
conn: http.Connection,
/// Read buffer for `conn`.
conn_read_buffer: std.ArrayList(u8) = .empty,
/// Needed to report OutOfMemory.
conn_err: Allocator.Error!void = {},
/// TODO: Come up with a solution where we don't have to embed this here?
config: *const Config,

/// Initializes the update client; meant to be used as singleton.
pub fn init(allocator: Allocator, config: *const Config) !Updater {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    Network.globalInit(allocator);
    errdefer Network.globalDeinit();
    // On error, will be deinitialized by arena.
    const ca_blob = try Network.loadCerts(arena_allocator);
    // Init connection.
    const connection = try http.Connection.init(ca_blob, config, null);
    errdefer connection.deinit();

    return .{
        .arena = arena,
        .ca_blob = ca_blob,
        .conn = connection,
        .config = config,
    };
}

pub fn deinit(self: *Updater) void {
    self.conn.deinit();
    Network.globalDeinit();
    self.arena.deinit();
}

const Version = struct {
    @"aarch64-linux": Entry,
    @"aarch64-macos": Entry,
    date: []const u8,
    version: []const u8,
    @"x86_64-linux": Entry,
    @"x86_64-macos": Entry,

    const Entry = struct {
        download_url: []const u8,
        shasum: []const u8,
        size: u64,
    };
};

const Nightly = struct { nightly: Version };

/// Returns Lightpanda versions for a channel; call `resetConnection` after
/// you're done with `Versions` to do further requests.
fn getVersions(
    self: *Updater,
    comptime channel: Channel,
) !switch (channel) {
    .stable => json.ArrayHashMap(Version),
    .nightly => Nightly, // Only care about nightly record.
} {
    try self.conn.setURL(VersionsUrl);
    try self.conn.setGetMode();
    try self.conn.setFollowLocation(true);
    try self.conn.setWriteCallback(onBytes);

    const status_int = self.conn.request(&self.config.http_headers) catch |err| {
        self.conn_err catch |conn_err| return conn_err;
        return err;
    };
    const status: std.http.Status = @enumFromInt(status_int);
    if (status != .ok) {
        return error.UnexpectedStatus;
    }

    const Json = switch (channel) {
        .stable => json.ArrayHashMap(Version),
        .nightly => Nightly,
    };
    return json.parseFromSliceLeaky(
        Json,
        self.arena.allocator(),
        self.conn_read_buffer.items,
        .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_if_needed,
            .parse_numbers = true,
        },
    );
}

/// Resets everything related to `conn`.
fn resetConnection(self: *Updater) void {
    self.conn.reset(self.config, self.ca_blob, null) catch {};
    self.conn_read_buffer.clearRetainingCapacity();
    self.conn_err = {};
}

fn versioning() []const u8 {
    comptime {
        const version = SemanticVersion.parse(lp.build_config.version) catch unreachable;
        const pre = version.pre orelse return "";
        const index = std.mem.indexOfScalar(u8, pre, '.') orelse pre.len;
        return pre[0..index];
    }
}

const SortCtx = struct {
    keys: []const []const u8,
    /// Carries the error that might happen while sorting.
    err: anyerror!void = {},

    pub fn lessThan(ctx: *SortCtx, a_index: usize, b_index: usize) bool {
        const keys = ctx.keys;
        const a_version = SemanticVersion.parse(keys[a_index]) catch |err| {
            ctx.err = err;
            return false;
        };
        const b_version = SemanticVersion.parse(keys[b_index]) catch |err| {
            ctx.err = err;
            return false;
        };

        return a_version.order(b_version).compare(.lt);
    }
};

/// Informs about running version to given `Writer`.
pub fn inform(self: *Updater, writer: *std.Io.Writer) !void {
    const kind = comptime versioning();
    if (comptime std.mem.eql(u8, "dev", kind)) {
        try writer.print("Running a development version of Lightpanda ({s}).\n", .{lp.build_config.version});
        return writer.flush();
    }
    if (comptime std.mem.eql(u8, "nightly", kind)) {
        try writer.print("Running a nightly version of Lightpanda ({s}).\n", .{lp.build_config.version});
        return writer.flush();
    }

    var versions = (try self.getVersions(.stable)).map;
    defer self.resetConnection();

    // Remove "nightly" entry.
    lp.assert(versions.swapRemove("nightly"), "Updater.inform: \"nightly\" entry not found", .{});
    // Sorting is necessary.
    var sort_ctx = SortCtx{ .keys = versions.keys() };
    versions.sort(&sort_ctx);
    sort_ctx.err catch |err| return err;

    // Get the latest.
    const values = versions.values();
    const top = values[values.len - 1];

    const latest = try std.SemanticVersion.parse(top.version);
    const current = try std.SemanticVersion.parse(lp.build_config.version);

    switch (current.order(latest)) {
        .lt => try writer.print(
            \\Running an older version of Lightpanda ({s}), latest release is {s}.
            \\
            \\Update via one-liner:
            \\curl -fsSL https://pkg.lightpanda.io/install.sh | bash
            \\
        , .{ lp.build_config.version, top.version }),
        .gt, .eq => try writer.writeAll("Lightpanda is up-to-date.\n"),
    }

    return writer.flush();
}

/// Invoked by `Connection` when there are body bytes.
fn onBytes(buffer: [*]const u8, buf_count: usize, buf_len: usize, raw_conn: ?*anyopaque) usize {
    const conn: *http.Connection = @ptrCast(@alignCast(raw_conn));
    const self: *Updater = @fieldParentPtr("conn", conn);

    const chunk = buffer[0 .. buf_count * buf_len];
    self.conn_read_buffer.appendSlice(self.arena.allocator(), chunk) catch |err| {
        self.conn_err = err;
        return 0;
    };
    return chunk.len;
}
