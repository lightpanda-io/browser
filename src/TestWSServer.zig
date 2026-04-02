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
const posix = std.posix;

const TestWSServer = @This();

shutdown: std.atomic.Value(bool),
listener: ?posix.socket_t,

pub fn init() TestWSServer {
    return .{
        .shutdown = .init(true),
        .listener = null,
    };
}

pub fn stop(self: *TestWSServer) void {
    self.shutdown.store(true, .release);
    if (self.listener) |socket| {
        switch (@import("builtin").target.os.tag) {
            .linux => std.posix.shutdown(socket, .recv) catch {},
            else => std.posix.close(socket),
        }
    }
}

pub fn run(self: *TestWSServer, wg: *std.Thread.WaitGroup) void {
    self.runImpl(wg) catch |err| {
        std.debug.print("WebSocket echo server error: {}\n", .{err});
    };
}

fn runImpl(self: *TestWSServer, wg: *std.Thread.WaitGroup) !void {
    const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(socket);

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 9584);

    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(socket, &addr.any, addr.getOsSockLen());
    try posix.listen(socket, 8);

    self.listener = socket;
    self.shutdown.store(false, .release);
    wg.finish();

    while (!self.shutdown.load(.acquire)) {
        var client_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client = posix.accept(socket, &client_addr, &addr_len, 0) catch |err| {
            if (self.shutdown.load(.acquire)) return;
            std.debug.print("[WS Server] Accept error: {}\n", .{err});
            continue;
        };

        const thread = std.Thread.spawn(.{}, handleClient, .{client}) catch |err| {
            std.debug.print("[WS Server] Thread spawn error: {}\n", .{err});
            posix.close(client);
            continue;
        };
        thread.detach();
    }
}

fn handleClient(client: posix.socket_t) void {
    defer posix.close(client);

    var buf: [4096]u8 = undefined;
    const n = posix.read(client, &buf) catch return;

    const request = buf[0..n];

    // Find Sec-WebSocket-Key
    const key_header = "Sec-WebSocket-Key: ";
    const key_start = std.mem.indexOf(u8, request, key_header) orelse return;
    const key_line_start = key_start + key_header.len;
    const key_end = std.mem.indexOfScalarPos(u8, request, key_line_start, '\r') orelse return;
    const key = request[key_line_start..key_end];

    // Compute accept key
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var hash: [20]u8 = undefined;
    hasher.final(&hash);

    var accept_key: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

    // Send upgrade response
    var resp_buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept_key}) catch return;
    _ = posix.write(client, resp) catch return;

    // Message loop with larger buffer for big messages
    var msg_buf: [128 * 1024]u8 = undefined;
    var recv_buf = RecvBuffer{ .buf = &msg_buf };

    while (true) {
        const frame = recv_buf.readFrame(client) orelse break;

        // Close frame - echo it back before closing
        if (frame.opcode == 8) {
            sendFrame(client, 8, "", frame.payload) catch {};
            break;
        }

        // Handle commands or echo
        if (frame.opcode == 1) { // Text
            handleTextMessage(client, frame.payload) catch break;
        } else if (frame.opcode == 2) { // Binary
            handleBinaryMessage(client, frame.payload) catch break;
        }
    }
}

const Frame = struct {
    opcode: u8,
    payload: []u8,
};

