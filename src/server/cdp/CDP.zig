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
const lp = @import("lightpanda");

const App = @import("../../App.zig");
const Inbox = @import("../../Inbox.zig");
const Notification = @import("../../Notification.zig");

const sys_net = @import("../../sys/net.zig");
const HttpClient = @import("../../network/HttpClient.zig");

const Page = @import("../../browser/Page.zig");
const Frame = @import("../../browser/Frame.zig");
const Browser = @import("../../browser/Browser.zig");
const Session = @import("../../browser/Session.zig");

const WS = @import("../WS.zig");
const Link = @import("../Link.zig");
const Incrementing = @import("id.zig").Incrementing;
pub const Target = @import("Target.zig");

const network_domain = @import("domains/network.zig");

const js = lp.js;
const log = lp.log;
const json = std.json;
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const URL_BASE = "chrome://newtab/";

const SessionIdGen = Incrementing(u32, "SID");
const BrowserSessionIdGen = Incrementing(u32, "BSID");
const BrowserContextIdGen = Incrementing(u32, "BID");
// webmcp tool invocation
pub const InvocationIdGen = Incrementing(u32, "INV");

// Generic so that we can inject mocks into it.
const CDP = @This();

app: *App,
link: Link,
browser: Browser,
allocator: Allocator,

// when true, any target creation must be attached.
target_auto_attach: bool = false,

// Target.setDiscoverTargets: when true, page target changes are reported
// via Target.targetInfoChanged.
target_discover: bool = false,

session_id_gen: SessionIdGen = .{},
browser_session_id_gen: BrowserSessionIdGen = .{},
browser_context_id_gen: BrowserContextIdGen = .{},

// Session from Target.attachToBrowserTarget. Distinct from the page
// session (BrowserContext.session_id) as it targets the browser itself and
// outlives any browser context.
browser_session_id: ?[]const u8 = null,

browser_context: ?BrowserContext,
disable_set_cache_disabled: bool = false,

// Re-used arena for processing a message. Works because we strictly process
// one message at a time.
message_arena: std.heap.ArenaAllocator,

// Retained until the outermost notification handler returns.
notification_arena: std.heap.ArenaAllocator,
notification_depth: u32 = 0,

// Valid for the entire lifetime of the BrowserContext. Should minimize
// (or altogether eliminate) our use of this.
browser_context_arena: std.heap.ArenaAllocator,

// Files handed out as IO stream handles (Page.printToPDF ReturnAsStream).
streams: @import("domains/io.zig").Streams,

pub fn init(self: *CDP, app: *App, socket: posix.socket_t, inbox: *Inbox) !void {
    const allocator = app.allocator;
    {
        // this is documentation, and future-proofing, to show exactly where
        // the socket's ownership is
        errdefer sys_net.close(socket);

        self.* = .{
            .app = app,
            .link = undefined,
            .browser = undefined,
            .allocator = allocator,
            .browser_context = null,
            .message_arena = std.heap.ArenaAllocator.init(allocator),
            .notification_arena = std.heap.ArenaAllocator.init(allocator),
            .browser_context_arena = std.heap.ArenaAllocator.init(allocator),
            .streams = .{ .allocator = allocator },
        };
    }

    // takes ownership of the socket
    try self.link.init(app, socket, .cdp, inbox);
    errdefer self.link.deinit();

    try self.browser.init(app, .{ .env = .{ .with_inspector = true } });
}

pub fn deinit(self: *CDP) void {
    if (self.browser_context) |*bc| {
        bc.deinit();
    }
    self.browser.deinit();
    self.message_arena.deinit();
    self.notification_arena.deinit();
    self.browser_context_arena.deinit();
    self.streams.deinit();
    self.link.deinit();
}
// Called by the Server run loop when readable bytes arrive on the CDP
// socket. Feeds them through the WS framer and pushes each parsed frame
// into the worker's inbox. Returns false if a close frame was seen (or a
// fatal frame error) so the loop drops the link from its poll set.
//
// Called in the Worker to dispatch a single CDP message bubbled up by
// HttpClient.drainInbox. The Server run loop already parsed the JSON
// when it pushed the message to the inbox, so we skip straight to
// dispatchParsed without re-parsing. `c.raw` and `c.arena` outlive
// this call (they're owned by the inbox Message which drainInbox
// frees right after we return), so `c.input`'s string slices stay
// valid for the duration of dispatch.
pub fn onMessage(self: *CDP, c: *Inbox.Message.Cdp) anyerror!void {
    // Once a terminate is pending, don't dispatch
    if (self.browser.env.terminatePending()) {
        return;
    }

    const arena = &self.message_arena;
    defer _ = arena.reset(.{ .retain_with_limit = 1024 * 16 });
    return self.dispatchParsed(arena.allocator(), .{ .cdp = self }, c.raw, c.input, null);
}

// Parse + dispatch a raw JSON CDP message. Used by tests (which
// don't go through the Network thread / inbox pipeline) and by any
// caller that has bytes rather than a pre-parsed InputMessage.
pub fn processMessage(self: *CDP, msg: []const u8) !void {
    const arena = &self.message_arena;
    defer _ = arena.reset(.{ .retain_with_limit = 1024 * 16 });
    return self.dispatch(arena.allocator(), .{ .cdp = self }, msg, null);
}

