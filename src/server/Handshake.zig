// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

// The pre-upgrade HTTP phase of a connection. Owns the socket until it
// either serves a plain HTTP request (/json/*, /metrics) and closes, or
// completes a websocket upgrade — at which point the request path decides
// which protocol driver the connection is handed to.

const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const sys_net = @import("../sys/net.zig");
const uuidv4 = @import("../id.zig").uuidv4;
const header_parser = @import("../network/header_parser.zig");
const bidi_session = @import("bidi/session.zig");

const log = lp.log;
const posix = std.posix;

const Handshake = @This();

pub const Driver = enum { cdp, bidi };

// Which driver an upgraded socket is handed to.
pub const Route = union(Driver) {
    cdp,
    bidi: ?[36]u8, // the sessionId
};

// Which route families are served.
pub const Protocols = struct {
    cdp: bool = false,
    webdriver: bool = false,
};

// What every handshake on a server needs; built once by Server.
pub const Options = struct {
    protocols: Protocols,
    bidi_session_url: []const u8,
    json_version_response: []const u8,
};

app: *App,
len: usize = 0,
socket: posix.socket_t,
// cdpMaxHTTPMessageSize is a u14, so this covers any configured limit.
buf: [std.math.maxInt(u14) + 1]u8 = undefined,
options: *const Options,

const Result = union(enum) {
    more,
    close,
    upgrade: Route,
};

