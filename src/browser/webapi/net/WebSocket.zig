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
const builtin = @import("builtin");
const js = @import("../../js/js.zig");
const Net = @import("../../../Net.zig");
const log = @import("../../../log.zig");

const String = @import("../../../string.zig").String;
const Http = @import("../../../http/Http.zig");
const URL = @import("../../URL.zig");
const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const Blob = @import("../Blob.zig");
const CloseEvent = @import("../event/CloseEvent.zig");
const MessageEvent = @import("../event/MessageEvent.zig");

const Allocator = std.mem.Allocator;
const page_allocator = std.heap.page_allocator;

const WebSocket = @This();

_page: *Page,
_proto: *EventTarget,
_arena: Allocator,
_url: [:0]const u8,
_state: ReadyState = .connecting,
_socket: ?std.net.Stream = null,
_thread: ?std.Thread = null,
_lock: std.Thread.Mutex = .{},
_events: std.ArrayListUnmanaged(QueuedEvent) = .empty,
_poll_scheduled: bool = false,
_close_queued: bool = false,
_stop_requested: bool = false,
_retained: bool = false,
_protocol: []const u8 = "",
_extensions: []const u8 = "",
_binary_type: BinaryType = .blob,
_on_open: ?js.Function.Temp = null,
_on_message: ?js.Function.Temp = null,
_on_error: ?js.Function.Temp = null,
_on_close: ?js.Function.Temp = null,
_close_sent: bool = false,

const ReadyState = enum(u8) {
    connecting = 0,
    open = 1,
    closing = 2,
    closed = 3,
};

const QueuedEvent = union(enum) {
    open,
    message: MessagePayload,
    err,
    close: CloseInfo,
};

const MessagePayload = union(enum) {
    text: []u8,
    binary: []u8,
};

const CloseInfo = struct {
    code: u16 = 1000,
    reason: []u8 = &.{},
    was_clean: bool = true,
};

const BinaryType = enum {
    blob,
    arraybuffer,
};

const CLIENT_TEXT_OPCODE: u8 = 0x1;
const CLIENT_BINARY_OPCODE: u8 = 0x2;
const CLIENT_CLOSE_OPCODE: u8 = 0x8;
const CLIENT_PONG_OPCODE: u8 = 0xA;

pub const CONNECTING: u8 = @intFromEnum(ReadyState.connecting);
pub const OPEN: u8 = @intFromEnum(ReadyState.open);
pub const CLOSING: u8 = @intFromEnum(ReadyState.closing);
pub const CLOSED: u8 = @intFromEnum(ReadyState.closed);

pub fn init(raw_url: [:0]const u8, page: *Page) !*WebSocket {
    const arena = try page.getArena(.{ .debug = "WebSocket" });
    errdefer page.releaseArena(arena);

    const url = try URL.resolve(arena, page.base(), raw_url, .{
        .always_dupe = true,
        .encode = true,
    });
    if (URL.getHash(url).len > 0) {
        return error.SyntaxError;
    }

    const protocol = URL.getProtocol(url);
    if (!std.mem.eql(u8, protocol, "ws:") and !std.mem.eql(u8, protocol, "wss:")) {
        return error.SyntaxError;
    }

    const self = try page._factory.eventTargetWithAllocator(arena, WebSocket{
        ._page = page,
        ._proto = undefined,
        ._arena = arena,
        ._url = url,
    });
    try page.js.scheduler.add(self, WebSocket.poll, 0, .{
        .name = "WebSocket.poll",
        .low_priority = false,
    });
    self._poll_scheduled = true;

    self.connect() catch |err| {
        log.warn(.http, "websocket.connect", .{ .url = url, .err = err });
        try self.queueEvent(.err);
        try self.queueClose(.{
            .code = 1006,
            .reason = try dupCloseReason(""),
            .was_clean = false,
        });
    };

    return self;
}

pub fn deinit(self: *WebSocket, _: bool, page: *Page) void {
    self.stopAndCloseStream();
    if (self._thread) |thread| {
        thread.join();
        self._thread = null;
    }

    self.clearQueuedEvents();
    self._events.deinit(page_allocator);

    if (self._on_open) |cb| page.js.release(cb);
    if (self._on_message) |cb| page.js.release(cb);
    if (self._on_error) |cb| page.js.release(cb);
    if (self._on_close) |cb| page.js.release(cb);

    page.releaseArena(self._arena);
}