pub const SendJSONOpts = struct {
    size_hint: usize = 0,
};
pub fn sendJSON(self: *CDP, message: anytype, opts: SendJSONOpts) !void {
    try self.link.sendJSON(message, .{
        .size_hint = opts.size_hint,
        .stringify = .{ .emit_null_optional_fields = false },
    });
}

// Parse-then-dispatch entry point. Used by:
//   - CDP.processMessage (tests, and any other caller that hands us
//     raw JSON bytes).
//   - Target.sendMessageToTarget (a CDP command that wraps another
//     CDP message as a string parameter and forwards it through the
//     dispatch table).
// The normal Network-thread path doesn't go through here — it parses
// once on the Network thread and reaches dispatchParsed directly via
// onMessage.
// `target_session_id` routes a page command that has no sessionId of its own
// (Target.sendMessageToTarget wraps one).
pub fn dispatch(self: *CDP, arena: Allocator, sender: Command.Sender, str: []const u8, target_session_id: ?[]const u8) !void {
    const input = json.parseFromSliceLeaky(InputMessage, arena, str, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJSON;
    return self.dispatchParsed(arena, sender, str, input, target_session_id);
}

// Dispatch a pre-parsed CDP message. The caller is responsible for
// keeping `str` and the backing storage for `input`'s string slices
// alive for the duration of the call.
fn dispatchParsed(self: *CDP, arena: Allocator, sender: Command.Sender, str: []const u8, input: InputMessage, target_session_id: ?[]const u8) !void {
    lp.metrics.serve_commands.incr(.cdp);

    var command = Command{
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
        .target_session_id = target_session_id,
    };

    // See dispatchStartupCommand for more info on this.
    var is_startup = false;
    if (input.sessionId) |input_session_id| {
        if (std.mem.eql(u8, input_session_id, "STARTUP")) {
            is_startup = true;
        } else if (self.isValidSessionId(input_session_id) == false) {
            return command.sendError(-32001, "Unknown sessionId", .{});
        }
    }

    if (is_startup) {
        dispatchStartupCommand(&command, input.method) catch |err| {
            command.sendError(-31999, @errorName(err), .{}) catch return err;
        };
    } else {
        dispatchCommand(&command, input.method) catch |err| {
            switch (err) {
                error.InvalidMethod, error.UnknownDomain, error.UnknownMethod => {
                    lp.metrics.serve_unknown_commands.incr(.cdp);
                    // Chrome's code and wording; drivers feature-detect on it.
                    const message = command.arena.print("'{s}' wasn't found", .{input.method}) catch return err;
                    command.sendError(-32601, message, .{}) catch return err;
                },
                else => command.sendError(-31998, @errorName(err), .{}) catch return err,
            }
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
fn dispatchStartupCommand(command: *Command, method: []const u8) !void {
    // Stagehand parses the response and error if we don't return a
    // correct one for Page.getFrameTree on startup call.
    if (std.mem.eql(u8, method, "Page.getFrameTree")) {
        // The Page.getFrameTree handles startup response gracefully.
        return dispatchCommand(command, method);
    }

    // The placeholder session has no page behind it: an empty
    // result would look like success while nothing happened.
    // Say so, and point at the way to get a real target.
    if (std.mem.eql(u8, method, "Page.navigate")) {
        return command.sendError(-32000, "No page on the STARTUP session; create a real target with Target.createTarget", .{});
    }

    return command.sendResult(null, .{});
}

fn dispatchCommand(command: *Command, method: []const u8) !void {
    const domain = blk: {
        const i = std.mem.findScalarPos(u8, method, 0, '.') orelse {
            return error.InvalidMethod;
        };
        command.input.action = method[i + 1 ..];
        break :blk method[0..i];
    };

    switch (domain.len) {
        2 => switch (@as(u16, @bitCast(domain[0..2].*))) {
            asUint(u16, "LP") => return @import("domains/lp.zig").processMessage(command),
            asUint(u16, "IO") => return @import("domains/io.zig").processMessage(command),
            else => {},
        },
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
            asUint(u48, "Audits") => return @import("domains/audits.zig").processMessage(command),
            asUint(u48, "WebMCP") => return @import("domains/webmcp.zig").processMessage(command),
            else => {},
        },
        7 => switch (@as(u56, @bitCast(domain[0..7].*))) {
            asUint(u56, "Browser") => return @import("domains/browser.zig").processMessage(command),
            asUint(u56, "Runtime") => return @import("domains/runtime.zig").processMessage(command),
            asUint(u56, "Network") => return network_domain.processMessage(command),
            asUint(u56, "Storage") => return @import("domains/storage.zig").processMessage(command),
            asUint(u56, "Console") => return @import("domains/console.zig").processMessage(command),
            else => {},
        },
        8 => switch (@as(u64, @bitCast(domain[0..8].*))) {
            asUint(u64, "Security") => return @import("domains/security.zig").processMessage(command),
            asUint(u64, "Debugger") => return @import("domains/debugger.zig").processMessage(command),
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
        13 => switch (@as(u104, @bitCast(domain[0..13].*))) {
            asUint(u104, "Accessibility") => return @import("domains/accessibility.zig").processMessage(command),
            else => {},
        },

        else => {},
    }

    return error.UnknownDomain;
}

pub fn resolveSessionId(self: *const CDP, input_session_id: []const u8) ?[]const u8 {
    if (self.browser_session_id) |browser_session_id| {
        if (std.mem.eql(u8, browser_session_id, input_session_id)) {
            return browser_session_id;
        }
    }
    const browser_context = if (self.browser_context) |*bc| bc else return null;
    return browser_context.attached_sessions.getKey(input_session_id);
}

fn isValidSessionId(self: *const CDP, input_session_id: []const u8) bool {
    return self.resolveSessionId(input_session_id) != null;
}

pub fn createBrowserContext(self: *CDP) ![]const u8 {
    if (self.browser_context != null) {
        return error.AlreadyExists;
    }
    const id = self.browser_context_id_gen.next();

    self.browser_context = @as(BrowserContext, undefined);
    const browser_context = &self.browser_context.?;

    try BrowserContext.init(browser_context, id, self);
    return id;
}

pub fn disposeBrowserContext(self: *CDP) void {
    const bc = &(self.browser_context orelse return);
    bc.deinit();
    self.browser.closeSession();
    self.browser_context = null;
    _ = self.browser_context_arena.reset(.{ .retain_with_limit = 1024 * 16 });
}

const SendEventOpts = struct {
    session_id: ?[]const u8 = null,
};
pub fn sendEvent(self: *CDP, method: []const u8, p: anytype, opts: SendEventOpts) !void {
    return self.sendJSON(.{
        .method = method,
        .params = if (comptime @typeInfo(@TypeOf(p)) == .null) struct {}{} else p,
        .sessionId = opts.session_id,
    }, .{});
}

pub const BrowserContext = struct {
    // A CDP session attached to a page target. Each owns a V8 inspector
    // session; V8 keeps `Runtime.enable` state and remote object ids per
    // session, so a command is answered on the session it was sent through
    // and a session only gets the inspector events it enabled.
    pub const AttachedSession = struct {
        id: []const u8,
        parent_id: ?[]const u8,
        target: *Target,
        inspector_session: js.Inspector.Session,

        /// V8 -> this session. Stamp OUR id on responses and events.
        pub fn onInspectorResponse(ctx: *anyopaque, _: u32, msg: []const u8) void {
            const self: *AttachedSession = @ptrCast(@alignCast(ctx));
            self.target.bc.sendInspectorMessage(msg, self.id) catch |err| {
                log.debug(.cdp, "send inspector response", .{ .err = err });
            };
        }

        pub fn onInspectorEvent(ctx: *anyopaque, msg: []const u8) void {
            const self: *AttachedSession = @ptrCast(@alignCast(ctx));
            if (log.enabled(.cdp, .debug)) {
                // msg should be {"method":<method>,...
                lp.assert(std.mem.startsWith(u8, msg, "{\"method\":"), "onInspectorEvent prefix", .{});
                const method_end = std.mem.findScalar(u8, msg, ',') orelse {
                    log.err(.cdp, "invalid inspector event", .{ .msg = msg });
                    return;
                };
                const method = msg[10..method_end];
                log.debug(.cdp, "inspector event", .{ .method = method, .session_id = self.id });
            }

            self.target.bc.sendInspectorMessage(msg, self.id) catch |err| {
                log.debug(.cdp, "send inspector event", .{ .err = err });
            };
        }
    };
    id: []const u8,
    cdp: *CDP,

    // Represents the browser session. There is no equivalent in CDP. For
    // all intents and purpose, from CDP's point of view our Browser and
    // our Session more or less maps to a BrowserContext. THIS HAS ZERO
    // RELATION TO SESSION_ID
    session: *Session,

    // Tied to the lifetime of the BrowserContext
    arena: Allocator,

    // From the parent's notification_arena.allocator(). Most of the CDP
    // code paths deal with a cmd which has its own arena (from the
    // message_arena). But notifications happen outside of the typical CDP
    // request->response, and thus don't have a cmd and don't have an arena.
    notification_arena: Allocator,

    // The page targets, in creation order. Each maps to one top-level Page
    // of `session`.
    targets: std.ArrayList(*Target) = .empty,

    // Inspector context group of the next target. Never 0.
    next_group_id: js.Inspector.GroupId = 1,

    // Every session attached to a page target, by session id.
    // Insertion-ordered so detach events come out in attach order.
    //
    // Request with a session id that isn't there is rejected.
    attached_sessions: std.StringArrayHashMapUnmanaged(*AttachedSession) = .empty,

    http_proxy_changed: bool = false,
    user_agent_changed: bool = false,

    notification: *Notification,

    fn init(self: *BrowserContext, id: []const u8, cdp: *CDP) !void {
        const allocator = cdp.allocator;

        // Create notification for this BrowserContext
        const notification = try Notification.init(allocator);
        errdefer notification.deinit();

        const session = try cdp.browser.newSession(notification);
        if (cdp.app.config.cookieFile()) |cookie_path| {
            lp.cookies.loadFromFile(session, cookie_path);
        }

        self.* = .{
            .id = id,
            .cdp = cdp,
            .session = session,
            .arena = cdp.browser_context_arena.allocator(),
            .notification_arena = cdp.notification_arena.allocator(),
            .notification = notification,
        };
        errdefer self.deinit();

        try notification.register(.frame_remove, self, onFrameRemove);
        try notification.register(.frame_created, self, onFrameCreated);
        try notification.register(.frame_navigate, self, onFrameNavigate);
        try notification.register(.frame_navigated, self, onFrameNavigated);
        try notification.register(.frame_navigated_within_document, self, onFrameNavigatedWithinDocument);
        try notification.register(.frame_navigate_failed, self, onFrameNavigateFailed);
        try notification.register(.frame_child_frame_created, self, onFrameChildFrameCreated);
        try notification.register(.frame_child_frame_detached, self, onFrameChildFrameDetached);
        try notification.register(.frame_destroyed, self, onFrameDestroyed);
        try notification.register(.frame_dom_content_loaded, self, onFrameDOMContentLoaded);
        try notification.register(.frame_loaded, self, onFrameLoaded);
        try notification.register(.javascript_dialog_opening, self, onJavascriptDialogOpening);
    }

    pub fn deinit(self: *BrowserContext) void {
        const browser = &self.cdp.browser;
        const allocator = self.cdp.allocator;

        // resetContextGroup detach the inspector from all contexts.
        // It appends async tasks, so we make sure we run the message loop
        // before deinit it.
        for (self.targets.items) |target| {
            self.inspector().resetContextGroup(target.group_id);
        }
        self.detachAllSessions();

        // Before closeSession: the targets must not process any new
        // notification, and their isolated world contexts must go before
        // the page contexts they're nested in.
        for (self.targets.items) |target| {
            target.destroy();
        }
        self.targets.deinit(allocator);

        self.notification.unregisterAll(self);
        browser.closeSession();

        self.attached_sessions.deinit(allocator);

        // Session.deinit (called via closeSession above) already cleared this
        // notification off any ownerless CorsGate/RobotsGate transfers.
        self.notification.deinit();

        if (self.http_proxy_changed) {
            // has to be called after browser.closeSession, since it won't
            // work if there are active connections.
            browser.http_client.changeProxy(null) catch |err| {
                log.warn(.http, "changeProxy", .{ .err = err });
            };
        }
        if (self.user_agent_changed) {
            browser.http_client.clearUserAgentOverride();
        }
        browser.http_client.clearAcceptLanguageOverride();
    }

    // A new target, not bound to a page yet: the next page created in the
    // session gets it (see onFrameCreated).
    pub fn createTarget(self: *BrowserContext) !*Target {
        const target = try Target.create(self, self.next_group_id);
        errdefer target.destroy();
        try self.targets.append(self.cdp.allocator, target);
        self.next_group_id += 1;
        return target;
    }

    // Closes `target` and its page, then frees it.
    pub fn closeTarget(self: *BrowserContext, target: *Target) !void {
        defer self.removeTarget(target);
        try target.close();
    }

    // Frees `target`, which must be closed (see Target.close).
    fn removeTarget(self: *BrowserContext, target: *Target) void {
        if (std.mem.findScalar(*Target, self.targets.items, target)) |i| {
            _ = self.targets.orderedRemove(i);
        }
        target.destroy();
    }

    pub fn firstTarget(self: *const BrowserContext) ?*Target {
        return if (self.targets.items.len == 0) null else self.targets.items[0];
    }

    // The target the client knows by `target_id`.
    pub fn findTarget(self: *const BrowserContext, target_id: []const u8) ?*Target {
        for (self.targets.items) |target| {
            const tid = target.target_id orelse continue;
            if (std.mem.eql(u8, &tid, target_id)) {
                return target;
            }
        }
        return null;
    }

    pub fn findTargetByFrameId(self: *const BrowserContext, frame_id: u32) ?*Target {
        for (self.targets.items) |target| {
            if (target.frame_id == frame_id) {
                return target;
            }
        }
        return null;
    }

    // The target whose page `frame_id` belongs to: its root frame, a child
    // frame or a popup.
    pub fn targetForFrame(self: *const BrowserContext, frame_id: u32) ?*Target {
        if (self.findTargetByFrameId(frame_id)) |target| {
            return target;
        }
        const frame = self.session.findFrameByFrameId(frame_id) orelse return null;
        return self.findTargetByFrameId(frame.page.frame._frame_id);
    }

    fn onFrameRemove(ctx: *anyopaque, event: Notification.FrameRemove) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.findTargetByFrameId(event.frame_id) orelse return;
        @import("domains/page.zig").frameRemove(target);
    }

    // A new top-level Page, or the replacement of one after a root
    // navigation (same frame id). A new page binds the target created for
    // it (Target.createTarget) or, created another way, gets its own,
    // reported on Target.setAutoAttach.
    fn onFrameCreated(ctx: *anyopaque, frame: *Frame) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.findTargetByFrameId(frame._frame_id) orelse blk: {
            for (self.targets.items) |target| {
                if (target.frame_id == null) {
                    break :blk target;
                }
            }
            break :blk try self.createTarget();
        };
        target.frame_id = frame._frame_id;
        return @import("domains/page.zig").frameCreated(target);
    }

    fn onFrameNavigate(ctx: *anyopaque, msg: *const Notification.FrameNavigate) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.targetForFrame(msg.frame_id) orelse return;
        return @import("domains/page.zig").frameNavigate(target, msg);
    }

    fn onFrameNavigated(ctx: *anyopaque, msg: *const Notification.FrameNavigated) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.targetForFrame(msg.frame_id) orelse return;
        const arena = self.acquireNotificationArena();
        defer self.releaseNotificationArena();
        return @import("domains/page.zig").frameNavigated(arena, target, msg);
    }

    fn onFrameNavigateFailed(ctx: *anyopaque, msg: *const Notification.FrameNavigateFailed) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.targetForFrame(msg.frame_id) orelse return;
        return @import("domains/page.zig").frameNavigateFailed(target, msg);
    }

    fn onFrameNavigatedWithinDocument(ctx: *anyopaque, msg: *const Notification.FrameNavigatedWithinDocument) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.targetForFrame(msg.frame_id) orelse return;
        return @import("domains/page.zig").frameNavigatedWithinDocument(target, msg);
    }

    fn onFrameDestroyed(ctx: *anyopaque, frame: *const Frame) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.findTargetByFrameId(frame.page.frame._frame_id) orelse return;
        @import("domains/page.zig").frameDestroyed(target, frame);
    }

    fn onFrameChildFrameCreated(ctx: *anyopaque, msg: *const Notification.FrameChildFrameCreated) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.targetForFrame(msg.parent_id) orelse return;
        return @import("domains/page.zig").frameChildFrameCreated(target, msg);
    }

    fn onFrameChildFrameDetached(ctx: *anyopaque, msg: *const Notification.FrameChildFrameDetached) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.targetForFrame(msg.parent_id) orelse return;
        return @import("domains/page.zig").frameChildFrameDetached(target, msg);
    }

    fn onFrameDOMContentLoaded(ctx: *anyopaque, msg: *const Notification.FrameDOMContentLoaded) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.targetForFrame(msg.frame_id) orelse return;
        return @import("domains/page.zig").frameDOMContentLoaded(target, msg);
    }

    fn onFrameLoaded(ctx: *anyopaque, msg: *const Notification.FrameLoaded) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.targetForFrame(msg.frame_id) orelse return;
        return @import("domains/page.zig").frameLoaded(target, msg);
    }

    fn onJavascriptDialogOpening(ctx: *anyopaque, msg: *const Notification.JavascriptDialogOpening) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        const target = self.findTargetByFrameId(msg.page_id) orelse return;
        return @import("domains/page.zig").javascriptDialogOpening(target, msg);
    }

    // Registers for the download notifications dispatched by Frame when a
    // navigation is treated as a file download. Idempotent. See issue #2701.
    // Browser-level events: not tied to a target.
    pub fn downloadEventsEnable(self: *BrowserContext) !void {
        try self.notification.register(.download_will_begin, self, onDownloadWillBegin);
        try self.notification.register(.download_progress, self, onDownloadProgress);
    }

    pub fn downloadEventsDisable(self: *BrowserContext) void {
        self.notification.unregister(.download_will_begin, self);
        self.notification.unregister(.download_progress, self);
    }

    fn onDownloadWillBegin(ctx: *anyopaque, msg: *const Notification.DownloadWillBegin) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/browser.zig").downloadWillBegin(self, msg);
    }

    fn onDownloadProgress(ctx: *anyopaque, msg: *const Notification.DownloadProgress) !void {
        const self: *BrowserContext = @ptrCast(@alignCast(ctx));
        return @import("domains/browser.zig").downloadProgress(self, msg);
    }

    pub fn acquireNotificationArena(self: *BrowserContext) Allocator {
        self.cdp.notification_depth += 1;
        return self.notification_arena;
    }

    pub fn releaseNotificationArena(self: *BrowserContext) void {
        self.cdp.notification_depth -= 1;
        if (self.cdp.notification_depth == 0) {
            _ = self.cdp.notification_arena.reset(.{ .retain_with_limit = 1024 * 64 });
        }
    }

    pub inline fn inspector(self: *const BrowserContext) *js.Inspector {
        return self.cdp.browser.env.inspector.?;
    }

    /// Attaches `session_id` to `target` with its own inspector session.
    /// The id is copied into the context's arena.
    pub fn attachSession(self: *BrowserContext, target: *Target, session_id: []const u8, parent_id: ?[]const u8) !*AttachedSession {
        if (self.attached_sessions.contains(session_id)) {
            return error.SessionAlreadyAttached;
        }
        const allocator = self.cdp.allocator;

        const attached = try allocator.create(AttachedSession);
        errdefer allocator.destroy(attached);

        attached.* = .{
            .id = try self.arena.dupe(u8, session_id),
            .parent_id = parent_id,
            .target = target,
            .inspector_session = undefined,
        };
        attached.inspector_session.init(self.inspector(), target.group_id, attached);
        errdefer attached.inspector_session.deinit();

        try self.attached_sessions.put(allocator, attached.id, attached);
        return attached;
    }

    /// Stops the session's inspector session and forgets it.
    /// Returns false when no such session is attached.
    pub fn detachSession(self: *BrowserContext, session_id: []const u8) bool {
        const kv = self.attached_sessions.fetchOrderedRemove(session_id) orelse return false;
        const target = kv.value.target;
        if (target.session_id) |primary| {
            if (std.mem.eql(u8, primary, session_id)) {
                target.session_id = null;
            }
        }
        self.destroySession(kv.value);
        return true;
    }

    // Detaches every session attached to `target`.
    pub fn detachTargetSessions(self: *BrowserContext, target: *Target) void {
        var i: usize = 0;
        while (i < self.attached_sessions.count()) {
            const attached = self.attached_sessions.values()[i];
            if (attached.target != target) {
                i += 1;
                continue;
            }
            self.attached_sessions.orderedRemoveAt(i);
            self.destroySession(attached);
        }
        target.session_id = null;
    }

    pub fn detachAllSessions(self: *BrowserContext) void {
        for (self.attached_sessions.values()) |attached| {
            self.destroySession(attached);
        }
        self.attached_sessions.clearRetainingCapacity();
        for (self.targets.items) |target| {
            target.session_id = null;
        }
    }

    fn destroySession(self: *BrowserContext, attached: *AttachedSession) void {
        attached.inspector_session.deinit();
        self.cdp.allocator.destroy(attached);
    }

    // This is hacky x 2. First, we create the JSON payload by gluing the
    // session_id onto it. Second, we're much more client/websocket aware than
    // we should be.
    fn sendInspectorMessage(self: *BrowserContext, msg: []const u8, session_id: []const u8) !void {
        const cdp = self.cdp;
        const allocator = cdp.link.acquireSendArena();
        defer cdp.link.releaseSendArena();

        const field = ",\"sessionId\":\"";

        // + 1 for the closing quote after the session id
        // + 10 for the max websocket header
        const message_len = msg.len + session_id.len + 1 + field.len + 10;

        var buf: std.ArrayList(u8) = .empty;
        buf.ensureTotalCapacityPrecise(allocator, message_len) catch |err| {
            log.err(.cdp, "inspector buffer", .{ .err = err });
            return;
        };

        // reserve 10 bytes for websocket header
        buf.appendSliceAssumeCapacity(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

        // -1  because we don't want the closing brace '}'
        buf.appendSliceAssumeCapacity(msg[0 .. msg.len - 1]);
        buf.appendSliceAssumeCapacity(field);
        buf.appendSliceAssumeCapacity(session_id);
        buf.appendSliceAssumeCapacity("\"}");
        if (comptime lp.IS_DEBUG) {
            std.debug.assert(buf.items.len == message_len);
        }

        try cdp.link.sendJSONRaw(buf);
    }
};

