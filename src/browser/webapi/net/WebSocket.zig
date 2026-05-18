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
const libcurl = @import("../../../sys/libcurl.zig");

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
const posix = std.posix;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const WebSocket = @This();

// After `MAX_SEND_RETRIES` consecutive Again responses with no
// progress, the WS is closed with an abnormal-closure status —
// guards the worker against a stalled peer chewing CPU through
// the inbox-resubmit retry loop. Set generously since AGAIN on
// normal browser WS traffic is rare; only a wedged peer should
// approach this.
const MAX_SEND_RETRIES: u32 = 1024;

// Reception scratch passed to curl_ws_recv. Sized to match the
// historical WS recv buffer for parity. Each frame's payload is
// reassembled into `_recv_buffer`.
const RECV_CHUNK: usize = 16 * 1024;

_rc: lp.RC(u8) = .{},
_frame: *Frame,
_proto: *EventTarget,
_arena: Allocator,

// Connection state
_ready_state: ReadyState = .connecting,
_url: [:0]const u8 = "",
_binary_type: BinaryType = .blob,

_conn: ?*http.Connection,
_http_client: *HttpClient,
_req_headers: http.Headers,

_owner_node: std.DoublyLinkedList.Node = .{},

// libcurl-owned socket fd. Captured on the network thread inside
// the sockopt callback (which fires once per socket, right after
// creation and before connect()). Stays valid through the WS's
// open/closing lifetime; the network thread polls it on our
// behalf once handshakeComplete fires.
_socket_fd: posix.fd_t = -1,

// Network → worker dedup. Network sets to true before pushing a
// ws_readable; worker clears it after draining curl_ws_recv to
// Again. Without this, level-triggered POLLIN would re-push a
// readable event every poll iteration that the worker hasn't yet
// drained, piling duplicates in the inbox.
_pending_readable: std.atomic.Value(bool) = .init(false),

// Outgoing messages awaiting curl_ws_send. Worker-only: pushed
// by send()/close(), drained inline (and via ws_send_retry when
// curl_ws_send returns Again).
_send_queue: std.ArrayList(Message) = .empty,

// Bytes of `_send_queue[0]` already pushed to libcurl. Reset to
// 0 each time the head message is fully sent and popped.
_send_offset: usize = 0,

// Consecutive Again-without-progress count. Cleared whenever a
// curl_ws_send call moves any bytes; bumped each time we have to
// re-push a ws_send_retry. Hits MAX_SEND_RETRIES → transport
// error close.
_send_retries: u32 = 0,

// Set when a ws_send_retry is already in the inbox so we don't
// pile up duplicates. Cleared inside handleSendRetry. Single-
// thread (worker-only) so no atomic needed.
_send_retry_queued: bool = false,

// Frame reassembly. curl_ws_recv hands us chunks of one frame
// at a time; we buffer here until `meta.bytes_left == 0`. Lives
// on `_arena` so it shares the WS's allocation lifetime.
_recv_buffer: std.ArrayList(u8) = .empty,
// Type of the in-progress frame (set on the first chunk of a
// frame, used for dispatch when the frame completes).
_recv_frame_type: http.WsFrameType = .binary,

// Close-frame state. _close_code/_close_reason hold whatever
// the close event will surface to JS; populated by the side
// that initiates (close() or the server-close path in
// handleReadable). _close_dispatched guards against firing the
// JS close event more than once across the multiple terminal
// paths (handshake failure, clean close, abort, net disconnect).
_close_code: u16 = 1000,
_close_reason: []const u8 = "",
_close_dispatched: bool = false,

// Negotiated subprotocol from `Sec-WebSocket-Protocol` (set in
// the header callback during the upgrade).
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

    const http_client = &frame._session.browser.http_client;
    const conn = http_client.network.newWSConn() orelse {
        return error.NoFreeConnection;
    };

    errdefer http_client.network.releaseConn(conn);

    try conn.setURL(resolved_url);
    try libcurl.curl_easy_setopt(conn._easy, .verbose, true);
    // CONNECT_ONLY=2: libcurl drives the upgrade handshake, then
    // multi delivers a CURLMSG_DONE. After that the worker owns
    // the easy handle and does I/O via curl_ws_send / curl_ws_recv.
    try conn.setConnectOnly(true);
    // Force a brand-new TCP socket for the handshake — a cached
    // WS conn left over from a prior WS in the cpool can't be
    // reused for a new HTTP upgrade. The resulting conn still
    // ends up in the cpool after handshake, which is what
    // curl_ws_send/recv need to look it up later.
    try conn.setFreshConnect(true);
    // Capture the socket fd at creation. CURLINFO_ACTIVESOCKET
    // can't be queried reliably after the handshake (during the
    // upgrade it returns BAD; post-completion libcurl's internal
    // teardown invalidates it before the worker can read it).
    // The sockopt callback fires once with the fresh fd before
    // connect() — most reliable place to grab it.
    try conn.setSockoptCallback(sockoptCallback);
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
    http_client.submitConn(conn);
    frame._http_owner.addWS(self);

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
    // false: the WebSocket is being torn down without a terminal
    // completion having arrived (GC). Tears down whichever phase
    // we're in — see `cleanup` for the per-state branching.
    self.cleanup(false);

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
    self.cleanup(false);
}