pub fn asEventTarget(self: *WebSocket) *EventTarget {
    return self._proto;
}

pub fn getUrl(self: *const WebSocket) []const u8 {
    return self._url;
}

pub fn getReadyState(self: *WebSocket) u8 {
    self._lock.lock();
    defer self._lock.unlock();
    return @intFromEnum(self._state);
}

pub fn getBufferedAmount(_: *const WebSocket) u32 {
    return 0;
}

pub fn getProtocol(self: *const WebSocket) []const u8 {
    return self._protocol;
}

pub fn getExtensions(self: *const WebSocket) []const u8 {
    return self._extensions;
}

pub fn getBinaryType(self: *const WebSocket) []const u8 {
    return switch (self._binary_type) {
        .blob => "blob",
        .arraybuffer => "arraybuffer",
    };
}

pub fn setBinaryType(self: *WebSocket, value: []const u8) !void {
    if (std.mem.eql(u8, value, "blob")) {
        self._binary_type = .blob;
    } else if (std.mem.eql(u8, value, "arraybuffer")) {
        self._binary_type = .arraybuffer;
    }
}

pub fn getOnOpen(self: *const WebSocket) ?js.Function.Temp {
    return self._on_open;
}

pub fn setOnOpen(self: *WebSocket, cb: ?js.Function.Temp) !void {
    self._on_open = cb;
}

pub fn getOnMessage(self: *const WebSocket) ?js.Function.Temp {
    return self._on_message;
}

pub fn setOnMessage(self: *WebSocket, cb: ?js.Function.Temp) !void {
    self._on_message = cb;
}

pub fn getOnError(self: *const WebSocket) ?js.Function.Temp {
    return self._on_error;
}

pub fn setOnError(self: *WebSocket, cb: ?js.Function.Temp) !void {
    self._on_error = cb;
}

pub fn getOnClose(self: *const WebSocket) ?js.Function.Temp {
    return self._on_close;
}

pub fn setOnClose(self: *WebSocket, cb: ?js.Function.Temp) !void {
    self._on_close = cb;
}

pub fn send(self: *WebSocket, data: js.Value.Temp, page: *Page) !void {
    {
        self._lock.lock();
        defer self._lock.unlock();
        if (self._state != .open or self._socket == null) {
            return error.InvalidStateError;
        }
    }

    const value = data.local(page.js.local.?);
    if (value.isString()) |_| {
        try self.sendFrame(CLIENT_TEXT_OPCODE, try value.toZig([]const u8));
        return;
    }

    if (value.isArrayBuffer() or value.isArrayBufferView() or value.isTypedArray()) {
        const typed = try value.toZig(js.TypedArray(u8));
        try self.sendFrame(CLIENT_BINARY_OPCODE, typed.values);
        return;
    }

    return error.InvalidArgument;
}

pub fn close(self: *WebSocket, code_: ?u16, reason_: ?[]const u8) !void {
    const code = code_ orelse 1000;
    const reason = reason_ orelse "";

    if (reason.len > 123 or !std.unicode.utf8ValidateSlice(reason)) {
        return error.SyntaxError;
    }

    if (code_ != null and code != 1000 and (code < 3000 or code > 4999)) {
        return error.InvalidAccessError;
    }

    {
        self._lock.lock();
        defer self._lock.unlock();
        switch (self._state) {
            .closing, .closed => return,
            else => self._state = .closing,
        }
        self._close_sent = true;
    }

    var close_payload = try std.ArrayList(u8).initCapacity(self._arena, 2 + reason.len);
    defer close_payload.deinit(self._arena);
    try close_payload.append(self._arena, @intCast((code >> 8) & 0xff));
    try close_payload.append(self._arena, @intCast(code & 0xff));
    try close_payload.appendSlice(self._arena, reason);

    self.sendFrame(CLIENT_CLOSE_OPCODE, close_payload.items) catch |err| {
        log.warn(.http, "websocket.close", .{ .url = self._url, .err = err });
        try self.queueClose(.{
            .code = 1006,
            .reason = try page_allocator.dupe(u8, ""),
            .was_clean = false,
        });
        return;
    };
}

