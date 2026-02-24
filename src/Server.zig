// Copyright (C) 2023-2025 Lightpanda (Selecy SAS)
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
const builtin = @import("builtin");

const net = std.net;
const posix = std.posix;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const log = @import("log.zig");
const App = @import("App.zig");
const Config = @import("Config.zig");
const CDP = @import("cdp/cdp.zig").CDP;
const Net = @import("Net.zig");
const Http = @import("http/Http.zig");
const HttpClient = @import("http/Client.zig");

const Server = @This();

app: *App,
shutdown: std.atomic.Value(bool) = .init(false),
allocator: Allocator,
listener: ?posix.socket_t,
json_version_response: []const u8,

// Thread management
active_threads: std.atomic.Value(u32) = .init(0),
clients: std.ArrayList(*Client) = .{},
client_mutex: std.Thread.Mutex = .{},
clients_pool: std.heap.MemoryPool(Client),

pub fn init(app: *App, address: net.Address) !Server {
    const allocator = app.allocator;
    const json_version_response = try buildJSONVersionResponse(allocator, address);
    errdefer allocator.free(json_version_response);

    return .{
        .app = app,
        .listener = null,
        .allocator = allocator,
        .json_version_response = json_version_response,
        .clients_pool = std.heap.MemoryPool(Client).init(app.allocator),
    };
}

/// Interrupts the server so that main can complete normally and call all defer handlers.
pub fn stop(self: *Server) void {
    if (self.shutdown.swap(true, .release)) {
        return;
    }

    // Shutdown all active clients
    {
        self.client_mutex.lock();
        defer self.client_mutex.unlock();
        for (self.clients.items) |client| {
            client.stop();
        }
    }

    // Linux and BSD/macOS handle canceling a socket blocked on accept differently.
    // For Linux, we use std.shutdown, which will cause accept to return error.SocketNotListening (EINVAL).
    // For BSD, shutdown will return an error. Instead we call posix.close, which will result with error.ConnectionAborted (BADF).
    if (self.listener) |listener| switch (builtin.target.os.tag) {
        .linux => posix.shutdown(listener, .recv) catch |err| {
            log.warn(.app, "listener shutdown", .{ .err = err });
        },
        .macos, .freebsd, .netbsd, .openbsd => {
            self.listener = null;
            posix.close(listener);
        },
        else => unreachable,
    };
}

pub fn deinit(self: *Server) void {
    if (!self.shutdown.load(.acquire)) {
        self.stop();
    }

    self.joinThreads();
    if (self.listener) |listener| {
        posix.close(listener);
        self.listener = null;
    }
    self.clients.deinit(self.allocator);
    self.clients_pool.deinit();
    self.allocator.free(self.json_version_response);
}

pub fn run(self: *Server, address: net.Address, timeout_ms: u32) !void {
    const flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const listener = try posix.socket(address.any.family, flags, posix.IPPROTO.TCP);
    self.listener = listener;

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(posix.TCP, "NODELAY")) {
        try posix.setsockopt(listener, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
    }

    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, self.app.config.maxPendingConnections());

    log.info(.app, "server running", .{ .address = address });
    while (!self.shutdown.load(.acquire)) {
        const socket = posix.accept(listener, null, null, posix.SOCK.NONBLOCK) catch |err| {
            switch (err) {
                error.SocketNotListening, error.ConnectionAborted => {
                    log.info(.app, "server stopped", .{});
                    break;
                },
                error.WouldBlock => {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
                else => {
                    log.err(.app, "CDP accept", .{ .err = err });
                    std.Thread.sleep(std.time.ns_per_s);
                    continue;
                },
            }
        };

        self.spawnWorker(socket, timeout_ms) catch |err| {
            log.err(.app, "CDP spawn", .{ .err = err });
            posix.close(socket);
        };
    }
}