// Worker-thread handler invoked from `HttpClient.handleHttpCompletion`
// when the CONNECT_ONLY=2 upgrade finished successfully. Transitions
// to .open: hands the socket fd (captured in the header callback) to
// the network thread for POLLIN watching, and dispatches the JS open
// event. From here, all frame I/O happens directly on the worker via
// curl_ws_send/recv.
pub fn handshakeComplete(self: *WebSocket) !void {
    // If the WS was already aborted (kill / close-while-connecting),
    // the upgrade-completion edge raced us. Treat as no-op; cleanup
    // already ran.
    if (self._ready_state != .connecting) return;

    if (self._socket_fd < 0) return error.NoActiveSocket;
    self._ready_state = .open;

    // Hand the fd to the network thread. From this point a
    // ws_readable inbox event may arrive at any time; the handler
    // drains via curl_ws_recv.
    self._http_client.registerWebSocket(self, self._socket_fd);

    if (comptime IS_DEBUG) {
        log.info(.websocket, "open", .{ .url = self._url });
    }
    try self.dispatchOpenEvent();
}

// Failure path from handshake (libcurl returned an error before
// the upgrade completed). Dispatches error + close events and
// tears down. `err_` is null for the clean-close-during-handshake
// flow (kept for API parity with the prior callback-mode model,
// though it should rarely fire here now).
pub fn disconnected(self: *WebSocket, err_: ?anyerror) void {
    if (err_) |err| {
        log.warn(.websocket, "disconnected", .{ .err = err, .url = self._url });
    } else {
        log.info(.websocket, "disconnected", .{ .url = self._url, .reason = "closed" });
    }

    self._ready_state = .closed;

    // Defer cleanup so the event dispatches see the final state but
    // the conn release / ref drop runs after them.
    defer self.cleanup(true);

    if (err_ != null) {
        self.dispatchErrorEvent() catch |derr| {
            log.err(.websocket, "error event dispatch failed", .{ .err = derr });
        };
        // Code 1006 (abnormal closure) when the connection wasn't
        // cleanly closed.
        self._close_code = 1006;
        self._close_reason = "";
    }

    self.dispatchCloseSafe(self._close_code, self._close_reason, err_ == null);
}

// Worker-thread handler for the network-thread ws_disconnected
// ack. With the new synchronous cleanup, this should always
// arrive after cleanup has nulled `_conn` — so it's a no-op in
// the common case. Kept around as a safety net for the rare
// path where the network thread surfaces a disconnect we
// haven't yet observed (e.g. socket-level EOF before our close
// frame negotiation runs): in that case we trigger the same
// teardown cleanup would have done.
pub fn handleNetDisconnected(self: *WebSocket) void {
    self._socket_fd = -1;
    if (self._conn == null) return;
    if (self._ready_state == .open or self._ready_state == .closing) {
        self.dispatchCloseSafe(1006, "", false);
    }
    self.cleanup(false);
}

