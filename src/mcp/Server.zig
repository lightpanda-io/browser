const std = @import("std");

const lp = @import("lightpanda");

const App = @import("../App.zig");
const testing = @import("../testing.zig");
const protocol = @import("protocol.zig");
const resources = @import("resources.zig");
const router = @import("router.zig");
const tools = @import("tools.zig");
const Transport = @import("Transport.zig");
const CDPNode = @import("../cdp/Node.zig");

const Self = @This();

/// Session every un-scoped request lands on. Over stdio there is only ever
/// this one; the HTTP transport routes to it when a client sends no
/// `Mcp-Session-Id`.
pub const default_session_id = "default";

/// One isolated browsing context. Each owns its own V8 isolate (via
/// `Browser`), so two agents driving different sessions never touch the same
/// page. Heap-allocated and never moved after `init`: `Browser` registers
/// self-pointers (watchdog, http_client) that must stay stable.
pub const Session = struct {
    id: []const u8,
    browser: lp.Browser,
    session: *lp.Session,
    notification: *lp.Notification,
    node_registry: CDPNode.Registry,
    /// Owns `heal_target`'s strings; freed on every overwrite.
    heal_arena: std.heap.ArenaAllocator,
    /// The cure target `heal_commit` validates against: the finding of the
    /// last failed/suspicious file `replay`, minus the detail the cure check
    /// never reads. Server-held so a client cannot widen or retarget it — an
    /// echoed `threw` would let a fix-by-deletion commit; `heal_commit`'s
    /// `fields` may only narrow it.
    heal_target: ?HealTarget = null,

    const HealTarget = struct {
        path: []const u8,
        kind: lp.replay.WireFailure.Kind,
        dry_fields: []const []const u8,
    };

    fn isDefault(self: *const Session) bool {
        return std.mem.eql(u8, self.id, default_session_id);
    }

    /// A file replay speaks for its file: failed or suspicious arms the cure
    /// target, clean retires it. A `script` trial is neither — don't note it.
    pub fn noteFileReplay(self: *Session, report: lp.replay.RunReport) error{OutOfMemory}!void {
        switch (report.status) {
            .ok => return self.retireHealTarget(report.path),
            .failed, .suspicious => {},
        }
        const failure = report.failure.?;
        // Drop first: an OOM mid-copy must not leave a target pointing into
        // the freed arena.
        self.dropHealTarget();
        const arena = self.heal_arena.allocator();
        const dry_fields = try arena.alloc([]const u8, failure.dry_fields.len);
        for (failure.dry_fields, dry_fields) |field, *owned| owned.* = try arena.dupe(u8, field);
        self.heal_target = .{ .path = try arena.dupe(u8, report.path), .kind = failure.kind, .dry_fields = dry_fields };
    }

    /// Forget `path`'s target — a clean replay or a committed cure. No-op for
    /// any other path.
    pub fn retireHealTarget(self: *Session, path: []const u8) void {
        if (self.cureTarget(path) == null) return;
        self.dropHealTarget();
    }

    pub fn cureTarget(self: *const Session, path: []const u8) ?lp.replay.WireFailure {
        const target = self.heal_target orelse return null;
        if (!std.mem.eql(u8, target.path, path)) return null;
        return .{ .kind = target.kind, .dry_fields = target.dry_fields };
    }

    fn dropHealTarget(self: *Session) void {
        self.heal_target = null;
        _ = self.heal_arena.reset(.free_all);
    }
};

allocator: std.mem.Allocator,
app: *App,

sessions: std.StringHashMapUnmanaged(*Session) = .empty,
/// Monotonic counter backing auto-generated session ids (`s1`, `s2`, …).
session_seq: u32 = 0,
/// When several sessions (each its own V8 isolate) share one thread, V8's
/// "current isolate" is a per-thread stack, so an isolate must be *entered*
/// around any use of it and left un-entered otherwise. The HTTP transport
/// sets this; stdio (one isolate, permanently entered by `Env`) leaves it
/// false and keeps its historical behavior. See `enterIsolate`/`exitIsolate`.
park_isolates: bool = false,
/// The session the request currently being handled targets. Safe as a single
/// field because every request is dispatched on one thread, one at a time;
/// the transport sets it (via `useSession`) before each dispatch. Tools and
/// resources read it rather than threading a session through every call.
active_session: *Session = undefined,
transport: Transport,

pub fn init(allocator: std.mem.Allocator, app: *App, writer: *std.Io.Writer) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .app = app,
        .transport = .init(allocator, writer),
    };
    errdefer self.transport.deinit();

    self.active_session = try self.createSession(default_session_id);
    return self;
}

pub fn deinit(self: *Self) void {
    var it = self.sessions.valueIterator();
    while (it.next()) |entry| self.destroySession(entry.*);
    self.sessions.deinit(self.allocator);

    self.transport.deinit();
    self.allocator.destroy(self);
}

/// Create the session named `id`, or return the existing one. The `id` is
/// duped, so the caller keeps ownership of its slice.
pub fn createSession(self: *Self, id: []const u8) !*Session {
    if (self.sessions.get(id)) |existing| return existing;

    const owned_id = try self.allocator.dupe(u8, id);
    errdefer self.allocator.free(owned_id);

    const entry = try self.allocator.create(Session);
    errdefer self.allocator.destroy(entry);

    const notification = try lp.Notification.init(self.allocator);
    errdefer notification.deinit();

    entry.* = .{
        .id = owned_id,
        .browser = undefined,
        .session = undefined,
        .notification = notification,
        .node_registry = CDPNode.Registry.init(self.allocator),
        .heal_arena = .init(self.allocator),
    };
    errdefer entry.node_registry.deinit();
    errdefer entry.heal_arena.deinit();

    try entry.browser.init(self.app, .{}, null);
    errdefer entry.browser.deinit();

    try self.restartSession(entry);

    try self.sessions.put(self.allocator, owned_id, entry);
    // Browser.init left the isolate entered; park it (see park_isolates).
    self.exitIsolate(entry);
    return entry;
}

