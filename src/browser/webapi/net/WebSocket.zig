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

const http = @import("../../../network/http.zig");

const js = @import("../../js/js.zig");
const Blob = @import("../Blob.zig");
const URL = @import("../../URL.zig");

const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");
const HttpClient = @import("../../HttpClient.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const CloseEvent = @import("../event/CloseEvent.zig");
const MessageEvent = @import("../event/MessageEvent.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const WebSocket = @This();

_rc: lp.RC(u8) = .{},
_frame: *Frame,
_proto: *EventTarget,
_arena: Allocator,

// Connection state
_ready_state: ReadyState = .connecting,
_url: [:0]const u8 = "",
_binary_type: BinaryType = .blob,

// Handshake tracking
_got_101: bool = false,
_got_upgrade: bool = false,

_conn: ?*http.Connection,
_http_client: *HttpClient,
_req_headers: http.Headers,

// buffered outgoing messages
_send_queue: std.ArrayList(Message) = .empty,
_send_offset: usize = 0,

// buffered incoming frame
_recv_buffer: std.ArrayList(u8) = .empty,

// close info for event dispatch
_close_code: u16 = 1000,
_close_reason: []const u8 = "",

// negotiated protocol
_protocol: []const u8 = "",

// Event handlers
_on_open: ?js.Function.Temp = null,
_on_message: ?js.Function.Temp = null,
_on_error: ?js.Function.Temp = null,
_on_close: ?js.Function.Temp = null,

pub const ReadyState = enum(u8) {
    connecting = 0,
    open = 1,
    closing = 2,
    closed = 3,
};

pub const BinaryType = enum {
    blob,
    arraybuffer,
};

pub fn init(url: []const u8, protocols: [][]const u8, frame: *Frame) !*WebSocket {
    {
        if (url.len < 6) {
            return error.SyntaxError;
        }
        const normalized_start = std.ascii.lowerString(&frame.buf, url[0..6]);
        if (!std.mem.startsWith(u8, normalized_start, "ws://") and !std.mem.startsWith(u8, normalized_start, "wss://")) {
            return error.SyntaxError;
        }
        // Fragments are not allowed in WebSocket URLs
        if (std.mem.indexOfScalar(u8, url, '#') != null) {
            return error.SyntaxError;
        }
        for (protocols) |protocol| {
            if (!isValidProtocol(protocol)) {
                return error.SyntaxError;
            }
        }
    }

    const arena = try frame.getArena(.medium, "WebSocket");
    errdefer frame.releaseArena(arena);

    const resolved_url = try URL.resolve(arena, frame.base(), url, .{ .always_dupe = true, .encoding = frame.charset });

    const http_client = frame._session.browser.http_client;
    const conn = http_client.network.newConnection() orelse {
        return error.NoFreeConnection;
    };

    errdefer http_client.network.releaseConnection(conn);

    try conn.setURL(resolved_url);
    try conn.setConnectOnly(false);

    try conn.setReadCallback(sendDataCallback, true);
    try conn.setWriteCallback(receivedDataCallback);
    try conn.setHeaderCallback(receivedHeaderCallback);

    var headers = try http_client.newHeaders();
    errdefer headers.deinit();
    if (protocols.len > 0) {
        const header = try std.fmt.allocPrintSentinel(arena, "Sec-WebSocket-Protocol: {s}", .{try std.mem.join(arena, ", ", protocols)}, 0);
        try headers.add(header);
        try conn.setHeaders(&headers);
    }

    const self = try frame._factory.eventTargetWithAllocator(arena, WebSocket{
        ._frame = frame,
        ._conn = conn,
        ._arena = arena,
        ._proto = undefined,
        ._url = resolved_url,
        ._req_headers = headers,
        ._http_client = http_client,
    });
    conn.transport = .{ .websocket = self };
    try http_client.trackConn(conn);

    if (comptime IS_DEBUG) {
        log.info(.websocket, "connecting", .{ .url = url });
    }

    // Unlike an XHR object where we only selectively reference the instance
    // while the request is actually inflight, WS connection is "inflight" from
    // the moment it's created.
    self.acquireRef();

    return self;
}

pub fn deinit(self: *WebSocket, page: *Page) void {
    self.cleanup();

    if (self._on_open) |func| {
        func.release();
    }
    if (self._on_message) |func| {
        func.release();
    }
    if (self._on_error) |func| {
        func.release();
    }
    if (self._on_close) |func| {
        func.release();
    }

    for (self._send_queue.items) |msg| {
        msg.deinit(page);
    }

    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *WebSocket, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *WebSocket) void {
    self._rc.acquire();
}

fn asEventTarget(self: *WebSocket) *EventTarget {
    return self._proto;
}

// we're being aborted internally (e.g. frame shutting down)
pub fn kill(self: *WebSocket) void {
    self.cleanup();
}

pub fn disconnected(self: *WebSocket, err_: ?anyerror) void {
    const was_clean = self._ready_state == .closing and err_ == null;
    self._ready_state = .closed;

    if (err_) |err| {
        log.warn(.websocket, "disconnected", .{ .err = err, .url = self._url });
    } else {
        log.info(.websocket, "disconnected", .{ .url = self._url, .reason = "closed" });
    }

    defer self.cleanup();

    // Use 1006 (abnormal closure) if connection wasn't cleanly closed
    const code = if (was_clean) self._close_code else 1006;
    const reason = if (was_clean) self._close_reason else "";

    // Spec requires error event before close on abnormal closure.
    // Dispatch events before cleanup since cleanup releases the ref count
    // which may free our event handler references.
    if (!was_clean) {
        self.dispatchErrorEvent() catch |err| {
            log.err(.websocket, "error event dispatch failed", .{ .err = err });
        };
    }

    self.dispatchCloseEvent(code, reason, was_clean) catch |err| {
        log.err(.websocket, "close event dispatch failed", .{ .err = err });
    };
}

fn cleanup(self: *WebSocket) void {
    if (self._conn) |conn| {
        self._http_client.removeConn(conn);
        self._req_headers.deinit();
        self._conn = null;
        self.releaseRef(self._frame._page);
        self._send_queue.clearRetainingCapacity();
    }
}

fn queueMessage(self: *WebSocket, msg: Message) !void {
    const was_empty = self._send_queue.items.len == 0;
    try self._send_queue.append(self._arena, msg);

    if (was_empty) {
        // Unpause the send callback so libcurl will request data
        if (self._conn) |conn| {
            try conn.pause(.{ .cont = true });
        }
    }
}

fn isValidProtocol(protocol: []const u8) bool {
    if (protocol.len == 0) return false;
    for (protocol) |c| {
        // Control characters and non-ASCII
        if (c <= 31 or c >= 127) return false;
        // Separators per RFC 2616
        switch (c) {
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}', ' ', '\t' => return false,
            else => {},
        }
    }
    return true;
}

/// WebSocket send() accepts string, Blob, ArrayBuffer, or TypedArray
const SendData = union(enum) {
    blob: *Blob,
    js_val: js.Value,
};

/// Union for extracting bytes from ArrayBuffer/TypedArray
const BinaryData = union(enum) {
    int8: []i8,
    uint8: []u8,
    int16: []i16,
    uint16: []u16,
    int32: []i32,
    uint32: []u32,
    int64: []i64,
    uint64: []u64,
    float32: []f32,
    float64: []f64,

    fn asBuffer(self: BinaryData) []u8 {
        return switch (self) {
            .int8 => |b| @as([*]u8, @ptrCast(b.ptr))[0..b.len],
            .uint8 => |b| b,
            inline .int16, .uint16 => |b| @as([*]u8, @ptrCast(b.ptr))[0 .. b.len * 2],
            inline .int32, .uint32, .float32 => |b| @as([*]u8, @ptrCast(b.ptr))[0 .. b.len * 4],
            inline .int64, .uint64, .float64 => |b| @as([*]u8, @ptrCast(b.ptr))[0 .. b.len * 8],
        };
    }
};

pub fn send(self: *WebSocket, data: SendData) !void {
    if (self._ready_state != .open) {
        return error.InvalidStateError;
    }

    switch (data) {
        .blob => |blob| {
            const arena = try self._frame.getArena(blob._slice.len, "WebSocket.message");
            errdefer self._frame.releaseArena(arena);
            try self.queueMessage(.{ .binary = .{
                .arena = arena,
                .data = try arena.dupe(u8, blob._slice),
            } });
        },
        .js_val => |js_val| {
            if (js_val.isString()) |str| {
                const arena = try self._frame.getArena(str.len(), "WebSocket.message");
                errdefer self._frame.releaseArena(arena);
                try self.queueMessage(.{ .text = .{
                    .arena = arena,
                    .data = try str.toSliceWithAlloc(arena),
                } });
            } else {
                const binary = try js_val.toZig(BinaryData);
                const buffer = binary.asBuffer();

                const arena = try self._frame.getArena(buffer.len, "WebSocket.message");
                errdefer self._frame.releaseArena(arena);
                try self.queueMessage(.{ .binary = .{
                    .arena = arena,
                    .data = try arena.dupe(u8, buffer),
                } });
            }
        },
    }
}

pub fn close(self: *WebSocket, code_: ?u16, reason_: ?[]const u8) !void {
    if (self._ready_state == .closing or self._ready_state == .closed) {
        return;
    }

    // Validate close code per spec: must be 1000 or in range 3000-4999
    if (code_) |code| {
        if (code != 1000 and (code < 3000 or code > 4999)) {
            return error.InvalidAccessError;
        }
    }

    const code = code_ orelse 1000;
    const reason = reason_ orelse "";

    if (self._ready_state == .connecting) {
        // Connection not yet established - fail it
        self._ready_state = .closed;
        self.cleanup();
        try self.dispatchCloseEvent(code, reason, false);
        return;
    }

    self._ready_state = .closing;
    self._close_code = code;
    self._close_reason = try self._arena.dupe(u8, reason);
    try self.queueMessage(.close);
}

pub fn getUrl(self: *const WebSocket) []const u8 {
    return self._url;
}

pub fn getReadyState(self: *const WebSocket) u16 {
    return @intFromEnum(self._ready_state);
}

pub fn getBufferedAmount(self: *const WebSocket) u32 {
    var buffered: u32 = 0;
    for (self._send_queue.items) |msg| {
        switch (msg) {
            .text, .binary => |byte_msg| buffered += @intCast(byte_msg.data.len),
            .close => buffered += @intCast(2 + self._close_reason.len),
        }
    }
    return buffered;
}

pub fn getBinaryType(self: *const WebSocket) []const u8 {
    return @tagName(self._binary_type);
}

pub fn getProtocol(self: *const WebSocket) []const u8 {
    return self._protocol;
}

pub fn setBinaryType(self: *WebSocket, value: []const u8) void {
    if (std.meta.stringToEnum(BinaryType, value)) |bt| {
        self._binary_type = bt;
    }
}

pub fn getOnOpen(self: *const WebSocket) ?js.Function.Temp {
    return self._on_open;
}

pub fn setOnOpen(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_open) |old| old.release();
    if (cb_) |cb| {
        self._on_open = try cb.tempWithThis(self);
    } else {
        self._on_open = null;
    }
}