// Runs the HTTP phase to completion. Returns the route to hand the
// upgraded socket to, or null if the connection is done (plain HTTP
// request served, error, timeout or disconnect).
pub fn run(app: *App, socket: posix.socket_t, options: *const Options) ?Route {
    var self = Handshake{
        .app = app,
        .socket = socket,
        .options = options,
    };

    while (true) {
        var pfds = [_]posix.pollfd{.{
            .fd = self.socket,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const n = posix.poll(&pfds, 5000) catch return null;
        if (n == 0) {
            log.info(.cdp, "handshake timeout", .{});
            return null;
        }
        const read_bytes = posix.read(self.socket, self.buf[self.len..]) catch |err| {
            log.warn(.cdp, "handshake read", .{ .err = err });
            return null;
        };
        if (read_bytes == 0) {
            log.info(.cdp, "handshake disconnect", .{});
            return null;
        }
        self.len += read_bytes;

        const result = self.processHttpRequest() catch return null;
        switch (result) {
            .more => continue,
            .close => return null,
            .upgrade => |route| return route,
        }
    }
}

fn processHttpRequest(self: *Handshake) !Result {
    const request = self.buf[0..self.len];

    if (request.len > self.app.config.cdpMaxHTTPMessageSize()) {
        log.warn(.cdp, "message too big", .{ .type = "HTTP", .len = request.len, .hint = "See the --cdp-max-http-message-size <bytes>" });
        self.sendHttpError(413, "Request too large");
        return error.RequestTooLarge;
    }

    // Wait for the whole header block; put any more data here.
    const head_len = (std.mem.indexOf(u8, request, "\r\n\r\n") orelse return .more) + 4;

    return self.handleHttpRequest(request, head_len) catch |err| {
        switch (err) {
            error.NotFound => self.sendHttpError(404, "Not found"),
            error.ForbiddenOrigin => self.sendHttpError(403, "Origin not allowed"),
            error.ForbiddenHost => self.sendHttpError(403, "Host not allowed"),
            error.InvalidRequest => self.sendHttpError(400, "Invalid request"),
            error.InvalidProtocol => self.sendHttpError(400, "Invalid HTTP protocol"),
            error.MissingHeaders => self.sendHttpError(400, "Missing required header"),
            error.InvalidUpgradeHeader => self.sendHttpError(400, "Unsupported upgrade type"),
            error.InvalidVersionHeader => self.sendHttpError(400, "Invalid websocket version"),
            error.InvalidConnectionHeader => self.sendHttpError(400, "Invalid connection header"),
            else => {
                log.err(.app, "server 500", .{ .err = err, .req = request[0..@min(100, request.len)] });
                self.sendHttpError(500, "Internal Server Error");
            },
        }
        return err;
    };
}

fn handleHttpRequest(self: *Handshake, request: []u8, head_len: usize) !Result {
    if (request.len < 18) {
        // 18 is [generously] the smallest acceptable HTTP request
        return error.InvalidRequest;
    }

    // The classic WebDriver session bootstrap is the only thing with a body.
    if (std.mem.startsWith(u8, request, "POST ") or std.mem.startsWith(u8, request, "DELETE ")) {
        if (!self.options.protocols.webdriver) {
            return error.NotFound;
        }
        return self.handleWebDriverRequest(request, head_len);
    }

    if (std.mem.eql(u8, request[0..4], "GET ") == false) {
        return error.NotFound;
    }

    // Everything else is a body-less GET: the header block is the request.
    if (head_len != request.len) {
        return .more;
    }

    const url_end = std.mem.indexOfScalarPos(u8, request, 4, ' ') orelse {
        return error.InvalidRequest;
    };

    const url = request[4..url_end];

    if (std.mem.eql(u8, url, "/metrics") and self.app.config.metricsEndpointEnabled()) {
        try self.sendMetrics();
        self.shutdown();
        return .close;
    }

    if (self.options.protocols.webdriver) {
        if (std.mem.eql(u8, url, "/session")) {
            // /session is the path Firefox advertises its BiDi endpoint on
            try self.upgrade(request);
            return .{ .upgrade = .{ .bidi = null } };
        }

        if (std.mem.startsWith(u8, url, "/session/") and url.len == "/session/".len + 36) {
            // The URL a POST /session handed out; the session id is the suffix.
            var session_id: [36]u8 = undefined;
            @memcpy(&session_id, url["/session/".len..]);
            try self.upgrade(request);
            return .{ .upgrade = .{ .bidi = session_id } };
        }

        if (std.mem.eql(u8, url, "/status")) {
            // WebDriver's discovery endpoint; `ready` is whether a new session
            // can be created, which the bootstrap never refuses.
            return self.sendWebDriver("200 OK", .{ .ready = true, .message = "" });
        }
    }

    if (!self.options.protocols.cdp) {
        return error.NotFound;
    }

    if (std.mem.eql(u8, url, "/")) {
        try self.upgrade(request);
        return .{ .upgrade = .cdp };
    }

    if (std.mem.eql(u8, url, "/json/version") or std.mem.eql(u8, url, "/json/version/")) {
        try self.send(self.options.json_version_response);
        // Chromedp (a Go driver) does an http request to /json/version
        // then to / (websocket upgrade) using a different connection.
        // Since we only allow 1 connection at a time, the 2nd one (the
        // websocket upgrade) blocks until the first one times out.
        // We can avoid that by closing the connection. json_version_response
        // has a Connection: Close header too.
        self.shutdown();
        return .close;
    }

    if (std.mem.eql(u8, url, "/json/list") or std.mem.eql(u8, url, "/json/list/") or
        std.mem.eql(u8, url, "/json") or std.mem.eql(u8, url, "/json/"))
    {
        try self.send(empty_json_list_response);
        self.shutdown();
        return .close;
    }

    if (std.mem.eql(u8, url, "/json/protocol") or std.mem.eql(u8, url, "/json/protocol/")) {
        try self.send(protocol_response);
        self.shutdown();
        return .close;
    }

    return error.NotFound;
}

// TODO: Temporary solution that provides the bare minimum for Selenium to
// connect. Serve a few of the (classic) WebDriver HTTP API. It's obvious that
// Handshake.zig needs to become a more generic HTTP server/router, but that
// can be done after the experimental BiDi code lands.
fn handleWebDriverRequest(self: *Handshake, request: []const u8, head_len: usize) !Result {
    // A malformed request line or header maps to a 400 in processHttpRequest.
    const method, const path, _, var header_iterator = header_parser.parseRequest(request) catch {
        return error.InvalidProtocol;
    };

    var content_length: usize = 0;
    while (header_iterator.next() catch return error.InvalidRequest) |header| {
        if (std.ascii.eqlIgnoreCase(header.key, "content-length")) {
            content_length = std.fmt.parseInt(usize, header.value, 10) catch return error.InvalidRequest;
        }
    }

    const total_len = head_len + content_length;
    if (request.len < total_len) {
        return .more;
    }
    if (request.len > total_len) {
        return error.InvalidRequest;
    }
    const body = request[head_len..total_len];

    switch (method) {
        .post => if (std.mem.eql(u8, path, "/session")) {
            return self.newSession(body);
        },
        .delete => if (std.mem.startsWith(u8, path, "/session/")) {
            return self.sendWebDriver("200 OK", null);
        },
        else => {},
    }
    return error.NotFound;
}

fn newSession(self: *Handshake, body: []const u8) !Result {
    const allocator = self.app.allocator;

    const Capability = struct { webSocketUrl: ?bool = null };
    const parsed = std.json.parseFromSlice(struct {
        capabilities: ?struct {
            alwaysMatch: ?Capability = null,
            firstMatch: ?[]const Capability = null,
        } = null,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return self.sendWebDriver("400 Bad Request", .{
            .@"error" = "invalid argument",
            .message = "invalid JSON body",
            .stacktrace = "",
        });
    };
    defer parsed.deinit();

    // Without the capability the client intends to drive the session over
    // HTTP, which this server doesn't serve: tell it now rather than 404
    // its first real command.
    if (!requestsWebSocketUrl(parsed.value.capabilities)) {
        return self.sendWebDriver("500 Internal Server Error", .{
            .@"error" = "session not created",
            .message = "only WebDriver BiDi sessions are supported; request the webSocketUrl capability",
            .stacktrace = "",
        });
    }

    var session_id: [36]u8 = undefined;
    uuidv4(&session_id);

    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.options.bidi_session_url, &session_id });
    defer allocator.free(url);

    return self.sendWebDriver("200 OK", .{
        .sessionId = &session_id,
        .capabilities = bidi_session.Capabilities{
            .userAgent = self.app.config.http_headers.user_agent,
            .webSocketUrl = url,
        },
    });
}

fn requestsWebSocketUrl(capabilities: anytype) bool {
    const caps = capabilities orelse return false;
    if (caps.alwaysMatch) |always| {
        if (always.webSocketUrl == true) {
            return true;
        }
    }
    for (caps.firstMatch orelse &.{}) |first| {
        if (first.webSocketUrl == true) {
            return true;
        }
    }
    return false;
}

// Answers a classic WebDriver request with {"value": value} and closes.
fn sendWebDriver(self: *Handshake, comptime status: []const u8, value: anytype) !Result {
    const allocator = self.app.allocator;

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 512);
    defer aw.deinit();
    try std.json.Stringify.value(.{ .value = value }, .{}, &aw.writer);
    const body = aw.written();

    const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 " ++ status ++ "\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        "{s}", .{ body.len, body });
    defer allocator.free(response);
    try self.send(response);
    self.shutdown();
    return .close;
}

