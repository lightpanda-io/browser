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

const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const sys_net = @import("../sys/net.zig");
const header_parser = @import("../network/header_parser.zig");
const statusCategory = @import("../network/http.zig").statusCategory;

const Server = @import("Server.zig");
const Driver = @import("Driver.zig");
const bidi_session = @import("bidi/session.zig");
const uuidv4 = @import("../id.zig").uuidv4;

const log = lp.log;
const posix = std.posix;
const Allocator = std.mem.Allocator;

// A client connection in its http phase: loop-owned, pooled.
pub const Connection = struct {
    state: State,
    buffer: Buffer,
    socket: posix.socket_t,
    address: sys_net.IpAddress,
    node: std.DoublyLinkedList.Node,

    // When a keepalive (or just connected) connection should be closed
    deadline: u64,

    // Response that couldn't be sent without blocking. Socket will switch to
    // "write-mode" until it's drained.
    pending: ?Writing,

    pub const Writing = struct {
        pos: usize, // how ,uch of Data we've already written
        data: Data,
        keepalive: bool,

        pub const Data = union(enum) {
            // copied out of the server's scratch buffer; freed once written
            owned: []const u8,

            // lives as long as the server; referenced, never freed
            static: []const u8,
        };

        pub fn remaining(self: *const Writing) []const u8 {
            return switch (self.data) {
                inline else => |d| d[self.pos..],
            };
        }

        pub fn deinit(self: *const Writing, allocator: Allocator) void {
            switch (self.data) {
                .static => {},
                .owned => |owned| allocator.free(owned),
            }
        }
    };

    pub fn deinit(self: *Connection) void {
        self.buffer.deinit();
    }

    // True if the request is in keepalive state and thus is a candidate to be
    // closed if we need its slot for a new connection.
    pub fn isIdle(self: *const Connection) bool {
        if (self.pending != null or self.buffer.len != 0) {
            // has a pending write, or has extra data to read
            return false;
        }
        return self.state == .header;
    }

    pub const Request = struct {
        method: Method,
        // origin-form, query string stripped, always starts with '/'
        path: []const u8,
        keepalive: bool,
        body: []const u8,

        // The raw request head (request line + headers, through the final
        // CRLF CRLF); a slice into the read buffer. Upgrade handlers re-parse
        // it for the WebSocket headers.
        head: []const u8,

        // Filled in by the router for /session/{id}[/...] routes; points
        // into the read buffer like path does.
        session_id: ?*const [36]u8 = null,
    };

    pub const Method = enum {
        GET,
        POST,
        PUT,
        DELETE,
    };

    pub const State = union(enum) {
        header: void, // still parsing the header
        request: Request,

        pub fn parseHeader(self: *State, data: []u8) !bool {
            const header_index = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
                return false;
            };

            // include the last line's \r\n so every line, including the request
            // line of a header-less request, is terminated
            const header = data[0 .. header_index + 2];
            const method, const path, const keepalive, const line_1_end = try parseRequestLine(header);

            _ = line_1_end;
            const body_start = header_index + 4;
            const total = body_start + try contentLength(header);
            if (data.len < total) {
                // the body is still arriving
                return false;
            }
            // A WebSocket upgrade may be pipelined with its first frames, but every
            // client we care about waits for the 101 first. Anything past the
            // declared body is unsupported (and rejects pipelining).
            if (data.len != total) {
                return error.BodyNotSupported;
            }

            self.* = .{ .request = .{
                .method = method,
                .path = path,
                .keepalive = keepalive,
                .body = data[body_start..total],
                .head = data[0..body_start],
            } };

            return true;
        }

        // The classic WebDriver bootstrap (POST /session) is the only thing
        // that sends a body; everything else is 0.
        fn contentLength(header: []const u8) !usize {
            const key = "\r\ncontent-length:";
            const at = std.ascii.indexOfIgnoreCase(header, key) orelse return 0;
            const start = at + key.len;
            const end = std.mem.indexOfPos(u8, header, start, "\r\n") orelse return error.InvalidHeader;
            const value = std.mem.trim(u8, header[start..end], " \t");
            return std.fmt.parseInt(usize, value, 10) catch error.InvalidHeader;
        }

        fn parseRequestLine(header: []const u8) !struct { Method, []const u8, bool, usize } {
            const l1 = std.mem.indexOfScalar(u8, header, '\r') orelse return error.InvalidHeader;
            if (l1 == header.len) {
                return error.InvalidHeader;
            }
            if (header[l1 + 1] != '\n') {
                return error.InvalidHeader;
            }

            var it = std.mem.tokenizeScalar(u8, header[0..l1], ' ');
            const method = std.meta.stringToEnum(Method, it.next() orelse return error.InvalidHeader) orelse return error.InvalidHTTPMethod;

            // Only the origin-form request-target is accepted; nothing we serve
            // reads the query string, so it's dropped here.
            const target = it.next() orelse return error.InvalidHeader;
            if (target[0] != '/') {
                return error.InvalidHeader;
            }
            const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

            const protocol = it.next() orelse return error.InvalidHeader;
            const keepalive = std.mem.indexOf(u8, protocol, "1.0") == null;

            return .{ method, path, keepalive, l1 };
        }
    };

    const Buffer = struct {
        buf: []u8,

        // position in buf up until where we have valid data
        len: usize,

        allocator: Allocator,

        fn init(allocator: Allocator, size: usize) !Buffer {
            return .{
                .len = 0,
                .buf = try allocator.alloc(u8, size),
                .allocator = allocator,
            };
        }

        fn deinit(self: *const Buffer) void {
            self.allocator.free(self.buf);
        }

        pub fn read(self: *Buffer, socket: posix.socket_t) ![]u8 {
            const len = self.len;
            if (len == self.buf.len) {
                return error.RequestTooLarge;
            }

            const n = try posix.read(socket, self.buf[len..]);
            if (n == 0) {
                return error.ConnectionClosed;
            }
            const total = len + n;
            self.len = total;
            return self.buf[0..total];
        }
    };

    pub const Pool = struct {
        allocator: Allocator,
        free: std.DoublyLinkedList,
        live: usize, // acquired and not yet released
        retain: usize, // min # to keep
        free_count: usize, // # of connections available in free
        buffer_size: usize, // --cdp-max-http-message-size

        pub fn init(app: *App) !Pool {
            const retain = app.config.maxConnections();
            var self = Pool{
                .live = 0,
                .free = .{},
                .free_count = 0,
                .retain = retain,
                .allocator = app.allocator,
                .buffer_size = app.config.cdpMaxHTTPMessageSize(),
            };
            errdefer self.deinit();

            for (0..retain) |_| {
                const conn = try self.create();
                self.free.append(&conn.node);
                self.free_count += 1;
            }
            return self;
        }

        // Every live connection must have been released (the server disconnects
        // them all on deinit).
        pub fn deinit(self: *Pool) void {
            lp.assert(self.live == 0, "Connection.Pool.deinit live", .{ .live = self.live });
            while (self.free.popFirst()) |node| {
                const conn: *Connection = @fieldParentPtr("node", node);
                self.destroy(conn);
            }
        }

        pub fn acquire(self: *Pool) !*Connection {
            const conn = blk: {
                if (self.free.popFirst()) |node| {
                    self.free_count -= 1;
                    break :blk @as(*Connection, @fieldParentPtr("node", node));
                }
                break :blk try self.create();
            };
            self.live += 1;
            return conn;
        }

        pub fn release(self: *Pool, conn: *Connection) void {
            self.live -= 1;
            if (self.free_count == self.retain) {
                return self.destroy(conn);
            }

            conn.node = .{};
            conn.socket = -1;
            conn.address = .{ .ip4 = .unspecified(0) };
            conn.deadline = 0;
            conn.pending = null;
            conn.buffer.len = 0;
            conn.state = .header;

            self.free.prepend(&conn.node);
            self.free_count += 1;
        }

        fn create(self: *Pool) !*Connection {
            const allocator = self.allocator;
            const conn = try allocator.create(Connection);
            errdefer allocator.destroy(conn);
            conn.* = .{
                .node = .{},
                .socket = -1,
                .address = .{ .ip4 = .unspecified(0) },
                .deadline = 0,
                .pending = null,
                .state = .header,
                .buffer = try .init(allocator, self.buffer_size),
            };
            return conn;
        }

        fn destroy(self: *Pool, conn: *Connection) void {
            conn.deinit();
            self.allocator.destroy(conn);
        }
    };
};

