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

const App = @import("../../App.zig");
const uuidv4 = @import("../../id.zig").uuidv4;
const Server = @import("../Server.zig");
const Browser = @import("../../browser/Browser.zig");
const Session = @import("../../browser/Session.zig");
const Notification = @import("../../Notification.zig");
const NodeRegistry = @import("../../NodeRegistry.zig");

const Link = @import("../Link.zig");
const Inbox = @import("../../Inbox.zig");

const script = @import("script.zig");
const remote_value = @import("remote_value.zig");

const posix = std.posix;
const Allocator = std.mem.Allocator;

const BiDi = @This();

app: *App,

// The websocket, when a client is connected. Null for an HTTP WebDriver
// session (until it optionally connects via WebSocket)
link: ?*Link,

// The worker's mailbox, owned by the Worker and thus outliving the link.
inbox: *Inbox,

// WebDriver can be BiDi only, or HTTP WebDriver + BiDi or HTTP WebDriver only.
mode: Mode,

// Re-used arena for processing a message. Works because we strictly process
// one message at a time.
message_arena: std.heap.ArenaAllocator,

// Allocations that live for the whole session (subscriptions).
session_arena: std.heap.ArenaAllocator,

// The active session
session_id: ?[36]u8,

browser: Browser,
notification: *Notification,

// browsing context is the page
browsing_context: ?@import("browsing_context.zig").Context = null,

// A user context is a Session. There's a "default" and we allow 1 more to
// be created (limited because a Browser can only have 1 Session).
user_context: UserContext,

// Issues the script module's sharedIds
node_registry: NodeRegistry,

// Values the client owns via `resultOwnership: "root"`
handles: remote_value.Handles,

// Commands awaiting promise resolution
pending: std.ArrayList(*script.Pending) = .empty,

input_state: @import("input.zig").State = .{},

subscriptions: std.ArrayList(Subscription) = .empty,

const Subscription = struct {
    id: [36]u8,
    event: []const u8,
};

pub const Mode = union(enum) {
    // Directly created via websocket upgrade, tied to the websocket's lifetime
    bidi_only: void,

    // created via HTTP, a websocket may or may not web associated with it (it
    // can come and go), but the lifetime is explicit: either removed via HTTP
    // (DELETE /session/:id) or by the HTTP reaper
    http: *Server.Worker,
};

// What a worker is born from: a websocket upgrade (the session comes later
// via session.new) or an HTTP session (a websocket may come later via
// GET /session/{id}); never both.
pub const Origin = union(enum) {
    socket: posix.socket_t,
    session: struct { id: [36]u8, worker: *Server.Worker },
};

const InputMessage = struct {
    id: ?u64 = null,
    method: ?[]const u8 = null,
};

pub fn init(self: *BiDi, app: *App, inbox: *Inbox, origin: Origin) !void {
    const allocator = app.allocator;
    self.* = .{
        .app = app,
        .link = null,
        .inbox = inbox,
        .mode = switch (origin) {
            .socket => .bidi_only,
            .session => |session| .{ .http = session.worker },
        },
        .browser = undefined,
        .user_context = undefined,
        .notification = undefined,
        .session_id = switch (origin) {
            .socket => null,
            .session => |session| session.id,
        },
        .node_registry = .init(allocator),
        .handles = .{ .allocator = allocator },
        .message_arena = std.heap.ArenaAllocator.init(allocator),
        .session_arena = std.heap.ArenaAllocator.init(allocator),
    };

    try self.browser.init(app, .{});
    errdefer self.browser.deinit();

    switch (origin) {
        .socket => |socket| self.link = try Link.create(app, socket, .bidi, inbox),
        .session => {},
    }
    errdefer if (self.link) |l| l.destroy();

    self.notification = try Notification.init(allocator);
    errdefer self.notification.deinit();

    try self.newUserContext("default");
    try @import("browsing_context.zig").registerNotifications(self);
}

pub fn deinit(self: *BiDi) void {
    const allocator = self.app.allocator;

    self.notification.unregisterAll(self);

    // Cancel first, so that any completions during session teardown are still valid
    script.Pending.cancelAll(self);
    self.handles.deinit();
    self.browser.closeSession();
    // Now we can destroy
    script.Pending.destroyAll(self);
    self.pending.deinit(allocator);
    self.input_state.deinit(allocator);

    self.node_registry.deinit();
    self.notification.deinit();
    self.browser.deinit();
    // The loop let go of the link before we got here (Server.Worker.run)
    if (self.link) |l| {
        l.destroy();
    }
    self.message_arena.deinit();
    self.session_arena.deinit();
}

// Worker thread, from the inbox: the loop is already reading from it.
pub fn adoptLink(self: *BiDi, l: *Link) void {
    if (self.link != null) {
        // the loop only hands one over once it has seen the previous one
        // released (Server.Worker.link is null)
        lp.assert(false, "BiDi.adoptLink held", .{});
        l.destroy();
        return;
    }
    self.link = l;
}

// Worker thread. The link is gone (peer closed, or the loop dropped it).
// Returns true when the worker is done with it: a bidi-only session dies
// with its connection, an HTTP session just drops the link and waits
// for the next one, or for DELETE / the idle reaper.
pub fn onLinkGone(self: *BiDi) bool {
    const worker = switch (self.mode) {
        .bidi_only => return true,
        .http => |worker| worker,
    };
    self.releaseLink(worker);
    return false;
}

fn releaseLink(self: *BiDi, worker: *Server.Worker) void {
    const l = self.link orelse return;
    self.link = null;
    // blocks until the loop has stopped reading from it
    worker.releaseLink();
    l.destroy();
}

pub fn replaceSession(self: *BiDi, id: []const u8) !void {
    self.resetRealm();
    try self.newUserContext(id);
}

fn newUserContext(self: *BiDi, id: []const u8) !void {
    const session = try self.browser.newSession(self.notification);
    self.user_context = .{ .session = session, .id_len = @intCast(id.len), .id_buf = undefined };
    @memcpy(self.user_context.id_buf[0..id.len], id);
}

pub const UserContext = struct {
    id_len: u8,
    id_buf: [36]u8, // "default" or uuid
    session: *Session,

    pub fn id(self: *const UserContext) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn isDefault(self: *const UserContext) bool {
        return std.mem.eql(u8, self.id(), "default");
    }
};

pub fn resetRealm(self: *BiDi) void {
    script.Pending.realmReset(self);
    self.handles.releaseAll();
    self.node_registry.reset();
    if (self.browsing_context) |*ctx| {
        if (ctx.realm_announced) {
            ctx.realm_announced = false;
            self.sendEvent("script.realmDestroyed", .{ .realm = &ctx.realm_id }) catch {};
        }
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

    lp.metrics.serve_commands.incr(.bidi);
    self.dispatch(arena, id, method, data) catch |err| switch (err) {
        error.UnknownCommand => {
            lp.metrics.serve_unknown_commands.incr(.bidi);
            try self.sendError(id, "unknown command", method);
        },
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
        input,
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
        .browsingContext => return @import("browsing_context.zig").processMessage(&cmd),
        .input => return @import("input.zig").processMessage(&cmd),
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

// Without a link there's nobody to tell: an HTTP session between
// connections drops events and late results (a navigate that completes
// after the client went away).
fn sendJSON(self: *BiDi, message: anytype) !void {
    const l = self.link orelse return;
    return l.sendJSON(message, .{});
}
