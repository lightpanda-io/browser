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
const Inbox = @import("../Inbox.zig");
const ArenaPool = @import("../ArenaPool.zig");
const sys_net = @import("../sys/net.zig");

const WS = @import("WS.zig");
const CDP = @import("cdp/CDP.zig");
const Driver = @import("Driver.zig");

const log = lp.log;
const posix = std.posix;
const ArenaAllocator = std.heap.ArenaAllocator;

// The worker's end of an upgraded connection (the loop's is Server.WebSocket).
// Reads/framing happen on the server run loop (readAvailable → inbox); the worker
// thread is the sole writer (send*). The two sides touch disjoint state
// (reader+inbox vs send_arena+socket write) so no lock is needed beyond the
// inbox's own.
const Link = @This();

inbox: *Inbox,
arena_pool: *ArenaPool,
socket: posix.socket_t,
socket_flags: usize,
protocol: Driver.Protocol,
reader: WS.Reader,
send_arena: ArenaAllocator,

pub fn init(
    self: *Link,
    app: *App,
    socket: posix.socket_t,
    protocol: Driver.Protocol,
    inbox: *Inbox,
) !void {
    const socket_flags = try sys_net.fcntl(socket, posix.F.GETFL, 0);
    if (lp.IS_TEST == false) {
        const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        lp.assert(socket_flags & nonblocking == nonblocking, "Link.init blocking", .{});
    }

    const config = app.config;
    const allocator = app.allocator;

    self.* = .{
        .inbox = inbox,
        .socket = socket,
        .protocol = protocol,
        .arena_pool = &app.arena_pool,
        .socket_flags = socket_flags,
        .reader = try .init(allocator, config.cdpMaxMessageSize()),
        .send_arena = ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *Link) void {
    self.reader.deinit();
    self.send_arena.deinit();
}

pub fn send(self: *Link, data: []const u8) !void {
    var pos: usize = 0;
    var changed_to_blocking: bool = false;
    defer _ = self.send_arena.reset(.{ .retain_with_limit = 1024 * 32 });

    defer if (changed_to_blocking) {
        _ = sys_net.fcntl(self.socket, posix.F.SETFL, self.socket_flags) catch |err| {
            log.err(.app, "ws restore nonblocking", .{ .err = err });
        };
    };

    LOOP: while (pos < data.len) {
        const written = sys_net.write(self.socket, data[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                // The socket is nonblocking so loop reads never stall. Writes
                // are simpler if we can block: no per-connection pending-write
                // queue with its own allocations. On WouldBlock we flip the
                // socket to blocking for this write and flip it back after.
                // Should virtually never happen.
                lp.assert(changed_to_blocking == false, "Link double block", .{});
                changed_to_blocking = true;
                _ = try sys_net.fcntl(self.socket, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
                continue :LOOP;
            },
            else => return err,
        };

        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}

pub fn sendPong(self: *Link, data: []const u8) !void {
    if (data.len == 0) {
        return self.send(&WS.EMPTY_PONG);
    }
    var header_buf: [10]u8 = undefined;
    const header = WS.frameHeader(&header_buf, .pong, data.len);

    const allocator = self.send_arena.allocator();
    const framed = try allocator.alloc(u8, header.len + data.len);
    @memcpy(framed[0..header.len], header);
    @memcpy(framed[header.len..], data);
    return self.send(framed);
}

// Websocket frames have a variable-length header (2-10 bytes server->client).
// We serialize into a buffer whose first 10 bytes are reserved, then
// backfill the header right-aligned and send the slice.
pub fn sendJSON(self: *Link, message: anytype, opts: std.json.Stringify.Options) !void {
    const allocator = self.send_arena.allocator();

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 512);
    try aw.writer.writeAll(&[_]u8{0} ** 10);
    try std.json.Stringify.value(message, opts, &aw.writer);
    const framed = WS.fillHeader(aw.toArrayList());
    return self.send(framed);
}

pub fn sendJSONRaw(self: *Link, buf: std.ArrayList(u8)) !void {
    // Dangerous API! Assumes the caller reserved the first 10 bytes in buf.
    const framed = WS.fillHeader(buf);
    return self.send(framed);
}

pub const Read = struct {
    // false once a close frame was consumed: stop reading, the worker
    // replies and disconnects itself
    keep: bool,
    // at least one frame landed in the inbox
    pushed: bool,
};

// Server loop. The socket is readable
pub fn readAvailable(self: *Link, budget: usize) !Read {
    var pushed = false;
    var remaining = budget;
    while (remaining > 0) {
        const dst = self.reader.readBuf();
        if (dst.len == 0) {
            // a partial message already fills the buffer
            return error.TooLarge;
        }
        const want = dst[0..@min(dst.len, remaining)];
        const n = posix.read(self.socket, want) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (n == 0) {
            return error.Closed;
        }
        self.reader.len += n;
        if ((try self.processMessages(&pushed)) == false) {
            return .{ .keep = false, .pushed = pushed };
        }
        remaining -= n;
        if (n < want.len) {
            // a short read: the socket is (very likely) drained
            break;
        }
    }
    return .{ .keep = true, .pushed = pushed };
}

fn processMessages(self: *Link, pushed: *bool) !bool {
    var reader = &self.reader;
    while (true) {
        const msg = (try reader.next()) orelse break;

        const keep = switch (msg.type) {
            .pong => true,
            .ping, .text, .binary => try self.handleMessage(msg, pushed),
            .close => blk: {
                _ = try self.handleMessage(msg, pushed);
                break :blk false;
            },
        };

        if (msg.cleanup_fragment) {
            reader.cleanup();
        }
        if (!keep) {
            return false;
        }
    }
    reader.compact();
    return true;
}

fn handleMessage(self: *Link, msg: WS.Message, pushed: *bool) !bool {
    switch (msg.type) {
        .text, .binary => return switch (self.protocol) {
            .cdp => self.pushCdp(msg.data, pushed),
            .bidi => self.pushBiDi(msg.data, pushed),
        },
        .ping => {
            const arena = try self.arena_pool.acquire(.tiny, "ws ping");
            errdefer arena.release();
            self.inbox.push(arena, .{ .ping = try arena.dupe(u8, msg.data) });
            pushed.* = true;
            return true;
        },
        .close => {
            const arena = try self.arena_pool.acquire(.tiny, "ws close");
            self.inbox.push(arena, .close);
            pushed.* = true;
            return true;
        },
        .pong => unreachable, // processMessages skips pong
    }
}

// Parse a CDP JSON frame on the run loop and push it already-parsed: the
// consumer's allowlist works on input.method directly and the worker
// doesn't re-parse. On parse failure push .disconnect(InvalidJSON) so the
// worker tears down, same as a fatal framing error.
fn pushCdp(self: *Link, bytes: []const u8, pushed: *bool) !bool {
    const arena = try self.arena_pool.acquire(bytes.len, "cdp data");
    errdefer arena.release();

    const raw = try arena.dupe(u8, bytes);
    const input = std.json.parseFromSliceLeaky(
        CDP.InputMessage,
        arena.allocator(),
        raw,
        .{ .ignore_unknown_fields = true },
    ) catch {
        self.inbox.push(arena, .{ .disconnect = error.InvalidJSON });
        pushed.* = true;
        return false;
    };

    self.inbox.push(arena, .{ .cdp = .{ .raw = raw, .input = input } });
    pushed.* = true;
    return true;
}

// BiDi frames are pushed raw; the worker parses them.
fn pushBiDi(self: *Link, bytes: []const u8, pushed: *bool) !bool {
    const arena = try self.arena_pool.acquire(bytes.len, "bidi data");
    errdefer arena.release();
    self.inbox.push(arena, .{ .bidi = try arena.dupe(u8, bytes) });
    pushed.* = true;
    return true;
}

// Called from the worker (Driver.shutdown) to break the loop's read.
pub fn shutdown(self: *Link) void {
    sys_net.shutdown(self.socket, .recv) catch {};
}