// How long a connection may sit without completing a request before we close it.
pub const IDLE_TIMEOUT_MS = 10_000;

pub fn processEvent(server: *Server, conn: *Connection, rw: Server.IOEvent.ReadWrite, now: u64) void {
    if (conn.pending != null) {
        // registered for OUT only; a hangup shows up as a write error
        if (rw.writable or rw.hangup) {
            flush(server, conn, now);
        }
        return;
    }

    if (rw.readable) {
        const keepalive = processHTTP(server, conn, now) catch |err| blk: {
            writeError(conn, err);
            break :blk false;
        };
        if (keepalive == false) {
            disconnect(server, conn);
        }
        // else: the socket is level-triggered and stays registered; the
        // deadline was refreshed by processHTTP when the response went out
    } else if (rw.hangup) {
        disconnect(server, conn);
    }
}

// Continues a write that previously hit WouldBlock.
fn flush(server: *Server, conn: *Connection, now: u64) void {
    const pending = &conn.pending.?;
    const remaining = pending.remaining();
    const n = write(conn.socket, remaining) catch |err| {
        log.debug(.serve, "flush", .{ .err = err });
        return disconnect(server, conn);
    };

    if (n < remaining.len) {
        // hit a WouldBlock
        pending.pos += n;
        return;
    }

    // write is complete

    const keepalive = pending.keepalive;
    pending.deinit(server.app.allocator);
    conn.pending = null;

    if (keepalive == false) {
        return disconnect(server, conn);
    }
    server.io_engine.waitReadable(conn) catch |err| {
        log.err(.serve, "wait readable", .{ .err = err });
        return disconnect(server, conn);
    };
    touch(server, conn, now);
}

