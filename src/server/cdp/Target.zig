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

//! A CDP page target: one top-level Page of the BrowserContext's Session and
//! the CDP state that belongs to it. A BrowserContext holds up to
//! `max_targets` of them; they share its cookies and storage.
//!
//! Notifications are dispatched session-wide, so a handler registered by a
//! target sees every page's events and keeps those of its own page.

const std = @import("std");
const lp = @import("lightpanda");

const CDP = @import("CDP.zig");
const Node = @import("Node.zig");
const AXNode = @import("AXNode.zig");
const NodeRegistry = @import("../../NodeRegistry.zig");
const Notification = @import("../../Notification.zig");

const http = @import("../../network/http.zig");
const HttpClient = @import("../../network/HttpClient.zig");

const Mime = @import("../../browser/Mime.zig");
const Page = @import("../../browser/Page.zig");
const Frame = @import("../../browser/Frame.zig");
const Session = @import("../../browser/Session.zig");
const Label = @import("../../browser/webapi/element/html/Label.zig");

const fetch = @import("domains/fetch.zig");
const network_domain = @import("domains/network.zig");

const js = lp.js;
const log = lp.log;
const Allocator = std.mem.Allocator;
const BrowserContext = CDP.BrowserContext;
const IsolatedWorld = CDP.IsolatedWorld;
const InterceptState = fetch.InterceptState;

const Target = @This();

pub const max_targets = 16;

const CapturedResponse = struct {
    must_encode: bool,
    // null once evicted (size limit). We keep the map entry so that we
    // can give an "evicted" error instead of "unknown"
    data: ?std.ArrayList(u8),
};

// Key for `captured_responses` / `captured_requests`. Documents are
// keyed by `loader_id`, everything else by `request_id` — the two
// id-spaces are independent counters and overlap numerically (loader 1
// / request 1, loader 2 / request 2, ...), so the map key has to carry
// the namespace or entries collide. The wire-format prefix (`LID-` /
// `REQ-`) provides the same disambiguation on lookup; see
// `idFromRequestId` in domains/network.zig.
pub const CapturedKey = struct {
    kind: enum { request, loader },
    id: u32,
};

const ScriptOnNewDocument = struct {
    identifier: u32,
    source: []const u8,
    // Page.addScriptToEvaluateOnNewDocument's worldName. null means the main
    // world. A named world is seeded into every frame (see IsolatedWorld).
    world_name: ?[]const u8,
};

bc: *BrowserContext,
cdp: *CDP,
session: *Session,

// The page's root frame id. Stable across navigations: a root navigation's
// replacement Page reuses it. null until the page exists (see
// BrowserContext.onFrameCreated).
frame_id: ?u32 = null,

// Set once the target is reported to the client: by Target.createTarget, or
// by Target.setAutoAttach for a page created another way.
target_id: ?[14]u8 = null,

// The V8 inspector context group of the page's contexts. The target's
// sessions connect to it, so they only see this page's contexts.
group_id: js.Inspector.GroupId,

// The primary CDP session's id. After the target is created, the client
// "attaches" to it (either explicitly or automatically). We return a
// "sessionId" which identifies this link. `sessionId` is the how the CDP
// client informs us what it's trying to manipulate. Also in the
// BrowserContext's `attached_sessions`.
session_id: ?[]const u8 = null,

// Lives as long as the target.
arena: std.heap.ArenaAllocator,

// Valid for 1 page navigation (what CDP calls a "renderer").
frame_arena: std.heap.ArenaAllocator,

// A cancelled text-less keyDown drops the char message that follows it
// (chromedp's keyDown/char/keyUp split), as Chrome does.
suppress_next_char: bool = false,

security_origin: []const u8 = CDP.URL_BASE,
secure_context_type: []const u8 = "Secure", // TODO = enum
page_life_cycle_events: bool = false,

node_registry: NodeRegistry,
node_search_list: Node.Search.List,

// Node ids a DOM.setChildNodes event was already sent for. CDP protocol
// bookkeeping; ids are never reused within a registry's lifetime, so
// entries evicted by resetFrame can linger harmlessly until reset.
set_child_nodes_sent: std.AutoHashMapUnmanaged(NodeRegistry.Id, void) = .empty,

