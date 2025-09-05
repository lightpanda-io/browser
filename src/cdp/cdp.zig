// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;
const json = std.json;

const log = @import("../log.zig");
const App = @import("../app.zig").App;
const Env = @import("../browser/env.zig").Env;
const Browser = @import("../browser/browser.zig").Browser;
const Session = @import("../browser/session.zig").Session;
const Page = @import("../browser/page.zig").Page;
const Inspector = @import("../browser/env.zig").Env.Inspector;
const Incrementing = @import("../id.zig").Incrementing;
const Notification = @import("../notification.zig").Notification;
const NetworkState = @import("domains/network.zig").NetworkState;
const InterceptState = @import("domains/fetch.zig").InterceptState;

const polyfill = @import("../browser/polyfill/polyfill.zig");

pub const URL_BASE = "chrome://newtab/";
pub const LOADER_ID = "LOADERID24DD2FD56CF1EF33C965C79C";

pub const CDP = CDPT(struct {
    const Client = *@import("../server.zig").Client;
});

const SessionIdGen = Incrementing(u32, "SID");
const TargetIdGen = Incrementing(u32, "TID");
const LoaderIdGen = Incrementing(u32, "LID");
const BrowserContextIdGen = Incrementing(u32, "BID");

// Generic so that we can inject mocks into it.
pub fn CDPT(comptime TypeProvider: type) type {
    return struct {
        // Used for sending message to the client and closing on error
        client: TypeProvider.Client,

        allocator: Allocator,

        // The active browser
        browser: Browser,

        // when true, any target creation must be attached.
        target_auto_attach: bool = false,

        target_id_gen: TargetIdGen = .{},
        loader_id_gen: LoaderIdGen = .{},
        session_id_gen: SessionIdGen = .{},
        browser_context_id_gen: BrowserContextIdGen = .{},

        browser_context: ?BrowserContext(Self),

        // Re-used arena for processing a message. We're assuming that we're getting
        // 1 message at a time.
        message_arena: std.heap.ArenaAllocator,

        // Used for processing notifications within a browser context.
        notification_arena: std.heap.ArenaAllocator,

        const Self = @This();

        pub fn init(app: *App, client: TypeProvider.Client) !Self {
            const allocator = app.allocator;
            const browser = try Browser.init(app);
            errdefer browser.deinit();

            return .{
                .client = client,
                .browser = browser,
                .allocator = allocator,
                .browser_context = null,
                .message_arena = std.heap.ArenaAllocator.init(allocator),
                .notification_arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.browser_context) |*bc| {
                bc.deinit();
            }
            self.browser.deinit();
            self.message_arena.deinit();
            self.notification_arena.deinit();
        }

        pub fn handleMessage(self: *Self, msg: []const u8) bool {
            // if there's an error, it's already been logged
            self.processMessage(msg) catch return false;
            return true;
        }

        pub fn processMessage(self: *Self, msg: []const u8) !void {
            const arena = &self.message_arena;
            defer _ = arena.reset(.{ .retain_with_limit = 1024 * 16 });
            return self.dispatch(arena.allocator(), self, msg);
        }

        // @newhttp
        // A bit hacky right now. The main server loop doesn't unblock for
        // scheduled task. So we run this directly in order to process any
        // timeouts (or http events) which are ready to be processed.

        pub fn hasPage() bool {}
        pub fn pageWait(self: *Self, ms: i32) Session.WaitResult {
            const session = &(self.browser.session orelse return .no_page);
            return session.wait(ms);
        }

        // Called from above, in processMessage which handles client messages
        // but can also be called internally. For example, Target.sendMessageToTarget
        // calls back into dispatch to capture the response.
        pub fn dispatch(self: *Self, arena: Allocator, sender: anytype, str: []const u8) !void {
            const input = json.parseFromSliceLeaky(InputMessage, arena, str, .{
                .ignore_unknown_fields = true,
            }) catch return error.InvalidJSON;

            var command = Command(Self, @TypeOf(sender)){
                .input = .{
                    .json = str,
                    .id = input.id,
                    .action = "",
                    .params = input.params,
                    .session_id = input.sessionId,
                },
                .cdp = self,
                .arena = arena,
                .sender = sender,
                .browser_context = if (self.browser_context) |*bc| bc else null,
            };

            // See dispatchStartupCommand for more info on this.
            var is_startup = false;
            if (input.sessionId) |input_session_id| {
                if (std.mem.eql(u8, input_session_id, "STARTUP")) {
                    is_startup = true;
                } else if (self.isValidSessionId(input_session_id) == false) {
                    return command.sendError(-32001, "Unknown sessionId");
                }
            }

            if (is_startup) {
                dispatchStartupCommand(&command) catch |err| {
                    command.sendError(-31999, @errorName(err)) catch {};
                    return err;
                };
            } else {
                dispatchCommand(&command, input.method) catch |err| {
                    command.sendError(-31998, @errorName(err)) catch {};
                    return err;
                };
            }
        }

        // A CDP session isn't 100% fully driven by the driver. There's are
        // independent actions that the browser is expected to take. For example
        // Puppeteer expects the browser to startup a tab and thus have existing
        // targets.
        // To this end, we create a [very] dummy BrowserContext, Target and
        // Session. There isn't actually a BrowserContext, just a special id.
        // When messages are received with the "STARTUP" sessionId, we do
        // "special" handling - the bare minimum we need to do until the driver
        // switches to a real BrowserContext.
        // (I can imagine this logic will become driver-specific)
        fn dispatchStartupCommand(command: anytype) !void {
            return command.sendResult(null, .{});
        }

        fn dispatchCommand(command: anytype, method: []const u8) !void {
            const domain = blk: {
                const i = std.mem.indexOfScalarPos(u8, method, 0, '.') orelse {
                    return error.InvalidMethod;
                };
                command.input.action = method[i + 1 ..];
                break :blk method[0..i];
            };

            switch (domain.len) {
                3 => switch (@as(u24, @bitCast(domain[0..3].*))) {
                    asUint(u24, "DOM") => return @import("domains/dom.zig").processMessage(command),
                    asUint(u24, "Log") => return @import("domains/log.zig").processMessage(command),
                    asUint(u24, "CSS") => return @import("domains/css.zig").processMessage(command),
                    else => {},
                },
                4 => switch (@as(u32, @bitCast(domain[0..4].*))) {
                    asUint(u32, "Page") => return @import("domains/page.zig").processMessage(command),
                    else => {},
                },
                5 => switch (@as(u40, @bitCast(domain[0..5].*))) {
                    asUint(u40, "Fetch") => return @import("domains/fetch.zig").processMessage(command),
                    asUint(u40, "Input") => return @import("domains/input.zig").processMessage(command),
                    else => {},
                },
                6 => switch (@as(u48, @bitCast(domain[0..6].*))) {
                    asUint(u48, "Target") => return @import("domains/target.zig").processMessage(command),
                    else => {},
                },
                7 => switch (@as(u56, @bitCast(domain[0..7].*))) {
                    asUint(u56, "Browser") => return @import("domains/browser.zig").processMessage(command),
                    asUint(u56, "Runtime") => return @import("domains/runtime.zig").processMessage(command),
                    asUint(u56, "Network") => return @import("domains/network.zig").processMessage(command),
                    asUint(u56, "Storage") => return @import("domains/storage.zig").processMessage(command),
                    else => {},
                },
                8 => switch (@as(u64, @bitCast(domain[0..8].*))) {
                    asUint(u64, "Security") => return @import("domains/security.zig").processMessage(command),
                    else => {},
                },
                9 => switch (@as(u72, @bitCast(domain[0..9].*))) {
                    asUint(u72, "Emulation") => return @import("domains/emulation.zig").processMessage(command),
                    asUint(u72, "Inspector") => return @import("domains/inspector.zig").processMessage(command),
                    else => {},
                },
                11 => switch (@as(u88, @bitCast(domain[0..11].*))) {
                    asUint(u88, "Performance") => return @import("domains/performance.zig").processMessage(command),
                    else => {},
                },
                else => {},
            }

            return error.UnknownDomain;
        }

        fn isValidSessionId(self: *const Self, input_session_id: []const u8) bool {
            const browser_context = &(self.browser_context orelse return false);
            const session_id = browser_context.session_id orelse return false;
            return std.mem.eql(u8, session_id, input_session_id);
        }

        pub fn createBrowserContext(self: *Self) ![]const u8 {
            if (self.browser_context != null) {
                return error.AlreadyExists;
            }
            const id = self.browser_context_id_gen.next();

            self.browser_context = @as(BrowserContext(Self), undefined);
            const browser_context = &self.browser_context.?;

            try BrowserContext(Self).init(browser_context, id, self);
            return id;
        }

        pub fn disposeBrowserContext(self: *Self, browser_context_id: []const u8) bool {
            const bc = &(self.browser_context orelse return false);
            if (std.mem.eql(u8, bc.id, browser_context_id) == false) {
                return false;
            }
            bc.deinit();
            self.browser.closeSession();
            self.browser_context = null;
            return true;
        }

        const SendEventOpts = struct {
            session_id: ?[]const u8 = null,
        };
        pub fn sendEvent(self: *Self, method: []const u8, p: anytype, opts: SendEventOpts) !void {
            return self.sendJSON(.{
                .method = method,
                .params = if (comptime @typeInfo(@TypeOf(p)) == .null) struct {}{} else p,
                .sessionId = opts.session_id,
            });
        }

        pub fn sendJSON(self: *Self, message: anytype) !void {
            return self.client.sendJSON(message, .{
                .emit_null_optional_fields = false,
            });
        }
    };
}

