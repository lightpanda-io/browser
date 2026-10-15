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

const App = @import("../App.zig");
const testing = @import("../testing.zig");

const tools = @import("tools.zig");
const router = @import("router.zig");
const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const Transport = @import("Transport.zig");
const HttpServer = @import("HttpServer.zig");

const Self = @This();

/// The session an un-scoped request lands on: the only one over stdio, and
/// the one the HTTP transport routes to when a client sends no
/// `Mcp-Session-Id`.
pub const default_session_id = "default";

allocator: std.mem.Allocator,
app: *App,

/// The one session this server drives; the HTTP transport runs one server
/// per session.
active_session: *lp.ToolSession,
/// `default`, or the name the HTTP transport gave this session.
session_id: []const u8,
/// The HTTP transport, for the session tools. Null over stdio, where a
/// request can't name a session, so those tools are refused.
directory: ?*HttpServer = null,
transport: Transport,

pub fn init(allocator: std.mem.Allocator, app: *App, writer: *std.Io.Writer) !*Self {
    return initSession(allocator, app, writer, default_session_id);
}

/// A server for the session named `id`, which must outlive it.
pub fn initSession(allocator: std.mem.Allocator, app: *App, writer: *std.Io.Writer, id: []const u8) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    // Heap-allocated and never moved: `Browser` registers self-pointers.
    const entry = try allocator.create(lp.ToolSession);
    errdefer allocator.destroy(entry);

    try entry.init(app);
    errdefer entry.deinit();

    // Only the default session is backed by the on-disk cookie file; named
    // sessions start clean so agents stay isolated by default.
    if (isDefault(id)) {
        if (app.config.cookieFile()) |cookie_path| {
            lp.cookies.loadFromFile(entry.session, cookie_path);
        }
    }
    entry.exitIsolate();

    self.* = .{
        .allocator = allocator,
        .app = app,
        .active_session = entry,
        .session_id = id,
        .transport = .init(allocator, writer),
    };
    return self;
}

pub fn deinit(self: *Self) void {
    const entry = self.active_session;
    if (isDefault(self.session_id)) {
        if (self.app.config.cookieJarFile()) |cookie_jar_path| {
            lp.cookies.saveToFile(&entry.session.cookie_jar, cookie_jar_path);
        }
    }
    entry.enterIsolate();
    entry.deinit();
    self.allocator.destroy(entry);

    self.transport.deinit();
    self.allocator.destroy(self);
}

pub fn isDefault(id: []const u8) bool {
    return std.mem.eql(u8, id, default_session_id);
}

/// Pump the session's pending transfers and return how long the
/// caller may block before pumping again. See `Session.idleSlice`.
pub fn idle(self: *Self) u31 {
    // Pumping may resume JS (e.g. a completed script fetch), so it needs
    // the session's isolate current.
    const entry = self.active_session;
    entry.enterIsolate();
    defer entry.exitIsolate();
    return entry.session.idleSlice();
}

pub fn sendError(self: *Self, id: std.json.Value, code: protocol.ErrorCode, message: []const u8) !void {
    return self.transport.sendError(id, code, message);
}

pub fn sendResult(self: *Self, id: std.json.Value, result: anytype) !void {
    return self.transport.sendResult(id, result);
}

pub fn handleInitialize(self: *Self, req: protocol.Request) !void {
    const id = req.id orelse return;
    if (protocol.clientName(req.params)) |name| {
        self.app.telemetry.record(.{ .mcp_client = .fromName(name) });
    }
    try self.sendResult(id, protocol.InitializeResult{
        .protocolVersion = @tagName(protocol.Version.negotiate(req.params)),
        .capabilities = .{
            .resources = .{},
            .tools = .{},
        },
        .serverInfo = .{ .name = "lightpanda", .version = "0.1.0" },
        .instructions = lp.tools.driver_guidance,
    });
}

pub fn handleToolList(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    return tools.handleList(self, arena, req);
}

pub fn handleToolCall(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    // Dispatch runs page JS, so enter the target isolate around it.
    const entry = self.active_session;
    entry.enterIsolate();
    defer entry.exitIsolate();
    return tools.handleCall(self, arena, req);
}

pub fn handleResourceList(self: *Self, req: protocol.Request) !void {
    return resources.handleList(self, req);
}

pub fn handleResourceRead(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    const entry = self.active_session;
    entry.enterIsolate();
    defer entry.exitIsolate();
    return resources.handleRead(self, arena, req);
}

test "MCP.Server - Integration: synchronous smoke test" {
    const allocator = testing.allocator;
    const app = testing.test_app;

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}}}
    ;

    var in_reader: std.Io.Reader = .fixed(input);
    var out_alloc: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Self.init(allocator, app, &out_alloc.writer);
    defer server.deinit();

    try router.processRequests(server, &in_reader, null);

    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 1, .result = .{ .protocolVersion = "2024-11-05" } }, out_alloc.writer.buffered());
}

test "MCP.Server - initialize negotiates the protocol version" {
    var out_alloc: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Self.init(testing.allocator, testing.test_app, &out_alloc.writer);
    defer server.deinit();

    const aa = testing.arena_allocator;

    // A supported version is echoed back.
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 1, .result = .{ .protocolVersion = "2025-06-18" } }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // An unknown one gets the latest supported.
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 2, .result = .{ .protocolVersion = "2025-11-25" } }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // So does a request with no version at all.
    try router.handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 3, .result = .{ .protocolVersion = "2025-11-25" } }, out_alloc.writer.buffered());
}