fn handleConnection(self: *Server, socket: posix.socket_t, timeout_ms: u32) void {
    defer posix.close(socket);

    // Client is HUGE (> 512KB) because it has a large read buffer.
    // V8 crashes if this is on the stack (likely related to its size).
    const client = self.getClient() catch |err| {
        log.err(.app, "CDP client create", .{ .err = err });
        return;
    };
    defer self.releaseClient(client);

    client.* = Client.init(
        socket,
        self.allocator,
        self.app,
        self.json_version_response,
        timeout_ms,
    ) catch |err| {
        log.err(.app, "CDP client init", .{ .err = err });
        return;
    };
    defer client.deinit();

    self.registerClient(client);
    defer self.unregisterClient(client);

    // Check shutdown after registering to avoid missing stop() signal.
    // If stop() already iterated over clients, this client won't receive stop()
    // and would block joinThreads() indefinitely.
    if (self.shutdown.load(.acquire)) {
        return;
    }

    client.start();
}

fn getClient(self: *Server) !*Client {
    self.client_mutex.lock();
    defer self.client_mutex.unlock();
    return self.clients_pool.create();
}

fn releaseClient(self: *Server, client: *Client) void {
    self.client_mutex.lock();
    defer self.client_mutex.unlock();
    self.clients_pool.destroy(client);
}

fn registerClient(self: *Server, client: *Client) void {
    self.client_mutex.lock();
    defer self.client_mutex.unlock();
    self.clients.append(self.allocator, client) catch {};
}

fn unregisterClient(self: *Server, client: *Client) void {
    self.client_mutex.lock();
    defer self.client_mutex.unlock();
    for (self.clients.items, 0..) |c, i| {
        if (c == client) {
            _ = self.clients.swapRemove(i);
            break;
        }
    }
}

fn spawnWorker(self: *Server, socket: posix.socket_t, timeout_ms: u32) !void {
    if (self.shutdown.load(.acquire)) {
        return error.ShuttingDown;
    }

    // Atomically increment active_threads only if below max_connections.
    // Uses CAS loop to avoid race between checking the limit and incrementing.
    //
    // cmpxchgWeak may fail for two reasons:
    // 1. Another thread changed the value (increment or decrement)
    // 2. Spurious failure on some architectures (e.g. ARM)
    //
    // We use Weak instead of Strong because we need a retry loop anyway:
    // if CAS fails because a thread finished (counter decreased), we should
    // retry rather than return an error - there may now be room for a new connection.
    //
    // On failure, cmpxchgWeak returns the actual value, which we reuse to avoid
    // an extra load on the next iteration.
    const max_connections = self.app.config.maxConnections();
    var current = self.active_threads.load(.monotonic);
    while (current < max_connections) {
        current = self.active_threads.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) orelse break;
    } else {
        return error.MaxThreadsReached;
    }
    errdefer _ = self.active_threads.fetchSub(1, .monotonic);

    const thread = try std.Thread.spawn(.{}, runWorker, .{ self, socket, timeout_ms });
    thread.detach();
}

fn runWorker(self: *Server, socket: posix.socket_t, timeout_ms: u32) void {
    defer _ = self.active_threads.fetchSub(1, .monotonic);
    handleConnection(self, socket, timeout_ms);
}

