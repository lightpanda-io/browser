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

const CDP = @import("CDP.zig");

const App = @import("../../App.zig");
const Inbox = @import("../../Inbox.zig");
const ArenaPool = @import("../../ArenaPool.zig");

const WS = @import("../../network/WS.zig");
const sys_net = @import("../../sys/net.zig");

const log = lp.log;
const posix = std.posix;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Connection = @This();

// .starting covers the window until the server registers it with the network thread.
pub const State = enum { starting, live };

// reference to http_client.inbox
inbox: *Inbox,
arena_pool: *ArenaPool,
socket: posix.socket_t,
socket_flags: usize,
state: State = .starting,
reader: WS.Reader(true),
send_arena: ArenaAllocator,

pub fn init(
    self: *Connection,
    app: *App,
    socket: posix.socket_t,
    inbox: *Inbox,
) !void {
    const socket_flags = try sys_net.fcntl(socket, posix.F.GETFL, 0);
    const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    if (lp.IS_TEST == false) {
        lp.assert(socket_flags & nonblocking == nonblocking, "Connection.init blocking", .{});
    }

    const config = app.config;
    const allocator = app.allocator;

    self.* = .{
        .inbox = inbox,
        .socket = socket,
        .arena_pool = &app.arena_pool,
        .socket_flags = socket_flags,
        .reader = try .init(allocator, config.cdpMaxMessageSize()),
        .send_arena = ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *Connection) void {
    self.reader.deinit();
    self.send_arena.deinit();
}

pub fn send(self: *Connection, data: []const u8) !void {
    var pos: usize = 0;
    var changed_to_blocking: bool = false;
    defer _ = self.send_arena.reset(.{ .retain_with_limit = 1024 * 32 });

    defer if (changed_to_blocking) {
        // We had to change our socket to blocking mode to get our write out
        // We need to change it back to non-blocking.
        _ = sys_net.fcntl(self.socket, posix.F.SETFL, self.socket_flags) catch |err| {
            log.err(.app, "ws restore nonblocking", .{ .err = err });
        };
    };

    LOOP: while (pos < data.len) {
        const written = sys_net.write(self.socket, data[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                // self.socket is nonblocking, because we don't want to block
                // reads. But our life is a lot easier if we block writes,
                // largely, because we don't have to maintain a queue of pending
                // writes (which would each need their own allocations). So
                // if we get a WouldBlock error, we'll switch the socket to
                // blocking and switch it back to non-blocking after the write
                // is complete. Doesn't seem particularly efficiently, but
                // this should virtually never happen.
                lp.assert(changed_to_blocking == false, "Connection.double block", .{});
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

pub fn sendPong(self: *Connection, data: []const u8) !void {
    if (data.len == 0) {
        return self.send(&WS.EMPTY_PONG);
    }
    var header_buf: [10]u8 = undefined;
    const header = websocketHeader(&header_buf, .pong, data.len);

    const allocator = self.send_arena.allocator();
    const framed = try allocator.alloc(u8, header.len + data.len);
    @memcpy(framed[0..header.len], header);
    @memcpy(framed[header.len..], data);
    return self.send(framed);
}

// called by CDP
// Websocket frames have a variable length header. For server-client,
// it could be anywhere from 2 to 10 bytes. Our IO.Loop doesn't have
// writev, so we need to get creative. We'll JSON serialize to a
// buffer, where the first 10 bytes are reserved. We can then backfill
// the header and send the slice.
pub fn sendJSON(self: *Connection, message: anytype, opts: std.json.Stringify.Options) !void {
    const allocator = self.send_arena.allocator();

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 512);

    // reserve space for the maximum possible header
    try aw.writer.writeAll(&[_]u8{0} ** 10);
    try std.json.Stringify.value(message, opts, &aw.writer);
    const framed = fillWebsocketHeader(aw.toArrayList());
    return self.send(framed);
}

pub fn sendJSONRaw(
    self: *Connection,
    buf: std.ArrayList(u8),
) !void {
    // Dangerous API!. We assume the caller has reserved the first 10
    // bytes in `buf`.
    const framed = fillWebsocketHeader(buf);
    return self.send(framed);
}

// Append as many bytes as fit into the reader's free space. Returns
// the number of bytes copied. Used post-handshake when the network
// thread owns socket reads.
//
// Why partial: a single network read can carry more bytes than the
// reader's current free space (e.g. one large pending frame plus the
// start of another). The caller is expected to loop:
//
//   while (remaining.len > 0) {
//       const n = conn.feedBytes(remaining);
//       remaining = remaining[n..];
//       _ = try conn.processMessages();  // extracts frames + compacts
//       // processMessages also grows the reader buffer if it sees a
//       // frame header bigger than the current capacity, so the next
//       // feedBytes call has somewhere to land.
//   }
pub fn feedBytes(self: *Connection, data: []const u8) usize {
    const dst = self.reader.readBuf();
    const n = @min(data.len, dst.len);
    @memcpy(dst[0..n], data[0..n]);
    self.reader.len += n;
    return n;
}

// Framing-only iteration over received bytes. processMessages no
// longer auto-replies pong/close or sends close-on-error — the Network
// thread runs this loop and is read-only on the socket.
//
// Returns false if a close frame was seen (caller should drop the
// link) or the handler asked to stop; true if the loop exited because
// there were no more complete frames buffered.
pub fn processMessages(self: *Connection) !bool {
    var reader = &self.reader;
    while (true) {
        const msg = (try reader.next()) orelse break;

        const keep = switch (msg.type) {
            .pong => true,
            .ping, .text, .binary => try self.handleMessage(msg),
            .close => blk: {
                _ = try self.handleMessage(msg);
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

    // We might have read part of the next message. Our reader potentially
    // has to move data around in its buffer to make space.
    reader.compact();
    return true;
}

fn handleMessage(self: *Connection, msg: WS.Message) !bool {
    switch (msg.type) {
        .text, .binary => return self.pushCdp(msg.data),
        .ping => {
            const arena = try self.arena_pool.acquire(.tiny, "cdp ping");
            errdefer arena.release();
            self.inbox.push(arena, .{ .ping = try arena.dupe(u8, msg.data) });
            return true;
        },
        .close => {
            const arena = try self.arena_pool.acquire(.tiny, "cdp close");
            self.inbox.push(arena, .close);
            return true;
        },
        .pong => unreachable, // processMessages skips pong
    }
}

// Parse a CDP JSON frame on the Network thread and push it onto the
// inbox already-parsed. The consumer's allowlist check works on
// `input.method` directly (no substring matching against raw JSON),
// and the worker doesn't re-parse on dispatch. On parse failure we
// push `.disconnect(error.InvalidJSON)` so the worker tears down —
// treated the same way as a fatal WS framing error.
fn pushCdp(self: *Connection, bytes: []const u8) !bool {
    // TODO: is it worth trying to pad this for the cost overhead of parsing?
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
        return false;
    };

    self.inbox.push(arena, .{ .cdp = .{
        .raw = raw,
        .input = input,
    } });
    return true;
}

pub fn getAddress(self: *Connection) !sys_net.IpAddress {
    var storage: posix.sockaddr.storage = undefined;
    var socklen: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try posix.getpeername(self.socket, @ptrCast(&storage), &socklen);
    return sys_net.addressFromSockaddr(@ptrCast(&storage));
}

pub fn shutdown(self: *Connection) void {
    sys_net.shutdown(self.socket, .recv) catch {};
}

fn fillWebsocketHeader(buf: std.ArrayList(u8)) []const u8 {
    // can't use buf[0..10] here, because the header length
    // is variable. If it's just 2 bytes, for example, we need the
    // framed message to be:
    //     h1, h2, data
    // If we use buf[0..10], we'd get:
    //    h1, h2, 0, 0, 0, 0, 0, 0, 0, 0, data

    var header_buf: [10]u8 = undefined;

    // -10 because we reserved 10 bytes for the header above
    const header = websocketHeader(&header_buf, .text, buf.items.len - 10);
    const start = 10 - header.len;

    const message = buf.items;
    @memcpy(message[start..10], header);
    return message[start..];
}

// makes the assumption that our caller reserved the first
// 10 bytes for the header
fn websocketHeader(buf: []u8, op_code: WS.OpCode, payload_len: usize) []const u8 {
    lp.assert(buf.len == 10, "Websocket.Header", .{ .len = buf.len });

    const len = payload_len;
    buf[0] = 128 | @intFromEnum(op_code); // fin | opcode

    if (len <= 125) {
        buf[1] = @intCast(len);
        return buf[0..2];
    }

    if (len < 65536) {
        buf[1] = 126;
        buf[2] = @intCast((len >> 8) & 0xFF);
        buf[3] = @intCast(len & 0xFF);
        return buf[0..4];
    }

    buf[1] = 127;
    buf[2] = 0;
    buf[3] = 0;
    buf[4] = 0;
    buf[5] = 0;
    buf[6] = @intCast((len >> 24) & 0xFF);
    buf[7] = @intCast((len >> 16) & 0xFF);
    buf[8] = @intCast((len >> 8) & 0xFF);
    buf[9] = @intCast(len & 0xFF);
    return buf[0..10];
}