isolated_worlds: std.ArrayList(*IsolatedWorld) = .empty,

// True when Runtime.evaluate has been run in the main world. Optimization
// so that, if it has _not_ and the page is on its initial about:blank, we
// can use the existing Frame/js.Context as-is.
main_world_touched: bool = false,

// Runtime.exceptionThrown's exceptionDetails.exceptionId.
next_exception_id: u32 = 1,

// Scripts registered via Page.addScriptToEvaluateOnNewDocument.
// Evaluated in each new document after navigation completes.
scripts_on_new_document: std.ArrayList(ScriptOnNewDocument) = .empty,
next_script_id: u32 = 1,

// Extra headers to add to all requests.
extra_headers: std.ArrayList(http.Header) = .empty,

intercept_state: InterceptState,
fetch_session_id: ?[]const u8 = null,

// Request bodies retained for Network.getRequestPostData, which can be
// called after the transfer is gone. Capped at max_post_data_size.
captured_requests: std.AutoHashMapUnmanaged(CapturedKey, []const u8) = .empty,

// When network is enabled, we'll capture the transfer.id -> body
// This is awfully memory intensive, but our underlying http client and
// its users (script manager and frame) correctly do not hold the body
// memory longer than they have to. In fact, the main request is only
// ever streamed. So if CDP is the only thing that needs bodies in
// memory for an arbitrary amount of time, then that's where we're going
// to store them.
captured_responses_size: usize = 0,
captured_responses: std.AutoArrayHashMapUnmanaged(CapturedKey, CapturedResponse) = .empty,
network_limits: network_domain.BufferLimits = .{},

// Pre-armed response for the next JS dialog (alert/confirm/prompt).
// Set by LP.handleJavaScriptDialog; consumed (and cleared) when the
// next javascript_dialog_opening notification is dispatched. Strings
// are duplicated into self.arena so they outlive the CDP command's
// own message arena.
pending_dialog_response: ?Notification.DialogResponse = null,

// webmcp tool invocation
invocation_id_gen: CDP.InvocationIdGen = .{},
// WebMCP domain state. Populated when `WebMCP.enable` is received.
webmcp_invocations: std.AutoHashMapUnmanaged(u32, *@import("domains/webmcp.zig").Invocation) = .empty,

// Allocates the target. Its page is bound later, by onFrameCreated.
pub fn create(bc: *BrowserContext, group_id: js.Inspector.GroupId) !*Target {
    const allocator = bc.cdp.allocator;
    const self = try allocator.create(Target);
    errdefer allocator.destroy(self);

    self.* = .{
        .bc = bc,
        .cdp = bc.cdp,
        .session = bc.session,
        .group_id = group_id,
        .arena = .init(allocator),
        .frame_arena = .init(allocator),
        .node_registry = .init(allocator),
        .node_search_list = undefined,
        .intercept_state = try .init(allocator),
    };
    self.node_search_list = .init(allocator, &self.node_registry);
    return self;
}

// Frees everything the target holds, its page excepted (see `close`).
pub fn destroy(self: *Target) void {
    const allocator = self.cdp.allocator;
    const http_client = &self.cdp.browser.http_client;

    // abort all intercepted requests: some of these might callback into the
    // page/scriptmanager. intercept_state stores ids.
    for (self.intercept_state.pendingIntercepts()) |transfer_id| {
        if (http_client.findTransfer(transfer_id)) |transfer| {
            transfer.abortParked(error.ClientDisconnect);
        }
    }

    // Notify any CDP client waiting on an in-flight WebMCP invocation
    // before the V8 context (and its promise callbacks) get torn down.
    @import("domains/webmcp.zig").cancelAllPending(self);

    self.deinitIsolatedWorlds();
    self.bc.notification.unregisterAll(self);
    self.clearCapturedResponses();

    self.node_registry.deinit();
    self.node_search_list.deinit();
    self.set_child_nodes_sent.deinit(allocator);
    self.intercept_state.deinit();
    self.frame_arena.deinit();
    self.arena.deinit();
    allocator.destroy(self);
}

