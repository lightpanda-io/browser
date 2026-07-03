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
const crypto = @import("sys/libcrypto.zig");
const Config = @import("Config.zig");
const log = @import("log.zig");

/// Sole purpose of this client is to do updates; hence, its very minimal.
const Updater = @This();
arena: std.heap.ArenaAllocator,
x509_store: *crypto.X509_STORE,
config: *const Config,

/// Initializes the update client; meant to be used as singleton.
pub fn init(allocator: Allocator, config: *const Config) !Updater {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    Network.globalInit(allocator);
    errdefer Network.globalDeinit();
    const x509_store = try Network.createX509Store(arena.allocator());

    return .{
        .arena = arena,
        .x509_store = x509_store,
        .config = config,
    };
}

pub fn deinit(self: *Updater) void {
    Network.globalDeinit();
    self.arena.deinit();
}

fn versioning() []const u8 {
    comptime {
        const version = SemanticVersion.parse(lp.build_config.version) catch unreachable;
        const pre = version.pre orelse return "";
        const index = std.mem.indexOfScalar(u8, pre, '.') orelse pre.len;
        return pre[0..index];
    }
}

/// Sends running Lightpanda version to remote to get update information.
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

    const conn = try http.Connection.init(self.x509_store, self.config, null);
    defer conn.deinit();

    const allocator = self.arena.allocator();
    const url = try std.fmt.allocPrintSentinel(
        allocator,
        "https://telemetry.lightpanda.io/v/{s}",
        .{lp.build_config.version},
        0,
    );
    defer allocator.free(url);

    // Prepare the request.
    try conn.setURL(url);
    try conn.setGetMode();
    try conn.setFollowLocation(true);

    // Wraps everything needed to receive bytes.
    const ReceiverContext = struct {
        allocator: std.mem.Allocator,
        buffer: std.ArrayList(u8) = .empty,
        err: Allocator.Error!void = {},

        fn onBytes(buffer: [*]const u8, buf_count: usize, buf_len: usize, raw_ctx: ?*anyopaque) usize {
            const ctx: *@This() = @ptrCast(@alignCast(raw_ctx));
            const chunk = buffer[0 .. buf_count * buf_len];
            ctx.buffer.appendSlice(ctx.allocator, chunk) catch |err| {
                ctx.err = err;
                return 0;
            };
            return chunk.len;
        }
    };

    try libcurl.curl_easy_setopt(conn._easy, .write_function, ReceiverContext.onBytes);
    // Set receiver context.
    var ctx = ReceiverContext{ .allocator = allocator };
    defer ctx.buffer.deinit(allocator);
    try libcurl.curl_easy_setopt(conn._easy, .write_data, &ctx);

    // Make a request.
    const status_int = conn.request(&self.config.http_headers) catch |err| {
        ctx.err catch |ctx_err| return ctx_err;
        return err;
    };
    const status: std.http.Status = @enumFromInt(status_int);
    if (status != .ok) {
        return error.UnexpectedStatus;
    }

    try writer.writeAll(ctx.buffer.items);
    return writer.flush();
}