fn processHTTP(server: *Server, conn: *Connection, now: u64) !bool {
    const http = &conn.state;
    while (true) {
        switch (http.*) {
            .header => {
                const data = try conn.buffer.read(conn.socket);
                if (try http.parseHeader(data) == false) {
                    // don't have a complete header yet
                    return true;
                }
                if (comptime lp.IS_DEBUG) {
                    // we do have a complete header, the state must have transitioned
                    // to .request
                    std.debug.assert(http.* == .request);
                }
            },
            .request => |*req| {
                if (try serveHTTP(server, conn, req) == .upgraded) {
                    // The fd moved to a WebSocket (and out of server.http); all
                    // that's left of this Connection is to recycle it.
                    // upgradeConnection already took it out of http_connections.
                    recycle(server, conn);
                    return true;
                }

                // req lives in http.*; read what we need before resetting it
                const keepalive = req.keepalive;
                http.* = .header;
                conn.buffer.len = 0;

                if (conn.pending != null) {
                    // We got a WouldBlock and now have a pending write. The
                    // connection stays alive until we flush it. After the write
                    // if flushed, we'll apply the keepalive result.
                    return true;
                }

                if (keepalive == false) {
                    return false;
                }
                touch(server, conn, now);
                return true;
            },
        }
    }
}

// Error responses use a minimal, uniform shape: no reason phrase, an explicit
// Connection: Close, and no Content-Type. errorResponse builds it at comptime.
const invalid_request_response = errorResponse(400, "Invalid request");

const invalid_protocol_response = errorResponse(400, "Invalid HTTP protocol");

const missing_header_response = errorResponse(400, "Missing required header");

const forbidden_origin_response = errorResponse(403, "Origin not allowed");

const forbidden_host_response = errorResponse(403, "Host not allowed");

const request_too_large_response = errorResponse(413, "Request too large");

const not_found_response = errorResponse(404, "Not found");

const method_not_allowed_response = errorResponse(405, "Method not allowed");

const service_unavailable_response = errorResponse(503, "Too many connections");

const internal_error_response = errorResponse(500, "Internal server error");

const empty_json_list_response = staticResponse(.{ .status = "200 OK", .body = "[]", .content_type = "application/json; charset=UTF-8" });

// WebDriver's discovery endpoint; `ready` is whether a new session can be
// created, which the bootstrap never refuses.
const status_response = staticResponse(.{ .status = "200 OK", .body = "{\"value\":{\"ready\":true,\"message\":\"\"}}", .content_type = "application/json; charset=UTF-8" });

const delete_session_response = staticResponse(.{ .status = "200 OK", .body = "{\"value\":null}", .content_type = "application/json; charset=UTF-8" });

const protocol_response = staticResponse(.{ .status = "200 OK", .body = @embedFile("../data/protocol.json"), .content_type = "application/json; charset=UTF-8" });

const Served = enum {
    responded,
    upgraded,
};