fn deinitIsolatedWorlds(self: *Target) void {
    for (self.isolated_worlds.items) |world| {
        world.deinit();
    }
    self.isolated_worlds.clearRetainingCapacity();
}

// Shared by Target.closeTarget, Page.close and Target.disposeBrowserContext.
// Drivers settle page.close() on detachedFromTarget and drop the target
// on targetDestroyed, so both are sent even when nothing was attached.
// Closes the page. Called by BrowserContext.closeTarget, which then frees
// the target.
pub fn close(self: *Target) !void {
    const cdp = self.cdp;
    const bc = self.bc;
    if (self.target_id) |*target_id| {
        for (bc.attached_sessions.values()) |session| {
            if (session.target != self) {
                continue;
            }
            self.fetchDisableForSession(session.id);
            try cdp.sendEvent("Inspector.detached", .{
                .reason = "Render process gone.",
            }, .{ .session_id = session.id });
            try cdp.sendEvent("Target.detachedFromTarget", .{
                .targetId = target_id,
                .sessionId = session.id,
                .reason = "Render process gone.",
            }, .{ .session_id = session.parent_id });
        }
        try cdp.sendEvent("Target.targetDestroyed", .{ .targetId = target_id }, .{});
    }
    bc.detachTargetSessions(self);

    if (self.pageHandle()) |handle| {
        handle.close();
    }
    self.deinitIsolatedWorlds();
    self.target_id = null;
}

pub fn pageHandle(self: *const Target) ?Session.PageHandle {
    return .{ .session = self.session, .frame_id = self.frame_id orelse return null };
}

// True if `frame_id` is a frame of this target's page (popups included).
pub fn ownsFrame(self: *const Target, frame_id: u32) bool {
    return self.bc.targetForFrame(frame_id) == self;
}

// The frame `frame_id` of this target's page (popups included). null for a
// frame of another target's page: its state (node registry, isolated worlds)
// is cleaned up with that page, not this one.
pub fn findFrame(self: *const Target, frame_id: u32) ?*Frame {
    const frame = self.session.findFrameByFrameId(frame_id) orelse return null;
    if (self.frame_id != frame.page.frame._frame_id) {
        return null;
    }
    return frame;
}

// A transfer belongs to the page of the document that made it, a worker's
// to its owner's. By root_frame_id, not a frame lookup: a root navigation
// unlinks the old page before aborting its transfers, and the failures of its
// child frames' requests must still reach the target. Transfers with no frame
// (e.g. a test's) go to the first target.
fn ownsTransfer(self: *const Target, transfer: *const HttpClient.Transfer) bool {
    const req = &transfer.req;
    if (req.root_frame_id != 0) {
        return self.frame_id == req.root_frame_id;
    }
    const frame_id = req.document_frame_id orelse req.frame_id;
    if (frame_id == 0) {
        return self.bc.firstTarget() == self;
    }
    return self.ownsFrame(frame_id);
}

// The root frame of this target's live Page.
pub fn mainFrame(self: *const Target) ?*Frame {
    return &(self.mainPage() orelse return null).frame;
}

// True while this target's page is mid-commit (a root navigation's
// replacement is being promoted).
pub fn inCommit(self: *const Target) bool {
    return (self.pageHandle() orelse return false).inCommit();
}

// The live Page of this target, or null if no page is loaded.
pub fn mainPage(self: *const Target) ?*Page {
    return (self.pageHandle() orelse return null).page();
}

pub fn getURL(self: *const Target) ?[:0]const u8 {
    const frame = self.mainFrame() orelse return null;
    const url = frame.url;
    return if (url.len == 0) null else url;
}

pub fn getTitle(self: *const Target) ?[]const u8 {
    const frame = self.mainFrame() orelse return null;
    return frame.getTitle() catch |err| {
        log.err(.cdp, "page title", .{ .err = err });
        return null;
    };
}

pub fn reset(self: *Target) void {
    self.node_registry.reset();
    self.node_search_list.reset();
    self.set_child_nodes_sent.clearRetainingCapacity();
}

