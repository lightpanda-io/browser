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
const ArenaPool = @import("../../../ArenaPool.zig");

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
// Cached so deinit can release the arena even after `_frame._page` has
// been torn down.
_arena_pool: *ArenaPool,
// Guards mutable state shared between the network thread (libcurl
// callbacks) and the worker thread (close, drainPending, etc.).
_mutex: std.Thread.Mutex = .{},

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

// Single growing buffer for assembled ws frame bytes — both "currently
// assembling" and "completed but not yet dispatched" messages live here.
// Reset to zero length only by drainPending. Capacity grows to fit the
// largest message ever received, then stays put (arena allocation, never
// freed mid-life). Pending message data is referenced via _pending_messages
// offset/length pairs into items — slices stay valid until drain clears.
_recv_buffer: std.ArrayList(u8) = .empty,

// Offset within _recv_buffer where the current in-flight frame began.
// Used to slice out the message when bytes_left reaches 0.
_assembling_start: usize = 0,

// Events queued by libcurl callbacks; drained from the worker thread via
// drainPending. Callbacks must NEVER enter V8 directly (they can run from
// any thread driving curl_multi_perform), so all dispatch happens here.
_pending_messages: std.ArrayList(QueuedMessage) = .empty,
_pending_open: bool = false,
_pending_close: ?PendingClose = null,

// Set while we're sitting in HttpClient.ws_ready. Doubles as the dedup
// flag and the marker that we hold one extra "pending events" ref so the
// WebSocket stays alive between queueing and drain.
_in_ready_list: bool = false,

// Set while a cancel is in flight. We hold an extra ref so the WS
// can't be freed before the canceled completion arrives via
// drainCompletions → disconnected.
_cancel_pending: bool = false,

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

const QueuedMessage = struct {
    offset: usize,
    len: usize,
    frame_type: http.WsFrameType,
};

const PendingClose = struct {
    code: u16,
    reason: []const u8,
    was_clean: bool,
    with_error: bool,
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

    const http_client = &frame._session.browser.http_client;
    const conn = http_client.handle.newConnection() orelse {
        return error.NoFreeConnection;
    };

    errdefer http_client.handle.releaseConnection(conn);

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
        ._arena_pool = frame._session.browser.arena_pool,
        ._proto = undefined,
        ._url = resolved_url,
        ._req_headers = headers,
        ._http_client = http_client,
    });
    conn.transport = .{ .websocket = self };
    try http_client.handle.submitRequest(conn);

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
    _ = page;
    self.cleanup(true);

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
        msg.deinit(self._arena_pool);
    }
    self._arena_pool.release(self._arena);
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
    self._mutex.lock();
    self._ready_state = .closed;
    self._mutex.unlock();
    self.cleanup(false);
}

pub fn disconnected(self: *WebSocket, err_: ?anyerror) void {
    defer self.cleanup(true);

    self._mutex.lock();
    defer self._mutex.unlock();

    if (self._ready_state == .closed) return;

    const was_clean = self._ready_state == .closing and err_ == null;
    self._ready_state = .closed;

    if (err_) |err| {
        log.warn(.websocket, "disconnected", .{ .err = err, .url = self._url });
    } else {
        log.info(.websocket, "disconnected", .{ .url = self._url, .reason = "closed" });
    }

    self._pending_close = .{
        .code = if (was_clean) self._close_code else 1006,
        .reason = if (was_clean) self._close_reason else "",
        .was_clean = was_clean,
        .with_error = !was_clean,
    };
    self.markReadyLocked();
}

fn cleanup(self: *WebSocket, completed: bool) void {
    self._mutex.lock();
    const conn = self._conn orelse {
        self._mutex.unlock();
        return;
    };
    if (!completed) {
        if (self._cancel_pending) {
            self._mutex.unlock();
            return;
        }
        self._cancel_pending = true;
        self.acquireRef();
        self._mutex.unlock();
        self._http_client.handle.submitRemove(conn);
        return;
    }

    self._req_headers.deinit();
    self._conn = null;
    const release_cancel_ref = self._cancel_pending;
    self._cancel_pending = false;
    self._send_queue.clearRetainingCapacity();
    self._mutex.unlock();

    self._http_client.handle.finishConn(conn);
    self.releaseRef(self._frame._page); // create-time
    if (release_cancel_ref) {
        self.releaseRef(self._frame._page); // pending-cancel
    }
}

fn queueMessage(self: *WebSocket, msg: Message) !void {
    self._mutex.lock();
    defer self._mutex.unlock();
    return self.queueMessageLocked(msg);
}

