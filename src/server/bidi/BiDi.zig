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

const App = @import("../../App.zig");
const uuidv4 = @import("../../id.zig").uuidv4;
const Server = @import("../Server.zig");
const Browser = @import("../../browser/Browser.zig");
const Session = @import("../../browser/Session.zig");
const Notification = @import("../../Notification.zig");

const NodeRegistry = @import("../../NodeRegistry.zig");

const Driver = @import("../Driver.zig");
const Connection = @import("../Connection.zig");

const remote_value = @import("remote_value.zig");
const browsing_context = @import("browsing_context.zig");

const posix = std.posix;
const Allocator = std.mem.Allocator;

const BiDi = @This();

app: *App,
conn: Connection,

// Server run-loop read-side handle for the socket. Server registers it
// after the handshake and unregisters before teardown; see CDP.zig.
link: Server.Link,

// Re-used arena for processing a message. Works because we strictly process
// one message at a time.
message_arena: std.heap.ArenaAllocator,

// Allocations that live for the whole session (subscriptions).
session_arena: std.heap.ArenaAllocator,

// The active session, created by session.new
session_id: ?[36]u8 = null,

browser: Browser,
session: *Session,
notification: *Notification,
context: ?browsing_context.Context = null,

// Issues the script module's sharedIds
node_registry: NodeRegistry,

// Values the client owns via `resultOwnership: "root"`
handles: remote_value.Handles,

subscriptions: std.ArrayList(Subscription) = .empty,

const Subscription = struct {
    id: [36]u8,
    event: []const u8,
};

const InputMessage = struct {
    id: ?u64 = null,
    method: ?[]const u8 = null,
};

pub fn init(self: *BiDi, app: *App, socket: posix.socket_t) !void {
    const allocator = app.allocator;
    self.* = .{
        .app = app,
        .link = undefined,
        .conn = undefined,
        .browser = undefined,
        .session = undefined,
        .notification = undefined,
        .node_registry = .init(allocator),
        .handles = .{ .allocator = allocator },
        .message_arena = std.heap.ArenaAllocator.init(allocator),
        .session_arena = std.heap.ArenaAllocator.init(allocator),
    };

    const driver: Driver = .init(.{ .bidi = self });

    try self.browser.init(app, .{}, driver);
    errdefer self.browser.deinit();

    const http_client = &self.browser.http_client;
    try self.conn.init(app, socket, .bidi, &http_client.inbox);
    errdefer self.conn.deinit();

    self.link = .{
        .driver = driver,
        .state = .live,
        .socket = socket,
        .handles = http_client.handles,
    };

    // the remaining failures are OOM-class; no point cleaning up
    self.notification = try Notification.init(allocator);
    self.session = try self.browser.newSession(self.notification);
    try browsing_context.registerNotifications(self);
}

pub fn deinit(self: *BiDi) void {
    self.notification.unregisterAll(self);

    self.handles.deinit();
    self.browser.closeSession();

    self.node_registry.deinit();
    self.notification.deinit();
    self.browser.deinit();
    self.conn.deinit();
    self.message_arena.deinit();
    self.session_arena.deinit();
}

pub fn resetRealm(self: *BiDi) void {
    self.handles.releaseAll();
    self.node_registry.reset();
    if (self.context) |*ctx| {
        uuidv4(&ctx.realm_id);
    }
}

// Dispatch a single BiDi frame from the inbox. Unlike CDP, frames aren't
// parsed on the Network thread, so `data` is the raw JSON.
pub fn onMessage(self: *BiDi, data: []const u8) anyerror!void {
    if (self.browser.env.terminatePending()) {
        return;
    }

    defer _ = self.message_arena.reset(.{ .retain_with_limit = 4096 });
    const arena = self.message_arena.allocator();

    const input = std.json.parseFromSliceLeaky(InputMessage, arena, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        return self.sendError(null, "invalid argument", "invalid JSON message");
    };

    const id = input.id orelse {
        return self.sendError(null, "invalid argument", "missing command id");
    };
    const method = input.method orelse {
        return self.sendError(id, "invalid argument", "missing command method");
    };

    self.dispatch(arena, id, method, data) catch |err| switch (err) {
        error.UnknownCommand => try self.sendError(id, "unknown command", method),
        // Command.params already answered the client.
        error.InvalidParams => {},
        else => return err,
    };
}