const Route = struct {
    method: Connection.Method,
    // exact match against the normalized path
    path: []const u8,
    gate: Gate = .none,
    handler: *const fn (*Server, *Connection, *Connection.Request) anyerror!Served,

    // A closed gate makes the route invisible (404), not forbidden.
    const Gate = enum {
        none,
        cdp,
        webdriver,
        metrics,
    };
};

const routes = [_]Route{
    .{ .method = .GET, .path = "/", .gate = .cdp, .handler = upgradeCDP },
    .{ .method = .GET, .path = "/metrics", .gate = .metrics, .handler = serveMetrics },
    .{ .method = .GET, .path = "/json/version", .gate = .cdp, .handler = serveJSONVersion },
    .{ .method = .GET, .path = "/json/list", .gate = .cdp, .handler = serveJSONList },
    .{ .method = .GET, .path = "/json", .gate = .cdp, .handler = serveJSONList },
    .{ .method = .GET, .path = "/json/protocol", .gate = .cdp, .handler = serveJSONProtocol },
    // /session is the path Firefox advertises its BiDi endpoint on
    .{ .method = .GET, .path = "/session", .gate = .webdriver, .handler = upgradeBiDi },
    .{ .method = .POST, .path = "/session", .gate = .webdriver, .handler = newSession },
    .{ .method = .GET, .path = "/status", .gate = .webdriver, .handler = serveStatus },
};

const session_routes = [_]Route{
    .{ .method = .GET, .path = "", .handler = upgradeBiDi },
    .{ .method = .DELETE, .path = "", .handler = deleteSession },
};

// Routes under /session/{id}; path is what follows the id ("" for the
// session itself). The classic command surface goes here.
const SESSION_PREFIX = "/session/";

const SESSION_ID_LEN = 36;

fn serveHTTP(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    var path = req.path;
    if (path.len > 1 and path[path.len - 1] == '/') {
        path = path[0 .. path.len - 1];
    }

    if (std.mem.startsWith(u8, path, SESSION_PREFIX) and path.len >= SESSION_PREFIX.len + SESSION_ID_LEN) {
        if (!server.protocols.webdriver) {
            return serveNotFound(server, conn, req);
        }
        const tail = path[SESSION_PREFIX.len + SESSION_ID_LEN ..];
        if (tail.len != 0 and tail[0] != '/') {
            return serveNotFound(server, conn, req);
        }
        req.session_id = path[SESSION_PREFIX.len..][0..SESSION_ID_LEN];
        return dispatch(server, &session_routes, conn, req, tail);
    }
    return dispatch(server, &routes, conn, req, path);
}

fn dispatch(server: *Server, comptime table: []const Route, conn: *Connection, req: *Connection.Request, path: []const u8) !Served {
    var path_matched = false;
    inline for (table) |route| {
        if (std.mem.eql(u8, route.path, path) and gateOpen(server, route.gate)) {
            if (route.method == req.method) {
                return route.handler(server, conn, req);
            }
            path_matched = true;
        }
    }
    if (path_matched) {
        return serveMethodNotAllowed(server, conn, req);
    }
    return serveNotFound(server, conn, req);
}

// Best effort, connection is being closed. A partial write ends up as a partial
// write: no pending, no retry.
fn writeError(conn: *Connection, err: anyerror) void {
    const response: []const u8 = switch (err) {
        error.ConnectionClosed, error.ConnectionResetByPeer, error.BrokenPipe => return,
        error.InvalidHeader, error.InvalidHTTPMethod, error.BodyNotSupported => invalid_request_response,
        error.RequestTooLarge => request_too_large_response,
        else => blk: {
            log.warn(.serve, "serve error", .{ .err = err });
            break :blk internal_error_response;
        },
    };
    recordResponse(response);
    _ = write(conn.socket, response) catch {};
}

// Every response starts with the status line our two builders emit, so the
// category is read straight off the bytes rather than threaded through.
fn recordResponse(response: []const u8) void {
    const prefix = "HTTP/1.1 ";
    lp.assert(std.mem.startsWith(u8, response, prefix), "Server.recordResponse status line", .{});
    const status = std.fmt.parseInt(u16, response[prefix.len..][0..3], 10) catch 0;
    lp.metrics.serve_http_requests.incr(statusCategory(status));
}

const Response = union(enum) {
    // lives as long as the server; a queued remainder references it
    static: []const u8,
    // lives in server.scratch until the next response; a queued remainder is copied
    dynamic: []const u8,
};