fn connect(self: *WebSocket) !void {
    const request_url = try websocketHttpEquivalentUrl(self._arena, self._url);
    const host = URL.getHostname(self._url);
    if (host.len == 0) {
        return error.SyntaxError;
    }

    const port = try websocketPort(self._url);
    const address = resolveWebSocketAddress(self._arena, host, port) catch |err| {
        log.warn(.http, "websocket.resolve", .{ .url = self._url, .err = err });
        return err;
    };
    var stream = std.net.tcpConnectToAddress(address) catch |err| {
        log.warn(.http, "websocket.tcp_connect", .{ .url = self._url, .err = err });
        return err;
    };
    errdefer stream.close();

    const path = try websocketRequestTarget(self._arena, self._url);
    const request = try self.buildHandshakeRequest(path, request_url);

    socketWriteAll(&stream, request) catch |err| {
        log.warn(.http, "websocket.handshake.write", .{ .url = self._url, .err = err });
        return err;
    };
    self.validateHandshakeResponse(&stream) catch |err| {
        log.warn(.http, "websocket.handshake.read", .{ .url = self._url, .err = err });
        return err;
    };

    self._lock.lock();
    self._socket = stream;
    self._lock.unlock();

    try self.queueEvent(.open);
    self._thread = try std.Thread.spawn(.{}, readerMain, .{self});
}

fn resolveWebSocketAddress(allocator: Allocator, host: []const u8, port: u16) !std.net.Address {
    return std.net.Address.parseIp(host, port) catch {
        const address_list = try std.net.getAddressList(allocator, host, port);
        defer address_list.deinit();
        if (address_list.addrs.len == 0) {
            return error.UnknownHostName;
        }
        return address_list.addrs[0];
    };
}

fn buildHandshakeRequest(self: *WebSocket, target: []const u8, request_url: [:0]const u8) ![]const u8 {
    var headers = try self._page._session.browser.http_client.newHeaders();
    defer headers.deinit();

    try self._page.headersForRequestWithPolicy(self._arena, request_url, &headers, .{
        .include_credentials = true,
        .authorization_source_url = self._url,
    });

    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var sec_key_buf: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&sec_key_buf, &random_bytes);

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(self._arena);

    var writer = buf.writer(self._arena);
    try writer.print("GET {s} HTTP/1.1\r\n", .{target});
    try writer.print("Host: {s}\r\n", .{URL.getHost(self._url)});
    try writer.writeAll("Upgrade: websocket\r\n");
    try writer.writeAll("Connection: Upgrade\r\n");
    try writer.print("Sec-WebSocket-Key: {s}\r\n", .{sec_key_buf});
    try writer.writeAll("Sec-WebSocket-Version: 13\r\n");

    if (try URL.getOrigin(self._arena, self._page.url)) |origin| {
        try writer.print("Origin: {s}\r\n", .{origin});
    }

    var it = headers.iterator();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "connection") or
            std.ascii.eqlIgnoreCase(header.name, "upgrade") or
            std.ascii.eqlIgnoreCase(header.name, "host") or
            std.ascii.eqlIgnoreCase(header.name, "origin") or
            std.ascii.eqlIgnoreCase(header.name, "sec-websocket-key") or
            std.ascii.eqlIgnoreCase(header.name, "sec-websocket-version"))
        {
            continue;
        }
        try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    try writer.writeAll("\r\n");
    return buf.toOwnedSlice(self._arena);
}

fn validateHandshakeResponse(self: *WebSocket, stream: *std.net.Stream) !void {
    var response = std.ArrayList(u8).empty;
    defer response.deinit(self._arena);

    var temp: [1024]u8 = undefined;
    while (std.mem.indexOf(u8, response.items, "\r\n\r\n") == null) {
        const n = try socketRead(stream, &temp);
        if (n == 0) {
            return error.EndOfStream;
        }
        try response.appendSlice(self._arena, temp[0..n]);
        if (response.items.len > 16 * 1024) {
            return error.TooLarge;
        }
    }

    const response_bytes = response.items;
    if (!std.mem.startsWith(u8, response_bytes, "HTTP/1.1 101") and
        !std.mem.startsWith(u8, response_bytes, "HTTP/1.0 101"))
    {
        return error.NetworkError;
    }

    var saw_upgrade = false;
    var saw_connection = false;
    var saw_accept = false;

    var lines = std.mem.splitSequence(u8, response_bytes, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            saw_upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            saw_connection = std.ascii.indexOfIgnoreCase(value, "upgrade") != null;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            saw_accept = value.len > 0;
        }
    }

    if (!saw_upgrade or !saw_connection or !saw_accept) {
        log.warn(.http, "websocket.handshake.invalid", .{
            .url = self._url,
            .upgrade = saw_upgrade,
            .connection = saw_connection,
            .accept = saw_accept,
        });
        return error.NetworkError;
    }
}

