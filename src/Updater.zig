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

const http = @import("network/http.zig");
const Certificates = @import("network/Certificates.zig");
const libcurl = @import("sys/libcurl.zig");

const Allocator = std.mem.Allocator;

/// Sends running Lightpanda version to remote to get update information.
/// Outputs directly to given `Writer`.
pub fn inform(allocator: Allocator, config: *const lp.Config, writer: *std.Io.Writer) !void {
    const certificates = try Certificates.init(allocator, config);
    defer certificates.deinit();

    libcurl.curl_global_init(.{ .ssl = true }, null) catch |err| {
        lp.assert(false, "curl global init", .{ .err = err });
    };
    defer libcurl.curl_global_cleanup();

    var conn = try http.Connection.init(certificates, config, null);
    defer conn.deinit();

    try conn.setURL("https://telemetry.lightpanda.io/v/" ++ lp.build_config.version);
    try conn.setGetMode();
    try conn.setFollowLocation(true);

    // Wraps everything needed to receive bytes.

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

const ReceiverContext = struct {
    writer: *std.Io.Writer,
    err: std.Io.Writer.Error!void = {},

    fn drain(buffer: [*]const u8, buf_count: usize, buf_len: usize, ctx: *anyopaque) callconv(.c) usize {
        // libcurl only ever sends 1 buffer
        std.debug.assert(buf_count == 1);

        const self: *ReceiverContext = @ptrCast(@alignCast(ctx));
        const chunk = buffer[0..buf_len];
        self.writer.writeAll(chunk) catch |err| {
            self.err = err;
            return 0;
        };

        return buf_len;
    }
};