// Per-state teardown. Called from kill / deinit / close-on-
// connecting / clean-close paths and from `disconnected` /
// `handleNetDisconnected`. Idempotent: nulling `_conn` upfront
// means a second call short-circuits on the `orelse return`
// guard.
//
// In every non-terminal state we drive the conn release
// synchronously here (no async ack hop): submit any pending
// network-side unregister, then `disownConn` to remove from the
// multi, then drain the inbox so the two messages we just queued
// (`ws_disconnected` and the Canceled `http_completion`) are
// processed before we return — `ws_disconnected` becomes a no-op
// via the null-`_conn` guard, and `http_completion .none`
// releases the easy handle through the WS pool. After the drain,
// we drop the in-flight ref; if JS isn't holding the WS, deinit
// fires immediately.
//
//   - .connecting: conn in multi, fd not yet registered.
//   - .open / .closing: conn in multi, fd polled by network.
//   - .closed (via `disconnected`): we got here from the
//     handshake-failure path; the early-fail code in
//     `disconnected` sets `completed = true` and we just need to
//     finishConn + releaseRef.
fn cleanup(self: *WebSocket, completed: bool) void {
    const conn = self._conn orelse return;
    self._conn = null;

    self._frame._http_owner.removeWS(self);
    self._req_headers.deinit();

    // Drop any queued outbound payloads now — none of them can be
    // sent and their arenas should be returned to the pool.
    for (self._send_queue.items) |msg| {
        msg.deinit(self._frame._page);
    }
    self._send_queue.clearRetainingCapacity();

    switch (self._ready_state) {
        .connecting => {
            self._ready_state = .closed;
            // Conn is still in the multi. Synchronously remove so
            // libcurl callbacks (header / sockopt) stop firing;
            // disownConn waits and clears transport. The Canceled
            // completion that fires lands in the inbox's `.none`
            // arm — drain it here so the conn is provably back in
            // the pool before we return.
            self._http_client.disownConn(conn);
            _ = self._http_client.processInbox(0) catch {};
            self.releaseRef(self._frame._page);
        },
        .open, .closing => {
            self._ready_state = .closed;
            // Stop fd polling first, then drop the multi
            // attachment. Both messages are queued in order; the
            // network thread drains them in order (unregister
            // then remove), and `disownConn` blocks until both
            // are done. By the time it returns, two inbox
            // messages have been pushed back to us:
            //   - ws_disconnected: no-op now that _conn is null
            //   - http_completion (Canceled): `.none` arm
            //     releases the conn via the WS pool
            // Drain them before we drop the in-flight ref so the
            // WS struct stays alive while they're dispatched.
            if (self._socket_fd >= 0) {
                self._http_client.unregisterWebSocket(self, self._socket_fd);
            }
            self._http_client.disownConn(conn);
            _ = self._http_client.processInbox(0) catch {};
            self.releaseRef(self._frame._page);
        },
        .closed => {
            // Terminal path: `disconnected` set `completed=true`
            // after a handshake-failure dispatch. Conn isn't in
            // the multi anymore (the failing completion already
            // pulled it) and no fd polling is active — just hand
            // it back through the pool and drop the ref.
            // `completed=false` against a `.closed` state is
            // unreachable in practice: every other branch nulls
            // `_conn` so a second cleanup call short-circuits
            // on the `orelse return` guard up top.
            if (completed) {
                self._http_client.finishConn(conn);
                self.releaseRef(self._frame._page);
            }
        },
    }
}

fn queueMessage(self: *WebSocket, msg: Message) !void {
    try self._send_queue.append(self._arena, msg);
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

    try self.drainSendQueue();
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
        // Connection not yet established — fail it. cleanup
        // synchronously disowns the in-flight handshake.
        self._close_code = code;
        self._close_reason = try self._arena.dupe(u8, reason);
        self._ready_state = .closing;
        self.cleanup(false);
        // cleanup transitioned us to .closed; surface a clean
        // close event since the user-initiated abort isn't a
        // transport failure.
        self.dispatchCloseSafe(code, reason, true);
        return;
    }

    self._ready_state = .closing;
    self._close_code = code;
    self._close_reason = try self._arena.dupe(u8, reason);
    try self.queueMessage(.close);
    try self.drainSendQueue();
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

// Single-shot close dispatch that swallows the error + flips
// `_close_dispatched`. Callers that may race (handshake failure,
// clean close, ack-driven close, abort) all funnel through here.
fn dispatchCloseSafe(self: *WebSocket, code: u16, reason: []const u8, was_clean: bool) void {
    if (self._close_dispatched) return;
    self._close_dispatched = true;
    self.dispatchCloseEvent(code, reason, was_clean) catch |err| {
        log.err(.websocket, "close event dispatch failed", .{ .err = err });
    };
}