pub fn getOnMessage(self: *const WebSocket) ?js.Function.Temp {
    return self._on_message;
}

pub fn setOnMessage(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_message) |old| old.release();
    if (cb_) |cb| {
        self._on_message = try cb.tempWithThis(self);
    } else {
        self._on_message = null;
    }
}

pub fn getOnError(self: *const WebSocket) ?js.Function.Temp {
    return self._on_error;
}

pub fn setOnError(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_error) |old| old.release();
    if (cb_) |cb| {
        self._on_error = try cb.tempWithThis(self);
    } else {
        self._on_error = null;
    }
}

pub fn getOnClose(self: *const WebSocket) ?js.Function.Temp {
    return self._on_close;
}

pub fn setOnClose(self: *WebSocket, cb_: ?js.Function) !void {
    if (self._on_close) |old| old.release();
    if (cb_) |cb| {
        self._on_close = try cb.tempWithThis(self);
    } else {
        self._on_close = null;
    }
}

fn dispatchOpenEvent(self: *WebSocket) !void {
    const frame = self._frame;
    const target = self.asEventTarget();

    if (frame._event_manager.hasDirectListeners(target, "open", self._on_open)) {
        const event = try Event.initTrusted(comptime .wrap("open"), .{}, frame._page);
        try frame._event_manager.dispatchDirect(target, event, self._on_open, .{ .context = "WebSocket open" });
    }
}