pub fn BrowserContext(comptime CDP_T: type) type {
    const Node = @import("Node.zig");

    return struct {
        id: []const u8,
        cdp: *CDP_T,

        // Represents the browser session. There is no equivalent in CDP. For
        // all intents and purpose, from CDP's point of view our Browser and
        // our Session more or less maps to a BrowserContext. THIS HAS ZERO
        // RELATION TO SESSION_ID
        session: *Session,

        // Points to the session arena
        arena: Allocator,

        // From the parent's notification_arena.allocator(). Most of the CDP
        // code paths deal with a cmd which has its own arena (from the
        // message_arena). But notifications happen outside of the typical CDP
        // request->response, and thus don't have a cmd and don't have an arena.
        notification_arena: Allocator,

        // Maps to our Page. (There are other types of targets, but we only
        // deal with "pages" for now). Since we only allow 1 open page at a
        // time, we only have 1 target_id.
        target_id: ?[]const u8,

        // The CDP session_id. After the target/page is created, the client
        // "attaches" to it (either explicitly or automatically). We return a
        // "sessionId" which identifies this link. `sessionId` is the how
        // the CDP client informs us what it's trying to manipulate. Because we
        // only support 1 BrowserContext at a time, and 1 page at a time, this
        // is all pretty straightforward, but it still needs to be enforced, i.e.
        // if we get a request with a sessionId that doesn't match the current one
        // we should reject it.
        session_id: ?[]const u8,

        loader_id: []const u8,
        security_origin: []const u8,
        page_life_cycle_events: bool,
        secure_context_type: []const u8,
        node_registry: Node.Registry,
        node_search_list: Node.Search.List,

        inspector: Inspector,
        isolated_world: ?IsolatedWorld,

        http_proxy_changed: bool = false,

        // Extra headers to add to all requests.
        extra_headers: std.ArrayListUnmanaged([*c]const u8) = .empty,

        intercept_state: InterceptState,

        // When network is enabled, we'll capture the transfer.id -> body
        // This is awfully memory intensive, but our underlying http client and
        // its users (script manager and page) correctly do not hold the body
        // memory longer than they have to. In fact, the main request is only
        // ever streamed. So if CDP is the only thing that needs bodies in
        // memory for an arbitrary amount of time, then that's where we're going
        // to store the,
        captured_responses: std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged(u8)),

        const Self = @This();

        fn init(self: *Self, id: []const u8, cdp: *CDP_T) !void {
            const allocator = cdp.allocator;

            const session = try cdp.browser.newSession();
            const arena = session.arena;

            const inspector = try cdp.browser.env.newInspector(arena, self);

            var registry = Node.Registry.init(allocator);
            errdefer registry.deinit();

            self.* = .{
                .id = id,
                .cdp = cdp,
                .arena = arena,
                .target_id = null,
                .session_id = null,
                .session = session,
                .security_origin = URL_BASE,
                .secure_context_type = "Secure", // TODO = enum
                .loader_id = LOADER_ID,
                .page_life_cycle_events = false, // TODO; Target based value
                .node_registry = registry,
                .node_search_list = undefined,
                .isolated_world = null,
                .inspector = inspector,
                .notification_arena = cdp.notification_arena.allocator(),
                .intercept_state = try InterceptState.init(allocator),
                .captured_responses = .empty,
            };
            self.node_search_list = Node.Search.List.init(allocator, &self.node_registry);
            errdefer self.deinit();

            try cdp.browser.notification.register(.page_remove, self, onPageRemove);
            try cdp.browser.notification.register(.page_created, self, onPageCreated);
            try cdp.browser.notification.register(.page_navigate, self, onPageNavigate);
            try cdp.browser.notification.register(.page_navigated, self, onPageNavigated);
        }

        pub fn deinit(self: *Self) void {
            self.inspector.deinit();

            // abort all intercepted requests before closing the sesion/page
            // since some of these might callback into the page/scriptmanager
            for (self.intercept_state.pendingTransfers()) |transfer| {
                transfer.abort();
            }

            // If the session has a page, we need to clear it first. The page
            // context is always nested inside of the isolated world context,
            // so we need to shutdown the page one first.
            self.cdp.browser.closeSession();

            if (self.isolated_world) |*world| {
                world.deinit();
            }
            self.node_registry.deinit();
            self.node_search_list.deinit();
            self.cdp.browser.notification.unregisterAll(self);

            if (self.http_proxy_changed) {
                // has to be called after browser.closeSession, since it won't
                // work if there are active connections.
                self.cdp.browser.http_client.restoreOriginalProxy() catch |err| {
                    log.warn(.http, "restoreOriginalProxy", .{ .err = err });
                };
            }
            self.intercept_state.deinit();
        }

        pub fn reset(self: *Self) void {
            self.node_registry.reset();
            self.node_search_list.reset();
        }

        pub fn createIsolatedWorld(self: *Self, world_name: []const u8, grant_universal_access: bool) !*IsolatedWorld {
            if (self.isolated_world != null) {
                return error.CurrentlyOnly1IsolatedWorldSupported;
            }

            var executor = try self.cdp.browser.env.newExecutionWorld();
            errdefer executor.deinit();

            self.isolated_world = .{
                .name = try self.arena.dupe(u8, world_name),
                .executor = executor,
                .grant_universal_access = grant_universal_access,
            };
            return &self.isolated_world.?;
        }

        pub fn nodeWriter(self: *Self, root: *const Node, opts: Node.Writer.Opts) Node.Writer {
            return .{
                .root = root,
                .depth = opts.depth,
                .exclude_root = opts.exclude_root,
                .registry = &self.node_registry,
            };
        }

        pub fn getURL(self: *const Self) ?[]const u8 {
            const page = self.session.currentPage() orelse return null;
            const raw_url = page.url.raw;
            return if (raw_url.len == 0) null else raw_url;
        }

        pub fn networkEnable(self: *Self) !void {
            try self.cdp.browser.notification.register(.http_request_fail, self, onHttpRequestFail);
            try self.cdp.browser.notification.register(.http_request_start, self, onHttpRequestStart);
            try self.cdp.browser.notification.register(.http_request_done, self, onHttpRequestDone);
            try self.cdp.browser.notification.register(.http_response_data, self, onHttpResponseData);
            try self.cdp.browser.notification.register(.http_response_header_done, self, onHttpResponseHeadersDone);
        }

        pub fn networkDisable(self: *Self) void {
            self.cdp.browser.notification.unregister(.http_request_fail, self);
            self.cdp.browser.notification.unregister(.http_request_start, self);
            self.cdp.browser.notification.unregister(.http_request_done, self);
            self.cdp.browser.notification.unregister(.http_response_data, self);
            self.cdp.browser.notification.unregister(.http_response_header_done, self);
        }

        pub fn fetchEnable(self: *Self, authRequests: bool) !void {
            try self.cdp.browser.notification.register(.http_request_intercept, self, onHttpRequestIntercept);
            if (authRequests) {
                try self.cdp.browser.notification.register(.http_request_auth_required, self, onHttpRequestAuthRequired);
            }
        }

        pub fn fetchDisable(self: *Self) void {
            self.cdp.browser.notification.unregister(.http_request_intercept, self);
            self.cdp.browser.notification.unregister(.http_request_auth_required, self);
        }

        pub fn lifecycleEventsEnable(self: *Self) !void {
            self.page_life_cycle_events = true;
            try self.cdp.browser.notification.register(.page_network_idle, self, onPageNetworkIdle);
            try self.cdp.browser.notification.register(.page_network_almost_idle, self, onPageNetworkAlmostIdle);
        }

        pub fn lifecycleEventsDisable(self: *Self) void {
            self.page_life_cycle_events = false;
            self.cdp.browser.notification.unregister(.page_network_idle, self);
            self.cdp.browser.notification.unregister(.page_network_almost_idle, self);
        }

        pub fn onPageRemove(ctx: *anyopaque, _: Notification.PageRemove) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try @import("domains/page.zig").pageRemove(self);
        }

        pub fn onPageCreated(ctx: *anyopaque, page: *Page) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return @import("domains/page.zig").pageCreated(self, page);
        }

        pub fn onPageNavigate(ctx: *anyopaque, msg: *const Notification.PageNavigate) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.resetNotificationArena();
            return @import("domains/page.zig").pageNavigate(self.notification_arena, self, msg);
        }

        pub fn onPageNavigated(ctx: *anyopaque, msg: *const Notification.PageNavigated) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return @import("domains/page.zig").pageNavigated(self, msg);
        }

        pub fn onPageNetworkIdle(ctx: *anyopaque, msg: *const Notification.PageNetworkIdle) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return @import("domains/page.zig").pageNetworkIdle(self, msg);
        }

        pub fn onPageNetworkAlmostIdle(ctx: *anyopaque, msg: *const Notification.PageNetworkAlmostIdle) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return @import("domains/page.zig").pageNetworkAlmostIdle(self, msg);
        }

        pub fn onHttpRequestStart(ctx: *anyopaque, msg: *const Notification.RequestStart) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.resetNotificationArena();
            try @import("domains/network.zig").httpRequestStart(self.notification_arena, self, msg);
        }

        pub fn onHttpRequestIntercept(ctx: *anyopaque, msg: *const Notification.RequestIntercept) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.resetNotificationArena();
            try @import("domains/fetch.zig").requestIntercept(self.notification_arena, self, msg);
        }

        pub fn onHttpRequestFail(ctx: *anyopaque, msg: *const Notification.RequestFail) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.resetNotificationArena();
            return @import("domains/network.zig").httpRequestFail(self.notification_arena, self, msg);
        }

        pub fn onHttpResponseHeadersDone(ctx: *anyopaque, msg: *const Notification.ResponseHeaderDone) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.resetNotificationArena();
            return @import("domains/network.zig").httpResponseHeaderDone(self.notification_arena, self, msg);
        }

        pub fn onHttpRequestDone(ctx: *anyopaque, msg: *const Notification.RequestDone) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.resetNotificationArena();
            return @import("domains/network.zig").httpRequestDone(self.notification_arena, self, msg);
        }

        pub fn onHttpResponseData(ctx: *anyopaque, msg: *const Notification.ResponseData) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const arena = self.arena;

            const id = msg.transfer.id;
            const gop = try self.captured_responses.getOrPut(arena, id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            try gop.value_ptr.appendSlice(arena, try arena.dupe(u8, msg.data));
        }

        pub fn onHttpRequestAuthRequired(ctx: *anyopaque, data: *const Notification.RequestAuthRequired) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.resetNotificationArena();
            try @import("domains/fetch.zig").requestAuthRequired(self.notification_arena, self, data);
        }

        fn resetNotificationArena(self: *Self) void {
            defer _ = self.cdp.notification_arena.reset(.{ .retain_with_limit = 1024 * 64 });
        }

        pub fn callInspector(self: *const Self, msg: []const u8) void {
            self.inspector.send(msg);
            // force running micro tasks after send input to the inspector.
            self.cdp.browser.runMicrotasks();
        }

        pub fn onInspectorResponse(ctx: *anyopaque, _: u32, msg: []const u8) void {
            sendInspectorMessage(@ptrCast(@alignCast(ctx)), msg) catch |err| {
                log.err(.cdp, "send inspector response", .{ .err = err });
            };
        }

        pub fn onInspectorEvent(ctx: *anyopaque, msg: []const u8) void {
            if (log.enabled(.cdp, .debug)) {
                // msg should be {"method":<method>,...
                std.debug.assert(std.mem.startsWith(u8, msg, "{\"method\":"));
                const method_end = std.mem.indexOfScalar(u8, msg, ',') orelse {
                    log.err(.cdp, "invalid inspector event", .{ .msg = msg });
                    return;
                };
                const method = msg[10..method_end];
                log.debug(.cdp, "inspector event", .{ .method = method });
            }

            sendInspectorMessage(@ptrCast(@alignCast(ctx)), msg) catch |err| {
                log.err(.cdp, "send inspector event", .{ .err = err });
            };
        }

        // This is hacky x 2. First, we create the JSON payload by gluing our
        // session_id onto it. Second, we're much more client/websocket aware than
        // we should be.
        fn sendInspectorMessage(self: *Self, msg: []const u8) !void {
            const session_id = self.session_id orelse {
                // We no longer have an active session. What should we do
                // in this case?
                return;
            };

            const cdp = self.cdp;
            const allocator = cdp.client.send_arena.allocator();

            const field = ",\"sessionId\":\"";

            // + 1 for the closing quote after the session id
            // + 10 for the max websocket header
            const message_len = msg.len + session_id.len + 1 + field.len + 10;

            var buf: std.ArrayListUnmanaged(u8) = .{};
            buf.ensureTotalCapacity(allocator, message_len) catch |err| {
                log.err(.cdp, "inspector buffer", .{ .err = err });
                return;
            };

            // reserve 10 bytes for websocket header
            buf.appendSliceAssumeCapacity(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

            // -1  because we dont' want the closing brace '}'
            buf.appendSliceAssumeCapacity(msg[0 .. msg.len - 1]);
            buf.appendSliceAssumeCapacity(field);
            buf.appendSliceAssumeCapacity(session_id);
            buf.appendSliceAssumeCapacity("\"}");
            std.debug.assert(buf.items.len == message_len);

            try cdp.client.sendJSONRaw(buf);
        }
    };
}