// Can do a partial write
fn write(socket: posix.socket_t, data: []const u8) !usize {
    var pos: usize = 0;
    while (pos < data.len) {
        const n = sys_net.write(socket, data[pos..]) catch |err| switch (err) {
            error.WouldBlock => break,
            error.Interrupted => continue,
            else => return err,
        };
        pos += n;
    }
    return pos;
}

// Dynamic responses are built in server.scratch with room for the header
// reserved up front; once the body length is known the header is written
// right-aligned against it (the same trick as WS.fillHeader).
const HEADER_RESERVE = 192;
fn beginBody(server: *Server) !*std.Io.Writer {
    server.scratch.clearRetainingCapacity();
    try server.scratch.writer.splatByteAll(0, HEADER_RESERVE);
    return &server.scratch.writer;
}

fn serveDynamicHTTPResponse(server: *Server, conn: *Connection, req: *const Connection.Request, comptime status: []const u8, comptime content_type: []const u8) !Served {
    const header_format = "HTTP/1.1 " ++ status ++ "\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Content-Type: " ++ content_type ++ "\r\n\r\n";

    // a usize prints as at most 20 digits
    comptime std.debug.assert(header_format.len + 20 <= HEADER_RESERVE);

    const buf = server.scratch.written();
    var header_buf: [HEADER_RESERVE]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, header_format, .{buf.len - HEADER_RESERVE}) catch unreachable;
    const start = HEADER_RESERVE - header.len;
    @memcpy(buf[start..HEADER_RESERVE], header);
    return serveHTTPResponse(server, conn, req, .{ .dynamic = buf[start..] });
}

fn errorResponse(comptime status: u16, comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ status, body.len, body },
    );
}

fn staticResponse(comptime opts: struct {
    status: []const u8,
    body: []const u8,
    content_type: []const u8 = "text/plain",
    close: bool = false,
}) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 " ++ opts.status ++ "\r\n" ++
        "Content-Length: {d}\r\n" ++
        (if (opts.close) "Connection: Close\r\n" else "") ++
        "Content-Type: " ++ opts.content_type ++ "\r\n\r\n", .{opts.body.len}) ++ opts.body;
}

fn gateOpen(server: *const Server, gate: Route.Gate) bool {
    return switch (gate) {
        .none => true,
        .cdp => server.protocols.cdp,
        .webdriver => server.protocols.webdriver,
        .metrics => server.app.config.metricsEndpointEnabled(),
    };
}

fn upgradeCDP(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    return upgrade(server, conn, req, .cdp, null);
}

fn serveJSONVersion(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    return serveHTTPResponse(server, conn, req, .{ .static = server.json_version_response });
}

fn serveJSONList(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    return serveHTTPResponse(server, conn, req, .{ .static = empty_json_list_response });
}

fn serveJSONProtocol(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    return serveHTTPResponse(server, conn, req, .{ .static = protocol_response });
}

fn serveMetrics(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    const writer = try beginBody(server);
    lp.metrics.write(writer);
    return serveDynamicHTTPResponse(server, conn, req, "200 OK", "text/plain; version=0.0.4; charset=utf-8");
}

fn serveStatus(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    return serveHTTPResponse(server, conn, req, .{ .static = status_response });
}

// req.session_id is null for GET /session, set for GET /session/{id}
fn upgradeBiDi(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    const session_id: ?[36]u8 = if (req.session_id) |s| s.* else null;
    return upgrade(server, conn, req, .bidi, session_id);
}