fn upgrade(self: *Handshake, request: []u8) !void {
    // We need to make sure that we got all the necessary headers + values;
    // a bit per required header.
    const FOUND_UPGRADE: u8 = 1 << 0; // Upgrade: websocket
    const FOUND_VERSION: u8 = 1 << 1; // Sec-WebSocket-Version: 13
    const FOUND_CONNECTION: u8 = 1 << 2; // Connection: upgrade
    const FOUND_KEY: u8 = 1 << 3; // Sec-WebSocket-Key
    const FOUND_ALL = FOUND_UPGRADE | FOUND_VERSION | FOUND_CONNECTION | FOUND_KEY;

    // A malformed request line maps to a 400 in processHttpRequest.
    const method, _, const version, var header_iterator = header_parser.parseRequest(request) catch {
        return error.InvalidProtocol;
    };
    if (method != .get or version != .@"1.1") {
        return error.InvalidProtocol;
    }

    var found_headers: u8 = 0;
    // We need to extract the `Sec-WebSocket-Key` value.
    var sec_websocket_key: []const u8 = "";

    // A malformed header maps to a 400 in processHttpRequest.
    while (header_iterator.next() catch return error.InvalidRequest) |header| {
        const key = header.key;
        const value = header.value;

        // Header names are case-insensitive; `Header.parse` keeps their
        // original casing.
        if (std.ascii.eqlIgnoreCase(key, "upgrade")) {
            if (!std.ascii.eqlIgnoreCase("websocket", value)) {
                return error.InvalidUpgradeHeader;
            }
            found_headers |= FOUND_UPGRADE;
        } else if (std.ascii.eqlIgnoreCase(key, "sec-websocket-version")) {
            if (value.len != 2 or value[0] != '1' or value[1] != '3') {
                return error.InvalidVersionHeader;
            }
            found_headers |= FOUND_VERSION;
        } else if (std.ascii.eqlIgnoreCase(key, "connection")) {
            // find if connection header has upgrade in it, example header:
            // Connection: keep-alive, Upgrade
            if (std.ascii.indexOfIgnoreCase(value, "upgrade") == null) {
                return error.InvalidConnectionHeader;
            }
            found_headers |= FOUND_CONNECTION;
        } else if (std.ascii.eqlIgnoreCase(key, "sec-websocket-key")) {
            sec_websocket_key = value;
            found_headers |= FOUND_KEY;
        } else if (std.ascii.eqlIgnoreCase(key, "origin")) {
            // Only a browser sends `Origin`, and a browser has no business
            // driving CDP: whatever page sent this is cross-origin to us by
            // definition, including one served from loopback itself. Scripted
            // clients (Puppeteer, Playwright, chromedp, ...) never send it.
            log.warn(.cdp, "rejected websocket origin", .{
                .origin = value[0..@min(value.len, 64)],
            });
            return error.ForbiddenOrigin;
        } else if (std.ascii.eqlIgnoreCase(key, "host")) {
            const host = value;
            const is_allowed = blk: {
                // allow literal localhost
                if (std.mem.startsWith(u8, host, "localhost:")) {
                    break :blk true;
                }

                _ = std.Io.net.IpAddress.parseLiteral(host) catch break :blk false;
                break :blk true;
            };

            // Defense in depth against DNS rebinding: an IP literal is the only
            // thing that can legitimately reach us, because no name has to be
            // resolved to produce one. The one name we accept is
            // `localhost:<port>`, which browsers hardwire to loopback without
            // any DNS lookup. Any other name means something answered a DNS
            // lookup with our address, which is exactly what a rebinding
            // attack looks like. A request without a Host header isn't from a
            // browser, so it can't be the vector.
            if (!is_allowed) {
                log.warn(.cdp, "rejected websocket host", .{
                    .host = host[0..@min(host.len, 64)],
                    .hint = "connect to the CDP endpoint by IP address or localhost",
                });
                return error.ForbiddenHost;
            }
        }
    }

    // Check if we've received all related headers.
    if (found_headers != FOUND_ALL) {
        return error.MissingHeaders;
    }

    // our caller has already made sure this request ended in \r\n\r\n
    // so it isn't something we need to check again

    // Response to an upgrade request is always this, with the
    // Sec-Websocket-Accept value a special sha1 hash of the request
    // "sec-websocket-key" and a magic value.
    const template =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: upgrade\r\n" ++
        "Sec-Websocket-Accept: 0000000000000000000000000000\r\n\r\n";

    var res: [template.len]u8 = template.*;

    const key_pos = res.len - 32;
    var h: [20]u8 = undefined;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(sec_websocket_key);
    // websocket spec always used this value
    hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    hasher.final(&h);

    _ = std.base64.standard.Encoder.encode(res[key_pos .. key_pos + 28], h[0..]);

    return self.send(&res);
}