/// see: https://chromium.googlesource.com/chromium/src/+/master/third_party/blink/renderer/bindings/core/v8/V8BindingDesign.md#world
/// The current understanding. An isolated world lives in the same isolate, but a separated context.
/// Clients create this to be able to create variables and run code without interfering with the
/// normal namespace and values of the webframe. Similar to the main context we need to pretend to recreate it after
/// a executionContextsCleared event which happens when navigating to a new frame. A client can have a command be executed
/// An isolated world is identified by its name and has one V8::Context per
/// frame it has been seeded into. A world enters a frame on an explicit
/// trigger: Page.createIsolatedWorld or, or a preload script which is seeded
/// into every frame. Once seeded, the frame's context is rebuilt on every
/// navigation with no further client involvement.
/// Frame ids are stable across a child frame's re-navigation (the Frame is
/// torn down and re-initialized in place), so a per-frame context is removed
/// on frame_destroyed and created again on the frame's next frame_navigated.
pub const IsolatedWorld = struct {
    arena: *lp.Arena,
    browser: *Browser,
    name: []const u8,
    grant_universal_access: bool,
    contexts: std.ArrayList(FrameContext) = .empty,

    // Frames this world has been seeded into, by frame id.
    seeded_frames: std.ArrayList(u32) = .empty,

    // Identity tracking for this isolated world (separate from main world).
    // Shared by all of the world's frame contexts, like the main world shares
    // Page.identity across frames, and reset with them on root teardown.
    identity: js.Identity = .{},

    const FrameContext = struct {
        frame: *const Frame,
        context: *js.Context,
        // Per-context, not per-world: the call_arena is reset when a context's
        // call depth returns to 0, which would free the data of another frame's
        // in-flight call if they shared one.
        call_arena: *lp.Arena,
        local_arena: *lp.Arena,
    };

    pub fn deinit(self: *IsolatedWorld) void {
        self.removeAllContexts();
        self.arena.release();
    }

    pub fn seed(self: *IsolatedWorld, frame_id: u32) !void {
        if (self.isSeeded(frame_id)) {
            return;
        }
        return self.seeded_frames.append(self.arena.allocator(), frame_id);
    }

    pub fn isSeeded(self: *const IsolatedWorld, frame_id: u32) bool {
        return std.mem.findScalar(u32, self.seeded_frames.items, frame_id) != null;
    }

    // Keyed by Frame, not frame id: a retired root Page keeps its frame id
    // while its deferred teardown is pending, and that teardown must not
    // touch the live page's context.
    pub fn contextFor(self: *const IsolatedWorld, frame: *const Frame) ?*js.Context {
        for (self.contexts.items) |fc| {
            if (fc.frame == frame) {
                return fc.context;
            }
        }
        return null;
    }

    // Callers must register the returned context with the inspector
    pub fn createContext(self: *IsolatedWorld, frame: *Frame) !*js.Context {
        lp.assert(self.contextFor(frame) == null, "IsolatedWorld.createContext duplicate", .{ .frame_id = frame._frame_id });

        const browser = self.browser;
        const call_arena = try browser.arena_pool.acquire(.tiny, "IsolatedWorld.call_arena");
        errdefer call_arena.release();

        const local_arena = try browser.arena_pool.acquire(.tiny, "IsolatedWorld.local_arena");
        errdefer local_arena.release();

        const ctx = try browser.env.createContext(frame, .{
            .identity = &self.identity,
            .identity_arena = self.arena.allocator(),
            .call_arena = call_arena.allocator(),
            .local_arena = local_arena.allocator(),
            .debug_name = "IsolatedContext",
        });
        errdefer browser.env.destroyContext(ctx);
        try ctx.setOrigin(frame.origin);

        try self.contexts.append(self.arena.allocator(), .{
            .frame = frame,
            .context = ctx,
            .call_arena = call_arena,
            .local_arena = local_arena,
        });
        return ctx;
    }

    pub fn removeContext(self: *IsolatedWorld, frame: *const Frame) void {
        for (self.contexts.items, 0..) |fc, i| {
            if (fc.frame == frame) {
                self.destroyFrameContext(fc);
                _ = self.contexts.swapRemove(i);
                return;
            }
        }
    }

    pub fn removeAllContexts(self: *IsolatedWorld) void {
        for (self.contexts.items) |fc| {
            self.destroyFrameContext(fc);
        }
        self.contexts.clearRetainingCapacity();

        // The page's objects are going away with the root frame; wrappers
        // keyed by their addresses must not survive to alias a new page's.
        self.identity.deinit();
        self.identity = .{};
    }

    fn destroyFrameContext(self: *IsolatedWorld, fc: FrameContext) void {
        self.browser.env.destroyContext(fc.context);
        fc.call_arena.release();
        fc.local_arena.release();
    }
};