fn dispatchMessageEvent(self: *WebSocket, data: []const u8, frame_type: http.WsFrameType) !void {
    const frame = self._frame;
    const target = self.asEventTarget();

    if (frame._event_manager.hasDirectListeners(target, "message", self._on_message)) {
        const msg_data: MessageEvent.Data = if (frame_type == .binary)
            switch (self._binary_type) {
                .arraybuffer => .{ .arraybuffer = .{ .values = data } },
                .blob => blk: {
                    const blob = try Blob.initFromBytes(data, "", false, frame._page);
                    blob.acquireRef();
                    break :blk .{ .blob = blob };
                },
            }
        else
            .{ .string = data };

        const event = try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = msg_data,
            .origin = "",
        }, frame._page);
        try frame._event_manager.dispatchDirect(target, event.asEvent(), self._on_message, .{ .context = "WebSocket message" });
    }
}

fn dispatchErrorEvent(self: *WebSocket) !void {
    const frame = self._frame;
    const target = self.asEventTarget();

    if (frame._event_manager.hasDirectListeners(target, "error", self._on_error)) {
        const event = try Event.initTrusted(comptime .wrap("error"), .{}, frame._page);
        try frame._event_manager.dispatchDirect(target, event, self._on_error, .{ .context = "WebSocket error" });
    }
}

