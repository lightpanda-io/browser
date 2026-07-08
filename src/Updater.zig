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
x509_store: *crypto.X509_STORE,
config: *const Config,

/// Initializes the update client; meant to be used as singleton.
pub fn init(allocator: Allocator, config: *const Config) !Updater {
    Network.globalInit(allocator);
    errdefer Network.globalDeinit();
    const x509_store = try Network.createX509Store(allocator);

    return .{
        .x509_store = x509_store,
        .config = config,
    };
}

pub fn deinit(self: *Updater) void {
    Network.globalDeinit();
    crypto.X509_STORE_free(self.x509_store);
}

/// Sends running Lightpanda version to remote to get update information.
/// Outputs directly to given `Writer`.
pub fn inform(self: *Updater, writer: *std.Io.Writer) !void {
    const conn = try http.Connection.init(self.x509_store, self.config, null);
    defer conn.deinit();

    const url = std.fmt.comptimePrint("https://telemetry.lightpanda.io/v/{s}", .{lp.build_config.version});
    // Prepare the request.
    try conn.setURL(url);
    try conn.setGetMode();
    try conn.setFollowLocation(true);

    // Wraps everything needed to receive bytes.
    const ReceiverContext = struct {
        writer: *std.Io.Writer,
        err: std.Io.Writer.Error!void = {},

        /// curl -> writer.
        fn drain(
            buffer: [*]const u8,
            buf_count: usize,
            buf_len: usize,
            raw_ctx: *anyopaque,
        ) callconv(.c) usize {
            const ctx: *@This() = @ptrCast(@alignCast(raw_ctx));
            const chunk = buffer[0 .. buf_count * buf_len];
            ctx.writer.writeAll(chunk) catch |err| {
                ctx.err = err;
                return 0;
            };

            return chunk.len;
        }
    };

    // Set receiver context.
    var ctx = ReceiverContext{ .writer = writer };
    try libcurl.curl_easy_setopt(conn._easy, .write_data, &ctx);
    try libcurl.curl_easy_setopt(conn._easy, .write_function, ReceiverContext.drain);

    // Make a request.
    const status_int = conn.perform() catch |err| {
        ctx.err catch |ctx_err| return ctx_err;
        return err;
    };
    _ = status_int;
    return writer.flush();
}
