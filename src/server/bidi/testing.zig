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

const base = @import("../../testing.zig");
const Frame = @import("../../browser/Frame.zig");

const BiDi = @import("BiDi.zig");
const Inbox = @import("../../Inbox.zig");
const Driver = @import("../Driver.zig");

const json = std.json;
const posix = std.posix;

pub const io = base.io;
pub const allocator = base.allocator;
pub const arena = base.arena_allocator;
pub const expect = std.testing.expect;
pub const expectEqual = base.expectEqual;
pub const expectError = base.expectError;
pub const expectString = base.expectString;
pub const expectLog = base.expectLog;
pub const silenceLog = base.silenceLog;

// Where the test http server serves src/browser/tests from.
pub const test_server = "http://127.0.0.1:9582/src/browser/tests/";

pub const TestContext = struct {
    read_at: usize = 0,
    read_buf: [1024 * 32]u8 = undefined,
    bidi_: BiDi = undefined,
    bidi_initialized: bool = false,
    inbox: Inbox = .{},
    driver: Driver = undefined,
    bidi_socket: posix.socket_t,
    socket: posix.socket_t,
    received: std.ArrayList(json.Value) = .empty,
    received_raw: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *TestContext) void {
        if (self.bidi_initialized) {
            self.driver.detach();
            self.bidi_.deinit();
        }
        self.inbox.deinit();
        _ = std.c.close(self.socket);
        _ = std.c.close(self.bidi_socket);
        base.reset();
    }

    pub fn bidi(self: *TestContext) *BiDi {
        if (!self.bidi_initialized) {
            self.bidi_.init(base.test_app, self.bidi_socket, &self.inbox, null) catch |err| @panic(@errorName(err));
            self.bidi_initialized = true;
            self.driver = .init(.{ .bidi = &self.bidi_ }, &self.inbox);
            self.driver.attach();
        }
        return &self.bidi_;
    }

    pub fn processMessage(self: *TestContext, msg: anytype) !void {
        const payload: []const u8 = blk: {
            if (@typeInfo(@TypeOf(msg)) != .pointer) {
                break :blk try json.Stringify.valueAlloc(base.arena_allocator, msg, .{});
            }
            // assume this is a string we want to send as-is; if it isn't we'll
            // get a compile error, so no big deal.
            break :blk msg;
        };
        return self.bidi().onMessage(payload);
    }

    // Starts the session every command outside the session module needs.
    pub fn startSession(self: *TestContext) !void {
        try self.processMessage(.{ .id = command_id_session, .method = "session.new" });
    }

    pub const ContextOpts = struct {
        // Relative to `test_server`. Left null, the context stays on
        // about:blank.
        url: ?[]const u8 = null,
    };

    // session.new + browsingContext.create (+ navigate), answering with the
    // generated context id so tests don't have to dig it out of the replies.
    pub fn createContext(self: *TestContext, opts: ContextOpts) ![]const u8 {
        try self.startSession();
        try self.processMessage(.{ .id = command_id_create, .method = "browsingContext.create", .params = .{ .type = "tab" } });

        const ctx = &(self.bidi().browsing_context orelse return error.NoBrowsingContext);
        const context_id = try base.arena_allocator.dupe(u8, &ctx.id);

        if (opts.url) |url| {
            try self.processMessage(.{
                .id = command_id_navigate,
                .method = "browsingContext.navigate",
                .params = .{
                    .context = context_id,
                    .url = try std.fmt.allocPrint(base.arena_allocator, test_server ++ "{s}", .{url}),
                    .wait = "none",
                },
            });
            try self.wait();
        }
        return context_id;
    }

    // Runs the page until it's done loading. Navigation is asynchronous even
    // when the command already answered.
    pub fn wait(self: *TestContext) !void {
        const b = self.bidi();
        const ctx = b.browsing_context orelse return error.NoBrowsingContext;
        var runner = b.user_context.session.runner(.{});
        try runner.waitForFrame(ctx.frame_id, 2000, .{ .until = .done });
    }

    pub fn frame(self: *TestContext) !*Frame {
        return self.bidi().user_context.session.currentFrame() orelse error.NoFrame;
    }

    const SentOpts = struct {
        id: ?usize = null,
    };

    // The result half of a `{"type": "success", "id": N, "result": ...}`
    // reply.
    pub fn expectSentResult(self: *TestContext, expected: anytype, opts: SentOpts) !void {
        return self.expectSent(.{
            .type = "success",
            .id = opts.id,
            .result = if (comptime @typeInfo(@TypeOf(expected)) == .null) struct {}{} else expected,
        });
    }

    pub fn expectSentError(self: *TestContext, code: []const u8, message: ?[]const u8, opts: SentOpts) !void {
        return self.expectSent(.{
            .type = "error",
            .id = opts.id,
            .@"error" = code,
            .message = message,
        });
    }

    pub fn expectSentEvent(self: *TestContext, method: []const u8, params: anytype) !void {
        return self.expectSent(.{
            .type = "event",
            .method = method,
            .params = if (comptime @typeInfo(@TypeOf(params)) == .null) struct {}{} else params,
        });
    }

    // Matches on the fields `expected` actually sets, so a test can assert on
    // one field of a large result. Null optionals are skipped entirely, which
    // is what makes `.id = null` mean "any id".
    pub fn expectSent(self: *TestContext, expected: anytype) !void {
        const serialized = try json.Stringify.valueAlloc(base.arena_allocator, expected, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        });
        const expected_json = try json.parseFromSliceLeaky(json.Value, base.arena_allocator, serialized, .{});

        try self.read();
        for (self.received.items) |received| {
            if (try base.isEqualJson(expected_json, received)) {
                return;
            }
        }

        std.debug.print("Expected:\n{s}\n\n", .{serialized});
        self.dumpReceived();
        return error.MessageNotFound;
    }

    // The raw json of the nth message sent, for assertions that don't fit the
    // subset match (a generated id, a substring of a long result).
    pub fn sentMessage(self: *TestContext, index: usize) !json.Value {
        try self.read();
        if (index >= self.received.items.len) {
            self.dumpReceived();
            return error.MessageNotFound;
        }
        return self.received.items[index];
    }

    // No reply for `id` yet: the command is being held open.
    pub fn expectNotAnswered(self: *TestContext, id: usize) !void {
        try self.read();
        for (self.received.items) |received| {
            const got = received.object.get("id") orelse continue;
            if (got == .integer and got.integer == id) {
                self.dumpReceived();
                return error.UnexpectedAnswer;
            }
        }
    }

    pub fn expectSentCount(self: *TestContext, expected: usize) !void {
        try self.read();
        try expectEqual(expected, self.received.items.len);
    }

    fn dumpReceived(self: *const TestContext) void {
        std.debug.print("BiDi messages received ({d})\n", .{self.received_raw.items.len});
        for (self.received_raw.items, 0..) |received, i| {
            std.debug.print("=== Message: {d} ===\n{s}\n\n", .{ i, received });
        }
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

            var pos: usize = 0;
            while (pos < self.read_at) {
                // 2-byte header minimum
                if (self.read_at - pos < 2) break;

                const opcode = self.read_buf[pos] & 0x0F;
                const payload_len_byte = self.read_buf[pos + 1] & 0x7F;

                var header_size: usize = 2;
                var payload_len: usize = payload_len_byte;
                if (payload_len_byte == 126) {
                    if (self.read_at - pos < 4) break;
                    payload_len = std.mem.readInt(u16, self.read_buf[pos + 2 ..][0..2], .big);
                    header_size = 4;
                } else if (payload_len_byte == 127) {
                    if (self.read_at - pos < 10) break;
                    payload_len = @intCast(std.mem.readInt(u64, self.read_buf[pos + 2 ..][0..8], .big));
                    header_size = 10;
                }

                const frame_size = header_size + payload_len;
                if (self.read_at - pos < frame_size) break;

                // text (1) or binary (2); control frames aren't interesting here
                if (opcode == 1 or opcode == 2) {
                    const payload = self.read_buf[pos + header_size ..][0..payload_len];
                    try self.received.append(base.arena_allocator, try json.parseFromSliceLeaky(json.Value, base.arena_allocator, payload, .{}));
                    try self.received_raw.append(base.arena_allocator, try base.arena_allocator.dupe(u8, payload));
                }
                pos += frame_size;
            }

            if (pos > 0 and pos < self.read_at) {
                std.mem.copyForwards(u8, &self.read_buf, self.read_buf[pos..self.read_at]);
                self.read_at -= pos;
            } else if (pos == self.read_at) {
                self.read_at = 0;
            }
        }
    }
};

// Ids for the setup commands, well clear of what a test uses so a stray
// match can't come from the harness.
const command_id_session = 9001;
const command_id_create = 9002;
const command_id_navigate = 9003;

pub fn context() !TestContext {
    var pair: [2]posix.socket_t = undefined;
    if (std.c.socketpair(posix.AF.LOCAL, posix.SOCK.STREAM, 0, &pair) != 0) {
        return error.SocketPairFailed;
    }

    errdefer {
        _ = std.c.close(pair[0]);
        _ = std.c.close(pair[1]);
    }

    const timeout = std.mem.toBytes(posix.timeval{ .sec = 0, .usec = 5_000 });
    const buffer_size = std.mem.toBytes(@as(c_int, 32_768));
    for (pair) |socket| {
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVBUF, &buffer_size);
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDBUF, &buffer_size);
    }

    return .{
        .bidi_socket = pair[1],
        .socket = pair[0],
    };
}