fn dispatchCloseEvent(self: *WebSocket, code: u16, reason: []const u8, was_clean: bool) !void {
    const frame = self._frame;
    const target = self.asEventTarget();

    if (frame._event_manager.hasDirectListeners(target, "close", self._on_close)) {
        const event = try CloseEvent.initTrusted(comptime .wrap("close"), .{
            .code = code,
            .reason = reason,
            .wasClean = was_clean,
        }, frame);
        try frame._event_manager.dispatchDirect(target, event.asEvent(), self._on_close, .{ .context = "WebSocket close" });
    }
}

fn sendDataCallback(buffer: [*]u8, buf_count: usize, buf_len: usize, data: *anyopaque) usize {
    if (comptime IS_DEBUG) {
        std.debug.assert(buf_count == 1);
    }
    const conn: *http.Connection = @ptrCast(@alignCast(data));
    return _sendDataCallback(conn, buffer[0..buf_len]) catch |err| {
        log.warn(.websocket, "send callback", .{ .err = err });
        return http.readfunc_pause;
    };
}

fn _sendDataCallback(conn: *http.Connection, buf: []u8) !usize {
    lp.assert(buf.len >= 2, "WS short buffer", .{ .len = buf.len });

    const self = conn.transport.websocket;

    if (self._send_queue.items.len == 0) {
        // No data to send - pause until queueMessage is called
        return http.readfunc_pause;
    }

    const msg = &self._send_queue.items[0];

    switch (msg.*) {
        .close => {
            const code = self._close_code;
            const reason = self._close_reason;

            // Close frame: 2 bytes for code (big-endian) + optional reason
            // Truncate reason to fit in buf (max 123 bytes per spec)
            const reason_len: usize = @min(reason.len, 123, buf.len -| 2);
            const frame_len = 2 + reason_len;
            const to_copy = @min(buf.len, frame_len);

            var close_payload: [125]u8 = undefined;
            close_payload[0] = @intCast((code >> 8) & 0xFF);
            close_payload[1] = @intCast(code & 0xFF);
            if (reason_len > 0) {
                @memcpy(close_payload[2..][0..reason_len], reason[0..reason_len]);
            }

            try conn.wsStartFrame(.close, to_copy);
            @memcpy(buf[0..to_copy], close_payload[0..to_copy]);

            _ = self._send_queue.orderedRemove(0);
            return to_copy;
        },
        .text => |content| return self.writeContent(conn, buf, content, .text),
        .binary => |content| return self.writeContent(conn, buf, content, .binary),
    }
}