// Inbox handler for `ws_readable`. Clears the dedup flag then
// drains curl_ws_recv until Again (or a fatal error). Each
// complete frame either dispatches a JS message event, handles a
// close frame, or is silently consumed (ping/pong/cont — libcurl
// auto-handles ping via CURLWS_AUTOPONG).
pub fn handleReadable(self: *WebSocket) !void {
    // Clear the flag *after* we accept the notification: any data
    // that arrives during our drain still races a new push, which
    // is fine — once we hit Again the socket has no more data.
    defer self._pending_readable.store(false, .release);

    if (self._ready_state == .closed) return;

    const conn = self._conn orelse return;

    var chunk: [RECV_CHUNK]u8 = undefined;
    while (true) {
        const received, const meta = conn.wsRecv(&chunk) catch |err| switch (err) {
            error.Again => return,
            error.GotNothing, error.RecvError, error.NoFrameMeta => {
                // Treat as remote disconnect. We stay in this
                // function only to drain; the actual teardown
                // happens via the ws_disconnected ack the network
                // thread will deliver (we still need to ask it to
                // unregister). Fall through to the abort path.
                self.abortFromTransportError(err);
                return;
            },
            else => return err,
        };

        if (received == 0 and meta.bytes_left == 0) {
            // Defensive: empty frame, nothing in flight, no data.
            // Treat the same as Again.
            return;
        }

        if (meta.offset == 0) {
            // Start of a new frame.
            self._recv_frame_type = meta.frame_type;
            self._recv_buffer.clearRetainingCapacity();
            if (meta.len > self._http_client.max_response_size) {
                self.abortFromTransportError(error.MessageTooLarge);
                return;
            }
            try self._recv_buffer.ensureTotalCapacity(self._arena, meta.len);
        }

        try self._recv_buffer.appendSlice(self._arena, chunk[0..received]);

        if (meta.bytes_left > 0) continue;

        // Frame complete — dispatch and reset for the next one.
        switch (self._recv_frame_type) {
            .text, .binary => try self.dispatchMessageEvent(self._recv_buffer.items, self._recv_frame_type),
            .close => try self.handleServerClose(self._recv_buffer.items),
            .ping, .pong, .cont => {},
        }
        self._recv_buffer.clearRetainingCapacity();

        if (self._ready_state == .closed) return;
    }
}

// Parse a server-initiated close frame and respond per RFC 6455
// §5.5.1. If we were already in .closing (i.e. we sent close
// first), this is the peer's reply and we can finalize teardown.
fn handleServerClose(self: *WebSocket, payload: []const u8) !void {
    const received_code: u16 = if (payload.len >= 2)
        @as(u16, payload[0]) << 8 | payload[1]
    else
        1005; // No status code received

    if (self._ready_state == .closing) {
        // We initiated the close; the server has acked. Dispatch
        // and tear down. cleanup flips state from .closing → .closed
        // through its own branch (which submits the fd unregister).
        self.dispatchCloseSafe(self._close_code, self._close_reason, true);
        self.cleanup(false);
        return;
    }

    // Server-initiated close: queue our reciprocal close frame.
    self._close_code = received_code;
    if (payload.len > 2) {
        self._close_reason = try self._arena.dupe(u8, payload[2..]);
    }
    self._ready_state = .closing;
    try self.queueMessage(.close);
    try self.drainSendQueue();
}

// Worker-thread handler for `ws_send_retry`. Clears the queued
// flag and attempts another drain.
pub fn handleSendRetry(self: *WebSocket) !void {
    self._send_retry_queued = false;
    if (self._ready_state == .closed) return;
    try self.drainSendQueue();
}

// Walk the send queue, copying each message into libcurl via
// curl_ws_send until the queue is empty or curl_ws_send returns
// Again (partial send). On Again, push a ws_send_retry so the
// worker tries again on its next inbox tick. Bumps
// `_send_retries`; once that crosses MAX_SEND_RETRIES we abort
// with a transport-error close (the peer is wedged).
fn drainSendQueue(self: *WebSocket) !void {
    const conn = self._conn orelse return;

    while (self._send_queue.items.len > 0) {
        const msg = &self._send_queue.items[0];
        const result = try self.sendOne(conn, msg);
        switch (result) {
            .complete => {
                const popped = self._send_queue.orderedRemove(0);
                popped.deinit(self._frame._page);
                self._send_offset = 0;
                self._send_retries = 0;

                if (popped == .close) {
                    // We just put our close frame on the wire. If
                    // we were in .closing as the initiator, leave
                    // the WS in .closing waiting on the peer's
                    // reply (handled in handleReadable). If we
                    // were responding to a server close, this is
                    // the second close frame and we're done.
                    if (self._ready_state == .closed) return;
                }
            },
            .partial => |sent| {
                self._send_offset += sent;
                if (sent == 0) {
                    self._send_retries += 1;
                    if (self._send_retries >= MAX_SEND_RETRIES) {
                        self.abortFromTransportError(error.WsSendStalled);
                        return;
                    }
                } else {
                    self._send_retries = 0;
                }
                try self.scheduleSendRetry();
                return;
            },
        }
    }
}