fn poll(ctx: *anyopaque) !?u32 {
    const self: *WebSocket = @ptrCast(@alignCast(ctx));
    if (!self._retained) {
        self._page.js.strongRef(self);
        self._retained = true;
    }
    self.drainEvents();

    self._lock.lock();
    defer self._lock.unlock();
    if (self._state == .closed and self._events.items.len == 0) {
        if (self._retained) {
            self._page.js.weakRef(self);
            self._retained = false;
        }
        return null;
    }
    return 10;
}

fn drainEvents(self: *WebSocket) void {
    while (true) {
        const event_opt = blk: {
            self._lock.lock();
            defer self._lock.unlock();
            if (self._events.items.len == 0) break :blk null;
            break :blk self._events.orderedRemove(0);
        };
        const event_ = event_opt orelse break;
        self.dispatchQueuedEvent(event_);
    }
}

fn dispatchQueuedEvent(self: *WebSocket, event_: QueuedEvent) void {
    const page = self._page;
    switch (event_) {
        .open => {
            self._lock.lock();
            self._state = .open;
            self._lock.unlock();

            const event = Event.initTrusted(comptime .wrap("open"), null, page) catch |err| {
                log.err(.dom, "WebSocket.open", .{ .err = err });
                return;
            };
            page._event_manager.dispatchDirect(
                self.asEventTarget(),
                event,
                self._on_open,
                .{ .context = "WebSocket.open" },
            ) catch |err| {
                log.err(.dom, "WebSocket.open", .{ .err = err });
            };
        },
        .message => |payload| {
            defer switch (payload) {
                .text => |text| page_allocator.free(text),
                .binary => |bytes| page_allocator.free(bytes),
            };

            var ls: js.Local.Scope = undefined;
            page.js.localScope(&ls);
            defer ls.deinit();

            const message_value = switch (payload) {
                .text => |text| ls.local.zigValueToJs(text, .{}),
                .binary => |bytes| blk: {
                    switch (self._binary_type) {
                        .arraybuffer => break :blk ls.local.zigValueToJs(js.ArrayBuffer{ .values = bytes }, .{}),
                        .blob => {
                            const blob = Blob.init(&.{bytes}, null, page) catch |err| {
                                log.err(.dom, "WebSocket.message.blob", .{ .err = err });
                                return;
                            };
                            break :blk ls.local.zigValueToJs(blob, .{});
                        },
                    }
                },
            } catch |err| {
                log.err(.dom, "WebSocket.message.value", .{ .err = err });
                return;
            };
            const message_temp = message_value.temp() catch |err| {
                log.err(.dom, "WebSocket.message.temp", .{ .err = err });
                return;
            };

            const message_event = MessageEvent.initTrusted(comptime .wrap("message"), .{
                .data = message_temp,
                .origin = websocketEventOrigin(self._url, page),
                .source = null,
            }, page) catch |err| {
                page.js.release(message_temp);
                log.err(.dom, "WebSocket.message", .{ .err = err });
                return;
            };

            page._event_manager.dispatchDirect(
                self.asEventTarget(),
                message_event.asEvent(),
                self._on_message,
                .{ .context = "WebSocket.message" },
            ) catch |err| {
                log.err(.dom, "WebSocket.message", .{ .err = err });
            };
        },
        .err => {
            const event = Event.initTrusted(comptime .wrap("error"), null, page) catch |err| {
                log.err(.dom, "WebSocket.error", .{ .err = err });
                return;
            };
            page._event_manager.dispatchDirect(
                self.asEventTarget(),
                event,
                self._on_error,
                .{ .context = "WebSocket.error" },
            ) catch |err| {
                log.err(.dom, "WebSocket.error", .{ .err = err });
            };
        },
        .close => |info| {
            self._lock.lock();
            self._state = .closed;
            self._lock.unlock();

            defer page_allocator.free(info.reason);

            const event = CloseEvent.initTrusted(comptime .wrap("close"), .{
                .code = info.code,
                .reason = info.reason,
                .wasClean = info.was_clean,
            }, page) catch |err| {
                log.err(.dom, "WebSocket.close", .{ .err = err });
                return;
            };
            page._event_manager.dispatchDirect(
                self.asEventTarget(),
                event.asEvent(),
                self._on_close,
                .{ .context = "WebSocket.close" },
            ) catch |err| {
                log.err(.dom, "WebSocket.close", .{ .err = err });
            };
        },
    }
}