/// Point `entry` at a fresh browsing session — pages, cookies and node ids
/// dropped. Bring-up for `createSession` and the reset heal validation
/// requires. Only the default session is backed by the on-disk cookie file:
/// named sessions stay isolated, and a restart discards the in-memory
/// failure-state cookies for that clean baseline identity.
pub fn restartSession(self: *Self, entry: *Session) !void {
    entry.session = try lp.tools.freshSession(&entry.browser, entry.notification, &entry.node_registry);
    if (entry.isDefault()) {
        if (self.app.config.cookieFile()) |cookie_path| {
            lp.cookies.loadFromFile(entry.session, cookie_path);
        }
    }
}

/// Switch to the multi-isolate discipline: park the default (which `Server.init`
/// left entered) and require every use to bracket with `enterIsolate`. The HTTP
/// transport calls this on its worker thread before serving anyone.
pub fn enableIsolateParking(self: *Self) void {
    self.park_isolates = true;
    self.exitIsolate(self.defaultSession());
}

/// Make `entry`'s isolate the current one for this thread. Must bracket any
/// use of its Browser/Session (dispatch, idle pumping, teardown). No-op under
/// stdio, where the single isolate is permanently current.
pub fn enterIsolate(self: *Self, entry: *Session) void {
    if (self.park_isolates) entry.browser.env.isolate.enter();
}

pub fn exitIsolate(self: *Self, entry: *Session) void {
    if (self.park_isolates) entry.browser.env.isolate.exit();
}

/// Tear down the session named `id`. Returns false if no such session, or if
/// it is the default (which lives for the whole process).
pub fn closeSession(self: *Self, id: []const u8) bool {
    if (std.mem.eql(u8, id, default_session_id)) return false;
    const entry = self.sessions.fetchRemove(id) orelse return false;
    if (self.active_session == entry.value) self.active_session = self.defaultSession();
    self.destroySession(entry.value);
    return true;
}

fn destroySession(self: *Self, entry: *Session) void {
    if (entry.isDefault()) {
        if (self.app.config.cookieJarFile()) |cookie_jar_path| {
            lp.cookies.saveToFile(&entry.session.cookie_jar, cookie_jar_path);
        }
    }

    // Re-enter so `Browser.deinit`'s `Env.deinit` exit stays balanced against
    // a parked isolate (and operates on the current one).
    self.enterIsolate(entry);
    entry.heal_arena.deinit();
    entry.node_registry.deinit();
    entry.browser.deinit();
    entry.notification.deinit();
    self.allocator.free(entry.id);
    self.allocator.destroy(entry);
}

/// The session an un-scoped (stdio, or header-less HTTP) request targets.
pub fn defaultSession(self: *Self) *Session {
    return self.sessions.get(default_session_id).?;
}

/// Point subsequent tool/resource dispatch at the session named `id`, creating
/// it on first use. A null or empty `id` selects the default.
pub fn useSession(self: *Self, id: ?[]const u8) !*Session {
    const wanted = id orelse "";
    self.active_session = if (wanted.len == 0) self.defaultSession() else try self.createSession(wanted);
    return self.active_session;
}

/// A session id that is not currently in use, formatted into `arena`.
pub fn nextSessionId(self: *Self, arena: std.mem.Allocator) ![]const u8 {
    while (true) {
        self.session_seq += 1;
        const candidate = try std.fmt.allocPrint(arena, "s{d}", .{self.session_seq});
        if (!self.sessions.contains(candidate)) return candidate;
    }
}

/// Pump every live session's pending transfers and return the shortest time
/// the caller may block before pumping again. See `Session.idleSlice`.
pub fn idle(self: *Self) u31 {
    var wait: u31 = std.math.maxInt(u31);
    var it = self.sessions.valueIterator();
    while (it.next()) |entry| {
        // Pumping may resume JS (e.g. a completed script fetch), so it needs
        // the session's isolate current.
        self.enterIsolate(entry.*);
        wait = @min(wait, entry.*.session.idleSlice());
        self.exitIsolate(entry.*);
    }
    return wait;
}

pub fn sendError(self: *Self, id: std.json.Value, code: protocol.ErrorCode, message: []const u8) !void {
    return self.transport.sendError(id, code, message);
}

pub fn sendResult(self: *Self, id: std.json.Value, result: anytype) !void {
    return self.transport.sendResult(id, result);
}

pub fn handleInitialize(self: *Self, req: protocol.Request) !void {
    const id = req.id orelse return;
    try self.sendResult(id, protocol.InitializeResult{
        .protocolVersion = @tagName(protocol.Version.negotiate(req.params)),
        .capabilities = .{
            .resources = .{},
            .tools = .{},
        },
        .serverInfo = .{ .name = "lightpanda", .version = "0.1.0" },
        .instructions = lp.tools.driver_guidance ++ tools.script_lifecycle_note,
    });
}

pub fn handleToolList(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    return tools.handleList(self, arena, req);
}

pub fn handleToolCall(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    // Dispatch runs page JS, so enter the target isolate around it.
    const entry = self.active_session;
    self.enterIsolate(entry);
    defer self.exitIsolate(entry);
    return tools.handleCall(self, arena, req);
}

pub fn handleResourceList(self: *Self, req: protocol.Request) !void {
    return resources.handleList(self, req);
}

pub fn handleResourceRead(self: *Self, arena: std.mem.Allocator, req: protocol.Request) !void {
    const entry = self.active_session;
    self.enterIsolate(entry);
    defer self.exitIsolate(entry);
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