fn joinThreads(self: *Server) void {
    while (self.active_threads.load(.monotonic) > 0) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

// Handle exactly one TCP connection.
pub const Client = struct {
    // The client is initially serving HTTP requests but, under normal circumstances
    // should eventually be upgraded to a websocket connections
    mode: union(enum) {
        http: void,
        cdp: CDP,
    },

    allocator: Allocator,
    app: *App,
    http: *HttpClient,
    ws: Net.WsConnection,

    fn init(
        socket: posix.socket_t,
        allocator: Allocator,
        app: *App,
        json_version_response: []const u8,
        timeout_ms: u32,
    ) !Client {
        var ws = try Net.WsConnection.init(socket, allocator, json_version_response, timeout_ms);
        errdefer ws.deinit();

        if (log.enabled(.app, .info)) {
            const client_address = ws.getAddress() catch null;
            log.info(.app, "client connected", .{ .ip = client_address });
        }

        const http = try app.http.createClient(allocator);
        errdefer http.deinit();

        return .{
            .allocator = allocator,
            .app = app,
            .http = http,
            .ws = ws,
            .mode = .{ .http = {} },
        };
    }

    fn stop(self: *Client) void {
        self.ws.shutdown();
    }

    fn deinit(self: *Client) void {
        switch (self.mode) {
            .cdp => |*cdp| cdp.deinit(),
            .http => {},
        }
        self.ws.deinit();
        self.http.deinit();
    }

    fn start(self: *Client) void {
        const http = self.http;
        http.cdp_client = .{
            .socket = self.ws.socket,
            .ctx = self,
            .blocking_read_start = Client.blockingReadStart,
            .blocking_read = Client.blockingRead,
            .blocking_read_end = Client.blockingReadStop,
        };
        defer http.cdp_client = null;

        self.httpLoop(http) catch |err| {
            log.err(.app, "CDP client loop", .{ .err = err });
        };
    }

    fn httpLoop(self: *Client, http: *HttpClient) !void {
        lp.assert(self.mode == .http, "Client.httpLoop invalid mode", .{});

        while (true) {
            const status = http.tick(self.ws.timeout_ms) catch |err| {
                log.err(.app, "http tick", .{ .err = err });
                return;
            };
            if (status != .cdp_socket) {
                log.info(.app, "CDP timeout", .{});
                return;
            }

            if (self.readSocket() == false) {
                return;
            }

            if (self.mode == .cdp) {
                break;
            }
        }

        var cdp = &self.mode.cdp;
        var last_message = timestamp(.monotonic);
        var ms_remaining = self.ws.timeout_ms;

        while (true) {
            switch (cdp.pageWait(ms_remaining)) {
                .cdp_socket => {
                    if (self.readSocket() == false) {
                        return;
                    }
                    last_message = timestamp(.monotonic);
                    ms_remaining = self.ws.timeout_ms;
                },
                .no_page => {
                    const status = http.tick(ms_remaining) catch |err| {
                        log.err(.app, "http tick", .{ .err = err });
                        return;
                    };
                    if (status != .cdp_socket) {
                        log.info(.app, "CDP timeout", .{});
                        return;
                    }
                    if (self.readSocket() == false) {
                        return;
                    }
                    last_message = timestamp(.monotonic);
                    ms_remaining = self.ws.timeout_ms;
                },
                .done => {
                    const elapsed = timestamp(.monotonic) - last_message;
                    if (elapsed > ms_remaining) {
                        log.info(.app, "CDP timeout", .{});
                        return;
                    }
                    ms_remaining -= @intCast(elapsed);
                },
            }
        }
    }

    fn blockingReadStart(ctx: *anyopaque) bool {
        const self: *Client = @ptrCast(@alignCast(ctx));
        self.ws.setBlocking(true) catch |err| {
            log.warn(.app, "CDP blockingReadStart", .{ .err = err });
            return false;
        };
        return true;
    }

    fn blockingRead(ctx: *anyopaque) bool {
        const self: *Client = @ptrCast(@alignCast(ctx));
        return self.readSocket();
    }

    fn blockingReadStop(ctx: *anyopaque) bool {
        const self: *Client = @ptrCast(@alignCast(ctx));
        self.ws.setBlocking(false) catch |err| {
            log.warn(.app, "CDP blockingReadStop", .{ .err = err });
            return false;
        };
        return true;
    }

    fn readSocket(self: *Client) bool {
        const n = self.ws.read() catch |err| {
            log.warn(.app, "CDP read", .{ .err = err });
            return false;
        };

        if (n == 0) {
            log.info(.app, "CDP disconnect", .{});
            return false;
        }

        return self.processData() catch false;
    }

    fn processData(self: *Client) !bool {
        switch (self.mode) {
            .cdp => |*cdp| return self.processWebsocketMessage(cdp),
            .http => return self.processHTTPRequest(),
        }
    }

    fn processHTTPRequest(self: *Client) !bool {
        lp.assert(self.ws.reader.pos == 0, "Client.HTTP pos", .{ .pos = self.ws.reader.pos });
        const request = self.ws.reader.buf[0..self.ws.reader.len];

        if (request.len > Config.CDP_MAX_HTTP_REQUEST_SIZE) {
            self.writeHTTPErrorResponse(413, "Request too large");
            return error.RequestTooLarge;
        }

        // we're only expecting [body-less] GET requests.
        if (std.mem.endsWith(u8, request, "\r\n\r\n") == false) {
            // we need more data, put any more data here
            return true;
        }

        // the next incoming data can go to the front of our buffer
        defer self.ws.reader.len = 0;
        return self.handleHTTPRequest(request) catch |err| {
            switch (err) {
                error.NotFound => self.writeHTTPErrorResponse(404, "Not found"),
                error.InvalidRequest => self.writeHTTPErrorResponse(400, "Invalid request"),
                error.InvalidProtocol => self.writeHTTPErrorResponse(400, "Invalid HTTP protocol"),
                error.MissingHeaders => self.writeHTTPErrorResponse(400, "Missing required header"),
                error.InvalidUpgradeHeader => self.writeHTTPErrorResponse(400, "Unsupported upgrade type"),
                error.InvalidVersionHeader => self.writeHTTPErrorResponse(400, "Invalid websocket version"),
                error.InvalidConnectionHeader => self.writeHTTPErrorResponse(400, "Invalid connection header"),
                else => {
                    log.err(.app, "server 500", .{ .err = err, .req = request[0..@min(100, request.len)] });
                    self.writeHTTPErrorResponse(500, "Internal Server Error");
                },
            }
            return err;
        };
    }

    fn handleHTTPRequest(self: *Client, request: []u8) !bool {
        if (request.len < 18) {
            // 18 is [generously] the smallest acceptable HTTP request
            return error.InvalidRequest;
        }

        if (std.mem.eql(u8, request[0..4], "GET ") == false) {
            return error.NotFound;
        }

        const url_end = std.mem.indexOfScalarPos(u8, request, 4, ' ') orelse {
            return error.InvalidRequest;
        };

        const url = request[4..url_end];

        if (std.mem.eql(u8, url, "/")) {
            try self.upgradeConnection(request);
            return true;
        }

        if (std.mem.eql(u8, url, "/json/version") or std.mem.eql(u8, url, "/json/version/")) {
            try self.ws.send(self.ws.json_version_response);
            // Chromedp (a Go driver) does an http request to /json/version
            // then to / (websocket upgrade) using a different connection.
            // Since we only allow 1 connection at a time, the 2nd one (the
            // websocket upgrade) blocks until the first one times out.
            // We can avoid that by closing the connection. json_version_response
            // has a Connection: Close header too.
            self.ws.shutdown();
            return false;
        }

        return error.NotFound;
    }

    fn upgradeConnection(self: *Client, request: []u8) !void {
        try self.ws.upgrade(request);
        self.mode = .{ .cdp = try CDP.init(self.app, self.http, self) };
    }

    fn writeHTTPErrorResponse(self: *Client, comptime status: u16, comptime body: []const u8) void {
        self.ws.sendHttpError(status, body);
    }

    fn processWebsocketMessage(self: *Client, cdp: *CDP) !bool {
        return self.ws.processMessages(cdp);
    }

    pub fn sendAllocator(self: *Client) Allocator {
        return self.ws.send_arena.allocator();
    }

    pub fn sendJSON(self: *Client, message: anytype, opts: std.json.Stringify.Options) !void {
        return self.ws.sendJSON(message, opts);
    }

    pub fn sendJSONRaw(self: *Client, buf: std.ArrayList(u8)) !void {
        return self.ws.sendJSONRaw(buf);
    }
};

// Utils
// --------

fn buildJSONVersionResponse(
    allocator: Allocator,
    address: net.Address,
) ![]const u8 {
    const body_format = "{{\"webSocketDebuggerUrl\": \"ws://{f}/\"}}";
    const body_len = std.fmt.count(body_format, .{address});

    // We send a Connection: Close (and actually close the connection)
    // because chromedp (Go driver) sends a request to /json/version and then
    // does an upgrade request, on a different connection. Since we only allow
    // 1 connection at a time, the upgrade connection doesn't proceed until we
    // timeout the /json/version. So, instead of waiting for that, we just
    // always close HTTP requests.
    const response_format =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        body_format;
    return try std.fmt.allocPrint(allocator, response_format, .{ body_len, address });
}

pub const timestamp = @import("datetime.zig").timestamp;

const testing = std.testing;
test "server: buildJSONVersionResponse" {
    const address = try net.Address.parseIp4("127.0.0.1", 9001);
    const res = try buildJSONVersionResponse(testing.allocator, address);
    defer testing.allocator.free(res);

    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 48\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        "{\"webSocketDebuggerUrl\": \"ws://127.0.0.1:9001/\"}", res);
}