const RecvBuffer = struct {
    buf: []u8,
    start: usize = 0,
    end: usize = 0,

    fn available(self: *RecvBuffer) []u8 {
        return self.buf[self.start..self.end];
    }

    fn consume(self: *RecvBuffer, n: usize) void {
        self.start += n;
        if (self.start >= self.end) {
            self.start = 0;
            self.end = 0;
        }
    }

    fn ensureBytes(self: *RecvBuffer, client: posix.socket_t, needed: usize) bool {
        while (self.end - self.start < needed) {
            // Compact buffer if needed
            if (self.end >= self.buf.len - 1024) {
                const avail = self.end - self.start;
                std.mem.copyForwards(u8, self.buf[0..avail], self.buf[self.start..self.end]);
                self.start = 0;
                self.end = avail;
            }

            const n = posix.read(client, self.buf[self.end..]) catch return false;
            if (n == 0) return false;
            self.end += n;
        }
        return true;
    }

    fn readFrame(self: *RecvBuffer, client: posix.socket_t) ?Frame {
        // Need at least 2 bytes for basic header
        if (!self.ensureBytes(client, 2)) return null;

        const data = self.available();
        const opcode = data[0] & 0x0F;
        const masked = (data[1] & 0x80) != 0;
        var payload_len: usize = data[1] & 0x7F;
        var header_size: usize = 2;

        // Extended payload length
        if (payload_len == 126) {
            if (!self.ensureBytes(client, 4)) return null;
            const d = self.available();
            payload_len = @as(usize, d[2]) << 8 | d[3];
            header_size = 4;
        } else if (payload_len == 127) {
            if (!self.ensureBytes(client, 10)) return null;
            const d = self.available();
            payload_len = @as(usize, d[2]) << 56 |
                @as(usize, d[3]) << 48 |
                @as(usize, d[4]) << 40 |
                @as(usize, d[5]) << 32 |
                @as(usize, d[6]) << 24 |
                @as(usize, d[7]) << 16 |
                @as(usize, d[8]) << 8 |
                d[9];
            header_size = 10;
        }

        const mask_size: usize = if (masked) 4 else 0;
        const total_frame_size = header_size + mask_size + payload_len;

        if (!self.ensureBytes(client, total_frame_size)) return null;

        const frame_data = self.available();

        // Get mask key if present
        var mask_key: [4]u8 = undefined;
        if (masked) {
            @memcpy(&mask_key, frame_data[header_size..][0..4]);
        }

        // Get payload and unmask
        const payload_start = header_size + mask_size;
        const payload = frame_data[payload_start..][0..payload_len];

        if (masked) {
            for (payload, 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
        }

        self.consume(total_frame_size);

        return .{ .opcode = opcode, .payload = payload };
    }
};

fn handleTextMessage(client: posix.socket_t, payload: []const u8) !void {
    // Command: force-close - close socket immediately without close frame
    if (std.mem.eql(u8, payload, "force-close")) {
        return error.ForceClose;
    }

    // Command: send-large:N - send a message of N bytes
    if (std.mem.startsWith(u8, payload, "send-large:")) {
        const size_str = payload["send-large:".len..];
        const size = std.fmt.parseInt(usize, size_str, 10) catch return error.InvalidCommand;
        try sendLargeMessage(client, size);
        return;
    }

    // Command: close:CODE:REASON - send close frame with specific code/reason
    if (std.mem.startsWith(u8, payload, "close:")) {
        const rest = payload["close:".len..];
        if (std.mem.indexOf(u8, rest, ":")) |sep| {
            const code = std.fmt.parseInt(u16, rest[0..sep], 10) catch 1000;
            const reason = rest[sep + 1 ..];
            try sendCloseFrame(client, code, reason);
        }
        return;
    }

    // Default: echo with "echo-" prefix
    const prefix = "echo-";
    try sendFrame(client, 1, prefix, payload);
}

fn handleBinaryMessage(client: posix.socket_t, payload: []const u8) !void {
    // Echo binary data back with byte 0xEE prepended as marker
    const marker = [_]u8{0xEE};
    try sendFrame(client, 2, &marker, payload);
}

fn sendFrame(client: posix.socket_t, opcode: u8, prefix: []const u8, payload: []const u8) !void {
    const total_len = prefix.len + payload.len;

    // Build header
    var header: [10]u8 = undefined;
    var header_len: usize = 2;

    header[0] = 0x80 | opcode; // FIN + opcode

    if (total_len <= 125) {
        header[1] = @intCast(total_len);
    } else if (total_len <= 65535) {
        header[1] = 126;
        header[2] = @intCast((total_len >> 8) & 0xFF);
        header[3] = @intCast(total_len & 0xFF);
        header_len = 4;
    } else {
        header[1] = 127;
        header[2] = @intCast((total_len >> 56) & 0xFF);
        header[3] = @intCast((total_len >> 48) & 0xFF);
        header[4] = @intCast((total_len >> 40) & 0xFF);
        header[5] = @intCast((total_len >> 32) & 0xFF);
        header[6] = @intCast((total_len >> 24) & 0xFF);
        header[7] = @intCast((total_len >> 16) & 0xFF);
        header[8] = @intCast((total_len >> 8) & 0xFF);
        header[9] = @intCast(total_len & 0xFF);
        header_len = 10;
    }

    _ = try posix.write(client, header[0..header_len]);
    if (prefix.len > 0) {
        _ = try posix.write(client, prefix);
    }
    if (payload.len > 0) {
        _ = try posix.write(client, payload);
    }
}

fn sendLargeMessage(client: posix.socket_t, size: usize) !void {
    // Build header
    var header: [10]u8 = undefined;
    var header_len: usize = 2;

    header[0] = 0x81; // FIN + text

    if (size <= 125) {
        header[1] = @intCast(size);
    } else if (size <= 65535) {
        header[1] = 126;
        header[2] = @intCast((size >> 8) & 0xFF);
        header[3] = @intCast(size & 0xFF);
        header_len = 4;
    } else {
        header[1] = 127;
        header[2] = @intCast((size >> 56) & 0xFF);
        header[3] = @intCast((size >> 48) & 0xFF);
        header[4] = @intCast((size >> 40) & 0xFF);
        header[5] = @intCast((size >> 32) & 0xFF);
        header[6] = @intCast((size >> 24) & 0xFF);
        header[7] = @intCast((size >> 16) & 0xFF);
        header[8] = @intCast((size >> 8) & 0xFF);
        header[9] = @intCast(size & 0xFF);
        header_len = 10;
    }

    _ = try posix.write(client, header[0..header_len]);

    // Send payload in chunks - pattern of 'A'-'Z' repeating
    var sent: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (sent < size) {
        const to_send = @min(chunk.len, size - sent);
        for (chunk[0..to_send], 0..) |*b, i| {
            b.* = @intCast('A' + ((sent + i) % 26));
        }
        _ = try posix.write(client, chunk[0..to_send]);
        sent += to_send;
    }
}

fn sendCloseFrame(client: posix.socket_t, code: u16, reason: []const u8) !void {
    const reason_len = @min(reason.len, 123); // Max 123 bytes for reason
    const payload_len = 2 + reason_len;

    var frame: [129]u8 = undefined; // 2 header + 2 code + 123 reason + 2 padding
    frame[0] = 0x88; // FIN + close
    frame[1] = @intCast(payload_len);
    frame[2] = @intCast((code >> 8) & 0xFF);
    frame[3] = @intCast(code & 0xFF);
    if (reason_len > 0) {
        @memcpy(frame[4..][0..reason_len], reason[0..reason_len]);
    }

    _ = try posix.write(client, frame[0 .. 4 + reason_len]);
}
