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
const Id = @import("../id.zig");

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

    fn isDefault(self: *const Session) bool {
        return std.mem.eql(u8, self.id, default_session_id);
    }
};

allocator: std.mem.Allocator,
app: *App,

sessions: std.StringHashMapUnmanaged(*Session) = .empty,
/// Monotonic counter backing auto-generated session ids (`s1`, `s2`, …).
session_seq: u32 = 0,
/// Endpoint nodes may have only one active HTTP WebDriver session.
webdriver_session: ?*Session = null,
webdriver_session_id: ?[36]u8 = null,
webdriver_page_load_wait: ?lp.Config.WaitUntil = .load,
webdriver_page_load_timeout_ms: ?u64 = 300_000,
webdriver_script_timeout_ms: ?u64 = 30_000,
webdriver_implicit_timeout_ms: ?u64 = 0,
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
    const self = try initEmpty(allocator, app, writer);
    errdefer {
        self.transport.deinit();
        allocator.destroy(self);
    }

    self.active_session = try self.createSession(default_session_id);
    return self;
}

/// Initialize the WebDriver endpoint without an otherwise-unused default
/// browser. The first New Session command creates the sole browser lazily.
pub fn initWebDriver(allocator: std.mem.Allocator, app: *App, writer: *std.Io.Writer) !*Self {
    try app.watchdog.enableExecutionDeadlines();
    return initEmpty(allocator, app, writer);
}

fn initEmpty(allocator: std.mem.Allocator, app: *App, writer: *std.Io.Writer) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .app = app,
        .transport = .init(allocator, writer),
    };
    errdefer self.transport.deinit();

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
    };
    errdefer entry.node_registry.deinit();

    try entry.browser.init(self.app, .{}, null);
    errdefer entry.browser.deinit();

    entry.session = try entry.browser.newSession(notification);
    try entry.session.enableConsoleCapture();

    // Only the default session is backed by the on-disk cookie file; named
    // sessions start clean so agents stay isolated by default.
    if (entry.isDefault()) {
        if (self.app.config.cookieFile()) |cookie_path| {
            lp.cookies.loadFromFile(entry.session, cookie_path);
        }
    }

    try self.sessions.put(self.allocator, owned_id, entry);
    // Browser.init left the isolate entered; park it (see park_isolates).
    self.exitIsolate(entry);
    return entry;
}

/// Switch to the multi-isolate discipline: park the default (which `Server.init`
/// left entered) and require every use to bracket with `enterIsolate`. The HTTP
/// transport calls this on its worker thread before serving anyone.
pub fn enableIsolateParking(self: *Self) void {
    self.park_isolates = true;
    if (self.sessions.get(default_session_id)) |entry| self.exitIsolate(entry);
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

/// Create a W3C WebDriver session with its initial about:blank document.
/// The browser state is marked before the page is created so navigator.webdriver
/// is true from the first script execution in that browsing context.
pub fn createWebDriverSession(
    self: *Self,
    id: []const u8,
    page_load_wait: ?lp.Config.WaitUntil,
    page_load_timeout_ms: ?u64,
    script_timeout_ms: ?u64,
    implicit_timeout_ms: ?u64,
) !*Session {
    if (self.webdriver_session != null) {
        return error.SessionAlreadyExists;
    }
    if (id.len != 36) return error.InvalidSessionId;

    const entry = try self.createSession(id);
    errdefer {
        const removed = self.sessions.fetchRemove(id).?;
        self.destroySession(removed.value);
    }

    self.enterIsolate(entry);
    defer self.exitIsolate(entry);

    entry.browser.webdriver_active = true;
    errdefer entry.browser.webdriver_active = false;

    _ = try entry.session.createPage();

    var owned_id: [36]u8 = undefined;
    @memcpy(&owned_id, id);
    self.webdriver_page_load_wait = page_load_wait;
    self.webdriver_page_load_timeout_ms = page_load_timeout_ms;
    self.webdriver_script_timeout_ms = script_timeout_ms;
    self.webdriver_implicit_timeout_ms = implicit_timeout_ms;
    self.webdriver_session = entry;
    self.webdriver_session_id = owned_id;
    return entry;
}

/// Return an existing W3C WebDriver session. This never creates a session for
/// an unknown id, unlike useSession which is intentionally MCP-friendly.
pub fn getWebDriverSession(self: *Self, id: []const u8) ?*Session {
    const entry = self.webdriver_session orelse return null;
    const active_id = self.webdriver_session_id orelse return null;
    return if (std.mem.eql(u8, &active_id, id)) entry else null;
}

pub fn closeWebDriverSession(self: *Self, id: []const u8) bool {
    const entry = self.getWebDriverSession(id) orelse return false;
    self.cancelWebDriverTermination();
    entry.browser.webdriver_active = false;

    self.webdriver_session = null;
    self.webdriver_session_id = null;
    self.webdriver_page_load_wait = .load;
    self.webdriver_page_load_timeout_ms = 300_000;
    self.webdriver_script_timeout_ms = 30_000;
    self.webdriver_implicit_timeout_ms = 0;
    const removed = self.sessions.fetchRemove(id) orelse unreachable;
    std.debug.assert(removed.value == entry);
    self.destroySession(entry);
    return true;
}

pub fn webdriverReady(self: *const Self) bool {
    return self.webdriver_session == null;
}

pub fn webdriverEnvironment(self: *Self) ?*lp.js.Env {
    const entry = self.webdriver_session orelse return null;
    return &entry.browser.env;
}

/// Cancel a transport-requested V8 termination while its isolate is current.
/// The HTTP worker calls this after idle work and just before teardown.
pub fn cancelWebDriverTermination(self: *Self) void {
    const entry = self.webdriver_session orelse return;
    self.enterIsolate(entry);
    defer self.exitIsolate(entry);
    if (entry.browser.env.terminatePending()) entry.browser.env.cancelTerminate();
}

pub fn webdriverPageLoadWait(self: *const Self) ?lp.Config.WaitUntil {
    return self.webdriver_page_load_wait;
}

pub fn webdriverPageLoadTimeout(self: *const Self) ?u64 {
    return self.webdriver_page_load_timeout_ms;
}

pub fn webdriverScriptTimeout(self: *const Self) ?u64 {
    return self.webdriver_script_timeout_ms;
}

pub fn webdriverImplicitTimeout(self: *const Self) ?u64 {
    return self.webdriver_implicit_timeout_ms;
}

pub fn setWebDriverScriptTimeout(self: *Self, timeout_ms: ?u64) void {
    self.webdriver_script_timeout_ms = timeout_ms;
}

pub fn setWebDriverPageLoadTimeout(self: *Self, timeout_ms: ?u64) void {
    self.webdriver_page_load_timeout_ms = timeout_ms;
}

pub fn setWebDriverImplicitTimeout(self: *Self, timeout_ms: ?u64) void {
    self.webdriver_implicit_timeout_ms = timeout_ms;
}

/// Generate the UUID required for a WebDriver session id.
pub fn nextWebDriverSessionId(self: *Self, arena: std.mem.Allocator) ![]const u8 {
    while (true) {
        var uuid: [36]u8 = undefined;
        Id.uuidv4(&uuid);
        if (!self.sessions.contains(&uuid)) return arena.dupe(u8, &uuid);
    }
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
        .protocolVersion = @tagName(protocol.Version.default),
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