fn queueEvent(self: *WebSocket, event_: QueuedEvent) !void {
    self._lock.lock();
    defer self._lock.unlock();
    try self._events.append(page_allocator, event_);
}

fn queueClose(self: *WebSocket, info: CloseInfo) !void {
    self._lock.lock();
    defer self._lock.unlock();
    if (self._close_queued) {
        page_allocator.free(info.reason);
        return;
    }
    self._close_queued = true;
    self._state = .closed;
    try self._events.append(page_allocator, .{ .close = info });
}

fn dupCloseReason(reason: []const u8) ![]u8 {
    return try page_allocator.dupe(u8, reason);
}

fn clearQueuedEvents(self: *WebSocket) void {
    for (self._events.items) |event_| {
        switch (event_) {
            .message => |payload| switch (payload) {
                .text => |text| page_allocator.free(text),
                .binary => |bytes| page_allocator.free(bytes),
            },
            .close => |info| page_allocator.free(info.reason),
            else => {},
        }
    }
    self._events.clearRetainingCapacity();
}

fn compactReader(comptime expect_mask: bool, reader: *Net.Reader(expect_mask)) void {
    const partial_bytes = reader.len - reader.pos;
    if (partial_bytes == 0) {
        reader.pos = 0;
        reader.len = 0;
        return;
    }

    std.mem.copyForwards(u8, reader.buf[0..partial_bytes], reader.buf[reader.pos..reader.len]);
    reader.pos = 0;
    reader.len = partial_bytes;
}

fn socketRead(stream: *const std.net.Stream, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        const rc = ws2_32.recv(stream.handle, buf.ptr, @intCast(@min(buf.len, @as(usize, std.math.maxInt(i32)))), 0);
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEINTR,
                .WSAECONNABORTED,
                .WSAECONNRESET,
                .WSAESHUTDOWN,
                => 0,
                else => |err| std.os.windows.unexpectedWSAError(err),
            };
        }
        return @intCast(rc);
    }
    return std.posix.read(stream.handle, buf);
}

fn socketWriteAll(stream: *const std.net.Stream, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const written = if (builtin.os.tag == .windows) blk: {
            const ws2_32 = std.os.windows.ws2_32;
            const remaining = data[pos..];
            const rc = ws2_32.send(stream.handle, remaining.ptr, @intCast(@min(remaining.len, @as(usize, std.math.maxInt(i32)))), 0);
            if (rc == ws2_32.SOCKET_ERROR) {
                return std.os.windows.unexpectedWSAError(ws2_32.WSAGetLastError());
            }
            break :blk @as(usize, @intCast(rc));
        } else try std.posix.write(stream.handle, data[pos..]);
        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}

fn stopAndCloseStream(self: *WebSocket) void {
    self._lock.lock();
    defer self._lock.unlock();
    self._stop_requested = true;
    if (self._socket) |stream| {
        stream.close();
        self._socket = null;
    }
}

