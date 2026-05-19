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

const App = @import("App.zig");
const Config = @import("Config.zig");

const CDP = @import("cdp/CDP.zig");

const log = lp.log;
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Server = @This();

app: *App,
max_connections: usize,
json_version_response: []const u8,

active_threads: std.atomic.Value(u32) = .init(0),

cdps: std.ArrayList(*CDP) = .{},
cdp_mutex: std.Thread.Mutex = .{},
cdp_pool: std.heap.MemoryPool(CDP),

pub fn init(app: *App, address: net.Address) !*Server {
    const self = try app.allocator.create(Server);
    errdefer app.allocator.destroy(self);

    self.* = .{
        .app = app,
        .json_version_response = "",
        .cdp_pool = .init(app.allocator),
        .max_connections = app.config.maxConnections(),
    };
    errdefer self.cdp_pool.deinit();

    // Bind first so /json/version can advertise the OS-assigned port (--port 0).
    var bound_address = address;
    try app.network.bind(&bound_address, self, onAccept);
    log.info(.app, "server running", .{ .address = bound_address });

    self.json_version_response = try buildJSONVersionResponse(app, bound_address.getPort());
    return self;
}

pub fn shutdown(self: *Server) void {
    self.cdp_mutex.lock();
    defer self.cdp_mutex.unlock();

    self.app.network.unbind();

    for (self.cdps.items) |cdp| {
        if (cdp.conn.state == .live) {
            cdp.browser.env.terminate();
            // We use to send a nice WS close frame here but (a) it isn't
            // strictly required and (b) we'd have to protect against an interleaved
            // write from the worker thread.
        }
        cdp.conn.shutdown();
    }
}

pub fn deinit(self: *Server) void {
    self.shutdown();

    while (self.active_threads.load(.monotonic) > 0) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    self.cdps.deinit(self.app.allocator);
    self.cdp_pool.deinit();
    self.app.allocator.free(self.json_version_response);
    self.app.allocator.destroy(self);
}

fn onAccept(ctx: *anyopaque, socket: posix.socket_t) void {
    const self: *Server = @ptrCast(@alignCast(ctx));

    configureSocket(socket) catch {
        posix.close(socket);
        return;
    };

    self.spawnWorker(socket) catch |err| {
        log.err(.app, "CDP spawn", .{ .err = err });
        posix.close(socket);
    };
}

// Liveness is enforced at the TCP layer via keepalive probes sent by the
// kernel. This is transparent to CDP clients — unlike a WebSocket ping, which
// go-rod panics on and chromedp logs as "malformed". Tunables in Config.zig.
fn configureSocket(socket: posix.socket_t) !void {
    posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &std.mem.toBytes(@as(c_int, 1))) catch |err| {
        log.warn(.app, "SO_KEEPALIVE", .{ .err = err });
        return err;
    };

    const idle_opt = switch (builtin.os.tag) {
        .macos, .ios => posix.TCP.KEEPALIVE,
        else => posix.TCP.KEEPIDLE,
    };
    posix.setsockopt(socket, posix.IPPROTO.TCP, idle_opt, &std.mem.toBytes(Config.CDP_KEEPALIVE_IDLE_S)) catch |err| {
        log.warn(.app, "TCP_KEEPIDLE", .{ .err = err });
        return err;
    };
    posix.setsockopt(socket, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, &std.mem.toBytes(Config.CDP_KEEPALIVE_INTVL_S)) catch |err| {
        log.warn(.app, "TCP_KEEPINTVL", .{ .err = err });
        return err;
    };
    posix.setsockopt(socket, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, &std.mem.toBytes(Config.CDP_KEEPALIVE_CNT)) catch |err| {
        log.warn(.app, "TCP_KEEPCNT", .{ .err = err });
        return err;
    };
}

fn spawnWorker(self: *Server, socket: posix.socket_t) !void {
    if (self.app.shutdown()) {
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
    var current = self.active_threads.load(.monotonic);
    while (current < self.max_connections) {
        current = self.active_threads.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) orelse break;
    } else {
        return error.MaxThreadsReached;
    }
    errdefer _ = self.active_threads.fetchSub(1, .monotonic);

    const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, socket });
    thread.detach();
}