const SendOneResult = union(enum) {
    complete,
    partial: usize,
};

fn sendOne(self: *WebSocket, conn: *http.Connection, msg: *Message) !SendOneResult {
    switch (msg.*) {
        .text => |c| return self.sendBytes(conn, c.data, .text),
        .binary => |c| return self.sendBytes(conn, c.data, .binary),
        .close => return self.sendClose(conn),
    }
}

fn sendBytes(
    self: *WebSocket,
    conn: *http.Connection,
    data: []const u8,
    frame_type: http.WsFrameType,
) !SendOneResult {
    const remaining = data[self._send_offset..];
    const sent = try conn.wsSend(remaining, frame_type);
    if (sent == remaining.len) return .complete;
    return .{ .partial = sent };
}

fn sendClose(self: *WebSocket, conn: *http.Connection) !SendOneResult {
    // Build close payload on the stack: 2-byte code + optional
    // reason (truncated to fit the 125-byte control-frame limit).
    var payload: [125]u8 = undefined;
    const reason_len = @min(self._close_reason.len, 123);
    payload[0] = @intCast((self._close_code >> 8) & 0xFF);
    payload[1] = @intCast(self._close_code & 0xFF);
    if (reason_len > 0) {
        @memcpy(payload[2..][0..reason_len], self._close_reason[0..reason_len]);
    }
    const frame_len = 2 + reason_len;

    const remaining = payload[self._send_offset..frame_len];
    const sent = try conn.wsSend(remaining, .close);
    if (sent == remaining.len) return .complete;
    return .{ .partial = sent };
}

fn scheduleSendRetry(self: *WebSocket) !void {
    if (self._send_retry_queued) return;
    self._send_retry_queued = true;
    self._http_client.inbox.push(.{ .ws_send_retry = self }) catch |err| {
        self._send_retry_queued = false;
        return err;
    };
}

// Transport-level error in the worker's read/write path (peer
// reset, stalled send, malformed framing). Marks the WS as
// closed and tears down — the close event surfaces as abnormal.
fn abortFromTransportError(self: *WebSocket, err: anyerror) void {
    log.warn(.websocket, "transport error", .{ .err = err, .url = self._url });
    self.dispatchErrorEvent() catch |derr| {
        log.err(.websocket, "error event dispatch failed", .{ .err = derr });
    };
    self.dispatchCloseSafe(1006, "", false);
    self.cleanup(false);
}

// Sockopt callback — fires on the network thread after libcurl
// creates the TCP socket for the upgrade and before connect().
// We use it solely to stash the fd on the WS so the worker can
// hand it to the network thread's poll set after handshakeComplete.
fn sockoptCallback(clientp: *anyopaque, fd: libcurl.CurlSocket, _: libcurl.CurlSockType) c_int {
    const conn: *http.Connection = @ptrCast(@alignCast(clientp));
    const self = conn.transport.websocket;
    self._socket_fd = @intCast(fd);
    return libcurl.curl_sockopt_ok;
}

// Header callback — fires during the libcurl-driven upgrade.
// Captures `Sec-WebSocket-Protocol` from the response.
fn receivedHeaderCallback(buffer: [*]const u8, header_count: usize, buf_len: usize, data: *anyopaque) usize {
    if (comptime IS_DEBUG) {
        std.debug.assert(header_count == 1);
    }
    const conn: *http.Connection = @ptrCast(@alignCast(data));
    const self = conn.transport.websocket;
    const header = buffer[0..buf_len];

    // Skip HTTP/x.y status lines and the blank-line terminator —
    // libcurl validates the upgrade itself.
    if (buf_len <= 2 or std.mem.startsWith(u8, header, "HTTP/")) {
        return buf_len;
    }

    const colon = std.mem.indexOfScalarPos(u8, header, 0, ':') orelse return buf_len;
    const header_name = header[0..colon];
    const value = std.mem.trim(u8, header[colon + 1 ..], " \t\r\n");

    if (std.ascii.eqlIgnoreCase(header_name, "sec-websocket-protocol")) {
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