test "Client: http invalid request" {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest("GET /over/9000 HTTP/1.1\r\n" ++ "Header: " ++ ("a" ** 4100) ++ "\r\n\r\n");
    try testing.expectEqualStrings("HTTP/1.1 413 \r\n" ++
        "Connection: Close\r\n" ++
        "Content-Length: 17\r\n\r\n" ++
        "Request too large", res);
}

test "Client: http invalid handshake" {
    try assertHTTPError(
        400,
        "Invalid request",
        "\r\n\r\n",
    );

    try assertHTTPError(
        404,
        "Not found",
        "GET /over/9000 HTTP/1.1\r\n\r\n",
    );

    try assertHTTPError(
        404,
        "Not found",
        "POST / HTTP/1.1\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Invalid HTTP protocol",
        "GET / HTTP/1.0\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\nConnection:  upgrade\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n",
    );

    try assertHTTPError(
        400,
        "Missing required header",
        "GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\n\r\n",
    );
}

test "Client: http valid handshake" {
    var c = try createTestClient();
    defer c.deinit();

    const request =
        "GET /   HTTP/1.1\r\n" ++
        "Connection: upgrade\r\n" ++
        "Upgrade: websocket\r\n" ++
        "sec-websocket-version:13\r\n" ++
        "sec-websocket-key: this is my key\r\n" ++
        "Custom:  Header-Value\r\n\r\n";

    const res = try c.httpRequest(request);
    try testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: upgrade\r\n" ++
        "Sec-Websocket-Accept: flzHu2DevQ2dSCSVqKSii5e9C2o=\r\n\r\n", res);
}

