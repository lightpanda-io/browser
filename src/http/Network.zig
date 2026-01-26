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
const Allocator = std.mem.Allocator;

const log = @import("../log.zig");
const Config = @import("../Config.zig");
const Http = @import("Http.zig");

pub const c = Http.c;

const Network = @This();

allocator: Allocator,
config: *const Config,
ca_blob: ?c.curl_blob,
user_agent: [:0]const u8,
proxy_bearer_header: ?[:0]const u8,

pub fn init(allocator: Allocator, config: *const Config) !Network {
    try Http.errorCheck(c.curl_global_init(c.CURL_GLOBAL_SSL));
    errdefer c.curl_global_cleanup();

    const user_agent = try config.userAgent(allocator);
    errdefer allocator.free(user_agent);

    var proxy_bearer_header: ?[:0]const u8 = null;
    if (config.proxyBearerToken()) |bt| {
        proxy_bearer_header = try std.fmt.allocPrintSentinel(allocator, "Proxy-Authorization: Bearer {s}", .{bt}, 0);
    }
    errdefer if (proxy_bearer_header) |h| allocator.free(h);

    var ca_blob: ?c.curl_blob = null;
    if (config.tlsVerifyHost()) {
        ca_blob = try loadCerts(allocator);
    }

    return .{
        .allocator = allocator,
        .config = config,
        .ca_blob = ca_blob,
        .user_agent = user_agent,
        .proxy_bearer_header = proxy_bearer_header,
    };
}

pub fn deinit(self: *Network) void {
    if (self.ca_blob) |ca_blob| {
        const data: [*]u8 = @ptrCast(ca_blob.data);
        self.allocator.free(data[0..ca_blob.len]);
    }
    if (self.proxy_bearer_header) |h| self.allocator.free(h);
    self.allocator.free(self.user_agent);
    c.curl_global_cleanup();
}

pub fn createHttp(self: *Network, allocator: Allocator) !Http {
    return Http.init(allocator, self);
}

// TODO: on BSD / Linux, we could just read the PEM file directly.
// This whole rescan + decode is really just needed for MacOS. On Linux
// bundle.rescan does find the .pem file(s) which could be in a few different
// places, so it's still useful, just not efficient.
fn loadCerts(allocator: Allocator) !c.curl_blob {
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
        (bundle.map.count() * 75) + // start / end per certificate + extra, just in case
        (encoded_size / 64) // newline per 64 characters
    ;
    try arr.ensureTotalCapacity(allocator, buffer_size);
    errdefer arr.deinit(allocator);
    var writer = arr.writer(allocator);

    var it = bundle.map.valueIterator();
    while (it.next()) |index| {
        const cert = try std.crypto.Certificate.der.Element.parse(bytes, index.*);

        try writer.writeAll("-----BEGIN CERTIFICATE-----\n");
        var line_writer = LineWriter{ .inner = writer };
        try encoder.encodeWriter(&line_writer, bytes[index.*..cert.slice.end]);
        try writer.writeAll("\n-----END CERTIFICATE-----\n");
    }

    // Final encoding should not be larger than our initial size estimate
    lp.assert(buffer_size > arr.items.len, "Network loadCerts", .{ .estimate = buffer_size, .len = arr.items.len });

    // Allocate exactly the size needed and copy the data
    const result = try allocator.dupe(u8, arr.items);
    // Free the original oversized allocation
    arr.deinit(allocator);

    return .{
        .len = result.len,
        .data = result.ptr,
        .flags = 0,
    };
}

// Wraps lines @ 64 columns. A PEM is basically a base64 encoded DER (which is
// what Zig has), with lines wrapped at 64 characters and with a basic header
// and footer
const LineWriter = struct {
    col: usize = 0,
    inner: std.ArrayListUnmanaged(u8).Writer,

    pub fn writeAll(self: *LineWriter, data: []const u8) !void {
        var writer = self.inner;

        var col = self.col;
        const len = 64 - col;

        var remain = data;
        if (remain.len > len) {
            col = 0;
            try writer.writeAll(data[0..len]);
            try writer.writeByte('\n');
            remain = data[len..];
        }

        while (remain.len > 64) {
            try writer.writeAll(remain[0..64]);
            try writer.writeByte('\n');
            remain = data[len..];
        }
        try writer.writeAll(remain);
        self.col = col + remain.len;
    }
};