// What Selenium does before it speaks BiDi: a classic POST /session that
// hands back the websocket URL of a session that already exists.
fn newSession(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    const allocator = server.app.allocator;

    const Capability = struct { webSocketUrl: ?bool = null };
    const parsed = std.json.parseFromSlice(struct {
        capabilities: ?struct {
            alwaysMatch: ?Capability = null,
            firstMatch: ?[]const Capability = null,
        } = null,
    }, allocator, req.body, .{ .ignore_unknown_fields = true }) catch {
        return serveWebDriver(server, conn, req, "400 Bad Request", .{
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
        return serveWebDriver(server, conn, req, "500 Internal Server Error", .{
            .@"error" = "session not created",
            .message = "only WebDriver BiDi sessions are supported; request the webSocketUrl capability",
            .stacktrace = "",
        });
    }

    var session_id: [36]u8 = undefined;
    uuidv4(&session_id);

    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ server.bidi_session_url, &session_id });
    defer allocator.free(url);

    return serveWebDriver(server, conn, req, "200 OK", .{
        .sessionId = &session_id,
        .capabilities = bidi_session.Capabilities{
            .userAgent = server.app.config.http_headers.user_agent,
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

// Answers a classic WebDriver request with {"value": value}.
fn serveWebDriver(server: *Server, conn: *Connection, req: *const Connection.Request, comptime status: []const u8, value: anytype) !Served {
    const writer = try beginBody(server);
    try std.json.Stringify.value(.{ .value = value }, .{}, writer);
    return serveDynamicHTTPResponse(server, conn, req, status, "application/json; charset=UTF-8");
}

fn deleteSession(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    return serveHTTPResponse(server, conn, req, .{ .static = delete_session_response });
}

fn serveNotFound(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    return serveHTTPResponse(server, conn, req, .{ .static = not_found_response });
}

fn serveMethodNotAllowed(server: *Server, conn: *Connection, req: *Connection.Request) !Served {
    return serveHTTPResponse(server, conn, req, .{ .static = method_not_allowed_response });
}

// Writes what the socket will take now. Anything left is queued on the
// connection, which switches to waiting for writability.
fn serveHTTPResponse(server: *Server, conn: *Connection, req: *const Connection.Request, response: Response) !Served {
    const data = switch (response) {
        inline else => |d| d,
    };
    recordResponse(data);
    const n = try write(conn.socket, data);
    if (n == data.len) {
        return .responded;
    }

    lp.assert(conn.pending == null, "Server.send pending", .{});
    conn.pending = .{
        .pos = 0,
        .keepalive = req.keepalive,
        .data = switch (response) {
            .static => .{ .static = data[n..] },
            .dynamic => .{ .owned = try server.app.allocator.dupe(u8, data[n..]) },
        },
    };
    // on failure the caller disconnects, which frees pending
    try server.io_engine.waitWritable(conn);
    return .responded;
}

// HTTP-phase teardown. Websockets tear down via releaseWorker.
pub fn disconnect(server: *Server, conn: *Connection) void {
    server.io_engine.remove(conn.socket);
    sys_net.close(conn.socket);
    if (conn.pending) |*pending| {
        pending.deinit(server.app.allocator);
        conn.pending = null;
    }
    server.http_connections.remove(&conn.node);
    recycle(server, conn);
}

// Return a connection to the pool; a slot in the fd budget is free.
fn recycle(server: *Server, conn: *Connection) void {
    server.http_connection_pool.release(conn);
    server.slotFreed();
}

fn touch(server: *Server, conn: *Connection, now: u64) void {
    conn.deadline = now + IDLE_TIMEOUT_MS;
    const node = &conn.node;
    if (server.http_connections.last == node) {
        return;
    }

    server.http_connections.remove(&conn.node);
    server.http_connections.append(&conn.node);
}

pub fn buildJSONVersionResponse(app: *const App, port: u16) ![]const u8 {
    const host = app.config.advertiseHost();
    if (app.config.bindIsWildcard()) {
        // Serve is bound to INADDR_ANY but no --advertise-host was given;
        // advertiseHost() falls back to 127.0.0.1 so clients can still
        // connect locally. Surface the trade-off so users running
        // outside the same host know they have to opt in.
        log.note(.cdp, "advertising loopback for wildcard bind", .{
            .message = "--host is a wildcard (0.0.0.0 / ::) without --advertise-host; clients on other hosts will need --advertise-host to reach the CDP endpoint",
        });
    }
    const body_format =
        "{{" ++
        "\"Browser\": \"Lightpanda/1.0\", " ++
        "\"Protocol-Version\": \"1.3\", " ++
        "\"User-Agent\": \"Lightpanda/1.0\", " ++
        "\"Lightpanda-Version\": \"" ++ lp.build_config.version ++ "\", " ++
        "\"webSocketDebuggerUrl\": \"ws://{s}:{d}/\"" ++
        "}}";
    const body_len = std.fmt.count(body_format, .{ host, port });

    const response_format =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        body_format;
    return try std.fmt.allocPrint(app.allocator, response_format, .{ body_len, host, port });
}

// Shared upgrade path: validate the WebSocket headers, write the 101, park the
// fd, and spawn the worker that will build the driver and attach it.
fn upgrade(server: *Server, conn: *Connection, req: *Connection.Request, protocol: Driver.Protocol, session_id: ?[36]u8) !Served {
    if (server.websocket_pool.isFull()) {
        lp.metrics.serve_connection_limit.incr();
        return serveHTTPResponse(server, conn, req, .{ .static = service_unavailable_response });
    }

    var accept_buf: [28]u8 = undefined;
    const accept_key = webSocketAccept(req.head, &accept_buf) catch |err| {
        const response: []const u8 = switch (err) {
            error.ForbiddenOrigin => forbidden_origin_response,
            error.ForbiddenHost => forbidden_host_response,
            error.InvalidProtocol => invalid_protocol_response,
            error.MissingHeader => missing_header_response,
            else => invalid_request_response,
        };
        return serveHTTPResponse(server, conn, req, .{ .static = response });
    };

    // The 101 is ~129 bytes into an empty send buffer, so a single write
    // always completes; a partial write here means the peer is already gone.
    var response_buf: [160]u8 = undefined;
    const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: upgrade\r\n" ++
        "Sec-Websocket-Accept: {s}\r\n\r\n", .{accept_key}) catch unreachable;
    const n = write(conn.socket, response) catch return error.ConnectionClosed;
    if (n != response.len) {
        return error.ConnectionClosed;
    }

    server.upgradeConnection(conn, protocol, session_id);
    return .upgraded;
}

// Validate an incoming WebSocket upgrade request head and, on success, write
// the Sec-WebSocket-Accept value into `out`. Mirrors the origin/host defenses
// from the old Handshake path.
fn webSocketAccept(head: []const u8, out: *[28]u8) ![]const u8 {
    const FOUND_UPGRADE: u8 = 1 << 0;
    const FOUND_VERSION: u8 = 1 << 1;
    const FOUND_CONNECTION: u8 = 1 << 2;
    const FOUND_KEY: u8 = 1 << 3;
    const FOUND_ALL = FOUND_UPGRADE | FOUND_VERSION | FOUND_CONNECTION | FOUND_KEY;

    const method, _, const version, var it = header_parser.parseRequest(head) catch return error.InvalidRequest;
    if (method != .get or version != .@"1.1") {
        return error.InvalidProtocol;
    }

    var found: u8 = 0;
    var key: []const u8 = "";
    while (it.next() catch return error.InvalidRequest) |h| {
        if (std.ascii.eqlIgnoreCase(h.key, "upgrade")) {
            if (!std.ascii.eqlIgnoreCase("websocket", h.value)) return error.MissingHeader;
            found |= FOUND_UPGRADE;
        } else if (std.ascii.eqlIgnoreCase(h.key, "sec-websocket-version")) {
            if (h.value.len != 2 or h.value[0] != '1' or h.value[1] != '3') return error.MissingHeader;
            found |= FOUND_VERSION;
        } else if (std.ascii.eqlIgnoreCase(h.key, "connection")) {
            if (std.ascii.indexOfIgnoreCase(h.value, "upgrade") == null) return error.MissingHeader;
            found |= FOUND_CONNECTION;
        } else if (std.ascii.eqlIgnoreCase(h.key, "sec-websocket-key")) {
            key = h.value;
            found |= FOUND_KEY;
        } else if (std.ascii.eqlIgnoreCase(h.key, "origin")) {
            // Only a browser sends Origin, and a browser has no business
            // driving CDP/BiDi: it's cross-origin to us by definition.
            log.warn(.serve, "rejected websocket origin", .{ .origin = h.value[0..@min(h.value.len, 64)] });
            return error.ForbiddenOrigin;
        } else if (std.ascii.eqlIgnoreCase(h.key, "host")) {
            // Defense in depth against DNS rebinding: only an IP literal can
            // legitimately reach us (no name resolution involved). The one
            // name we accept is `localhost:<port>`, which browsers hardwire
            // to loopback without a lookup.
            if (!std.mem.startsWith(u8, h.value, "localhost:")) {
                _ = std.Io.net.IpAddress.parseLiteral(h.value) catch {
                    log.warn(.serve, "rejected websocket host", .{ .host = h.value[0..@min(h.value.len, 64)] });
                    return error.ForbiddenHost;
                };
            }
        }
    }
    if (found != FOUND_ALL) {
        return error.MissingHeader;
    }

    var sha: [20]u8 = undefined;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    hasher.final(&sha);
    _ = std.base64.standard.Encoder.encode(out, &sha);
    return out;
}