test "Client: read invalid websocket message" {
    // 131 = 128 (fin) | 3  where 3 isn't a valid type
    try assertWebSocketError(
        1002,
        &.{ 131, 128, 'm', 'a', 's', 'k' },
    );

    for ([_]u8{ 16, 32, 64 }) |rsv| {
        // none of the reserve flags should be set
        try assertWebSocketError(
            1002,
            &.{ rsv, 128, 'm', 'a', 's', 'k' },
        );

        // as a bitmask
        try assertWebSocketError(
            1002,
            &.{ rsv + 4, 128, 'm', 'a', 's', 'k' },
        );
    }

    // client->server messages must be masked
    try assertWebSocketError(
        1002,
        &.{ 129, 1, 'a' },
    );

    // control types (ping/ping/close) can't be > 125 bytes
    for ([_]u8{ 136, 137, 138 }) |op| {
        try assertWebSocketError(
            1002,
            &.{ op, 254, 1, 1 },
        );
    }

    // length of message is 0000 0810, i.e: 1024 * 512 + 265
    try assertWebSocketError(1009, &.{ 129, 255, 0, 0, 0, 0, 0, 8, 1, 0, 'm', 'a', 's', 'k' });

    // continuation type message must come after a normal message
    // even when not a fin frame
    try assertWebSocketError(
        1002,
        &.{ 0, 129, 'm', 'a', 's', 'k', 'd' },
    );

    // continuation type message must come after a normal message
    // even as a fin frame
    try assertWebSocketError(
        1002,
        &.{ 128, 129, 'm', 'a', 's', 'k', 'd' },
    );

    // text (non-fin) - text (non-fin)
    try assertWebSocketError(
        1002,
        &.{ 1, 129, 'm', 'a', 's', 'k', 'd', 1, 128, 'k', 's', 'a', 'm' },
    );

    // text (non-fin) - text (fin) should always been continuation after non-fin
    try assertWebSocketError(
        1002,
        &.{ 1, 129, 'm', 'a', 's', 'k', 'd', 129, 128, 'k', 's', 'a', 'm' },
    );

    // close must be fin
    try assertWebSocketError(
        1002,
        &.{
            8, 129, 'm', 'a', 's', 'k', 'd',
        },
    );

    // ping must be fin
    try assertWebSocketError(
        1002,
        &.{
            9, 129, 'm', 'a', 's', 'k', 'd',
        },
    );

    // pong must be fin
    try assertWebSocketError(
        1002,
        &.{
            10, 129, 'm', 'a', 's', 'k', 'd',
        },
    );
}