// A BiDi method is always "<module>.<command>".
fn dispatch(self: *BiDi, arena: Allocator, id: u64, method: []const u8, data: []const u8) !void {
    const i = std.mem.indexOfScalar(u8, method, '.') orelse {
        return error.UnknownCommand;
    };
    const module = std.meta.stringToEnum(enum {
        session,
        script,
        browser,
        browsingContext,
    }, method[0..i]) orelse return error.UnknownCommand;

    // Only the session module is reachable without a session (it's what
    // creates one); it gates its own commands.
    if (self.session_id == null and module != .session) {
        return self.sendError(id, "invalid session id", "no active session");
    }

    const cmd: Command = .{
        .id = id,
        .bidi = self,
        .json = data,
        .arena = arena,
        .action = method[i + 1 ..],
    };

    switch (module) {
        .session => return @import("session.zig").processMessage(&cmd),
        .script => return @import("script.zig").processMessage(&cmd),
        .browser => return @import("browser.zig").processMessage(&cmd),
        .browsingContext => return browsing_context.processMessage(&cmd),
    }
}

// One command being processed. Handlers answer through it so they don't
// have to thread the id (and the raw message) around.
pub const Command = struct {
    bidi: *BiDi,

    // The message_arena; valid for the lifetime of the command.
    arena: Allocator,

    // Echoed back in the response.
    id: u64,

    // The "<command>" half of "<module>.<command>".
    action: []const u8,

    // The full raw message; `params` is parsed out of it on demand.
    json: []const u8,

    // Parses the command's params object. Answers the client and returns
    // error.InvalidParams when the message has no params or they don't
    // match T, so callers can just `try`. onMessage swallows that error.
    pub fn params(self: *const Command, comptime T: type) !T {
        const wrapper = std.json.parseFromSliceLeaky(struct { params: T }, self.arena, self.json, .{
            .ignore_unknown_fields = true,
        }) catch {
            try self.sendError("invalid argument", "invalid params");
            return error.InvalidParams;
        };
        return wrapper.params;
    }

    pub fn sendResult(self: *const Command, result: anytype) !void {
        return self.bidi.sendResult(self.id, result);
    }

    pub fn sendError(self: *const Command, code: []const u8, message: []const u8) !void {
        return self.bidi.sendError(self.id, code, message);
    }

    // Events aren't tied to the command, but handlers that emit one always
    // have a cmd on hand.
    pub fn sendEvent(self: *const Command, method: []const u8, p: anytype) !void {
        return self.bidi.sendEvent(method, p);
    }
};

// An event is delivered when its name is subscribed exactly, or its module
// is ("browsingContext" covers "browsingContext.load").
fn subscribed(self: *const BiDi, name: []const u8) bool {
    for (self.subscriptions.items) |sub| {
        if (std.mem.eql(u8, sub.event, name)) {
            return true;
        }
        if (sub.event.len < name.len and name[sub.event.len] == '.' and std.mem.startsWith(u8, name, sub.event)) {
            return true;
        }
    }
    return false;
}

pub fn sendEvent(self: *BiDi, method: []const u8, p: anytype) !void {
    if (!self.subscribed(method)) {
        return;
    }
    return self.sendJSON(.{ .type = "event", .method = method, .params = p });
}

pub fn sendResult(self: *BiDi, id: u64, result: anytype) !void {
    return self.sendJSON(.{ .type = "success", .id = id, .result = result });
}

pub fn sendError(self: *BiDi, id: ?u64, code: []const u8, message: []const u8) !void {
    return self.sendJSON(.{ .type = "error", .id = id, .@"error" = code, .message = message });
}

fn sendJSON(self: *BiDi, message: anytype) !void {
    return self.conn.sendJSON(message, .{});
}