fn writeContent(self: *WebSocket, conn: *http.Connection, buf: []u8, byte_msg: Message.Content, frame_type: http.WsFrameType) !usize {
    if (self._send_offset == 0) {
        // start of the message
        if (comptime IS_DEBUG) {
            log.debug(.websocket, "send start", .{ .url = self._url, .len = byte_msg.data.len });
        }
        try conn.wsStartFrame(frame_type, byte_msg.data.len);
    }

    const remaining = byte_msg.data[self._send_offset..];
    const to_copy = @min(remaining.len, buf.len);
    @memcpy(buf[0..to_copy], remaining[0..to_copy]);

    self._send_offset += to_copy;

    if (self._send_offset >= byte_msg.data.len) {
        const removed = self._send_queue.orderedRemove(0);
        removed.deinit(self._frame._page);
        if (comptime IS_DEBUG) {
            log.debug(.websocket, "send complete", .{ .url = self._url, .len = byte_msg.data.len, .queue = self._send_queue.items.len });
        }
        self._send_offset = 0;
    }

    return to_copy;
}

fn receivedDataCallback(buffer: [*]const u8, buf_count: usize, buf_len: usize, data: *anyopaque) usize {
    if (comptime IS_DEBUG) {
        std.debug.assert(buf_count == 1);
    }
    const conn: *http.Connection = @ptrCast(@alignCast(data));
    _receivedDataCallback(conn, buffer[0..buf_len]) catch |err| {
        log.warn(.websocket, "receive callback", .{ .err = err });
        // TODO: are there errors, like an invalid frame, that we shouldn't treat
        // as an error?
        return http.writefunc_error;
    };

    return buf_len;
}

fn _receivedDataCallback(conn: *http.Connection, data: []const u8) !void {
    const self = conn.transport.websocket;
    const meta = conn.wsMeta() orelse {
        log.err(.websocket, "missing meta", .{ .url = self._url });
        return error.NoFrameMeta;
    };

    if (meta.offset == 0) {
        if (comptime IS_DEBUG) {
            log.debug(.websocket, "incoming message", .{ .url = self._url, .len = meta.len, .bytes_left = meta.bytes_left, .type = meta.frame_type });
        }
        // Start of new frame. Pre-allocate buffer
        self._recv_buffer.clearRetainingCapacity();
        if (meta.len > self._http_client.max_response_size) {
            return error.MessageTooLarge;
        }
        try self._recv_buffer.ensureTotalCapacity(self._arena, meta.len);
    }

    try self._recv_buffer.appendSlice(self._arena, data);

    if (meta.bytes_left > 0) {
        // still more data waiting for this frame
        return;
    }

    const message = self._recv_buffer.items;
    switch (meta.frame_type) {
        .text, .binary => try self.dispatchMessageEvent(message, meta.frame_type),
        .close => {
            // Parse close frame: 2-byte code (big-endian) + optional reason
            const received_code = if (message.len >= 2)
                @as(u16, message[0]) << 8 | message[1]
            else
                1005; // No status code received

            if (self._ready_state == .closing) {
                // Client-initiated close: this is the server's response.
                // Close handshake complete - disconnect.
                self.disconnected(null);
            } else {
                // Server-initiated close: send reciprocal close frame per RFC 6455 §5.5.1
                self._close_code = received_code;
                if (message.len > 2) {
                    self._close_reason = try self._arena.dupe(u8, message[2..]);
                }
                self._ready_state = .closing;
                try self.queueMessage(.close);
            }
        },
        .ping, .pong, .cont => {},
    }
}