const GetOrPutIsolatedWorld = struct {
    world: *IsolatedWorld,
    found_existing: bool,
};

pub fn findIsolatedWorld(self: *const Target, world_name: []const u8) ?*IsolatedWorld {
    for (self.isolated_worlds.items) |world| {
        if (std.mem.eql(u8, world.name, world_name)) {
            return world;
        }
    }
    return null;
}

pub fn createIsolatedWorld(self: *Target, world_name: []const u8, grant_universal_access: bool) !GetOrPutIsolatedWorld {
    if (self.findIsolatedWorld(world_name)) |world| {
        if (world.grant_universal_access != grant_universal_access) {
            log.debug(.cdp, "isolated world mismatch", .{ .name = world_name, .gua = grant_universal_access });
        }
        return .{ .world = world, .found_existing = true };
    }

    const browser = &self.cdp.browser;
    const arena = try browser.arena_pool.acquire(.small, "IsolatedWorld");
    errdefer arena.release();

    const world = try arena.create(IsolatedWorld);
    world.* = .{
        .arena = arena,
        .browser = browser,
        .name = try arena.dupe(u8, world_name),
        .grant_universal_access = grant_universal_access,
    };

    try self.isolated_worlds.append(self.arena.allocator(), world);

    return .{ .world = world, .found_existing = false };
}

// only called when we fail to fully create a world (e.g. errdefer in
// Page.createIsolatedWorld).
pub fn removeIsolatedWorld(self: *Target, world: *IsolatedWorld) void {
    for (self.isolated_worlds.items, 0..) |w, i| {
        if (w == world) {
            _ = self.isolated_worlds.swapRemove(i);
            world.deinit();
            return;
        }
    }
}

pub fn nodeWriter(self: *Target, root: *const NodeRegistry.Node, opts: Node.Writer.Opts) Node.Writer {
    return .{
        .root = root,
        .depth = opts.depth,
        .exclude_root = opts.exclude_root,
        .registry = &self.node_registry,
    };
}

pub fn axnodeWriter(self: *Target, temp_arena: *lp.Arena, root: *const NodeRegistry.Node, opts: AXNode.Writer.Opts) !AXNode.Writer {
    // Bind the writer to the frame that owns the root node. Name resolution
    // (`Label.findLabelByFor` against `ownerDocument`) and visibility
    // checks (`frame._style_manager`) are per-frame; getting this wrong on
    // cross-frame queries produces names/visibility from the wrong document.
    const main_frame = self.mainFrame() orelse return error.FrameNotLoaded;
    const frame = root.dom.ownerFrame(main_frame) orelse return error.InvalidNodeId;
    const label_index = try frame.call_arena.create(Label.LabelByForIndex);
    label_index.* = .{};
    return .{
        .frame = frame,
        .root = root,
        .registry = &self.node_registry,
        .label_index = label_index,
        .temp_arena = temp_arena,
        .filter = opts.filter,
        .depth = opts.depth,
    };
}

pub fn networkEnable(self: *Target, limits: network_domain.BufferLimits) !void {
    const previous = self.network_limits;
    self.network_limits = limits;
    if (limits.resource < previous.resource) {
        // evict responses which are over the new small limit
        for (self.captured_responses.values()) |*resp| {
            const data = resp.data orelse continue;
            if (data.items.len > limits.resource) {
                self.evictCapturedResponse(resp);
            }
        }
    }
    if (limits.total < previous.total) {
        self.ensureCapturedSpace(0);
    }

    const notification = self.bc.notification;
    try notification.register(.http_request_fail, self, onHttpRequestFail);
    try notification.register(.http_request_start, self, onHttpRequestStart);
    try notification.register(.http_request_done, self, onHttpRequestDone);
    try notification.register(.http_response_data, self, onHttpResponseData);
    try notification.register(.http_response_header_done, self, onHttpResponseHeadersDone);
    try notification.register(.http_request_served_from_cache, self, onHttpRequestServedFromCache);
}