/// see: https://chromium.googlesource.com/chromium/src/+/master/third_party/blink/renderer/bindings/core/v8/V8BindingDesign.md#world
/// The current understanding. An isolated world lives in the same isolate, but a separated context.
/// Clients create this to be able to create variables and run code without interfering with the
/// normal namespace and values of the webpage. Similar to the main context we need to pretend to recreate it after
/// a executionContextsCleared event which happens when navigating to a new page. A client can have a command be executed
/// in the isolated world by using its Context ID or the worldName.
/// grantUniveralAccess Indecated whether the isolated world can reference objects like the DOM or other JS Objects.
/// An isolated world has it's own instance of globals like Window.
/// Generally the client needs to resolve a node into the isolated world to be able to work with it.
/// An object id is unique across all contexts, different object ids can refer to the same Node in different contexts.
const IsolatedWorld = struct {
    name: []const u8,
    executor: Env.ExecutionWorld,
    grant_universal_access: bool,

    // Polyfill loader for the isolated world.
    // We want to load polyfill in the world's context.
    polyfill_loader: polyfill.Loader = .{},

    pub fn deinit(self: *IsolatedWorld) void {
        self.executor.deinit();
    }
    pub fn removeContext(self: *IsolatedWorld) !void {
        if (self.executor.js_context == null) return error.NoIsolatedContextToRemove;
        self.executor.removeJsContext();
    }

    // The isolate world must share at least some of the state with the related page, specifically the DocumentHTML
    // (assuming grantUniveralAccess will be set to True!).
    // We just created the world and the page. The page's state lives in the session, but is update on navigation.
    // This also means this pointer becomes invalid after removePage untill a new page is created.
    // Currently we have only 1 page/frame and thus also only 1 state in the isolate world.
    pub fn createContext(self: *IsolatedWorld, page: *Page) !void {
        if (self.executor.js_context != null) return error.Only1IsolatedContextSupported;
        _ = try self.executor.createJsContext(
            &page.window,
            page,
            {},
            false,
            Env.GlobalMissingCallback.init(&self.polyfill_loader),
        );
    }
};

