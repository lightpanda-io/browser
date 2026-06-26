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
const lp = @import("lightpanda");

const Network = @import("network/Network.zig");
const http = @import("network/http.zig");
const libcurl = @import("sys/libcurl.zig");
const Config = @import("Config.zig");
const log = @import("log.zig");

// TODO: Remove this.
const MockVersion: [:0]const u8 = "0.16.0";

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
conn_err: enum(u1) { none, out_of_memory } = .none,
/// TODO: Come up with a solution where we don't have to embed this here?
config: *const Config,

/// Initializes the update client; meant to be used as singleton.
pub fn init(allocator: std.mem.Allocator, config: *const Config) !Updater {
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
        switch (self.conn_err) {
            .none => return err,
            .out_of_memory => return error.OutOfMemory,
        }
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
fn resetConnection(self: *Updater) !void {
    try self.conn.reset(self.config, self.ca_blob, null);
    self.conn_read_buffer.clearRetainingCapacity();
    self.conn_err = .none;
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

/// Informs about running version to given `Writer` by desired `Channel`.
pub fn inform(self: *Updater, channel: Channel, writer: *std.Io.Writer) !void {
    switch (channel) {
        .stable => {
            var versions = (try self.getVersions(.stable)).map;
            defer self.resetConnection() catch {};

            // Remove "nightly" entry.
            lp.assert(versions.swapRemove("nightly"), "Updater.inform: \"nightly\" entry not found", .{});
            // Sorting is necessary.
            var sort_ctx = SortCtx{ .keys = versions.keys() };
            versions.sort(&sort_ctx);
            sort_ctx.err catch |err| return err;

            // Get the latest.
            const values = versions.values();
            const top = values[values.len - 1];

            std.debug.print("{s}\n", .{top.version});
        },
        .nightly => {
            const versions = try self.getVersions(.nightly);
            defer self.resetConnection() catch {};
            const nightly = versions.nightly;
            // Parse to SemVer for comparison.
            const semver_nightly = try SemanticVersion.parse(nightly.version);
            const semver_current = try SemanticVersion.parse(lp.build_config.version);

            switch (semver_current.order(semver_nightly)) {
                .lt => try writer.print("A new version of Lightpanda nightly ({s}) is available.\n", .{nightly.version}),
                .eq => try writer.writeAll("You're up-to-date."),
                .gt => unreachable,
            }
            return writer.flush();
        },
    }
}

/// Invoked by `Connection` when there are body bytes.
fn onBytes(buffer: [*]const u8, buf_count: usize, buf_len: usize, raw_conn: ?*anyopaque) usize {
    const conn: *http.Connection = @ptrCast(@alignCast(raw_conn));
    const self: *Updater = @fieldParentPtr("conn", conn);

    const chunk = buffer[0 .. buf_count * buf_len];
    self.conn_read_buffer.appendSlice(self.arena.allocator(), chunk) catch |err| {
        if (err != error.OutOfMemory) unreachable;
        // We have to do this in order to report errors from here.
        self.conn_err = .out_of_memory;
        return 0;
    };
    return chunk.len;
}