test "Client: ping reply" {
    try assertWebSocketMessage(
        // fin | pong, len
        &.{ 138, 0 },

        // fin | ping, masked | len, 4-byte mask
        &.{ 137, 128, 0, 0, 0, 0 },
    );

    try assertWebSocketMessage(
        // fin | pong, len, payload
        &.{ 138, 5, 100, 96, 97, 109, 104 },

        // fin | ping, masked | len, 4-byte mask, 5 byte payload
        &.{ 137, 133, 0, 5, 7, 10, 100, 101, 102, 103, 104 },
    );
}

test "Client: close message" {
    try assertWebSocketMessage(
        // fin | close, len, close code (normal)
        &.{ 136, 2, 3, 232 },

        // fin | close, masked | len, 4-byte mask
        &.{ 136, 128, 0, 0, 0, 0 },
    );
}

test "server: 404" {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest("GET /unknown HTTP/1.1\r\n\r\n");
    try testing.expectEqualStrings("HTTP/1.1 404 \r\n" ++
        "Connection: Close\r\n" ++
        "Content-Length: 9\r\n\r\n" ++
        "Not found", res);
}

test "server: get /json/version" {
    const expected_response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 48\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        "{\"webSocketDebuggerUrl\": \"ws://127.0.0.1:9583/\"}";

    {
        // twice on the same connection
        var c = try createTestClient();
        defer c.deinit();

        const res1 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expectEqualStrings(expected_response, res1);
    }

    {
        // again on a new connection
        var c = try createTestClient();
        defer c.deinit();

        const res1 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expectEqualStrings(expected_response, res1);
    }
}

fn assertHTTPError(
    comptime expected_status: u16,
    comptime expected_body: []const u8,
    input: []const u8,
) !void {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest(input);
    const expected_response = std.fmt.comptimePrint(
        "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ expected_status, expected_body.len, expected_body },
    );

    try testing.expectEqualStrings(expected_response, res);
}

fn assertWebSocketError(close_code: u16, input: []const u8) !void {
    var c = try createTestClient();
    defer c.deinit();

    try c.handshake();
    try c.stream.writeAll(input);

    const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
    defer if (msg.cleanup_fragment) {
        c.reader.cleanup();
    };

    try testing.expectEqual(.close, msg.type);
    try testing.expectEqual(2, msg.data.len);
    try testing.expectEqual(close_code, std.mem.readInt(u16, msg.data[0..2], .big));
}

