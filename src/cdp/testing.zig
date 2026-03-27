// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const posix = std.posix;

const CDP = @import("CDP.zig");
const Server = @import("../Server.zig");

const base = @import("../testing.zig");
pub const allocator = base.allocator;
pub const expectJson = base.expectJson;
pub const expect = std.testing.expect;
pub const expectEqual = base.expectEqual;
pub const expectError = base.expectError;
pub const expectEqualSlices = base.expectEqualSlices;
pub const pageTest = base.pageTest;
pub const newString = base.newString;

const TestContext = struct {
    read_at: usize = 0,
    read_buf: [1024 * 32]u8 = undefined,
    cdp_: ?CDP = null,
    client: Server.Client,
    socket: posix.socket_t,
    received: std.ArrayList(json.Value) = .empty,
    received_raw: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *TestContext) void {
        if (self.cdp_) |*c| {
            c.deinit();
        }
        self.client.deinit();
        posix.close(self.socket);
        base.reset();
    }

    pub fn cdp(self: *TestContext) *CDP {
        if (self.cdp_ == null) {
            self.cdp_ = CDP.init(&self.client) catch |err| @panic(@errorName(err));
        }
        return &self.cdp_.?;
    }

    const BrowserContextOpts = struct {
        id: ?[]const u8 = null,
        target_id: ?[14]u8 = null,
        session_id: ?[]const u8 = null,
        url: ?[:0]const u8 = null,
    };
    pub fn loadBrowserContext(self: *TestContext, opts: BrowserContextOpts) !*CDP.BrowserContext(CDP) {
        var c = self.cdp();
        if (c.browser_context) |bc| {
            _ = c.disposeBrowserContext(bc.id);
        }

        _ = try c.createBrowserContext();
        var bc = &c.browser_context.?;

        if (opts.id) |id| {
            bc.id = id;
        }

        if (opts.target_id) |tid| {
            bc.target_id = tid;
        }

        if (opts.session_id) |sid| {
            bc.session_id = sid;
        }

        if (opts.url) |url| {
            if (bc.session_id == null) {
                bc.session_id = "SID-X";
            }
            if (bc.target_id == null) {
                bc.target_id = "TID-000000000Z".*;
            }
            const page = try bc.session.createPage();
            const full_url = try std.fmt.allocPrintSentinel(
                base.arena_allocator,
                "http://127.0.0.1:9582/src/browser/tests/{s}",
                .{url},
                0,
            );
            try page.navigate(full_url, .{});
            var runner = try bc.session.runner(.{});
            try runner.wait(.{ .ms = 2000 });
        }
        return bc;
    }

    pub fn processMessage(self: *TestContext, msg: anytype) !void {
        const json_message: []const u8 = blk: {
            if (@typeInfo(@TypeOf(msg)) != .pointer) {
                break :blk try std.json.Stringify.valueAlloc(base.arena_allocator, msg, .{});
            }
            // assume this is a string we want to send as-is, if it isn't, we'll
            // get a compile error, so no big deal.
            break :blk msg;
        };
        return self.cdp().processMessage(json_message);
    }

    pub fn expectSentCount(self: *TestContext, expected: usize) !void {
        try self.read();
        try expectEqual(expected, self.received.items.len);
    }

    const ExpectResultOpts = struct {
        id: ?usize = null,
        index: ?usize = null,
        session_id: ?[]const u8 = null,
    };
    pub fn expectSentResult(self: *TestContext, expected: anytype, opts: ExpectResultOpts) !void {
        const expected_result = .{
            .id = opts.id,
            .result = if (comptime @typeInfo(@TypeOf(expected)) == .null) struct {}{} else expected,
            .sessionId = opts.session_id,
        };

        try self.expectSent(expected_result, .{ .index = opts.index });
    }

    const ExpectEventOpts = struct {
        index: ?usize = null,
        session_id: ?[]const u8 = null,
    };
    pub fn expectSentEvent(self: *TestContext, method: []const u8, params: anytype, opts: ExpectEventOpts) !void {
        const expected_event = .{
            .method = method,
            .params = if (comptime @typeInfo(@TypeOf(params)) == .null) struct {}{} else params,
            .sessionId = opts.session_id,
        };

        try self.expectSent(expected_event, .{ .index = opts.index });
    }

    const ExpectErrorOpts = struct {
        id: ?usize = null,
        index: ?usize = null,
    };
    pub fn expectSentError(self: *TestContext, code: i32, message: []const u8, opts: ExpectErrorOpts) !void {
        const expected_message = .{
            .id = opts.id,
            .@"error" = .{ .code = code, .message = message },
        };
        try self.expectSent(expected_message, .{ .index = opts.index });
    }

    const SentOpts = struct {
        index: ?usize = null,
    };
    pub fn expectSent(self: *TestContext, expected: anytype, opts: SentOpts) !void {
        const serialized = try json.Stringify.valueAlloc(base.arena_allocator, expected, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        });
        for (0..5) |_| {
            for (self.received.items, 0..) |received, i| {
                if (try compareExpectedToSent(serialized, received) == false) {
                    continue;
                }

                if (opts.index) |expected_index| {
                    if (expected_index != i) {
                        std.debug.print("Expected message at index: {d}, was at index: {d}\n", .{ expected_index, i });
                        self.dumpReceived();
                        return error.ErrorAtWrongIndex;
                    }
                }
                return;
            }
            std.Thread.sleep(5 * std.time.ns_per_ms);
            try self.read();
        }
        self.dumpReceived();
        return error.ErrorNotFound;
    }

    fn dumpReceived(self: *const TestContext) void {
        std.debug.print("CDP Message Received ({d})\n", .{self.received_raw.items.len});
        for (self.received_raw.items, 0..) |received, i| {
            std.debug.print("===Message: {d}===\n{s}\n\n", .{ i, received });
        }
    }

    pub fn getSentMessage(self: *TestContext, index: usize) !?json.Value {
        for (0..5) |_| {
            if (index < self.received.items.len) {
                return self.received.items[index];
            }
            std.Thread.sleep(5 * std.time.ns_per_ms);
            try self.read();
        }
        return null;
    }

    fn read(self: *TestContext) !void {
        while (true) {
            const n = posix.read(self.socket, self.read_buf[self.read_at..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            if (n == 0) {
                return;
            }

            self.read_at += n;

            // Try to parse complete WebSocket frames
            var pos: usize = 0;
            while (pos < self.read_at) {
                // Need at least 2 bytes for header
                if (self.read_at - pos < 2) break;

                const opcode = self.read_buf[pos] & 0x0F;
                const payload_len_byte = self.read_buf[pos + 1] & 0x7F;

                var header_size: usize = 2;
                var payload_len: usize = payload_len_byte;

                if (payload_len_byte == 126) {
                    if (self.read_at - pos < 4) break;
                    payload_len = std.mem.readInt(u16, self.read_buf[pos + 2 ..][0..2], .big);
                    header_size = 4;
                }
                // Skip 8-byte length case (127) - not needed

                const frame_size = header_size + payload_len;
                if (self.read_at - pos < frame_size) break;

                // We have a complete frame - process text (1) or binary (2), skip others
                if (opcode == 1 or opcode == 2) {
                    const payload = self.read_buf[pos + header_size ..][0..payload_len];
                    const parsed = try std.json.parseFromSliceLeaky(json.Value, base.arena_allocator, payload, .{});
                    try self.received.append(base.arena_allocator, parsed);
                    try self.received_raw.append(base.arena_allocator, try base.arena_allocator.dupe(u8, payload));
                }

                pos += frame_size;
            }

            // Move remaining partial data to beginning of buffer
            if (pos > 0 and pos < self.read_at) {
                std.mem.copyForwards(u8, &self.read_buf, self.read_buf[pos..self.read_at]);
                self.read_at -= pos;
            } else if (pos == self.read_at) {
                self.read_at = 0;
            }
        }
    }
};

pub fn context() !TestContext {
    var pair: [2]posix.socket_t = undefined;
    const rc = std.c.socketpair(posix.AF.LOCAL, posix.SOCK.STREAM, 0, &pair);
    if (rc != 0) {
        return error.SocketPairFailed;
    }

    errdefer {
        posix.close(pair[0]);
        posix.close(pair[1]);
    }

    const timeout = std.mem.toBytes(posix.timeval{ .sec = 0, .usec = 5_000 });
    try posix.setsockopt(pair[0], posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(pair[0], posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
    try posix.setsockopt(pair[1], posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(pair[1], posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);

    try posix.setsockopt(pair[0], posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, 32_768)));
    try posix.setsockopt(pair[0], posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 32_768)));
    try posix.setsockopt(pair[1], posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, 32_768)));
    try posix.setsockopt(pair[1], posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 32_768)));

    const client = try Server.Client.init(pair[1], base.arena_allocator, base.test_app, "json-version", 2000);

    return .{
        .client = client,
        .socket = pair[0],
    };
}

// Zig makes this hard. When sendJSON is called, we're sending an anytype.
// We can't record that in an ArrayList(???), so we serialize it to JSON.
// Now, ideally, we could just take our expected structure, serialize it to
// json and check if the two are equal.
// Except serializing to JSON isn't deterministic.
// So we serialize the JSON then we deserialize to json.Value. And then we can
// compare our anytype expectation with the json.Value that we captured

fn compareExpectedToSent(expected: []const u8, actual: json.Value) !bool {
    const expected_value = try std.json.parseFromSlice(json.Value, std.testing.allocator, expected, .{});
    defer expected_value.deinit();
    return base.isEqualJson(expected_value.value, actual);
}