// This is a generic because when we send a result we have two different
// behaviors. Normally, we're sending the result to the client. But in some cases
// we want to capture the result. So we want the command.sendResult to be
// generic.
pub fn Command(comptime CDP_T: type, comptime Sender: type) type {
    return struct {
        // A misc arena that can be used for any allocation for processing
        // the message
        arena: Allocator,

        // reference to our CDP instance
        cdp: *CDP_T,

        // The browser context this command targets
        browser_context: ?*BrowserContext(CDP_T),

        // The command input (the id, optional session_id, params, ...)
        input: Input,

        // In most cases, Sender is going to be cdp itself. We'll call
        // sender.sendJSON() and CDP will send it to the client. But some
        // comamnds are dispatched internally, in which cases the Sender will
        // be code to capture the data that we were "sending".
        sender: Sender,

        const Self = @This();

        pub fn params(self: *const Self, comptime T: type) !?T {
            if (self.input.params) |p| {
                return try json.parseFromSliceLeaky(
                    T,
                    self.arena,
                    p.raw,
                    .{ .ignore_unknown_fields = true },
                );
            }
            return null;
        }

        pub fn createBrowserContext(self: *Self) !*BrowserContext(CDP_T) {
            _ = try self.cdp.createBrowserContext();
            self.browser_context = &(self.cdp.browser_context.?);
            return self.browser_context.?;
        }

        const SendResultOpts = struct {
            include_session_id: bool = true,
        };
        pub fn sendResult(self: *Self, result: anytype, opts: SendResultOpts) !void {
            return self.sender.sendJSON(.{
                .id = self.input.id,
                .result = if (comptime @typeInfo(@TypeOf(result)) == .null) struct {}{} else result,
                .sessionId = if (opts.include_session_id) self.input.session_id else null,
            });
        }

        const SendEventOpts = struct {
            session_id: ?[]const u8 = null,
        };
        pub fn sendEvent(self: *Self, method: []const u8, p: anytype, opts: CDP_T.SendEventOpts) !void {
            // Events ALWAYS go to the client. self.sender should not be used
            return self.cdp.sendEvent(method, p, opts);
        }

        pub fn sendError(self: *Self, code: i32, message: []const u8) !void {
            return self.sender.sendJSON(.{
                .id = self.input.id,
                .@"error" = .{ .code = code, .message = message },
            });
        }

        const Input = struct {
            // When we reply to a message, we echo back the message id
            id: ?i64,

            // The "action" of the message.Given a method of "LOG.enable", the
            // action is "enable"
            action: []const u8,

            // See notes in BrowserContext about session_id
            session_id: ?[]const u8,

            // Unparsed / untyped input.params.
            params: ?InputParams,

            // The full raw json input
            json: []const u8,
        };
    };
}