// This is a generic because when we send a result we have two different
// behaviors. Normally, we're sending the result to the client. But in some cases
// we want to capture the result. So we want the command.sendResult to be
// generic.
pub const Command = struct {
    // A misc arena that can be used for any allocation for processing
    // the message
    arena: Allocator,

    // reference to our CDP instance
    cdp: *CDP,

    // The browser context this command targets
    browser_context: ?*BrowserContext,

    // The session to route the command to when it has no sessionId of its
    // own, see dispatch.
    target_session_id: ?[]const u8 = null,

    // The command input (the id, optional session_id, params, ...)
    input: Input,

    // In most cases, Sender is going to be cdp itself. We'll call
    // sender.sendJSON() and CDP will send it to the client. But some
    // commands are dispatched internally, in which cases the Sender will
    // be code to capture the data that we were "sending".
    sender: Sender,

    const Sender = union(enum) {
        cdp: *CDP,
        capture: *std.Io.Writer,

        pub fn sendJSON(self: Sender, message: anytype, opts: SendJSONOpts) !void {
            switch (self) {
                .cdp => |cdp| return cdp.sendJSON(message, opts),
                .capture => |writer| {
                    return std.json.Stringify.value(message, .{
                        .emit_null_optional_fields = false,
                    }, writer);
                },
            }
        }
    };

    pub fn params(self: *const Command, comptime T: type) !?T {
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

    // The page target the command is for: the one of the session it was sent
    // through, else the first one, for clients that send page commands with
    // no session.
    pub fn target(self: *const Command) !*Target {
        const bc = self.browser_context orelse return error.BrowserContextNotLoaded;
        if (self.input.session_id orelse self.target_session_id) |session_id| {
            if (bc.attached_sessions.get(session_id)) |attached| {
                return attached.target;
            }
        }
        return bc.firstTarget() orelse error.TargetNotLoaded;
    }

    pub fn createBrowserContext(self: *Command) !*BrowserContext {
        _ = try self.cdp.createBrowserContext();
        self.browser_context = &(self.cdp.browser_context.?);
        return self.browser_context.?;
    }

    const SendResultOpts = struct {
        size_hint: usize = 0, // hint about the final serialized size
    };
    pub fn sendResult(self: *Command, result: anytype, opts: SendResultOpts) !void {
        return self.sender.sendJSON(.{
            .id = self.input.id,
            .result = if (comptime @typeInfo(@TypeOf(result)) == .null) struct {}{} else result,
            .sessionId = self.input.session_id,
        }, .{ .size_hint = opts.size_hint });
    }

    pub fn sendEvent(self: *Command, method: []const u8, p: anytype, opts: SendEventOpts) !void {
        // Events ALWAYS go to the client. self.sender should not be used
        return self.cdp.sendEvent(method, p, opts);
    }

    const SendErrorOpts = struct {};
    pub fn sendError(self: *Command, code: i32, message: []const u8, _: SendErrorOpts) !void {
        return self.sender.sendJSON(.{
            .id = self.input.id,
            .@"error" = .{ .code = code, .message = message },
            .sessionId = self.input.session_id,
        }, .{});
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

// When we parse a JSON message from the client, this is the structure
// we always expect. Parsed on the Network thread inside
// Link.handleMessage; the slices reference the raw JSON bytes
// (or arena allocations for fields that needed unescaping). Both
// outlive the InputMessage for the inbox message's lifetime.
pub const InputMessage = struct {
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
    var ctx = try testing.context();
    defer ctx.deinit();

    try testing.expectError(error.InvalidJSON, ctx.processMessage("invalid"));

    // method is required
    try testing.expectError(error.InvalidJSON, ctx.processMessage(.{}));

    try ctx.processMessage(.{
        .method = "Target",
    });
    try ctx.expectSentError(-32601, "'Target' wasn't found", .{});

    try ctx.processMessage(.{
        .method = "Unknown.domain",
    });
    try ctx.expectSentError(-32601, "'Unknown.domain' wasn't found", .{});

    try ctx.processMessage(.{
        .method = "Target.over9000",
    });
    try ctx.expectSentError(-32601, "'Target.over9000' wasn't found", .{});
}

test "cdp: invalid sessionId" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // we have no browser context
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "nope" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }

    {
        // we have a browser context but no session_id
        _ = try ctx.loadBrowserContext(.{});
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "BC-Has-No-SessionId" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }

    {
        // we have a browser context with a different session_id
        _ = try ctx.loadBrowserContext(.{ .session_id = "SESS-2" });
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "SESS-1" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }
}

test "cdp: STARTUP sessionId" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // we have no browser context
        try ctx.processMessage(.{ .id = 2, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 2, .index = 0, .session_id = "STARTUP" });
    }

    {
        // we have a browser context but no session_id
        _ = try ctx.loadBrowserContext(.{});
        try ctx.processMessage(.{ .id = 3, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 3, .index = 1, .session_id = "STARTUP" });
    }

    {
        // we have a browser context with a different session_id
        _ = try ctx.loadBrowserContext(.{ .session_id = "SESS-2" });
        try ctx.processMessage(.{ .id = 4, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 4, .index = 2, .session_id = "STARTUP" });
    }
}