fn queueMessageLocked(self: *WebSocket, msg: Message) !void {
    const was_empty = self._send_queue.items.len == 0;
    try self._send_queue.append(self._arena, msg);

    if (was_empty) {
        if (self._conn) |conn| {
            self._http_client.handle.submitUnpause(conn);
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
    // Validate close code per spec: must be 1000 or in range 3000-4999
    if (code_) |code| {
        if (code != 1000 and (code < 3000 or code > 4999)) {
            return error.InvalidAccessError;
        }
    }

    const code = code_ orelse 1000;
    const reason = reason_ orelse "";

    self._mutex.lock();
    if (self._ready_state == .closing or self._ready_state == .closed) {
        self._mutex.unlock();
        return;
    }

    if (self._ready_state == .connecting) {
        const reason_dup = self._arena.dupe(u8, reason) catch |err| {
            self._mutex.unlock();
            return err;
        };
        self._ready_state = .closed;
        self._pending_close = .{
            .code = code,
            .reason = reason_dup,
            .was_clean = false,
            .with_error = false,
        };
        self.markReadyLocked();
        self._mutex.unlock();
        self.cleanup(false);
        return;
    }

    self._ready_state = .closing;
    self._close_code = code;
    self._close_reason = self._arena.dupe(u8, reason) catch |err| {
        self._mutex.unlock();
        return err;
    };
    const queue_err = self.queueMessageLocked(.close);
    self._mutex.unlock();
    return queue_err;
}

pub fn getUrl(self: *const WebSocket) []const u8 {
    return self._url;
}

pub fn getReadyState(self: *const WebSocket) u16 {
    const ws: *WebSocket = @constCast(self);
    ws._mutex.lock();
    defer ws._mutex.unlock();
    return @intFromEnum(ws._ready_state);
}

pub fn getBufferedAmount(self: *const WebSocket) u32 {
    const ws: *WebSocket = @constCast(self);
    ws._mutex.lock();
    defer ws._mutex.unlock();

    var buffered: u32 = 0;
    for (ws._send_queue.items) |msg| {
        switch (msg) {
            .text, .binary => |byte_msg| buffered += @intCast(byte_msg.data.len),
            .close => buffered += @intCast(2 + ws._close_reason.len),
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

fn markReady(self: *WebSocket) void {
    self._mutex.lock();
    defer self._mutex.unlock();
    self.markReadyLocked();
}

fn markReadyLocked(self: *WebSocket) void {
    if (self._in_ready_list) return;
    self._in_ready_list = true;
    self.acquireRef();
    self._http_client.addReadyWs(self);
}

// Dispatches all queued events to JS. Must be called from the worker
// thread (the one that owns the V8 isolate). Snapshots all pending
// state under the mutex so JS callbacks can safely re-enter while we
// dispatch — they observe a fresh, empty queue.
pub fn drainPending(self: *WebSocket) void {
    self._mutex.lock();
    self._in_ready_list = false;
    const pending_open = self._pending_open;
    self._pending_open = false;
    const pending_close = self._pending_close;
    self._pending_close = null;
    const pending_messages = self._pending_messages;
    self._pending_messages = .empty;
    const recv_buffer = self._recv_buffer;
    self._recv_buffer = .empty;
    self._mutex.unlock();

    defer self.releaseRef(self._frame._page);

    if (pending_open) {
        self.dispatchOpenEvent() catch |err| {
            log.err(.websocket, "open event fail", .{ .err = err });
        };
    }

    for (pending_messages.items) |msg| {
        const data = recv_buffer.items[msg.offset..][0..msg.len];
        self.dispatchMessageEvent(data, msg.frame_type) catch |err| {
            log.warn(.websocket, "message dispatch", .{ .err = err });
        };
    }

    if (pending_close) |pc| {
        if (pc.with_error) {
            self.dispatchErrorEvent() catch |err| {
                log.err(.websocket, "error event dispatch failed", .{ .err = err });
            };
        }
        self.dispatchCloseEvent(pc.code, pc.reason, pc.was_clean) catch |err| {
            log.err(.websocket, "close event dispatch failed", .{ .err = err });
        };
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
    self._mutex.lock();
    defer self._mutex.unlock();

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
        removed.deinit(self._arena_pool);
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
    self._mutex.lock();
    defer self._mutex.unlock();

    const meta = conn.wsMeta() orelse {
        log.err(.websocket, "missing meta", .{ .url = self._url });
        return error.NoFrameMeta;
    };

    if (meta.offset == 0) {
        if (comptime IS_DEBUG) {
            log.debug(.websocket, "incoming message", .{ .url = self._url, .len = meta.len, .bytes_left = meta.bytes_left, .type = meta.frame_type });
        }
        if (meta.len > self._http_client.max_response_size) {
            return error.MessageTooLarge;
        }
        self._assembling_start = self._recv_buffer.items.len;
        try self._recv_buffer.ensureTotalCapacity(self._arena, self._assembling_start + meta.len);
    }

    try self._recv_buffer.appendSlice(self._arena, data);

    if (meta.bytes_left > 0) return;

    const start = self._assembling_start;
    const len = self._recv_buffer.items.len - start;
    switch (meta.frame_type) {
        .text, .binary => {
            try self._pending_messages.append(self._arena, .{
                .offset = start,
                .len = len,
                .frame_type = meta.frame_type,
            });
            self.markReadyLocked();
        },
        .close => {
            const message = self._recv_buffer.items[start..][0..len];
            const received_code = if (message.len >= 2)
                @as(u16, message[0]) << 8 | message[1]
            else
                1005; // No status code received

            if (self._ready_state == .closing) {
                // Client-initiated close — server's response. Don't
                // disconnect inline: we're inside a libcurl callback
                // and tearing the conn down here would UAF the easy
                // handle. Curl will deliver normal completion when the
                // server closes the socket per RFC 6455 §5.5.1.
            } else {
                self._close_code = received_code;
                if (message.len > 2) {
                    self._close_reason = try self._arena.dupe(u8, message[2..]);
                }
                self._ready_state = .closing;
                try self.queueMessageLocked(.close);
            }
            self._recv_buffer.shrinkRetainingCapacity(start);
        },
        .ping, .pong, .cont => {
            self._recv_buffer.shrinkRetainingCapacity(start);
        },
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
    self._mutex.lock();
    defer self._mutex.unlock();

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

        self._pending_open = true;
        self.markReadyLocked();
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
    fn deinit(self: Message, pool: *ArenaPool) void {
        switch (self) {
            .text, .binary => |msg| pool.release(msg.arena),
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
