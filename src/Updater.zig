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

// TODO: Update this with actual versions.json when ready.
const Versions = struct {
    master: Entry,
    @"0.16.0": Entry, // Consider this as stable.

    /// Single version record.
    const Entry = struct {
        version: []const u8,
        src: struct {
            tarball: []const u8,
            shasum: []const u8,
            size: u64,
        },
    };
};

/// Returns Lightpanda versions; call `resetConnection` after you're done with
/// `Versions` to do further requests.
fn getVersions(self: *Updater) !Versions {
    try self.conn.setURL(VersionsUrl);
    try self.conn.setGetMode();
    try self.conn.setFollowLocation(true);
    try self.conn.setWriteCallback(onBytes);

    const status = self.conn.request(&self.config.http_headers) catch |err| {
        switch (self.conn_err) {
            .none => return err,
            .out_of_memory => return error.OutOfMemory,
        }
    };
    if (status != 200) {
        return error.UnexpectedStatus;
    }

    return std.json.parseFromSliceLeaky(
        Versions,
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

/// Informs about running version to given `Writer` by desired `Channel`.
pub fn inform(self: *Updater, channel: Channel, writer: std.Io.Writer) void {
    const versions = try self.getVersions();
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