fn readerMain(self: *WebSocket) void {
    var reader = Net.Reader(false).init(page_allocator) catch |err| {
        self.queueEvent(.err) catch {};
        self.queueClose(.{ .code = 1006, .reason = dupCloseReason("") catch unreachable, .was_clean = false }) catch {};
        log.err(.http, "websocket.reader.init", .{ .url = self._url, .err = err });
        return;
    };
    defer reader.deinit();

    while (true) {
        const stream = blk: {
            self._lock.lock();
            defer self._lock.unlock();
            if (self._stop_requested) break :blk null;
            break :blk self._socket;
        } orelse break;

        const n = socketRead(&stream, reader.readBuf()) catch |err| {
            if (!self.isStopRequested()) {
                self.queueEvent(.err) catch {};
                self.queueClose(.{ .code = 1006, .reason = dupCloseReason("") catch unreachable, .was_clean = false }) catch {};
                log.warn(.http, "websocket.read", .{ .url = self._url, .err = err });
            }
            break;
        };

        if (n == 0) {
            if (!self.isStopRequested()) {
                self.queueClose(.{ .code = 1006, .reason = dupCloseReason("") catch unreachable, .was_clean = false }) catch {};
            }
            break;
        }

        reader.len += n;
        while (true) {
            const message = reader.next() catch |err| {
                self.queueEvent(.err) catch {};
                self.queueClose(.{ .code = 1006, .reason = dupCloseReason("") catch unreachable, .was_clean = false }) catch {};
                log.warn(.http, "websocket.frame", .{ .url = self._url, .err = err });
                return;
            };
            if (message == null) break;
            const msg = message.?;
            switch (msg.type) {
                .text => {
                    const payload = page_allocator.dupe(u8, msg.data) catch {
                        self.queueEvent(.err) catch {};
                        self.queueClose(.{ .code = 1006, .reason = dupCloseReason("") catch unreachable, .was_clean = false }) catch {};
                        return;
                    };
                    self.queueEvent(.{ .message = .{ .text = payload } }) catch {
                        page_allocator.free(payload);
                        return;
                    };
                },
                .ping => {
                    self.sendFrame(CLIENT_PONG_OPCODE, msg.data) catch |err| {
                        log.warn(.http, "websocket.pong", .{ .url = self._url, .err = err });
                    };
                },
                .pong => {},
                .close => {
                    const close_info = parseCloseInfo(msg.data) catch {
                        self.queueEvent(.err) catch {};
                        self.queueClose(.{ .code = 1006, .reason = dupCloseReason("") catch unreachable, .was_clean = false }) catch {};
                        return;
                    };
                    if (!self._close_sent) {
                        self.sendFrame(CLIENT_CLOSE_OPCODE, msg.data) catch |err| {
                            log.warn(.http, "websocket.close_ack", .{ .url = self._url, .err = err });
                        };
                    }
                    self.queueClose(close_info) catch {};
                    return;
                },
                .binary => {
                    const payload = page_allocator.dupe(u8, msg.data) catch {
                        self.queueEvent(.err) catch {};
                        self.queueClose(.{ .code = 1006, .reason = dupCloseReason("") catch unreachable, .was_clean = false }) catch {};
                        return;
                    };
                    self.queueEvent(.{ .message = .{ .binary = payload } }) catch {
                        page_allocator.free(payload);
                        return;
                    };
                },
            }
            if (msg.cleanup_fragment) {
                reader.cleanup();
            }
        }
        compactReader(false, &reader);
    }
}

fn parseCloseInfo(data: []const u8) !CloseInfo {
    if (data.len < 2) {
        return .{
            .code = 1000,
            .reason = try dupCloseReason(""),
            .was_clean = true,
        };
    }
    const code = (@as(u16, data[0]) << 8) | data[1];
    return .{
        .code = code,
        .reason = try dupCloseReason(data[2..]),
        .was_clean = true,
    };
}

fn isStopRequested(self: *WebSocket) bool {
    self._lock.lock();
    defer self._lock.unlock();
    return self._stop_requested;
}

fn sendFrame(self: *WebSocket, opcode: u8, payload: []const u8) !void {
    var mask_key: [4]u8 = undefined;
    std.crypto.random.bytes(&mask_key);

    const masked = try page_allocator.dupe(u8, payload);
    defer page_allocator.free(masked);
    for (masked, 0..) |byte, i| {
        masked[i] = byte ^ mask_key[i & 3];
    }

    var header: [14]u8 = undefined;
    const header_len = buildClientFrameHeader(&header, opcode, masked.len, mask_key);

    self._lock.lock();
    defer self._lock.unlock();

    const stream = self._socket orelse return error.Closed;
    try socketWriteAll(&stream, header[0..header_len]);
    try socketWriteAll(&stream, masked);
}

fn buildClientFrameHeader(buf: []u8, opcode: u8, payload_len: usize, mask_key: [4]u8) usize {
    var i: usize = 0;
    buf[i] = 0x80 | opcode;
    i += 1;

    if (payload_len <= 125) {
        buf[i] = 0x80 | @as(u8, @intCast(payload_len));
        i += 1;
    } else if (payload_len <= 0xffff) {
        buf[i] = 0x80 | 126;
        i += 1;
        buf[i] = @intCast((payload_len >> 8) & 0xff);
        buf[i + 1] = @intCast(payload_len & 0xff);
        i += 2;
    } else {
        buf[i] = 0x80 | 127;
        i += 1;
        buf[i + 0] = 0;
        buf[i + 1] = 0;
        buf[i + 2] = 0;
        buf[i + 3] = 0;
        buf[i + 4] = @intCast((payload_len >> 24) & 0xff);
        buf[i + 5] = @intCast((payload_len >> 16) & 0xff);
        buf[i + 6] = @intCast((payload_len >> 8) & 0xff);
        buf[i + 7] = @intCast(payload_len & 0xff);
        i += 8;
    }

    @memcpy(buf[i .. i + 4], &mask_key);
    i += 4;
    return i;
}