pub fn networkDisable(self: *Target) void {
    const notification = self.bc.notification;
    notification.unregister(.http_request_fail, self);
    notification.unregister(.http_request_start, self);
    notification.unregister(.http_request_done, self);
    notification.unregister(.http_response_data, self);
    notification.unregister(.http_response_header_done, self);
    notification.unregister(.http_request_served_from_cache, self);
    self.clearCapturedResponses();
}

pub fn clearCapturedResponses(self: *Target) void {
    const allocator = self.cdp.allocator;
    for (self.captured_responses.values()) |*resp| {
        if (resp.data) |*data| {
            data.deinit(allocator);
        }
    }
    self.captured_responses.deinit(allocator);
    self.captured_responses = .empty;
    self.captured_responses_size = 0;
}

fn evictCapturedResponse(self: *Target, resp: *CapturedResponse) void {
    if (resp.data) |*data| {
        self.captured_responses_size -= data.items.len;
        data.deinit(self.cdp.allocator);
        resp.data = null;
    }
}

// Evict captured responses, ordered by age, until we can fit `size` more bytes
fn ensureCapturedSpace(self: *Target, size: usize) void {
    for (self.captured_responses.values()) |*resp| {
        if (self.captured_responses_size + size <= self.network_limits.total) {
            return;
        }
        const data = resp.data orelse continue;
        if (data.items.len == 0) {
            continue;
        }
        self.evictCapturedResponse(resp);
    }
}

pub fn fetchEnable(self: *Target, patterns: ?[]const fetch.RequestPattern, authRequests: bool, session_id: []const u8) !void {
    self.fetchDisable(); //in case of multiple calls
    errdefer self.fetchDisable();
    try self.intercept_state.setPatterns(patterns);
    self.fetch_session_id = session_id;
    const notification = self.bc.notification;
    try notification.register(.http_request_intercept, self, onHttpRequestIntercept);
    try notification.register(.http_response_intercept, self, onHttpResponseIntercept);
    if (authRequests) {
        try notification.register(.http_request_auth_required, self, onHttpRequestAuthRequired);
    }
}

pub fn fetchDisableForSession(self: *Target, session_id: []const u8) void {
    const active_session_id = self.fetch_session_id orelse return;
    if (std.mem.eql(u8, active_session_id, session_id)) {
        self.fetchDisable();
    }
}

fn fetchDisable(self: *Target) void {
    const notification = self.bc.notification;
    notification.unregister(.http_request_intercept, self);
    notification.unregister(.http_response_intercept, self);
    notification.unregister(.http_request_auth_required, self);
    self.intercept_state.clearPatterns();
    self.fetch_session_id = null;
}

pub fn lifecycleEventsEnable(self: *Target) !void {
    self.page_life_cycle_events = true;
    const notification = self.bc.notification;
    try notification.register(.frame_network_idle, self, onFrameNetworkIdle);
    try notification.register(.frame_network_almost_idle, self, onFrameNetworkAlmostIdle);
}

pub fn lifecycleEventsDisable(self: *Target) void {
    self.page_life_cycle_events = false;
    const notification = self.bc.notification;
    notification.unregister(.frame_network_idle, self);
    notification.unregister(.frame_network_almost_idle, self);
}

pub fn consoleEnable(self: *Target) !void {
    try self.bc.notification.register(.console_message, self, onConsoleMessage);
}

pub fn consoleDisable(self: *Target) void {
    self.bc.notification.unregister(.console_message, self);
}

pub fn runtimeEnable(self: *Target) !void {
    const notification = self.bc.notification;
    try notification.register(.runtime_console_message, self, onRuntimeConsoleMessage);
    try notification.register(.exception_thrown, self, onExceptionThrown);
}

pub fn runtimeDisable(self: *Target) void {
    const notification = self.bc.notification;
    notification.unregister(.runtime_console_message, self);
    notification.unregister(.exception_thrown, self);
}

pub fn webmcpEnable(self: *Target) !void {
    const notification = self.bc.notification;
    try notification.register(.model_context_tool_added, self, onModelContextToolAdded);
    try notification.register(.model_context_tool_removed, self, onModelContextToolRemoved);
}