fn handleConnection(self: *Server, socket: posix.socket_t) void {
    defer _ = self.active_threads.fetchSub(1, .monotonic);
    defer posix.close(socket);

    const cdp = blk: {
        self.cdp_mutex.lock();
        defer self.cdp_mutex.unlock();
        break :blk self.cdp_pool.create() catch @panic("OOM");
    };
    defer {
        self.cdp_mutex.lock();
        defer self.cdp_mutex.unlock();
        self.cdp_pool.destroy(cdp);
    }

    cdp.init(self.app, socket, self.json_version_response) catch |err| {
        log.err(.app, "CDP init", .{ .err = err });
        return;
    };
    defer cdp.deinit();

    if (log.enabled(.app, .info)) {
        const client_address = cdp.conn.getAddress() catch null;
        log.info(.app, "client connected", .{ .ip = client_address });
    }

    {
        // track the connection
        self.cdp_mutex.lock();
        defer self.cdp_mutex.unlock();
        self.cdps.append(self.app.allocator, cdp) catch {};
    }

    defer {
        // untrack the connection
        self.cdp_mutex.lock();
        defer self.cdp_mutex.unlock();
        for (self.cdps.items, 0..) |c, i| {
            if (c == cdp) {
                _ = self.cdps.swapRemove(i);
                break;
            }
        }
    }

    const upgraded = cdp.conn.handshake() catch |err| {
        log.err(.app, "CDP handshake", .{ .err = err });
        return;
    };

    if (!upgraded) {
        return;
    }

    {
        // Transition from .handshake state to .live
        // Lock needed even though the main thread hasn't seen this yet because
        // shutdown could access this from the sighandler thread.
        self.cdp_mutex.lock();
        defer self.cdp_mutex.unlock();
        cdp.conn.state = .live;
    }

    // Hand the read side of the CDP socket over to the Network thread.
    // From here until the matching unregisterCdp, the worker must NOT
    // read from the socket directly — bytes arrive via the inbox.
    // unregisterCdp is synchronous, so by the time it returns Network
    // is guaranteed to be done with this link.
    //
    // cdp_link_active gates HttpClient.perform's block in
    // curl_multi_poll: with it false (tests, pre-handshake), perform
    // skips the poll when there's no in-flight curl work — sleeping
    // would just eat the timeout waiting for a wakeup that won't
    // come. We set it true *after* registerCdp so Network is already
    // accepting wakeups by the time the worker might poll, and clear
    // it *after* unregisterCdp returns (Network is guaranteed done
    // with us by then).
    self.app.network.registerCdp(&cdp.link);
    cdp.browser.http_client.cdp_link_active = true;
    defer {
        self.app.network.unregisterCdp(&cdp.link);
        cdp.browser.http_client.cdp_link_active = false;
    }

    // Check shutdown after markLive so that a concurrent shutdown either
    // sees us as .live and terminates us, or we observe the stop signal
    // here. Otherwise we could miss it and block deinit() indefinitely.
    if (self.app.shutdown()) {
        return;
    }

    while (true) {
        const next = cdp.tick() catch |err| {
            log.err(.app, "cdp tick", .{ .err = err });
            return;
        };
        if (!next) break;
    }
}

fn buildJSONVersionResponse(app: *const App, port: u16) ![]const u8 {
    const host = app.config.advertiseHost();
    if (std.mem.eql(u8, host, "0.0.0.0")) {
        log.info(.cdp, "unreachable advertised host", .{
            .message = "when --host is set to 0.0.0.0 consider setting --advertise-host to a reachable address",
        });
    }
    const body_format =
        "{{" ++
        "\"Browser\": \"Lightpanda/1.0\", " ++
        "\"Protocol-Version\": \"1.3\", " ++
        "\"User-Agent\": \"Lightpanda/1.0\", " ++
        "\"webSocketDebuggerUrl\": \"ws://{s}:{d}/\"" ++
        "}}";
    const body_len = std.fmt.count(body_format, .{ host, port });

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
    return try std.fmt.allocPrint(app.allocator, response_format, .{ body_len, host, port });
}

const testing = @import("testing.zig");
test "server: buildJSONVersionResponse" {
    const res = try buildJSONVersionResponse(testing.test_app, testing.test_app.config.port());
    defer testing.test_app.allocator.free(res);

    // The response includes the build version, so check structure rather than exact bytes.
    try testing.expect(std.mem.startsWith(u8, res, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, res, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, res, "Connection: Close") != null);

    // Verify all required JSON fields are present in the body
    try testing.expect(std.mem.indexOf(u8, res, "\"Browser\": \"Lightpanda/") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"Protocol-Version\": \"1.3\"") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"User-Agent\": \"Lightpanda/") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"webSocketDebuggerUrl\": \"ws://127.0.0.1:9222/\"") != null);
}

test "Client: http invalid request" {
    var c = try createTestClient();
    defer c.deinit();

    const res = try c.httpRequest("GET /over/9000 HTTP/1.1\r\n" ++ "Header: " ++ ("a" ** 4100) ++ "\r\n\r\n");
    try testing.expectEqual("HTTP/1.1 413 \r\n" ++
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
    try testing.expectEqual("HTTP/1.1 101 Switching Protocols\r\n" ++
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
    try testing.expectEqual("HTTP/1.1 404 \r\n" ++
        "Connection: Close\r\n" ++
        "Content-Length: 9\r\n\r\n" ++
        "Not found", res);
}

test "server: get /json/version" {
    {
        // twice on the same connection
        var c = try createTestClient();
        defer c.deinit();

        const res1 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expect(std.mem.startsWith(u8, res1, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(std.mem.indexOf(u8, res1, "\"Browser\": \"Lightpanda/") != null);
        try testing.expect(std.mem.indexOf(u8, res1, "\"Protocol-Version\": \"1.3\"") != null);
        try testing.expect(std.mem.indexOf(u8, res1, "\"webSocketDebuggerUrl\": \"ws://127.0.0.1:9583/\"") != null);
    }

    {
        // again on a new connection
        var c = try createTestClient();
        defer c.deinit();

        const res1 = try c.httpRequest("GET /json/version HTTP/1.1\r\n\r\n");
        try testing.expect(std.mem.startsWith(u8, res1, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(std.mem.indexOf(u8, res1, "\"Browser\": \"Lightpanda/") != null);
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

    try testing.expectEqual(expected_response, res);
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
    reader: WS.Reader(false, 1024),

    const WS = @import("network/WS.zig");

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
        try testing.expectEqual("HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: upgrade\r\n" ++
            "Sec-Websocket-Accept: flzHu2DevQ2dSCSVqKSii5e9C2o=\r\n\r\n", res);
    }

    fn readWebsocketMessage(self: *TestClient) !?WS.Message {
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