fn sendMetrics(self: *Handshake) !void {
    const allocator = self.app.allocator;

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();
    lp.metrics.write(&aw.writer);
    const body = aw.written();

    const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n\r\n" ++
        "{s}", .{ body.len, body });
    defer allocator.free(response);
    try self.send(response);
}

fn sendHttpError(self: *Handshake, comptime status: u16, comptime body: []const u8) void {
    const response = std.fmt.comptimePrint(
        "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ status, body.len, body },
    );

    // we're going to close this connection anyways, swallowing any
    // error seems safe
    self.send(response) catch {};
}

// The socket is non-blocking (reads must never block once the network
// thread owns them), but our responses are small one-shot writes, so on
// WouldBlock we just wait for writability rather than queueing.
fn send(self: *Handshake, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const written = sys_net.write(self.socket, data[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                var pfds = [_]posix.pollfd{.{
                    .fd = self.socket,
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                const n = try posix.poll(&pfds, 5000);
                if (n == 0) {
                    return error.Timeout;
                }
                continue;
            },
            else => return err,
        };

        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}

fn shutdown(self: *Handshake) void {
    sys_net.shutdown(self.socket, .recv) catch {};
}

const empty_json_list_response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Length: 2\r\n" ++
    "Connection: Close\r\n" ++
    "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
    "[]";

const protocol_json = @embedFile("../data/protocol.json");

const protocol_response = std.fmt.comptimePrint(
    "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n",
    .{protocol_json.len},
) ++ protocol_json;