pub fn webmcpDisable(self: *Target) void {
    const notification = self.bc.notification;
    notification.unregister(.model_context_tool_added, self);
    notification.unregister(.model_context_tool_removed, self);
}

/// The first session attached to the target.
pub fn attachPrimarySession(self: *Target, session_id: []const u8) !*BrowserContext.AttachedSession {
    lp.assert(self.session_id == null, "CDP.Target.attachPrimarySession already attached", .{});
    const attached = try self.bc.attachSession(self, session_id, null);
    self.session_id = attached.id;
    return attached;
}

pub fn inspectorSession(self: *const Target, session_id: ?[]const u8) !*js.Inspector.Session {
    const id = session_id orelse self.session_id orelse return error.SessionNotAttached;
    const attached = self.bc.attached_sessions.get(id) orelse return error.SessionNotAttached;
    if (attached.target != self) {
        return error.SessionNotAttached;
    }
    return &attached.inspector_session;
}

/// Forwards `cmd`'s raw JSON to the inspector session of the session it was sent through.
pub fn callInspector(self: *Target, cmd: *const CDP.Command) !void {
    const inspector_session = try self.inspectorSession(cmd.input.session_id);
    inspector_session.send(cmd.input.json);
    self.session.browser.env.runMicrotasks();
}

fn onFrameNetworkIdle(ctx: *anyopaque, msg: *const Notification.FrameNetworkIdle) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsFrame(msg.frame_id)) return;
    return @import("domains/page.zig").frameNetworkIdle(self, msg);
}

fn onFrameNetworkAlmostIdle(ctx: *anyopaque, msg: *const Notification.FrameNetworkAlmostIdle) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsFrame(msg.frame_id)) return;
    return @import("domains/page.zig").frameNetworkAlmostIdle(self, msg);
}

fn onHttpRequestStart(ctx: *anyopaque, msg: *const Notification.RequestStart) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    const transfer = msg.transfer;
    if (!self.ownsTransfer(transfer)) return;
    {
        // capture the request
        const key = keyFromTransfer(transfer);
        const body = transfer.req.body orelse "";
        if (body.len == 0 or body.len > network_domain.max_post_data_size) {
            _ = self.captured_requests.remove(key);
        } else {
            const frame_arena = self.frame_arena.allocator();
            const owned_body = try frame_arena.dupe(u8, body);
            try self.captured_requests.put(frame_arena, key, owned_body);
        }
    }
    const arena = self.bc.acquireNotificationArena();
    defer self.bc.releaseNotificationArena();
    try network_domain.httpRequestStart(arena, self, msg);
}

fn onHttpRequestIntercept(ctx: *anyopaque, msg: *const Notification.RequestIntercept) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsTransfer(msg.transfer)) return;
    const arena = self.bc.acquireNotificationArena();
    defer self.bc.releaseNotificationArena();
    try fetch.requestIntercept(arena, self, msg);
}

fn onHttpResponseIntercept(ctx: *anyopaque, msg: *const Notification.ResponseIntercept) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsTransfer(msg.transfer)) return;
    const arena = self.bc.acquireNotificationArena();
    defer self.bc.releaseNotificationArena();
    try fetch.responseIntercept(arena, self, msg);
}

fn onHttpRequestFail(ctx: *anyopaque, msg: *const Notification.RequestFail) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsTransfer(msg.transfer)) return;
    return network_domain.httpRequestFail(self, msg);
}

fn keyFromTransfer(transfer: *const HttpClient.Transfer) CapturedKey {
    return if (transfer.req.resource_type == .document)
        .{ .kind = .loader, .id = transfer.req.loader_id }
    else
        .{ .kind = .request, .id = transfer.id };
}

