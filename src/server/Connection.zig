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
const WS = @import("../network/WS.zig");
const sys_net = @import("../sys/net.zig");
const ArenaPool = @import("../ArenaPool.zig");

const CDP = @import("cdp/CDP.zig");

const log = lp.log;
const posix = std.posix;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Connection = @This();

// is .starting until server.track is called
const State = enum { starting, live };

const Protocol = enum { cdp, bidi };

// reference to http_client.inbox
inbox: *Inbox,
arena_pool: *ArenaPool,
socket: posix.socket_t,
socket_flags: usize,
state: State = .starting,
protocol: Protocol,
reader: WS.Reader(true),
send_arena: ArenaAllocator,

pub fn init(
    self: *Connection,
    app: *App,
    socket: posix.socket_t,
    protocol: Protocol,
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
        .protocol = protocol,
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
    const header = WS.frameHeader(&header_buf, .pong, data.len);

    const allocator = self.send_arena.allocator();
    const framed = try allocator.alloc(u8, header.len + data.len);
    @memcpy(framed[0..header.len], header);
    @memcpy(framed[header.len..], data);
    return self.send(framed);
}

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
    const framed = WS.fillHeader(aw.toArrayList());
    return self.send(framed);
}

pub fn sendJSONRaw(self: *Connection, buf: std.ArrayList(u8)) !void {
    // Dangerous API!. We assume the caller has reserved the first 10
    // bytes in `buf`.
    const framed = WS.fillHeader(buf);
    return self.send(framed);
}

pub fn feed(self: *Connection, data: []const u8) !bool {
    var remaining = data;
    while (remaining.len > 0) {
        // we copy what will fit into our read buffer
        const dst = self.reader.readBuf();
        const used = @min(remaining.len, dst.len);
        @memcpy(dst[0..used], remaining[0..used]);
        self.reader.len += used;

        // If we copied 1+ valid messages, this will process it.
        if ((try self.processMessages()) == false) {
            return false;
        }

        remaining = remaining[used..];
    }
    return true;
}

// Framing-only iteration over received bytes. Will process as many messages
// as are buffered.
fn processMessages(self: *Connection) !bool {
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
        .text, .binary => return switch (self.protocol) {
            .cdp => self.pushCdp(msg.data),
            .bidi => self.pushBiDi(msg.data),
        },
        .ping => {
            const arena = try self.arena_pool.acquire(.tiny, "ws ping");
            errdefer arena.release();
            self.inbox.push(arena, .{ .ping = try arena.dupe(u8, msg.data) });
            return true;
        },
        .close => {
            const arena = try self.arena_pool.acquire(.tiny, "ws close");
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

// BiDi frames are pushed raw; the worker parses them. Unlike CDP there's
// no allowlist that needs the method name on this thread yet — when BiDi
// grows request interception, this is where that parse would go.
fn pushBiDi(self: *Connection, bytes: []const u8) !bool {
    const arena = try self.arena_pool.acquire(bytes.len, "bidi data");
    errdefer arena.release();

    self.inbox.push(arena, .{ .bidi = try arena.dupe(u8, bytes) });
    return true;
}

pub fn shutdown(self: *Connection) void {
    sys_net.shutdown(self.socket, .recv) catch {};
}