fn websocketPort(url: [:0]const u8) !u16 {
    if (URL.getPort(url).len > 0) {
        return try std.fmt.parseUnsigned(u16, URL.getPort(url), 10);
    }
    if (std.mem.eql(u8, URL.getProtocol(url), "wss:")) {
        return 443;
    }
    return 80;
}

fn websocketRequestTarget(allocator: Allocator, url: [:0]const u8) ![]const u8 {
    const pathname = URL.getPathname(url);
    const search = URL.getSearch(url);
    const path = if (pathname.len == 0) "/" else pathname;
    return if (search.len == 0)
        try allocator.dupe(u8, path)
    else
        try std.mem.concat(allocator, u8, &.{ path, search });
}

fn websocketHttpEquivalentUrl(allocator: Allocator, url: [:0]const u8) ![:0]const u8 {
    const protocol = URL.getProtocol(url);
    const http_protocol = if (std.mem.eql(u8, protocol, "wss:")) "https:" else "http:";
    return URL.buildUrl(
        allocator,
        http_protocol,
        URL.getHost(url),
        URL.getPathname(url),
        URL.getSearch(url),
        "",
    );
}

fn websocketEventOrigin(url: [:0]const u8, page: *Page) ?[]const u8 {
    const http_url = websocketHttpEquivalentUrl(page.call_arena, url) catch return null;
    return URL.getOrigin(page.call_arena, http_url) catch null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebSocket);

    pub const Meta = struct {
        pub const name = "WebSocket";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(WebSocket.deinit);
    };

    pub const constructor = bridge.constructor(WebSocket.init, .{ .dom_exception = true });
    pub const url = bridge.accessor(WebSocket.getUrl, null, .{});
    pub const readyState = bridge.accessor(WebSocket.getReadyState, null, .{});
    pub const bufferedAmount = bridge.accessor(WebSocket.getBufferedAmount, null, .{});
    pub const protocol = bridge.accessor(WebSocket.getProtocol, null, .{});
    pub const extensions = bridge.accessor(WebSocket.getExtensions, null, .{});
    pub const binaryType = bridge.accessor(WebSocket.getBinaryType, WebSocket.setBinaryType, .{});
    pub const send = bridge.function(WebSocket.send, .{ .dom_exception = true });
    pub const close = bridge.function(WebSocket.close, .{ .dom_exception = true });
    pub const onopen = bridge.accessor(WebSocket.getOnOpen, WebSocket.setOnOpen, .{});
    pub const onmessage = bridge.accessor(WebSocket.getOnMessage, WebSocket.setOnMessage, .{});
    pub const onerror = bridge.accessor(WebSocket.getOnError, WebSocket.setOnError, .{});
    pub const onclose = bridge.accessor(WebSocket.getOnClose, WebSocket.setOnClose, .{});
    pub const CONNECTING = bridge.property(WebSocket.CONNECTING, .{ .template = true, .readonly = true });
    pub const OPEN = bridge.property(WebSocket.OPEN, .{ .template = true, .readonly = true });
    pub const CLOSING = bridge.property(WebSocket.CLOSING, .{ .template = true, .readonly = true });
    pub const CLOSED = bridge.property(WebSocket.CLOSED, .{ .template = true, .readonly = true });
};

const testing = @import("../../../testing.zig");

const TestWsServer = struct {
    listener: ?std.net.Server = null,
    ready: std.Thread.WaitGroup = .{},
    last_error: ?anyerror = null,

    fn stop(self: *TestWsServer) void {
        if (self.listener) |*listener| {
            listener.stream.close();
        }
    }
};

fn testWebSocketServerThread(server: *TestWsServer) void {
    testWebSocketServerMain(server) catch |err| {
        server.last_error = err;
    };
}