// When we parse a JSON message from the client, this is the structure
// we always expect
const InputMessage = struct {
    id: ?i64 = null,
    method: []const u8,
    params: ?InputParams = null,
    sessionId: ?[]const u8 = null,
};

// The JSON "params" field changes based on the "method". Initially, we just
// capture the raw json object (including the opening and closing braces).
// Then, when we're processing the message, and we know what type it is, we
// can parse it (in Disaptch(T).params).
const InputParams = struct {
    raw: []const u8,

    pub fn jsonParse(
        _: Allocator,
        scanner: *json.Scanner,
        _: json.ParseOptions,
    ) !InputParams {
        const height = scanner.stackHeight();

        const start = scanner.cursor;
        if (try scanner.next() != .object_begin) {
            return error.UnexpectedToken;
        }
        try scanner.skipUntilStackHeight(height);
        const end = scanner.cursor;

        return .{ .raw = scanner.input[start..end] };
    }
};

fn asUint(comptime T: type, comptime string: []const u8) T {
    return @bitCast(string[0..string.len].*);
}

const testing = @import("testing.zig");
test "cdp: invalid json" {
    var ctx = testing.context();
    defer ctx.deinit();

    try testing.expectError(error.InvalidJSON, ctx.processMessage("invalid"));

    // method is required
    try testing.expectError(error.InvalidJSON, ctx.processMessage(.{}));

    try testing.expectError(error.InvalidMethod, ctx.processMessage(.{
        .method = "Target",
    }));
    try ctx.expectSentError(-31998, "InvalidMethod", .{});

    try testing.expectError(error.UnknownDomain, ctx.processMessage(.{
        .method = "Unknown.domain",
    }));

    try testing.expectError(error.UnknownMethod, ctx.processMessage(.{
        .method = "Target.over9000",
    }));
}

test "cdp: invalid sessionId" {
    var ctx = testing.context();
    defer ctx.deinit();

    {
        // we have no browser context
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "nope" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }

    {
        // we have a brower context but no session_id
        _ = try ctx.loadBrowserContext(.{});
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "BC-Has-No-SessionId" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }

    {
        // we have a brower context with a different session_id
        _ = try ctx.loadBrowserContext(.{ .session_id = "SESS-2" });
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "SESS-1" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }
}

test "cdp: STARTUP sessionId" {
    var ctx = testing.context();
    defer ctx.deinit();

    {
        // we have no browser context
        try ctx.processMessage(.{ .id = 2, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 2, .index = 0, .session_id = "STARTUP" });
    }

    {
        // we have a brower context but no session_id
        _ = try ctx.loadBrowserContext(.{});
        try ctx.processMessage(.{ .id = 3, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 3, .index = 0, .session_id = "STARTUP" });
    }

    {
        // we have a brower context with a different session_id
        _ = try ctx.loadBrowserContext(.{ .session_id = "SESS-2" });
        try ctx.processMessage(.{ .id = 4, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 4, .index = 0, .session_id = "STARTUP" });
    }
}