fn onHttpResponseHeadersDone(ctx: *anyopaque, msg: *const Notification.ResponseHeaderDone) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsTransfer(msg.transfer)) return;
    const arena = self.bc.acquireNotificationArena();
    defer self.bc.releaseNotificationArena();

    // Prepare the captured response value.
    const key = keyFromTransfer(msg.transfer);
    const gop = try self.captured_responses.getOrPut(self.cdp.allocator, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .data = blk: {
                const body_len = msg.transfer.bodyLen();
                if (body_len > self.network_limits.resource) {
                    break :blk null;
                }
                break :blk try std.ArrayList(u8).initCapacity(self.cdp.allocator, body_len);
            },
            // Encode the data in base64 by default, but don't encode
            // for well known content-type.
            .must_encode = blk: {
                if (msg.transfer.contentType()) |ct| {
                    const mime = Mime.parse(ct) catch break :blk true;
                    if (!mime.isText()) {
                        break :blk true;
                    }

                    if (std.ascii.eqlIgnoreCase("UTF-8", mime.charsetString())) {
                        break :blk false;
                    }
                }
                break :blk true;
            },
        };
    }

    return network_domain.httpResponseHeaderDone(arena, self, msg);
}

fn onHttpRequestDone(ctx: *anyopaque, msg: *const Notification.RequestDone) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsTransfer(msg.transfer)) return;
    return network_domain.httpRequestDone(self, msg);
}

pub fn onHttpResponseData(ctx: *anyopaque, msg: *const Notification.ResponseData) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsTransfer(msg.transfer)) return;

    const key = keyFromTransfer(msg.transfer);
    const resp = self.captured_responses.getPtr(key) orelse lp.assert(false, "onHttpResponseData missing captured response", .{});

    const data = &(resp.data orelse return);
    const chunk = msg.data;
    const limits = &self.network_limits;
    if (data.items.len + chunk.len > limits.resource or chunk.len > limits.total) {
        return self.evictCapturedResponse(resp);
    }
    // Can evict `resp` itself when it's the oldest, hence the re-check.
    self.ensureCapturedSpace(chunk.len);
    if (resp.data == null) {
        return;
    }
    try data.appendSlice(self.cdp.allocator, chunk);
    self.captured_responses_size += chunk.len;
}

fn onHttpRequestAuthRequired(ctx: *anyopaque, data: *const Notification.RequestAuthRequired) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsTransfer(data.transfer)) return;
    const arena = self.bc.acquireNotificationArena();
    defer self.bc.releaseNotificationArena();
    try fetch.requestAuthRequired(arena, self, data);
}

fn onHttpRequestServedFromCache(ctx: *anyopaque, msg: *const Notification.RequestServedFromCache) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsTransfer(msg.transfer)) return;
    return network_domain.httpServedFromCache(self, msg);
}

fn onConsoleMessage(ctx: *anyopaque, msg: *const Notification.ConsoleMessage) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsFrame(msg.frame_id)) return;
    const arena = self.bc.acquireNotificationArena();
    defer self.bc.releaseNotificationArena();
    return @import("domains/console.zig").consoleMessage(arena, self, msg);
}

fn onRuntimeConsoleMessage(ctx: *anyopaque, msg: *const Notification.ConsoleMessage) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsFrame(msg.frame_id)) return;
    const arena = self.bc.acquireNotificationArena();
    defer self.bc.releaseNotificationArena();
    return @import("domains/runtime.zig").consoleMessage(arena, self, msg);
}

fn onExceptionThrown(ctx: *anyopaque, msg: *const Notification.ExceptionThrown) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (!self.ownsFrame(msg.frame_id)) return;
    const arena = self.bc.acquireNotificationArena();
    defer self.bc.releaseNotificationArena();
    return @import("domains/runtime.zig").exceptionThrown(arena, self, msg);
}

fn onModelContextToolAdded(ctx: *anyopaque, event: *const Notification.ModelContextToolEvent) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (self.frame_id != event.exec.page.frame._frame_id) return;
    return @import("domains/webmcp.zig").onToolAdded(self, event);
}

fn onModelContextToolRemoved(ctx: *anyopaque, event: *const Notification.ModelContextToolEvent) !void {
    const self: *Target = @ptrCast(@alignCast(ctx));
    if (self.frame_id != event.exec.page.frame._frame_id) return;
    return @import("domains/webmcp.zig").onToolRemoved(self, event);
}