fn testWebSocketServerMain(server: *TestWsServer) !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 9593);
    server.listener = try address.listen(.{ .reuse_address = true });
    server.ready.finish();

    const conn = try server.listener.?.accept();
    defer conn.stream.close();

    var handshake_buf: [4096]u8 = undefined;
    var handshake_len: usize = 0;
    while (std.mem.indexOf(u8, handshake_buf[0..handshake_len], "\r\n\r\n") == null) {
        const n = try socketRead(&conn.stream, handshake_buf[handshake_len..]);
        if (n == 0) return error.EndOfStream;
        handshake_len += n;
    }

    const request = handshake_buf[0..handshake_len];
    const key_prefix = "Sec-WebSocket-Key:";
    const key_index = std.ascii.indexOfIgnoreCase(request, key_prefix) orelse return error.InvalidRequest;
    const key_line = request[key_index + key_prefix.len ..];
    const key_end = std.mem.indexOf(u8, key_line, "\r\n") orelse return error.InvalidRequest;
    const key = std.mem.trim(u8, key_line[0..key_end], " \t");

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    var accept_buf: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    const response = try std.fmt.allocPrint(std.testing.allocator,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept_buf},
    );
    defer std.testing.allocator.free(response);
    try socketWriteAll(&conn.stream, response);

    var reader = try Net.Reader(true).init(std.testing.allocator);
    defer reader.deinit();

    while (true) {
        const n = try socketRead(&conn.stream, reader.readBuf());
        if (n == 0) return;
        reader.len += n;
        while (true) {
            const maybe_msg = try reader.next();
            const msg = maybe_msg orelse break;
            switch (msg.type) {
                .text => {
                    if (std.mem.eql(u8, msg.data, "close-me")) {
                        const payload = &[_]u8{ 0x0f, 0xa1 } ++ "server-close";
                        const frame = try serverFrame(CLIENT_CLOSE_OPCODE, payload);
                        defer std.testing.allocator.free(frame);
                        try socketWriteAll(&conn.stream, frame);
                        return;
                    }

                    const payload = try std.mem.concat(std.testing.allocator, u8, &.{ "echo:", msg.data });
                    defer std.testing.allocator.free(payload);
                    const frame = try serverFrame(CLIENT_TEXT_OPCODE, payload);
                    defer std.testing.allocator.free(frame);
                    try socketWriteAll(&conn.stream, frame);
                },
                .close => {
                    const frame = try serverFrame(CLIENT_CLOSE_OPCODE, msg.data);
                    defer std.testing.allocator.free(frame);
                    try socketWriteAll(&conn.stream, frame);
                    return;
                },
                .ping => {
                    const frame = try serverFrame(CLIENT_PONG_OPCODE, msg.data);
                    defer std.testing.allocator.free(frame);
                    try socketWriteAll(&conn.stream, frame);
                },
                .binary => {
                    const frame = try serverFrame(CLIENT_BINARY_OPCODE, msg.data);
                    defer std.testing.allocator.free(frame);
                    try socketWriteAll(&conn.stream, frame);
                },
                .pong => {},
            }
            if (msg.cleanup_fragment) reader.cleanup();
        }
        compactReader(true, &reader);
    }
}

fn serverFrame(opcode: u8, payload: []const u8) ![]const u8 {
    var frame: std.ArrayList(u8) = .empty;
    errdefer frame.deinit(std.testing.allocator);
    try frame.append(std.testing.allocator, 0x80 | opcode);
    if (payload.len <= 125) {
        try frame.append(std.testing.allocator, @intCast(payload.len));
    } else if (payload.len <= 0xffff) {
        try frame.append(std.testing.allocator, 126);
        try frame.append(std.testing.allocator, @intCast((payload.len >> 8) & 0xff));
        try frame.append(std.testing.allocator, @intCast(payload.len & 0xff));
    } else {
        try frame.append(std.testing.allocator, 127);
        try frame.appendSlice(std.testing.allocator, &.{ 0, 0, 0, 0, @intCast((payload.len >> 24) & 0xff), @intCast((payload.len >> 16) & 0xff), @intCast((payload.len >> 8) & 0xff), @intCast(payload.len & 0xff) });
    }
    try frame.appendSlice(std.testing.allocator, payload);
    return frame.toOwnedSlice(std.testing.allocator);
}

test "WebApi: WebSocket" {
    var server = TestWsServer{};
    server.ready.start();
    const thread = try std.Thread.spawn(.{}, testWebSocketServerThread, .{&server});
    server.ready.wait();
    defer {
        server.stop();
        thread.join();
    }
    try testing.htmlRunner("net/websocket.html", .{});
    if (server.last_error) |err| return err;
}
