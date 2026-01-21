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

const log = @import("log.zig");
const SharedState = @import("SharedState.zig");
const SessionThread = @import("SessionThread.zig");
const SessionManager = @import("SessionManager.zig");

const Server = @This();

shared: *SharedState,
shutdown: bool = false,
allocator: Allocator,
listener: ?posix.socket_t,
session_manager: SessionManager,
json_version_response: []const u8,
timeout_ms: u32,
session_memory_limit: usize,

pub fn init(shared: *SharedState, address: net.Address, max_sessions: u32, session_memory_limit: usize) !Server {
    const allocator = shared.allocator;
    const json_version_response = try buildJSONVersionResponse(allocator, address);
    errdefer allocator.free(json_version_response);

    return .{
        .shared = shared,
        .listener = null,
        .allocator = allocator,
        .session_manager = SessionManager.init(allocator, max_sessions),
        .json_version_response = json_version_response,
        .timeout_ms = 0,
        .session_memory_limit = session_memory_limit,
    };
}

/// Interrupts the server so that main can complete normally and call all defer handlers.
pub fn stop(self: *Server) void {
    if (@atomicRmw(bool, &self.shutdown, .Xchg, true, .monotonic)) {
        return;
    }

    // Stop all active sessions
    self.session_manager.stopAll();

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
    self.session_manager.deinit();

    if (self.listener) |listener| {
        posix.close(listener);
        self.listener = null;
    }
    self.allocator.free(self.json_version_response);
}

pub fn run(self: *Server, address: net.Address, timeout_ms: u32) !void {
    self.timeout_ms = timeout_ms;

    const flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    const listener = try posix.socket(address.any.family, flags, posix.IPPROTO.TCP);
    self.listener = listener;

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(posix.TCP, "NODELAY")) {
        try posix.setsockopt(listener, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
    }

    try posix.bind(listener, &address.any, address.getOsSockLen());
    // Increase backlog from 1 to 128 to support multiple concurrent connections
    try posix.listen(listener, 128);

    log.info(.app, "server running", .{ .address = address });

    while (!@atomicLoad(bool, &self.shutdown, .monotonic)) {
        const socket = posix.accept(listener, null, null, posix.SOCK.NONBLOCK) catch |err| {
            switch (err) {
                error.SocketNotListening, error.ConnectionAborted => {
                    log.info(.app, "server stopped", .{});
                    break;
                },
                else => {
                    log.err(.app, "CDP accept", .{ .err = err });
                    std.Thread.sleep(std.time.ns_per_s);
                    continue;
                },
            }
        };

        if (log.enabled(.app, .info)) {
            var client_address: std.net.Address = undefined;
            var socklen: posix.socklen_t = @sizeOf(net.Address);
            posix.getsockname(socket, &client_address.any, &socklen) catch {};
            log.info(.app, "client connected", .{ .ip = client_address });
        }

        // Spawn a new session thread for this connection
        const session = SessionThread.spawn(
            self.shared,
            &self.session_manager,
            socket,
            timeout_ms,
            self.json_version_response,
            self.session_memory_limit,
        ) catch |err| {
            log.err(.app, "spawn session", .{ .err = err });
            posix.close(socket);
            continue;
        };

        self.session_manager.add(session) catch |err| switch (err) {
            error.TooManySessions => {
                log.warn(.app, "too many sessions", .{ .count = self.session_manager.count() });
                sendServiceUnavailable(socket);
                session.stop();
                session.join();
                session.deinit();
            },
            else => {
                log.err(.app, "add session", .{ .err = err });
                session.stop();
                session.join();
                session.deinit();
            },
        };
    }
}

fn sendServiceUnavailable(socket: posix.socket_t) void {
    const response =
        "HTTP/1.1 503 Service Unavailable\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Length: 31\r\n\r\n" ++
        "Too many concurrent connections";
    _ = posix.write(socket, response) catch {};
    posix.close(socket);
}

fn buildJSONVersionResponse(
    allocator: Allocator,
    address: net.Address,
) ![]const u8 {
    const body_format = "{{\"webSocketDebuggerUrl\": \"ws://{f}/\"}}";
    const body_len = std.fmt.count(body_format, .{address});

    const response_format =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: Close\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n\r\n" ++
        body_format;
    return try std.fmt.allocPrint(allocator, response_format, .{ body_len, address });
}

// Re-export Client from SessionThread for compatibility
pub const Client = SessionThread.Client;

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