// libcurl has no mechanism to signal that the connection is established. The
// best option I could come up with was looking for an upgrade header response.
fn receivedHeaderCallback(buffer: [*]const u8, header_count: usize, buf_len: usize, data: *anyopaque) usize {
    if (comptime IS_DEBUG) {
        std.debug.assert(header_count == 1);
    }
    const conn: *http.Connection = @ptrCast(@alignCast(data));
    const self = conn.transport.websocket;
    const header = buffer[0..buf_len];

    if (self._got_101 == false and std.mem.startsWith(u8, header, "HTTP/")) {
        if (std.mem.indexOf(u8, header, " 101 ")) |_| {
            self._got_101 = true;
        }
        return buf_len;
    }

    // Empty line = end of headers
    if (buf_len <= 2) {
        if (!self._got_101 or !self._got_upgrade) {
            return 0;
        }

        self._ready_state = .open;
        log.info(.websocket, "connected", .{ .url = self._url });

        self.dispatchOpenEvent() catch |err| {
            log.err(.websocket, "open event fail", .{ .err = err });
        };
        return buf_len;
    }

    const colon = std.mem.indexOfScalarPos(u8, header, 0, ':') orelse {
        // weird, continue...
        return buf_len;
    };

    const header_name = header[0..colon];
    const value = std.mem.trim(u8, header[colon + 1 ..], " \t\r\n");

    if (std.ascii.eqlIgnoreCase(header_name, "upgrade")) {
        if (std.ascii.eqlIgnoreCase(value, "websocket")) {
            self._got_upgrade = true;
        }
    } else if (std.ascii.eqlIgnoreCase(header_name, "sec-websocket-protocol")) {
        // TODO, we should validate this against our sent list.
        self._protocol = self._arena.dupe(u8, value) catch |err| {
            log.err(.websocket, "dupe protocol", .{ .err = err });
            return 0;
        };
    }

    return buf_len;
}

const Message = union(enum) {
    close,
    text: Content,
    binary: Content,

    const Content = struct {
        arena: Allocator,
        data: []const u8,
    };
    fn deinit(self: Message, page: *Page) void {
        switch (self) {
            .text, .binary => |msg| page.releaseArena(msg.arena),
            .close => {},
        }
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebSocket);

    pub const Meta = struct {
        pub const name = "WebSocket";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(WebSocket.init, .{ .dom_exception = true });

    pub const CONNECTING = bridge.property(@intFromEnum(ReadyState.connecting), .{ .template = true });
    pub const OPEN = bridge.property(@intFromEnum(ReadyState.open), .{ .template = true });
    pub const CLOSING = bridge.property(@intFromEnum(ReadyState.closing), .{ .template = true });
    pub const CLOSED = bridge.property(@intFromEnum(ReadyState.closed), .{ .template = true });

    pub const url = bridge.accessor(WebSocket.getUrl, null, .{});
    pub const readyState = bridge.accessor(WebSocket.getReadyState, null, .{});
    pub const bufferedAmount = bridge.accessor(WebSocket.getBufferedAmount, null, .{});
    pub const binaryType = bridge.accessor(WebSocket.getBinaryType, WebSocket.setBinaryType, .{});

    pub const protocol = bridge.accessor(WebSocket.getProtocol, null, .{});
    pub const extensions = bridge.property("", .{ .template = false });

    pub const onopen = bridge.accessor(WebSocket.getOnOpen, WebSocket.setOnOpen, .{});
    pub const onmessage = bridge.accessor(WebSocket.getOnMessage, WebSocket.setOnMessage, .{});
    pub const onerror = bridge.accessor(WebSocket.getOnError, WebSocket.setOnError, .{});
    pub const onclose = bridge.accessor(WebSocket.getOnClose, WebSocket.setOnClose, .{});

    pub const send = bridge.function(WebSocket.send, .{ .dom_exception = true });
    pub const close = bridge.function(WebSocket.close, .{ .dom_exception = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: WebSocket" {
    try testing.htmlRunner("net/websocket.html", .{});
}