fn assertWebSocketMessage(expected: []const u8, input: []const u8) !void {
    var c = try createTestClient();
    defer c.deinit();

    try c.handshake();
    try c.stream.writeAll(input);

    const msg = try c.readWebsocketMessage() orelse return error.NoMessage;
    defer if (msg.cleanup_fragment) {
        c.reader.cleanup();
    };

    const actual = c.reader.buf[0 .. msg.data.len + 2];
    try testing.expectEqualSlices(u8, expected, actual);
}

const MockCDP = struct {
    messages: std.ArrayList([]const u8) = .{},

    allocator: Allocator = testing.allocator,

    fn init(_: Allocator, client: anytype) MockCDP {
        _ = client;
        return .{};
    }

    fn deinit(self: *MockCDP) void {
        const allocator = self.allocator;
        for (self.messages.items) |msg| {
            allocator.free(msg);
        }
        self.messages.deinit(allocator);
    }

    fn handleMessage(self: *MockCDP, message: []const u8) bool {
        const owned = self.allocator.dupe(u8, message) catch unreachable;
        self.messages.append(self.allocator, owned) catch unreachable;
        return true;
    }
};

fn createTestClient() !TestClient {
    const address = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 9583);
    const stream = try std.net.tcpConnectToAddress(address);

    const timeout = std.mem.toBytes(posix.timeval{
        .sec = 2,
        .usec = 0,
    });
    try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
    return .{
        .stream = stream,
        .reader = .{
            .allocator = testing.allocator,
            .buf = try testing.allocator.alloc(u8, 1024 * 16),
        },
    };
}

const TestClient = struct {
    stream: std.net.Stream,
    buf: [1024]u8 = undefined,
    reader: Net.Reader(false),

    fn deinit(self: *TestClient) void {
        self.stream.close();
        self.reader.deinit();
    }

    fn httpRequest(self: *TestClient, req: []const u8) ![]const u8 {
        try self.stream.writeAll(req);

        var pos: usize = 0;
        var total_length: ?usize = null;
        while (true) {
            pos += try self.stream.read(self.buf[pos..]);
            if (pos == 0) {
                return error.NoMoreData;
            }
            const response = self.buf[0..pos];
            if (total_length == null) {
                const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse continue;
                const header = response[0 .. header_end + 4];

                const cl = blk: {
                    const cl_header = "Content-Length: ";
                    const start = (std.mem.indexOf(u8, header, cl_header) orelse {
                        break :blk 0;
                    }) + cl_header.len;

                    const end = std.mem.indexOfScalarPos(u8, header, start, '\r') orelse {
                        return error.InvalidContentLength;
                    };

                    break :blk std.fmt.parseInt(usize, header[start..end], 10) catch {
                        return error.InvalidContentLength;
                    };
                };

                total_length = cl + header.len;
            }

            if (total_length) |tl| {
                if (pos == tl) {
                    return response;
                }
                if (pos > tl) {
                    return error.DataExceedsContentLength;
                }
            }
        }
    }

    fn handshake(self: *TestClient) !void {
        const request =
            "GET /   HTTP/1.1\r\n" ++
            "Connection: upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "sec-websocket-version:13\r\n" ++
            "sec-websocket-key: this is my key\r\n" ++
            "Custom:  Header-Value\r\n\r\n";

        const res = try self.httpRequest(request);
        try testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: upgrade\r\n" ++
            "Sec-Websocket-Accept: flzHu2DevQ2dSCSVqKSii5e9C2o=\r\n\r\n", res);
    }

    fn readWebsocketMessage(self: *TestClient) !?Net.Message {
        while (true) {
            const n = try self.stream.read(self.reader.readBuf());
            if (n == 0) {
                return error.Closed;
            }
            self.reader.len += n;
            if (try self.reader.next()) |msg| {
                return msg;
            }
        }
    }
};