test "cdp: Page.navigate on the STARTUP session returns -32000" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Page.navigate",
        .sessionId = "STARTUP",
        .params = .{ .url = "https://example.com" },
    });
    try ctx.expectSentError(-32000, "No page on the STARTUP session; create a real target with Target.createTarget", .{ .id = 1 });
}

test "cdp: disconnect latches so the worker keeps exiting" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const client = &ctx.cdp().browser.http_client;

    // Simulate the Server run loop delivering a peer disconnect into the
    // worker's inbox — the dropLink(notify=true) path used on peer EOF and,
    // since #2510, on shutdown via shutdownLinks.
    {
        const arena = try client.arena_pool.acquire(.tiny, "test disconnect");
        ctx.inbox.push(arena, .{ .disconnect = null });
    }

    // First tick drains the .disconnect and tears the link down.
    try testing.expectError(error.ClientDisconnected, client.tick(0));

    // The inbox is now empty. Without the latch this second tick would fall
    // through to perform/poll with no producer left to wake it, so the worker
    // would never exit and Server.deinit() would spin on active_threads
    // (#2510). The latch keeps the terminal state sticky so the worker exits.
    try testing.expectError(error.ClientDisconnected, client.tick(0));
}

test "cdp: run sends a close frame on pending terminate" {
    testing.expectLog(&.{.cdp});

    var ctx = try testing.context();
    defer ctx.deinit();

    const cdp = ctx.cdp();
    cdp.browser.env.requestTerminate();
    // Clear the pending terminate so deinit's V8 calls don't trip over the
    // terminating-state asserts.
    defer cdp.browser.env.cancelTerminate();

    // The pending terminate makes the first tick the last one, so run returns.
    ctx.driver.run();

    // The client should receive a close frame (code 1001, going away), not
    // just an abrupt socket close.
    var buf: [WS.CLOSE_GOING_AWAY.len]u8 = undefined;
    const n = try posix.read(ctx.socket, &buf);
    try testing.expectEqualSlices(u8, &WS.CLOSE_GOING_AWAY, buf[0..n]);
}

test "cdp: syncRequest short-circuits after disconnect" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const client = &ctx.cdp().browser.http_client;

    // Latch disconnected via a drained disconnect (as above).
    {
        const arena = try client.arena_pool.acquire(.tiny, "test disconnect");
        ctx.inbox.push(arena, .{ .disconnect = null });
    }
    try testing.expectError(error.ClientDisconnected, client.tick(0));

    // A synchronous fetch attempted after the latch returns ClientDisconnected
    // without starting the request: syncRequest consumes (deinits) the
    // transfer on the early-return path, before any of the callbacks are
    // installed. The latch check runs before any req field is read, so the
    // rest are placeholders.
    const transfer = try client.newRequest(.{
        .method = .GET,
        .url = "http://127.0.0.1:9582/",
        .origin = null,
        .credentials_mode = .omit,
        .request_mode = .no_cors,
        .resource_type = .fetch,
        .shutdown_callback = HttpClient.noopShutdown,
    }, null);
    try testing.expectError(error.ClientDisconnected, transfer.submitSync(.{}));
}
