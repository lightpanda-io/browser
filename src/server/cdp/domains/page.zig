// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)

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

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");

const js = @import("../../../browser/js/js.zig");
const URL = @import("../../../browser/URL.zig");
const Frame = @import("../../../browser/Frame.zig");
const Notification = @import("../../../Notification.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getFrameTree,
        getNavigationHistory,
        setLifecycleEventsEnabled,
        addScriptToEvaluateOnNewDocument,
        removeScriptToEvaluateOnNewDocument,
        createIsolatedWorld,
        navigate,
        navigateToHistoryEntry,
        reload,
        stopLoading,
        close,
        captureScreenshot,
        printToPDF,
        getLayoutMetrics,
        handleJavaScriptDialog,
        setBypassCSP,
        bringToFront,
        setInterceptFileChooserDialog,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getFrameTree => return getFrameTree(cmd),
        .getNavigationHistory => return getNavigationHistory(cmd),
        .setLifecycleEventsEnabled => return setLifecycleEventsEnabled(cmd),
        .addScriptToEvaluateOnNewDocument => return addScriptToEvaluateOnNewDocument(cmd),
        .removeScriptToEvaluateOnNewDocument => return removeScriptToEvaluateOnNewDocument(cmd),
        .createIsolatedWorld => return createIsolatedWorld(cmd),
        .navigate => return navigate(cmd),
        .navigateToHistoryEntry => return navigateToHistoryEntry(cmd),
        .reload => return doReload(cmd),
        .stopLoading => return stopLoading(cmd),
        .close => return close(cmd),
        .captureScreenshot => return captureScreenshot(cmd),
        .printToPDF => return printToPDF(cmd),
        .getLayoutMetrics => return getLayoutMetrics(cmd),
        .handleJavaScriptDialog => return handleJavaScriptDialog(cmd),
        // CSP isn't enforced, there is a single page, and no file chooser
        // ever opens: each of these already holds.
        .setBypassCSP, .bringToFront, .setInterceptFileChooserDialog => return cmd.sendResult(null, .{}),
    }
}

fn getFrameTree(cmd: *CDP.Command) !void {
    // Stagehand parses the response and error if we don't return a
    // correct one for this call when browser context or target id are missing.
    const startup = .{
        .frameTree = .{
            .frame = .{
                .id = "TID-STARTUP",
                .loaderId = "LID-STARTUP",
                .securityOrigin = @import("../CDP.zig").URL_BASE,
                .url = "about:blank",
                .secureContextType = "Secure",
            },
        },
    };
    const bc = cmd.browser_context orelse return cmd.sendResult(startup, .{});
    if (bc.target_id == null) {
        return cmd.sendResult(startup, .{});
    }
    const frame = bc.mainFrame() orelse return cmd.sendResult(startup, .{});

    return cmd.sendResult(.{
        .frameTree = FrameTreeWriter{ .bc = bc, .frame = frame },
    }, .{});
}

fn setLifecycleEventsEnabled(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        enabled: bool,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    if (params.enabled == false) {
        bc.lifecycleEventsDisable();
        return cmd.sendResult(null, .{});
    }

    // Enable lifecycle events.
    try bc.lifecycleEventsEnable();

    // When we enable lifecycle events, we must dispatch events for all
    // attached targets.
    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;

    if (frame._load_state == .complete) {
        const frame_id = &id.toFrameId(frame._frame_id);
        const loader_id = &id.toLoaderId(frame._loader_id);

        const now = lp.datetime.timestamp(.boot);
        try sendPageLifecycle(bc, "DOMContentLoaded", now, frame_id, loader_id);
        try sendPageLifecycle(bc, "load", now, frame_id, loader_id);

        const http_client = frame._session.browser.http_client;
        const http_active = http_client.http_active;
        const http_buffered = http_client.dispatch_count;
        const total_network_activity = http_active + http_buffered + http_client.intercepted;
        if (frame._notified_network_almost_idle.check(total_network_activity <= 2)) {
            try sendPageLifecycle(bc, "networkAlmostIdle", now, frame_id, loader_id);
        }
        if (frame._notified_network_idle.check(total_network_activity == 0)) {
            try sendPageLifecycle(bc, "networkIdle", now, frame_id, loader_id);
        }
    }

    return cmd.sendResult(null, .{});
}

fn addScriptToEvaluateOnNewDocument(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        source: []const u8,
        worldName: ?[]const u8 = null,
        includeCommandLineAPI: bool = false,
        runImmediately: bool = false,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    if (params.runImmediately) {
        log.warn(.not_implemented, "addScriptOnNewDocument", .{ .param = "runImmediately" });
    }

    // A worldName registers the world itself.
    var world_name: ?[]const u8 = null;
    if (params.worldName) |name| {
        if (name.len > 0) {
            _ = try bc.createIsolatedWorld(name, true);
            world_name = try bc.arena.dupe(u8, name);
        }
    }

    const script_id = bc.next_script_id;
    bc.next_script_id += 1;

    const source_dupe = try bc.arena.dupe(u8, params.source);
    try bc.scripts_on_new_document.append(bc.arena, .{
        .identifier = script_id,
        .source = source_dupe,
        .world_name = world_name,
    });

    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{script_id}) catch "1";
    return cmd.sendResult(.{
        .identifier = id_str,
    }, .{});
}

fn removeScriptToEvaluateOnNewDocument(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        identifier: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const target_id = std.fmt.parseInt(u32, params.identifier, 10) catch
        return cmd.sendResult(null, .{});

    for (bc.scripts_on_new_document.items, 0..) |script, i| {
        if (script.identifier == target_id) {
            _ = bc.scripts_on_new_document.orderedRemove(i);
            break;
        }
    }
    return cmd.sendResult(null, .{});
}

fn close(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const target_id = bc.target_id orelse return error.TargetNotLoaded;

    // can't be null if we have a target_id
    lp.assert(bc.session.hasPage(), "CDP.frame.close null frame", .{});

    try cmd.sendResult(.{}, .{});

    // Following code is similar to target.closeTarget
    //
    // could be null, created but never attached
    if (bc.session_id) |session_id| {
        // Inspector.detached event
        try cmd.sendEvent("Inspector.detached", .{
            .reason = "Render process gone.",
        }, .{ .session_id = session_id });

        // detachedFromTarget event
        try cmd.sendEvent("Target.detachedFromTarget", .{
            .targetId = target_id,
            .sessionId = session_id,
            .reason = "Render process gone.",
        }, .{});

        bc.session_id = null;
    }

    if (bc.page_handle) |handle| {
        handle.close();
    }
    bc.page_handle = null;
    for (bc.isolated_worlds.items) |world| {
        world.deinit();
    }
    bc.isolated_worlds.clearRetainingCapacity();
    bc.target_id = null;
}

fn createIsolatedWorld(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        frameId: []const u8,
        worldName: []const u8,
        grantUniveralAccess: bool = false,
    })) orelse return error.InvalidParams;
    if (!params.grantUniveralAccess) {
        log.warn(.not_implemented, "Page.createIsolatedWorld", .{ .param = "grantUniveralAccess" });
        // When grantUniveralAccess == false and the client attempts to resolve
        // or otherwise access a DOM or other JS Object from another context that should fail.
    }
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    const frame_id = try id.parseFrameId(params.frameId);
    const frame = bc.session.findFrameByFrameId(frame_id) orelse {
        return cmd.sendError(-32000, "Frame with the given id does not belong to the target.", .{});
    };

    const gop = try bc.createIsolatedWorld(params.worldName, params.grantUniveralAccess);
    const world = gop.world;

    errdefer if (gop.found_existing == false) {
        bc.removeIsolatedWorld(world);
    };

    // Seed before creating: frameNavigated only rebuilds contexts for frames
    // the world was seeded into.
    try world.seed(frame._frame_id);

    // use the existing world context for a frame if we have it, else create one
    const js_context = world.contextFor(frame) orelse try createIsolatedWorldContext(cmd.arena, bc, world, frame, null);

    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();
    const context_id = bc.inspector_session.inspector.getContextId(&ls.local);
    return cmd.sendResult(.{ .executionContextId = context_id }, .{});
}

// Creates `world`'s context for `frame` and registers it with the inspector
fn createIsolatedWorldContext(arena: Allocator, bc: *CDP.BrowserContext, world: *CDP.IsolatedWorld, frame: *Frame, loader_id: ?[]const u8) !*js.Context {
    const js_context = try world.createContext(frame);
    errdefer world.removeContext(frame);
    try registerIsolatedWorldContext(arena, bc, world, js_context, frame, loader_id);
    return js_context;
}

// Registers a world context with the inspector, which assigns the id clients
// use and sends Runtime.executionContextCreated. We may re-register a living
// context, the client will get a new id, but both ids are still valid. This
// happens when we fast-path via `canNavigateInPlace`, `frameNavigated` still
// fires so registerIsolatedWorldContext gets re-called for the same context.
// Not the end of the world since it's bound to a single about:blank -> navigate
// and necessary since we call executionContextsCleared which tells the client
// the old id is invalid
fn registerIsolatedWorldContext(arena: Allocator, bc: *CDP.BrowserContext, world: *CDP.IsolatedWorld, js_context: *js.Context, frame: *const Frame, loader_id: ?[]const u8) !void {
    const frame_id = &id.toFrameId(frame._frame_id);
    const aux_data = if (loader_id) |lid|
        try std.fmt.allocPrint(arena, "{{\"isDefault\":false,\"type\":\"isolated\",\"frameId\":\"{s}\",\"loaderId\":\"{s}\"}}", .{ frame_id, lid })
    else
        try std.fmt.allocPrint(arena, "{{\"isDefault\":false,\"type\":\"isolated\",\"frameId\":\"{s}\"}}", .{frame_id});

    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();

    bc.inspector_session.inspector.contextCreated(
        &ls.local,
        world.name,
        frame.origin orelse "",
        aux_data,
        false,
    );
}

fn navigate(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        url: [:0]const u8,
        // referrer: ?[]const u8 = null,
        // transitionType: ?[]const u8 = null, // TODO: enum
        // frameId: ?[]const u8 = null,
        // referrerPolicy: ?[]const u8 = null, // TODO: enum
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // didn't create?
    // const target_id = bc.target_id orelse return error.TargetIdNotLoaded;

    // didn't attach?
    if (bc.session_id == null) {
        return error.SessionIdNotLoaded;
    }

    const session = bc.session;
    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;

    const encoded_url = try URL.resolveNavigation(frame.call_arena, params.url, .{});

    const opts: Frame.NavigateOpts = .{
        .reason = .address_bar,
        .cdp_id = cmd.input.id,
        .kind = .{ .push = null },
    };

    if (canNavigateInPlace(bc, frame)) {
        return frame.navigate(encoded_url, opts);
    }
    try session.initiateRootNavigation(frame._frame_id, encoded_url, opts);
}

fn stopLoading(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;
    bc.session.stopLoading(frame._frame_id);
    return cmd.sendResult(null, .{});
}

// Fast path that allows using the initial about:blank Frame as-is. Only safe
// when the frame is still waiting for a navigate AND no JS has been run in the
// instance (for about:blank, that's only possible via an Runtime.* call)
fn canNavigateInPlace(bc: *const CDP.BrowserContext, frame: *const Frame) bool {
    return frame._load_state == .waiting and !bc.main_world_touched;
}

fn doReload(cmd: *CDP.Command) !void {
    const params = try cmd.params(struct {
        ignoreCache: ?bool = null,
        scriptToEvaluateOnLoad: ?[]const u8 = null,
    });

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    if (bc.session_id == null) {
        return error.SessionIdNotLoaded;
    }

    const session = bc.session;
    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;

    // Capture URL plus the prior navigation's method/body/header before
    // we free the old frame's arena. Replaying the same HTTP
    // method on reload matches Chrome's F5 behavior — POST navigations
    // re-submit, GET navigations re-fetch.
    const reload_url = try cmd.arena.dupeZ(u8, frame.url);
    const prev_nav = frame._navigated_options;
    const prev_body: ?[]const u8, const prev_header: ?[:0]const u8 = blk: {
        const p = prev_nav orelse break :blk .{ null, null };
        break :blk .{
            if (p.body) |b| try cmd.arena.dupe(u8, b) else null,
            if (p.header) |h| try cmd.arena.dupeZ(u8, h) else null,
        };
    };

    try session.initiateRootNavigation(frame._frame_id, reload_url, .{
        .reason = .address_bar,
        .cdp_id = cmd.input.id,
        .kind = .reload,
        .force = if (params) |p| p.ignoreCache orelse false else false,
        .method = if (prev_nav) |p| p.method else .GET,
        .body = prev_body,
        .header = prev_header,
    });
}

const NavigationEntry = struct {
    id: i64,
    url: []const u8,
    userTypedURL: []const u8,
    title: []const u8,
    transitionType: []const u8,
};

fn getNavigationHistory(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    if (bc.session_id == null) {
        return error.SessionIdNotLoaded;
    }

    const nav = bc.session.navigation;
    const entries_in = nav._entries.items;

    const entries_out = try cmd.arena.alloc(NavigationEntry, entries_in.len);
    for (entries_in, 0..) |entry, i| {
        // Navigation.pushEntry always formats _id as a decimal usize counter,
        // so parse failure here is an internal invariant violation, not a
        // recoverable runtime error.
        const eid = std.fmt.parseInt(i64, entry._id, 10) catch @panic("Navigation entry _id is not a base-10 integer");
        entries_out[i] = .{
            .id = eid,
            .url = entry._url orelse "",
            .userTypedURL = entry._url orelse "",
            .title = "",
            .transitionType = "other",
        };
    }

    return cmd.sendResult(.{
        .currentIndex = @as(i64, @intCast(nav._index)),
        .entries = entries_out,
    }, .{});
}

fn navigateToHistoryEntry(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        entryId: i64,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    if (bc.session_id == null) {
        return error.SessionIdNotLoaded;
    }

    const session = bc.session;
    const nav = session.navigation;

    var target_index: ?usize = null;
    var target_url: ?[:0]const u8 = null;
    for (nav._entries.items, 0..) |entry, i| {
        const eid = std.fmt.parseInt(i64, entry._id, 10) catch @panic("Navigation entry _id is not a base-10 integer");
        if (eid == params.entryId) {
            target_index = i;
            target_url = entry._url;
            break;
        }
    }

    const idx = target_index orelse return error.InvalidParams;
    const url = target_url orelse return error.InvalidParams;

    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;

    const opts = Frame.NavigateOpts{
        .reason = .history,
        .cdp_id = cmd.input.id,
        .kind = .{ .traverse = idx },
    };

    if (canNavigateInPlace(bc, frame)) {
        return frame.navigate(url, opts);
    }

    try session.initiateRootNavigation(frame._frame_id, url, opts);
}

pub fn frameNavigate(bc: *CDP.BrowserContext, event: *const Notification.FrameNavigate) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    // Child-frame navigations must not invalidate node IDs owned by other
    // frames. A pending root keeps its old page addressable until frameRemove;
    // other root navigations can clear the registry immediately.
    if (!event.is_pending_root) {
        const root_frame = bc.mainFrame() orelse return error.FrameNotLoaded;
        if (event.frame_id == root_frame._frame_id) {
            bc.reset();
        }
    }

    const frame_id = &id.toFrameId(event.frame_id);
    const loader_id = &id.toLoaderId(event.loader_id);

    var cdp = bc.cdp;
    const reason_: ?[]const u8 = switch (event.opts.reason) {
        .anchor => "anchorClick",
        .script, .history, .navigation => "scriptInitiated",
        .form => switch (event.opts.method) {
            .GET => "formSubmissionGet",
            .POST => "formSubmissionPost",
            else => unreachable,
        },
        .address_bar => null,
        .initialFrameNavigation => "initialFrameNavigation",
    };
    if (reason_) |reason| {
        if (event.opts.reason != .initialFrameNavigation) {
            try cdp.sendEvent("Page.frameScheduledNavigation", .{
                .frameId = frame_id,
                .delay = 0,
                .reason = reason,
                .url = event.url,
            }, .{ .session_id = session_id });
        }
        try cdp.sendEvent("Page.frameRequestedNavigation", .{
            .frameId = frame_id,
            .reason = reason,
            .url = event.url,
            .disposition = "currentTab",
        }, .{ .session_id = session_id });
    }

    // frameStartedNavigating event
    try cdp.sendEvent("Page.frameStartedNavigating", .{
        .frameId = frame_id,
        .url = event.url,
        .loaderId = loader_id,
        .navigationType = "differentDocument",
    }, .{ .session_id = session_id });

    // frameStartedLoading event
    try cdp.sendEvent("Page.frameStartedLoading", .{
        .frameId = frame_id,
    }, .{ .session_id = session_id });
}

pub fn frameRemove(bc: *CDP.BrowserContext) void {
    // Clear all remote object mappings to prevent stale objectIds from being used
    // after the context is destroy
    bc.inspector_session.inspector.resetContextGroup();

    // The main frame is going to be removed, we need to remove contexts from other worlds first.
    for (bc.isolated_worlds.items) |isolated_world| {
        isolated_world.removeAllContexts();
    }

    // node_registry / node_search_list reference Nodes from the page being
    // torn down — clear them before the page's memory is freed. For pending
    // root commits this is the only reset, because frameNavigate set
    // is_pending_root=true and deliberately skipped its own reset so the
    // OLD page's nodes stayed addressable during the in-flight HTTP. For
    // synthetic / non-pending navs frameNavigate also calls bc.reset()
    // (via the !is_pending_root branch); the two are redundant but harmless.
    bc.reset();
}

pub fn frameCreated(bc: *CDP.BrowserContext, frame: *Frame) !void {
    // Record a handle to the new page so the context can resolve its live
    // page/frame (mainFrame / mainPage) without a session-wide "current" shim.
    bc.page_handle = .{ .session = bc.session, .frame_id = frame._frame_id };

    // Detect "in commit" mode: Session.commitPendingPage dispatches frame_
    // created BEFORE clearing `replaces` (deliberate ordering — see
    // Session.commitPendingPage), so the replacement still reports as in-flight.
    // The captured_response for the request we just committed was inserted by
    // onHttpResponseHeadersDone moments ago and lives in cdp.frame_arena;
    // resetting either would lose it.
    const in_commit = bc.inCommit();

    if (!in_commit) {
        _ = bc.cdp.frame_arena.reset(.{ .retain_with_limit = 1024 * 512 });
        bc.main_world_touched = false;
    }

    if (in_commit == false) {
        // Only retain captured responses until a navigation event. In CDP
        // terms, this is called a "renderer" and the cache-duration can be
        // controlled via Network.configureDurableMessages (which we don't
        // support).
        bc.captured_requests = .empty;
        bc.clearCapturedResponses();
    }
}

// A root navigation failed before commit — the pending Page is being
// discarded and no frameNavigated will ever fire, but the Page.navigate
// command that initiated it is still awaiting its response. Answer it with
// an errorText (Chrome semantics: "present if and only if navigation has
// failed") so the client isn't left waiting on the command id forever.
pub fn frameNavigateFailed(bc: *CDP.BrowserContext, event: *const Notification.FrameNavigateFailed) !void {
    const session_id = bc.session_id orelse return;

    const input_id = event.opts.cdp_id orelse return;
    try bc.cdp.sendJSON(.{
        .id = input_id,
        .result = .{
            .frameId = &id.toFrameId(event.frame_id),
            .loaderId = &id.toLoaderId(event.loader_id),
            .errorText = switch (event.err) {
                error.TransferCanceled => "net::ERR_ABORTED",
                else => |err| @errorName(err),
            },
        },
        .sessionId = session_id,
    });
}

// Fired from Frame.deinit while the frame's JS is still alive.
pub fn frameDestroyed(bc: *CDP.BrowserContext, frame: *const Frame) void {
    for (bc.isolated_worlds.items) |isolated_world| {
        isolated_world.removeContext(frame);
    }
}

pub fn frameChildFrameCreated(bc: *CDP.BrowserContext, event: *const Notification.FrameChildFrameCreated) !void {
    const session_id = bc.session_id orelse return;

    const cdp = bc.cdp;
    const frame_id = &id.toFrameId(event.frame_id);

    try cdp.sendEvent("Page.frameAttached", .{
        .frameId = frame_id,
        .parentFrameId = &id.toFrameId(event.parent_id),
    }, .{ .session_id = session_id });

    if (bc.page_life_cycle_events) {
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .name = "init",
            .frameId = frame_id,
            .loaderId = &id.toLoaderId(event.loader_id),
            .timestamp = event.timestamp,
        }, .{ .session_id = session_id });
    }
}

pub fn frameNavigated(arena: Allocator, bc: *CDP.BrowserContext, event: *const Notification.FrameNavigated) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    const frame_id = &id.toFrameId(event.frame_id);
    const loader_id = &id.toLoaderId(event.loader_id);

    var cdp = bc.cdp;

    // Drivers are sensitive to the order of events. Some more than others.
    // The result for the Page.navigate seems like it _must_ come after
    // the frameStartedLoading, but before any lifecycleEvent. So we
    // unfortunately have to put the input_id ito the NavigateOpts which gets
    // passed back into the notification.
    if (event.opts.cdp_id) |input_id| {
        try cdp.sendJSON(.{
            .id = input_id,
            .result = .{
                .frameId = frame_id,
                .loaderId = loader_id,
            },
            .sessionId = session_id,
        });
    }

    if (bc.page_life_cycle_events) {
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .name = "init",
            .frameId = frame_id,
            .loaderId = loader_id,
            .timestamp = event.timestamp,
        }, .{ .session_id = session_id });
    }

    const reason_: ?[]const u8 = switch (event.opts.reason) {
        .anchor => "anchorClick",
        .script, .history, .navigation => "scriptInitiated",
        .form => switch (event.opts.method) {
            .GET => "formSubmissionGet",
            .POST => "formSubmissionPost",
            else => unreachable,
        },
        .address_bar => null,
        .initialFrameNavigation => "initialFrameNavigation",
    };

    if (reason_ != null) {
        try cdp.sendEvent("Page.frameClearedScheduledNavigation", .{
            .frameId = frame_id,
        }, .{ .session_id = session_id });
    }

    const root_frame = bc.mainFrame() orelse return error.FrameNotLoaded;
    const is_root_frame = event.frame_id == root_frame._frame_id;

    // When we actually recreated the context we should have the inspector send
    // this event, see: resetContextGroup. Sending this event will tell the
    // client that the context ids they had are invalid and the context should
    // be dropped. The client will expect us to send new contextCreated events,
    // such that the client has new id's for the active contexts.
    // Only send executionContextsCleared for main frame navigations. For child
    // frames (iframes), clearing all contexts would destroy the main frame's
    // context, causing Puppeteer's frame.evaluate()/frame.content() to hang
    // forever.
    if (is_root_frame) {
        try cdp.sendEvent("Runtime.executionContextsCleared", null, .{ .session_id = session_id });
    }

    // Look up the actual navigated frame. For main frame navigations this is
    // the root frame; for iframes it is the child frame. Using the correct
    // frame's JS context for inspector.contextCreated prevents re-registering
    // the root context under a new id (which silently invalidates the
    // previous id on the V8 side).
    const frame = bc.session.findFrameByFrameId(event.frame_id) orelse return error.FrameNotFound;

    // frameNavigated event
    try cdp.sendEvent("Page.frameNavigated", .{
        .type = "Navigation",
        .frame = FrameWriter{ .bc = bc, .frame = frame },
    }, .{ .session_id = session_id });

    {
        const aux_data = try std.fmt.allocPrint(arena, "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\",\"loaderId\":\"{s}\"}}", .{ frame_id, loader_id });

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        bc.inspector_session.inspector.contextCreated(
            &ls.local,
            "",
            frame.origin orelse "",
            aux_data,
            is_root_frame,
        );
    }
    // A worldName preload script seeds its world into every frame. This is the
    // only way for a world to reach a frame besides the explicit Page.createIsolatedWorld.
    for (bc.scripts_on_new_document.items) |script| {
        const world = bc.findIsolatedWorld(script.world_name orelse continue) orelse continue;
        world.seed(frame._frame_id) catch |err| {
            log.warn(.cdp, "isolated world seed", .{ .err = err, .world = world.name, .frame_id = frame._frame_id });
        };
    }

    // Every world seeded into this frame gets a context, rebuilt on each
    // navigation as blink rebuilds a detached isolated-world window proxy.
    for (bc.isolated_worlds.items) |isolated_world| {
        if (isolated_world.contextFor(frame)) |js_context| {
            // The context was already created ahead of time (createIsolatedWorld).
            // A child keeps the id the client was given. The root's id was just
            // invalidated by executionContextsCleared: the first navigation of a
            // pristine about:blank keeps the Frame and its contexts.
            if (!is_root_frame) {
                continue;
            }
            registerIsolatedWorldContext(arena, bc, isolated_world, js_context, frame, loader_id) catch |err| {
                log.warn(.cdp, "isolated world context", .{ .err = err, .world = isolated_world.name, .frame_id = frame._frame_id });
            };
            continue;
        }

        if (!isolated_world.isSeeded(frame._frame_id)) {
            continue;
        }

        _ = createIsolatedWorldContext(arena, bc, isolated_world, frame, loader_id) catch |err| {
            log.warn(.cdp, "isolated world context", .{ .err = err, .world = isolated_world.name, .frame_id = frame._frame_id });
        };
    }

    // Evaluate scripts registered via Page.addScriptToEvaluateOnNewDocument.
    // Must run after the execution context is created but before the client
    // receives frameNavigated/loadEventFired so polyfills are available for
    // subsequent CDP commands.
    for (bc.scripts_on_new_document.items) |script| {
        const js_context = if (script.world_name) |name| blk: {
            const world = bc.findIsolatedWorld(name) orelse continue;
            break :blk world.contextFor(frame) orelse continue;
        } else frame.js;

        var ls: js.Local.Scope = undefined;
        js_context.localScope(&ls);
        defer ls.deinit();

        var try_catch: lp.js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        ls.local.eval(script.source, null) catch |err| {
            const caught = try_catch.caughtOrError(arena, err);
            log.warn(.cdp, "script on new doc", .{ .caught = caught });
        };
    }

    // The DOM.documentUpdated event must be send after the frameNavigated one.
    // chromedp client expects to receive the events is this order.
    // see https://github.com/chromedp/chromedp/issues/1558
    try cdp.sendEvent("DOM.documentUpdated", null, .{ .session_id = session_id });
}

pub fn frameNavigatedWithinDocument(bc: anytype, event: *const Notification.FrameNavigatedWithinDocument) !void {
    const session_id = bc.session_id orelse return;
    const frame_id = &id.toFrameId(event.frame_id);

    // Same-document navigation (pushState / replaceState / fragment). The
    // document and its execution context are unchanged, so — unlike
    // frameNavigated — we deliberately do NOT send Runtime.executionContextsCleared
    // or DOM.documentUpdated; doing so would invalidate the client's live
    // execution context ids and break Puppeteer's frame.evaluate().
    try bc.cdp.sendEvent("Page.navigatedWithinDocument", .{
        .frameId = frame_id,
        .url = event.url,
        .navigationType = @tagName(event.navigation_type),
    }, .{ .session_id = session_id });
}

pub fn frameDOMContentLoaded(bc: anytype, event: *const Notification.FrameDOMContentLoaded) !void {
    const session_id = bc.session_id orelse return;
    const timestamp = event.timestamp;
    var cdp = bc.cdp;

    try cdp.sendEvent(
        "Page.domContentEventFired",
        .{ .timestamp = timestamp },
        .{ .session_id = session_id },
    );

    if (bc.page_life_cycle_events) {
        const frame_id = &id.toFrameId(event.frame_id);
        const loader_id = &id.toLoaderId(event.loader_id);
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .timestamp = timestamp,
            .name = "DOMContentLoaded",
            .frameId = frame_id,
            .loaderId = loader_id,
        }, .{ .session_id = session_id });
    }
}

pub fn frameLoaded(bc: anytype, event: *const Notification.FrameLoaded) !void {
    const session_id = bc.session_id orelse return;
    const timestamp = event.timestamp;
    var cdp = bc.cdp;

    const frame_id = &id.toFrameId(event.frame_id);

    try cdp.sendEvent(
        "Page.loadEventFired",
        .{ .timestamp = timestamp },
        .{ .session_id = session_id },
    );

    if (bc.page_life_cycle_events) {
        const loader_id = &id.toLoaderId(event.loader_id);
        try cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
            .timestamp = timestamp,
            .name = "load",
            .frameId = frame_id,
            .loaderId = loader_id,
        }, .{ .session_id = session_id });
    }

    return cdp.sendEvent("Page.frameStoppedLoading", .{
        .frameId = frame_id,
    }, .{ .session_id = session_id });
}

pub fn frameNetworkIdle(bc: *CDP.BrowserContext, event: *const Notification.FrameNetworkIdle) !void {
    return sendPageLifecycle(bc, "networkIdle", event.timestamp, &id.toFrameId(event.frame_id), &id.toLoaderId(event.loader_id));
}

pub fn frameNetworkAlmostIdle(bc: *CDP.BrowserContext, event: *const Notification.FrameNetworkAlmostIdle) !void {
    return sendPageLifecycle(bc, "networkAlmostIdle", event.timestamp, &id.toFrameId(event.frame_id), &id.toLoaderId(event.loader_id));
}

fn sendPageLifecycle(bc: *CDP.BrowserContext, name: []const u8, timestamp: u64, frame_id: []const u8, loader_id: []const u8) !void {
    // detachTarget could be called, in which case, we still have a frame doing
    // things, but no session.
    const session_id = bc.session_id orelse return;

    return bc.cdp.sendEvent("Page.lifecycleEvent", LifecycleEvent{
        .name = name,
        .frameId = frame_id,
        .loaderId = loader_id,
        .timestamp = timestamp,
    }, .{ .session_id = session_id });
}

// https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-handleJavaScriptDialog
fn handleJavaScriptDialog(cmd: *CDP.Command) !void {
    // Dialogs auto-dismiss in headless mode. By the time the CDP client
    // sends this command, the dialog has already returned and there is
    // no pending dialog to accept or dismiss.
    //
    // Lightpanda-aware clients that want to control confirm/prompt return
    // values can pre-arm a response via LP.handleJavaScriptDialog instead
    // (see src/cdp/domains/lp.zig).
    _ = try cmd.params(struct {
        accept: bool,
        promptText: ?[]const u8 = null,
    });
    return cmd.sendError(-32000, "No dialog is showing", .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-javascriptDialogOpening
pub fn javascriptDialogOpening(bc: anytype, event: *const Notification.JavascriptDialogOpening) !void {
    // Pop any response pre-armed via LP.handleJavaScriptDialog onto the
    // dispatch's output param so the calling alert/confirm/prompt returns
    // the CDP client's choice. Cleared unconditionally — a stash applies
    // to exactly one dialog.
    if (bc.pending_dialog_response) |pending| {
        event.response.* = pending;
        bc.pending_dialog_response = null;
    }

    const session_id = bc.session_id orelse return;
    var cdp = bc.cdp;

    try cdp.sendEvent("Page.javascriptDialogOpening", .{
        .url = event.url,
        .message = event.message,
        .type = event.dialog_type,
        .hasBrowserHandler = false,
        .defaultPrompt = "",
    }, .{ .session_id = session_id });
}

const FrameWriter = struct {
    frame: *const Frame,
    bc: *const CDP.BrowserContext,

    pub fn jsonStringify(self: *const FrameWriter, w: anytype) error{WriteFailed}!void {
        try w.beginObject();
        try write(self.bc, self.frame, w);
        try w.endObject();
    }

    fn write(bc: *const CDP.BrowserContext, frame: *const Frame, w: anytype) error{WriteFailed}!void {
        try w.objectField("id");
        try w.write(&id.toFrameId(frame._frame_id));

        if (frame.parent) |parent| {
            try w.objectField("parentId");
            try w.write(&id.toFrameId(parent._frame_id));
        }

        try w.objectField("loaderId");
        try w.write(&id.toLoaderId(frame._loader_id));

        try w.objectField("url");
        try w.write(frame.url);

        try w.objectField("domainAndRegistry");
        try w.write("");

        try w.objectField("securityOrigin");
        try w.write(frame.origin orelse bc.security_origin);

        try w.objectField("mimeType");
        try w.write("text/html");

        try w.objectField("adFrameStatus");
        try w.write(.{ .adFrameType = "none" });

        try w.objectField("secureContextType");
        try w.write(bc.secure_context_type);

        try w.objectField("crossOriginIsolatedContextType");
        try w.write("NotIsolated");

        try w.objectField("gatedAPIFeatures");
        try w.beginArray();
        try w.endArray();
    }
};

const FrameTreeWriter = struct {
    bc: *const CDP.BrowserContext,
    frame: *const Frame,

    pub fn jsonStringify(self: *const FrameTreeWriter, w: anytype) error{WriteFailed}!void {
        try write(self.bc, self.frame, w);
    }

    fn write(bc: *const CDP.BrowserContext, frame: *const Frame, w: anytype) error{WriteFailed}!void {
        try w.beginObject();

        try w.objectField("frame");
        try w.beginObject();
        try FrameWriter.write(bc, frame, w);
        try w.endObject();

        const child_frames = frame.child_frames.items;
        if (child_frames.len > 0) {
            try w.objectField("childFrames");
            try w.beginArray();
            for (child_frames) |child| {
                try write(bc, child, w);
            }
            try w.endArray();
        }

        try w.endObject();
    }
};

const LifecycleEvent = struct {
    frameId: []const u8,
    loaderId: ?[]const u8,
    name: []const u8,
    timestamp: u64,
};

const Viewport = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    scale: f64,
};

fn captureScreenshot(cmd: *CDP.Command) !void {
    const Params = struct {
        format: ?[]const u8 = "png",
        quality: ?u8 = null,
        clip: ?Viewport = null,
        fromSurface: ?bool = false,
        captureBeyondViewport: ?bool = false,
        optimizeForSpeed: ?bool = false,
    };
    const params = try cmd.params(Params) orelse Params{};

    const format = params.format orelse "png";
    if (!std.mem.eql(u8, format, "png")) {
        log.warn(.not_implemented, "Page.captureScreenshot params", .{ .format = format });
        return cmd.sendError(-32000, "unsupported screenshot format.", .{});
    }
    if (params.quality != null) {
        log.warn(.not_implemented, "Page.captureScreenshot params", .{ .quality = params.quality });
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;
    const viewport = cmd.cdp.browser.getViewport();

    var opts: lp.screenshot.Opts = .fromViewport(viewport, params.captureBeyondViewport orelse false);
    if (params.clip) |clip| {
        opts.clip = .{
            .x = @floatCast(clip.x),
            .y = @floatCast(clip.y),
            .width = @floatCast(clip.width),
            .height = @floatCast(clip.height),
        };
        opts.scale *= @floatCast(clip.scale);
    }

    // Prepared streams itself as base64 straight into the outgoing message.
    const shot = try lp.screenshot.preparePng(cmd.arena, frame.window._document.asNode(), opts, frame);
    return cmd.sendResult(.{ .data = shot }, .{});
}

fn printToPDF(cmd: *CDP.Command) !void {
    // Lengths in inches; Chrome's defaults.
    const Params = struct {
        landscape: bool = false,
        displayHeaderFooter: bool = false,
        printBackground: bool = false,
        scale: f32 = 1,
        paperWidth: f32 = 8.5,
        paperHeight: f32 = 11,
        marginTop: f32 = 0.4,
        marginBottom: f32 = 0.4,
        marginLeft: f32 = 0.4,
        marginRight: f32 = 0.4,
        pageRanges: []const u8 = "",
        transferMode: enum { ReturnAsBase64, ReturnAsStream } = .ReturnAsBase64,
    };
    const params = try cmd.params(Params) orelse Params{};
    if (params.displayHeaderFooter) {
        log.warn(.not_implemented, "Page.printToPDF params", .{ .displayHeaderFooter = true });
    }

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;

    const paper_w = if (params.landscape) params.paperHeight else params.paperWidth;
    const paper_h = if (params.landscape) params.paperWidth else params.paperHeight;
    const opts: lp.pdf.Opts = .{
        .paper_width = paper_w * 96,
        .paper_height = paper_h * 96,
        .margin_top = params.marginTop * 96,
        .margin_right = params.marginRight * 96,
        .margin_bottom = params.marginBottom * 96,
        .margin_left = params.marginLeft * 96,
        .scale = params.scale,
        .print_background = params.printBackground,
        .page_ranges = lp.pdf.parsePageRanges(cmd.arena, params.pageRanges) catch |err| switch (err) {
            error.InvalidPageRangeSyntax => return cmd.sendError(-32000, "Invalid page range syntax", .{}),
            error.InvalidPageRange => return cmd.sendError(-32000, "Invalid page range", .{}),
            error.OutOfMemory => return error.OutOfMemory,
        },
    };
    const prepared = lp.pdf.prepare(cmd.arena, frame.window._document.asNode(), opts, frame) catch |err| switch (err) {
        error.InvalidPdfOptions => return cmd.sendError(-32602, "invalid print parameters", .{}),
        error.PageRangeExceedsPageCount => return cmd.sendError(-32000, "Page range exceeds page count", .{}),
        else => return err,
    };

    if (params.transferMode == .ReturnAsBase64) {
        return cmd.sendResult(.{ .data = prepared }, .{});
    }

    // Read via IO.read
    var aw: std.Io.Writer.Allocating = .init(cmd.cdp.allocator);
    errdefer aw.deinit();
    try prepared.write(&aw.writer);
    const handle = try cmd.cdp.streams.add(try aw.toOwnedSlice());
    return cmd.sendResult(.{
        .data = "",
        .stream = try std.fmt.allocPrint(cmd.arena, "{d}", .{handle}),
    }, .{});
}

fn getLayoutMetrics(cmd: *CDP.Command) !void {
    // The viewport override lives on the Browser, so read it there directly:
    // it stays correct even when no page is currently loaded.
    const viewport = cmd.cdp.browser.getViewport();
    const width = viewport.width;
    const height = viewport.height;

    // Full-page height as our text rendering lays it out, so a fullPage
    // screenshot (getLayoutMetrics → captureScreenshot) is consistent.
    const content_height: u32 = blk: {
        const bc = cmd.browser_context orelse break :blk height;
        const frame = bc.mainFrame() orelse break :blk height;
        const h = lp.screenshot.contentHeight(cmd.arena, frame.window._document.asNode(), width, frame) catch break :blk height;
        break :blk @max(height, h);
    };

    return cmd.sendResult(.{
        .layoutViewport = .{
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
        },
        .visualViewport = .{
            .offsetX = 0,
            .offsetY = 0,
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
            .scale = 1,
            .zoom = 1,
        },
        .contentSize = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = content_height,
        },
        .cssLayoutViewport = .{
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
        },
        .cssVisualViewport = .{
            .offsetX = 0,
            .offsetY = 0,
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
            .scale = 1,
            .zoom = 1,
        },
        .cssContentSize = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = content_height,
        },
    }, .{});
}

const testing = @import("../testing.zig");
test "cdp.frame: setup no-ops" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-NOOP" });

    try ctx.processMessage(.{ .id = 1, .method = "Page.setBypassCSP", .params = .{ .enabled = true } });
    try ctx.expectSentResult(null, .{ .id = 1 });

    try ctx.processMessage(.{ .id = 2, .method = "Page.bringToFront" });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "Page.setInterceptFileChooserDialog", .params = .{ .enabled = true } });
    try ctx.expectSentResult(null, .{ .id = 3 });
}

test "cdp.frame: getFrameTree" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // no browser context - should return TID-STARTUP
        try ctx.processMessage(.{ .id = 1, .method = "Page.getFrameTree", .sessionId = "STARTUP" });
        try ctx.expectSentResult(.{
            .frameTree = .{
                .frame = .{
                    .id = "TID-STARTUP",
                    .loaderId = "LID-STARTUP",
                    .url = "about:blank",
                    .secureContextType = "Secure",
                },
            },
        }, .{ .id = 1, .session_id = "STARTUP" });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });
    const root = bc.mainFrame() orelse unreachable;
    const root_id = id.toFrameId(root._frame_id);
    {
        try ctx.processMessage(.{ .id = 11, .method = "Page.getFrameTree" });
        try ctx.expectSentResult(.{
            .frameTree = .{
                .frame = .{
                    .id = &root_id,
                    .loaderId = "LID-0000000001",
                    .url = "http://127.0.0.1:9582/src/browser/tests/hi.html",
                    .domainAndRegistry = "",
                    .securityOrigin = root.origin orelse bc.security_origin,
                    .mimeType = "text/html",
                    .adFrameStatus = .{
                        .adFrameType = "none",
                    },
                    .secureContextType = bc.secure_context_type,
                    .crossOriginIsolatedContextType = "NotIsolated",
                    .gatedAPIFeatures = [_][]const u8{},
                },
            },
        }, .{ .id = 11 });
    }

    {
        // STARTUP session is handled when a broweser context and a target id exists.
        try ctx.processMessage(.{ .id = 12, .method = "Page.getFrameTree", .session_id = "STARTUP" });
        try ctx.expectSentResult(.{
            .frameTree = .{
                .frame = .{
                    .id = &root_id,
                    .loaderId = "LID-0000000001",
                    .url = "http://127.0.0.1:9582/src/browser/tests/hi.html",
                    .domainAndRegistry = "",
                    .securityOrigin = root.origin orelse bc.security_origin,
                    .mimeType = "text/html",
                    .adFrameStatus = .{
                        .adFrameType = "none",
                    },
                    .secureContextType = bc.secure_context_type,
                    .crossOriginIsolatedContextType = "NotIsolated",
                    .gatedAPIFeatures = [_][]const u8{},
                },
            },
        }, .{ .id = 12 });
    }
}

test "cdp.frame: createIsolatedWorld is idempotent per name" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });
    const root = bc.mainFrame() orelse unreachable;
    const root_id = id.toFrameId(root._frame_id);

    try ctx.processMessage(.{ .id = 20, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &root_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });
    try testing.expectEqual(1, bc.isolated_worlds.items.len);
    const world_context = bc.isolated_worlds.items[0].contextFor(root).?;

    try ctx.processMessage(.{ .id = 21, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &root_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });
    try testing.expectEqual(1, bc.isolated_worlds.items.len);
    try testing.expectEqual(world_context, bc.isolated_worlds.items[0].contextFor(root).?);

    try ctx.processMessage(.{ .id = 22, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &root_id,
        .worldName = "other",
        .grantUniveralAccess = true,
    } });
    try testing.expectEqual(2, bc.isolated_worlds.items.len);

    try ctx.processMessage(.{ .id = 23, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = "FID-4000000000",
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });
    try ctx.expectSentError(-32000, "Frame with the given id does not belong to the target.", .{ .id = 23 });
}

// #3347: a world requested for a child frame must evaluate against that
// frame's document, survive the root world, and follow the child across its
// re-navigation.
test "cdp.frame: createIsolatedWorld targets the requested frame" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-IW", .url = "cdp/isolated_world.html", .target_id = "FID-000000000X".* });
    const root = bc.mainFrame() orelse unreachable;
    try testing.expectEqual(1, root.child_frames.items.len);
    const child = root.child_frames.items[0];
    const root_id = id.toFrameId(root._frame_id);
    const child_id = id.toFrameId(child._frame_id);

    try ctx.processMessage(.{ .id = 30, .method = "Runtime.enable", .sessionId = "SID-X" });

    try ctx.processMessage(.{ .id = 31, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &root_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });
    const root_ctx = try isolatedWorldContextId(bc, root);
    try ctx.expectSentResult(.{ .executionContextId = root_ctx }, .{ .id = 31 });

    try ctx.processMessage(.{ .id = 32, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &child_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });
    const child_ctx = try isolatedWorldContextId(bc, child);
    try testing.expect(child_ctx != root_ctx);
    try ctx.expectSentResult(.{ .executionContextId = child_ctx }, .{ .id = 32 });
    try ctx.expectSentEvent("Runtime.executionContextCreated", .{ .context = .{
        .id = child_ctx,
        .name = "utility",
        .auxData = .{ .isDefault = false, .type = "isolated", .frameId = &child_id },
    } }, .{ .session_id = "SID-X" });

    try ctx.processMessage(.{ .id = 33, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "document.title",
        .contextId = child_ctx,
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "Jobs page one" } }, .{ .id = 33 });

    // Navigate only the child. Its Frame is re-initialized in place: same
    // frame id, new document, and a new world context announced for it.
    try ctx.processMessage(.{ .id = 34, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "document.querySelector('iframe').src = 'isolated_world_two.html'",
    } });
    try testing.waitForPage(bc);
    try testing.expectEqual(child, root.child_frames.items[0]);
    try testing.expect(std.mem.endsWith(u8, child.url, "/cdp/isolated_world_two.html"));

    try ctx.expectSentEvent("Runtime.executionContextDestroyed", .{ .executionContextId = child_ctx }, .{ .session_id = "SID-X" });
    const child_ctx2 = try isolatedWorldContextId(bc, child);
    try testing.expect(child_ctx2 != child_ctx);
    try ctx.expectSentEvent("Runtime.executionContextCreated", .{ .context = .{
        .id = child_ctx2,
        .name = "utility",
        .auxData = .{ .isDefault = false, .type = "isolated", .frameId = &child_id },
    } }, .{ .session_id = "SID-X" });

    // A driver that re-requests the world gets the announced context.
    try ctx.processMessage(.{ .id = 35, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &child_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });
    try ctx.expectSentResult(.{ .executionContextId = child_ctx2 }, .{ .id = 35 });

    try ctx.processMessage(.{ .id = 36, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "document.title",
        .contextId = child_ctx2,
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "Jobs page two" } }, .{ .id = 36 });

    // The root world was untouched by the child navigation.
    try ctx.processMessage(.{ .id = 37, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "document.title",
        .contextId = root_ctx,
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "Parent jobs" } }, .{ .id = 37 });
}

// Chrome only puts a world in a frame on an explicit trigger. A world the
// client asked for on the root must not appear in a sibling frame just
// because that frame navigated afterwards.
test "cdp.frame: an unseeded frame gets no isolated world context" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-IWS", .url = "cdp/isolated_world.html", .target_id = "FID-000000000X".* });
    const root = bc.mainFrame() orelse unreachable;
    const child = root.child_frames.items[0];
    const root_id = id.toFrameId(root._frame_id);

    try ctx.processMessage(.{ .id = 30, .method = "Runtime.enable", .sessionId = "SID-X" });
    try ctx.processMessage(.{ .id = 31, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &root_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });

    const world = bc.findIsolatedWorld("utility") orelse unreachable;
    try testing.expect(world.contextFor(root) != null);

    // Navigating the child is what used to create a context for it.
    try ctx.processMessage(.{ .id = 32, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "document.querySelector('iframe').src = 'isolated_world_two.html'",
    } });
    try testing.waitForPage(bc);

    try testing.expect(world.isSeeded(root._frame_id));
    try testing.expect(world.isSeeded(child._frame_id) == false);
    try testing.expect(world.contextFor(child) == null);
}

// A worldName preload script is the one trigger that reaches frames the client
// never named, matching blink's InjectScripts. Puppeteer relies on it to give
// dynamically-added iframes a utility world.
test "cdp.frame: a worldName preload script seeds every frame" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-IWP", .url = "cdp/isolated_world.html", .target_id = "FID-000000000X".* });
    const root = bc.mainFrame() orelse unreachable;
    const child = root.child_frames.items[0];

    try ctx.processMessage(.{ .id = 30, .method = "Runtime.enable", .sessionId = "SID-X" });
    try ctx.processMessage(.{ .id = 31, .method = "Page.addScriptToEvaluateOnNewDocument", .params = .{
        .source = "globalThis.__seeded = 'yes';",
        .worldName = "utility",
    } });

    // Registering the script registers the world, but seeds nothing yet.
    const world = bc.findIsolatedWorld("utility") orelse unreachable;
    try testing.expect(world.contextFor(child) == null);

    try ctx.processMessage(.{ .id = 32, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "document.querySelector('iframe').src = 'isolated_world_two.html'",
    } });
    try testing.waitForPage(bc);

    // The child was never named in a Page.createIsolatedWorld, but the script
    // seeded it on navigation.
    try testing.expect(world.isSeeded(child._frame_id));
    const child_ctx = try isolatedWorldContextId(bc, child);
    try ctx.processMessage(.{ .id = 33, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "__seeded",
        .contextId = child_ctx,
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "yes" } }, .{ .id = 33 });

    // ...and ran there, not in the main world.
    try ctx.processMessage(.{ .id = 34, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "typeof globalThis.__seeded",
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "undefined" } }, .{ .id = 34 });
}

// puppeteer: the utility world is created on the bootstrap about:blank and
// must be announced again for the first document, which navigates the
// pristine Frame in place (no teardown, no frame_destroyed).
test "cdp.frame: isolated world survives the in-place first navigation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 40, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.processMessage(.{ .id = 41, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    const bc = &ctx.cdp().browser_context.?;
    const session_id = bc.session_id.?;
    const root = bc.mainFrame() orelse unreachable;
    const root_id = id.toFrameId(root._frame_id);

    try ctx.processMessage(.{ .id = 42, .method = "Runtime.enable", .sessionId = session_id });
    try ctx.processMessage(.{ .id = 43, .method = "Page.createIsolatedWorld", .sessionId = session_id, .params = .{
        .frameId = &root_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });
    const blank_ctx = try isolatedWorldContextId(bc, root);

    try ctx.processMessage(.{ .id = 44, .method = "Page.navigate", .sessionId = session_id, .params = .{
        .url = "http://127.0.0.1:9582/src/browser/tests/cdp/isolated_world_one.html",
    } });
    try testing.waitForPage(bc);
    try testing.expectEqual(root, bc.mainFrame().?);

    const page_ctx = try isolatedWorldContextId(bc, root);
    try testing.expect(page_ctx != blank_ctx);
    try ctx.expectSentEvent("Runtime.executionContextCreated", .{ .context = .{
        .id = page_ctx,
        .name = "utility",
        .auxData = .{ .isDefault = false, .type = "isolated", .frameId = &root_id },
    } }, .{ .session_id = session_id });

    try ctx.processMessage(.{ .id = 45, .method = "Runtime.evaluate", .sessionId = session_id, .params = .{
        .expression = "document.title",
        .contextId = page_ctx,
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "Jobs page one" } }, .{ .id = 45 });
}

// A committed root navigation tears the old Page down later, with the same
// frame id as the live page. That teardown must not take the live page's
// world context with it.
test "cdp.frame: isolated world survives the old page's deferred teardown" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-IW2", .url = "cdp/isolated_world_one.html", .target_id = "FID-000000000X".* });
    const old_root = bc.mainFrame() orelse unreachable;
    const old_frame_id = old_root._frame_id;
    const root_id = id.toFrameId(old_frame_id);

    try ctx.processMessage(.{ .id = 50, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &root_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });
    try testing.expect(bc.isolated_worlds.items[0].contextFor(old_root) != null);

    try ctx.processMessage(.{ .id = 51, .method = "Page.navigate", .sessionId = "SID-X", .params = .{
        .url = "http://127.0.0.1:9582/src/browser/tests/cdp/isolated_world_two.html",
    } });
    try testing.waitForPage(bc);
    bc.session.processDestroyQueues();

    // old_root is freed now; only its address is compared.
    const root = bc.mainFrame() orelse unreachable;
    try testing.expect(root != old_root);
    try testing.expectEqual(old_frame_id, root._frame_id);
    try testing.expectEqual(1, bc.isolated_worlds.items[0].contexts.items.len);

    const page_ctx = try isolatedWorldContextId(bc, root);
    try ctx.processMessage(.{ .id = 52, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "document.title",
        .contextId = page_ctx,
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "Jobs page two" } }, .{ .id = 52 });
}

test "cdp.frame: isolated world contexts share their frame's origin token" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-IW3", .url = "cdp/isolated_world.html", .target_id = "FID-000000000X".* });
    const root = bc.mainFrame() orelse unreachable;
    const child = root.child_frames.items[0];
    const root_id = id.toFrameId(root._frame_id);
    const child_id = id.toFrameId(child._frame_id);

    try ctx.processMessage(.{ .id = 60, .method = "Runtime.enable", .sessionId = "SID-X" });
    try ctx.processMessage(.{ .id = 61, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &root_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });
    try ctx.processMessage(.{ .id = 62, .method = "Page.createIsolatedWorld", .params = .{
        .frameId = &child_id,
        .worldName = "utility",
        .grantUniveralAccess = true,
    } });

    // frames[0] is the child's window in this world; same origin as the root,
    // so V8 must let the root's context through.
    try ctx.processMessage(.{ .id = 63, .method = "Runtime.evaluate", .sessionId = "SID-X", .params = .{
        .expression = "frames[0].document.title",
        .contextId = try isolatedWorldContextId(bc, root),
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "Jobs page one" } }, .{ .id = 63 });
}

fn isolatedWorldContextId(bc: *CDP.BrowserContext, frame: *const Frame) !i32 {
    const js_context = bc.isolated_worlds.items[0].contextFor(frame) orelse return error.ContextNotFound;
    var ls: js.Local.Scope = undefined;
    js_context.localScope(&ls);
    defer ls.deinit();
    return bc.inspector_session.inspector.getContextId(&ls.local);
}

test "cdp.frame: child frame metadata" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-FRAME", .url = "cdp/empty_iframe.html", .target_id = "FID-000000000X".* });
    const root = bc.mainFrame() orelse unreachable;
    try testing.expectEqual(1, root.child_frames.items.len);
    const child = root.child_frames.items[0];

    const root_id = id.toFrameId(root._frame_id);
    const child_id = id.toFrameId(child._frame_id);
    const child_loader_id = id.toLoaderId(child._loader_id);

    try ctx.expectSentEvent("Page.frameNavigated", .{
        .frame = .{
            .id = &child_id,
            .parentId = &root_id,
            .loaderId = &child_loader_id,
            .url = "about:blank",
        },
    }, .{ .session_id = "SID-X" });

    try ctx.processMessage(.{ .id = 13, .method = "Page.getFrameTree" });
    try ctx.expectSentResult(.{
        .frameTree = .{
            .frame = .{ .id = &root_id },
            .childFrames = &.{.{
                .frame = .{
                    .id = &child_id,
                    .parentId = &root_id,
                    .loaderId = &child_loader_id,
                    .url = "about:blank",
                },
            }},
        },
    }, .{ .id = 13 });
}

test "cdp.frame: frameAttached" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .session_id = "SID-X" });

    bc.notification.dispatch(.frame_child_frame_created, &.{
        .frame_id = 2,
        .parent_id = 1,
        .loader_id = 7,
        .timestamp = 0,
    });

    try ctx.expectSentEvent("Page.frameAttached", .{
        .frameId = "FID-0000000002",
        .parentFrameId = "FID-0000000001",
    }, .{ .session_id = "SID-X" });
}

test "cdp.frame: child navigation preserves node registry" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .url = "hi.html" });
    const root_frame = bc.mainFrame().?;
    const node = try bc.node_registry.register(root_frame.window._document.asNode());
    const node_id = node.id;

    try frameNavigate(bc, &.{
        .req_id = 1,
        .frame_id = root_frame._frame_id + 1,
        .loader_id = 2,
        .timestamp = 0,
        .url = "about:blank",
        .opts = .{},
    });
    try testing.expectEqual(node, bc.node_registry.lookup_by_id.get(node_id).?);

    try frameNavigate(bc, &.{
        .req_id = 2,
        .frame_id = root_frame._frame_id,
        .loader_id = 3,
        .timestamp = 0,
        .url = "about:blank",
        .opts = .{},
    });
    try testing.expectEqual(null, bc.node_registry.lookup_by_id.get(node_id));
}

test "cdp.frame: captureScreenshot" {
    testing.silenceLog(&.{.not_implemented});

    var ctx = try testing.context();
    defer ctx.deinit();
    {
        try ctx.processMessage(.{ .id = 10, .method = "Page.captureScreenshot", .params = .{ .format = "jpg" } });
        try ctx.expectSentError(-32000, "unsupported screenshot format.", .{ .id = 10 });
    }

    _ = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    // Keep the payload small: the test transport buffers 32KB frames.
    try ctx.processMessage(.{ .id = 10, .method = "Emulation.setDeviceMetricsOverride", .params = .{ .width = 400, .height = 300 } });

    {
        // Viewport-sized: the PNG header carries the size.
        try ctx.processMessage(.{ .id = 11, .method = "Page.captureScreenshot" });
        const png = try screenshotResult(&ctx, 11);
        try testing.expectEqual(400, std.mem.readInt(u32, png[16..20], .big));
        try testing.expectEqual(300, std.mem.readInt(u32, png[20..24], .big));
    }

    {
        // clip + scale crops after layout and scales the raster.
        try ctx.processMessage(.{ .id = 12, .method = "Page.captureScreenshot", .params = .{
            .clip = .{ .x = 0, .y = 0, .width = 100, .height = 40, .scale = 2 },
        } });
        const png = try screenshotResult(&ctx, 12);
        try testing.expectEqual(200, std.mem.readInt(u32, png[16..20], .big));
        try testing.expectEqual(80, std.mem.readInt(u32, png[20..24], .big));
    }

    try ctx.processMessage(.{ .id = 13, .method = "Emulation.setDeviceMetricsOverride", .params = .{
        .width = 200,
        .height = 100,
        .deviceScaleFactor = 2,
    } });

    {
        // deviceScaleFactor alone rasters at 2x; the viewport stays CSS px.
        try ctx.processMessage(.{ .id = 14, .method = "Page.captureScreenshot" });
        const png = try screenshotResult(&ctx, 14);
        try testing.expectEqual(400, std.mem.readInt(u32, png[16..20], .big));
        try testing.expectEqual(200, std.mem.readInt(u32, png[20..24], .big));
    }

    {
        // clip.scale is a zoom on top of it, not a replacement: 2 * 2 = 4x.
        try ctx.processMessage(.{ .id = 15, .method = "Page.captureScreenshot", .params = .{
            .clip = .{ .x = 0, .y = 0, .width = 50, .height = 20, .scale = 2 },
        } });
        const png = try screenshotResult(&ctx, 15);
        try testing.expectEqual(200, std.mem.readInt(u32, png[16..20], .big));
        try testing.expectEqual(80, std.mem.readInt(u32, png[20..24], .big));
    }

    {
        // A width/height of 0 keeps the current values, and so does a
        // deviceScaleFactor of 0.
        try ctx.processMessage(.{ .id = 16, .method = "Emulation.setDeviceMetricsOverride", .params = .{
            .width = 0,
            .height = 0,
            .deviceScaleFactor = 0,
        } });
        try ctx.processMessage(.{ .id = 17, .method = "Page.captureScreenshot" });
        const png = try screenshotResult(&ctx, 17);
        try testing.expectEqual(400, std.mem.readInt(u32, png[16..20], .big));
        try testing.expectEqual(200, std.mem.readInt(u32, png[20..24], .big));
    }
}

fn screenshotResult(ctx: *testing.TestContext, msg_id: i64) ![]const u8 {
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const obj = msg.object;
        const got = obj.get("id") orelse continue;
        if (got != .integer or got.integer != msg_id) continue;
        const data = obj.get("result").?.object.get("data").?.string;
        const decoder = std.base64.standard.Decoder;
        const out = try testing.arena_allocator.alloc(u8, try decoder.calcSizeForSlice(data));
        try decoder.decode(out, data);
        try testing.expectEqual("\x89PNG\r\n\x1a\n", out[0..8]);
        return out;
    }
    return error.ResultNotFound;
}

test "cdp.frame: printToPDF" {
    testing.silenceLog(&.{.not_implemented});

    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    {
        try ctx.processMessage(.{ .id = 10, .method = "Page.printToPDF", .params = .{ .scale = 5 } });
        try ctx.expectSentError(-32602, "invalid print parameters", .{ .id = 10 });

        // Chrome's three page-range errors.
        try ctx.processMessage(.{ .id = 20, .method = "Page.printToPDF", .params = .{ .pageRanges = "x" } });
        try ctx.expectSentError(-32000, "Invalid page range syntax", .{ .id = 20 });
        try ctx.processMessage(.{ .id = 21, .method = "Page.printToPDF", .params = .{ .pageRanges = "3-1" } });
        try ctx.expectSentError(-32000, "Invalid page range", .{ .id = 21 });
        try ctx.processMessage(.{ .id = 22, .method = "Page.printToPDF", .params = .{ .pageRanges = "9" } });
        try ctx.expectSentError(-32000, "Page range exceeds page count", .{ .id = 22 });
    }

    {
        // Inline base64, landscape: Letter swapped, in points.
        try ctx.processMessage(.{ .id = 11, .method = "Page.printToPDF", .params = .{ .landscape = true } });
        const pdf = try pdfResult(&ctx, 11);
        try testing.expectEqual(true, std.mem.indexOf(u8, pdf, "/MediaBox [0 0 792.000 612.000]") != null);
    }

    {
        // The stream mode drivers use: a handle, then IO.read until eof.
        try ctx.processMessage(.{ .id = 12, .method = "Page.printToPDF", .params = .{ .transferMode = "ReturnAsStream" } });
        const handle = try streamHandle(&ctx, 12);

        try ctx.processMessage(.{ .id = 13, .method = "IO.read", .params = .{ .handle = handle, .size = 16 } });
        const head = try ioReadResult(&ctx, 13, false);
        try testing.expectEqual("%PDF-1.4\n", head[0..9]);

        try ctx.processMessage(.{ .id = 14, .method = "IO.read", .params = .{ .handle = handle } });
        const rest = try ioReadResult(&ctx, 14, true);
        try testing.expectEqual("%%EOF\n", rest[rest.len - 6 ..]);

        try ctx.processMessage(.{ .id = 15, .method = "IO.close", .params = .{ .handle = handle } });
        try ctx.expectSentResult(null, .{ .id = 15 });

        try ctx.processMessage(.{ .id = 16, .method = "IO.read", .params = .{ .handle = handle } });
        try ctx.expectSentError(-32000, "Invalid stream handle", .{ .id = 16 });
    }
}

fn pdfResult(ctx: *testing.TestContext, msg_id: i64) ![]const u8 {
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const obj = msg.object;
        const got = obj.get("id") orelse continue;
        if (got != .integer or got.integer != msg_id) continue;
        const data = obj.get("result").?.object.get("data").?.string;
        const decoder = std.base64.standard.Decoder;
        const out = try testing.arena_allocator.alloc(u8, try decoder.calcSizeForSlice(data));
        try decoder.decode(out, data);
        try testing.expectEqual("%PDF-1.4\n", out[0..9]);
        return out;
    }
    return error.ResultNotFound;
}

fn streamHandle(ctx: *testing.TestContext, msg_id: i64) ![]const u8 {
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const obj = msg.object;
        const got = obj.get("id") orelse continue;
        if (got != .integer or got.integer != msg_id) continue;
        const result = obj.get("result").?.object;
        try testing.expectEqual("", result.get("data").?.string);
        return try testing.arena_allocator.dupe(u8, result.get("stream").?.string);
    }
    return error.ResultNotFound;
}

fn ioReadResult(ctx: *testing.TestContext, msg_id: i64, expect_eof: bool) ![]const u8 {
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const obj = msg.object;
        const got = obj.get("id") orelse continue;
        if (got != .integer or got.integer != msg_id) continue;
        const result = obj.get("result").?.object;
        try testing.expectEqual(true, result.get("base64Encoded").?.bool);
        try testing.expectEqual(expect_eof, result.get("eof").?.bool);
        const data = result.get("data").?.string;
        const decoder = std.base64.standard.Decoder;
        const out = try testing.arena_allocator.alloc(u8, try decoder.calcSizeForSlice(data));
        try decoder.decode(out, data);
        return out;
    }
    return error.ResultNotFound;
}

test "cdp.frame: getLayoutMetrics" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    const width = 1920;
    const height = 1080;

    try ctx.processMessage(.{ .id = 12, .method = "Page.getLayoutMetrics" });
    try ctx.expectSentResult(.{
        .layoutViewport = .{
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
        },
        .visualViewport = .{
            .offsetX = 0,
            .offsetY = 0,
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
            .scale = 1,
            .zoom = 1,
        },
        .contentSize = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        },
        .cssLayoutViewport = .{
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
        },
        .cssVisualViewport = .{
            .offsetX = 0,
            .offsetY = 0,
            .pageX = 0,
            .pageY = 0,
            .clientWidth = width,
            .clientHeight = height,
            .scale = 1,
            .zoom = 1,
        },
        .cssContentSize = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        },
    }, .{ .id = 12 });
}

test "cdp.frame: reload" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // reload without browser context — should error
        try ctx.processMessage(.{ .id = 30, .method = "Page.reload" });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 30 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    {
        // reload with no params — should not error (navigation is async,
        // so no result is sent synchronously; we just verify no error)
        try ctx.processMessage(.{ .id = 31, .method = "Page.reload" });
        try testing.waitForPage(bc);
    }

    {
        // reload with ignoreCache param
        try ctx.processMessage(.{ .id = 32, .method = "Page.reload", .params = .{ .ignoreCache = true } });
        try testing.waitForPage(bc);
    }
}

test "cdp.page: stopLoading finishes a streaming document with what has arrived" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-SL1", .session_id = "SID-SL1", .target_id = "TID-SL1-000000".* });
    _ = try bc.session.createPage();
    try ctx.processMessage(.{ .id = 40, .method = "Page.navigate", .params = .{ .url = "http://127.0.0.1:9582/stop_loading/streaming.html" } });

    // Tick until the first chunk has arrived; the server holds the rest back.
    var runner = bc.session.runner(.{});
    const frame_id = bc.page_handle.?.frame_id;
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        _ = try runner.tickForFrame(frame_id, 20, .{});
        const frame = bc.mainFrame() orelse unreachable;
        if (bc.session.browser.http_client.findTransfer(frame._req_id)) |transfer| {
            if (std.mem.indexOf(u8, transfer.res.buffer.items, "first") != null) {
                break;
            }
        }
        if (attempts == 200) {
            return error.FirstChunkNeverArrived;
        }
    }

    try ctx.processMessage(.{ .id = 41, .method = "Page.stopLoading" });
    try ctx.expectSentResult(null, .{ .id = 41 });
    try testing.waitForPage(bc);

    // Blink semantics: the parser is cancelled, the document finishes with
    // what arrived, and load fires. No "Navigation failed" placeholder.
    const frame = bc.mainFrame() orelse unreachable;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const v = try ls.local.exec("document.readyState === 'complete' && document.getElementById('first') !== null && document.getElementById('second') === null && document.querySelector('h1') === null", null);
    try testing.expect(v.toBool());
}

test "cdp.page: stopLoading cancels an uncommitted root navigation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-SL2", .session_id = "SID-SL2", .target_id = "TID-SL2-000000".*, .url = "hi.html" });
    const live = bc.mainPage() orelse unreachable;

    // Slow origin: no headers arrive before we stop, so the navigation never commits.
    try ctx.processMessage(.{ .id = 50, .method = "Page.navigate", .params = .{ .url = "http://127.0.0.1:9582/src/browser/tests/hi.html?delay_ms=1000" } });
    try testing.expect(bc.session.replacementOf(live) != null);

    try ctx.processMessage(.{ .id = 51, .method = "Page.stopLoading" });
    // The pending Page.navigate is answered the way Chrome answers a stopped one...
    try ctx.expectSentResult(.{ .errorText = "net::ERR_ABORTED" }, .{ .id = 50, .session_id = "SID-SL2" });
    try ctx.expectSentResult(null, .{ .id = 51 });

    // ...and the live page is untouched and still scriptable.
    try testing.expectEqual(null, bc.session.replacementOf(live));
    try testing.expect(live == bc.mainPage().?);
    const frame = bc.mainFrame() orelse unreachable;
    try testing.expect(std.mem.endsWith(u8, frame.url, "/hi.html"));

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const v = try ls.local.exec("document.readyState === 'complete'", null);
    try testing.expect(v.toBool());
}

test "cdp.frame: reload replays POST navigation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    // Manually wire up the browser context: loadBrowserContext only does GET
    // navigations, but we need the first navigation to be POST.
    const cdp_inst = ctx.cdp();
    _ = try cdp_inst.createBrowserContext();
    var bc = &cdp_inst.browser_context.?;
    bc.id = "BID-A6";
    bc.session_id = "SID-X";
    bc.target_id = "TID-A6-0000000".*;

    // First navigation: POST a form-style payload to /echo_method.
    {
        const page = try bc.session.createPage();
        try page.navigate("http://127.0.0.1:9582/echo_method", .{
            .method = .POST,
            .body = "key=value",
            .header = "Content-Type: application/x-www-form-urlencoded",
        });
        try testing.waitForPage(bc);
    }

    // Sanity: the body confirms a POST round-tripped.
    {
        const f = bc.mainFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('method=POST')", null);
        try testing.expect(v.toBool());
    }

    // Trigger a CDP reload. With the fix in place, doReload captures the
    // prior POST method/body/header and replays them. Without it (regression
    // guard), the second request would silently fall back to GET.
    try ctx.processMessage(.{ .id = 50, .method = "Page.reload" });
    try testing.waitForPage(bc);

    {
        const f = bc.mainFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('method=POST')", null);
        try testing.expect(v.toBool());
    }
}

test "cdp.frame: reload after POST→redirect drops the POST" {
    // RFC 7231 §6.4.3 / §6.4.4: 302 and 303 responses to a POST cause the
    // user agent to convert the followup request to GET. The page that
    // actually loaded did so via GET, so a later Page.reload must NOT replay
    // the original POST body to the redirect target.
    var ctx = try testing.context();
    defer ctx.deinit();

    const cdp_inst = ctx.cdp();
    _ = try cdp_inst.createBrowserContext();
    var bc = &cdp_inst.browser_context.?;
    bc.id = "BID-A6R";
    bc.session_id = "SID-XR";
    bc.target_id = "TID-A6R-000000".*;

    // First navigation: POST /redirect_to_echo → 302 → GET /echo_method.
    {
        const page = try bc.session.createPage();
        try page.navigate("http://127.0.0.1:9582/redirect_to_echo", .{
            .method = .POST,
            .body = "key=value",
            .header = "Content-Type: application/x-www-form-urlencoded",
        });
        try testing.waitForPage(bc);
    }

    // Sanity: after the redirect, the loaded page is /echo_method via GET.
    {
        const f = bc.mainFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('method=GET')", null);
        try testing.expect(v.toBool());
    }

    // Reload. The request that produced the current page was GET, so the
    // reload must also be GET — not a re-POST of the original form data.
    try ctx.processMessage(.{ .id = 60, .method = "Page.reload" });
    try testing.waitForPage(bc);

    {
        const f = bc.mainFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('method=GET')", null);
        try testing.expect(v.toBool());
    }
}

test "cdp.frame: navigate inherits original fragment across redirect" {
    // RFC 7231 §7.1.2: when a 3xx Location header has no fragment, the redirect
    // inherits the fragment of the request URL.
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    {
        // Location: /redirect-target  (no fragment) — must inherit #myfrag.
        try ctx.processMessage(.{
            .id = 40,
            .method = "Page.navigate",
            .params = .{ .url = "http://127.0.0.1:9582/redirect-no-fragment#myfrag" },
        });
        try testing.waitForPage(bc);

        const frame = bc.mainFrame() orelse unreachable;
        try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/redirect-target#myfrag", frame.url);
    }

    {
        // Location: /redirect-target#target_fragment — target's fragment wins.
        try ctx.processMessage(.{
            .id = 41,
            .method = "Page.navigate",
            .params = .{ .url = "http://127.0.0.1:9582/redirect-with-fragment#requested" },
        });
        try testing.waitForPage(bc);

        const frame = bc.mainFrame() orelse unreachable;
        try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/redirect-target#target_fragment", frame.url);
    }

    {
        // No fragment on either side — final URL has no fragment.
        try ctx.processMessage(.{
            .id = 42,
            .method = "Page.navigate",
            .params = .{ .url = "http://127.0.0.1:9582/redirect-no-fragment" },
        });
        try testing.waitForPage(bc);

        const frame = bc.mainFrame() orelse unreachable;
        try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/redirect-target", frame.url);
    }
}

test "cdp.frame: navigate renders body of 3xx response without Location" {
    // RFC 9110 §15.4: a 3xx response without a Location header is not a
    // redirect — it's a final response whose body must be delivered, like
    // any other status. It must not abort the navigation.
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-3XX", .url = "hi.html", .target_id = "FID-0000003XX0".* });

    try ctx.processMessage(.{
        .id = 50,
        .method = "Page.navigate",
        .params = .{ .url = "http://127.0.0.1:9582/303-no-location" },
    });
    try testing.waitForPage(bc);

    const frame = bc.mainFrame() orelse unreachable;
    try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/303-no-location", frame.url);

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const v = try ls.local.exec("document.title === 'landed' && document.body.innerText.includes('see other body')", null);
    try testing.expect(v.toBool());
}

test "cdp.frame: navigate does not follow Location on a non-redirect 3xx" {
    // The fetch standard's redirect statuses are exactly 301, 302, 303, 307
    // and 308. A 300 (Multiple Choices) may carry a Location header as a
    // preference hint, but it is not a redirect: the response itself must be
    // delivered and the Location must not be followed.
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-300L", .url = "hi.html", .target_id = "FID-0000003000".* });

    try ctx.processMessage(.{
        .id = 51,
        .method = "Page.navigate",
        .params = .{ .url = "http://127.0.0.1:9582/300-with-location" },
    });
    try testing.waitForPage(bc);

    const frame = bc.mainFrame() orelse unreachable;
    try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/300-with-location", frame.url);

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const v = try ls.local.exec("document.title === 'choices' && document.body.innerText.includes('multiple choices body')", null);
    try testing.expect(v.toBool());
}

test "cdp.frame: navigate answers with errorText when the navigation fails" {
    testing.silenceLog(&.{.frame});

    // A root navigation that fails before commit (here: connection refused —
    // nothing listens on port 1) must still answer the Page.navigate command.
    // Chrome resolves it with an errorText field ("present if and only if
    // navigation has failed"); leaving the command id unanswered forever
    // deadlocks clients that await the response.
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-NAVF", .url = "hi.html", .target_id = "FID-000000NAVF".* });

    try ctx.processMessage(.{
        .id = 52,
        .method = "Page.navigate",
        .params = .{ .url = "http://127.0.0.1:1/unreachable" },
    });
    try testing.waitForPage(bc);

    // The pending page was discarded; the active document is untouched.
    const frame = bc.mainFrame() orelse unreachable;
    try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/src/browser/tests/hi.html", frame.url);

    try ctx.expectSentResult(.{
        .frameId = "FID-0000000001",
        .loaderId = "LID-0000000002",
        .errorText = "CouldntConnect",
    }, .{ .id = 52 });
}

test "cdp.frame: navigate to about:blank replaces a non-blank document" {
    // Regression test for #2363. Page.navigate("about:blank") issued against a
    // tab that already holds a real document must replace the active document
    // with a fresh about:blank page — not leave the previous page in place.
    // A synthetic (no-HTTP) navigation has no response-headers callback to
    // commit a pending Page, so it must swap the active Page immediately.
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-AB", .url = "hi.html", .target_id = "TID-AB-0000000".* });

    // Precondition: the tab is on a non-blank document.
    {
        const frame = bc.mainFrame() orelse unreachable;
        try testing.expect(std.mem.endsWith(u8, frame.url, "/hi.html"));
    }

    try ctx.processMessage(.{ .id = 70, .method = "Page.navigate", .params = .{ .url = "about:blank" } });
    try testing.waitForPage(bc);

    // The active frame must now point at the replaced about:blank document.
    const frame = bc.mainFrame() orelse unreachable;
    try testing.expectEqualSlices(u8, "about:blank", frame.url);

    // ...and the active page's JS context must agree — the exact symptom in the
    // bug report was window.location.href staying on the previous URL.
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const v = try ls.local.exec("window.location.href === 'about:blank'", null);
    try testing.expect(v.toBool());
}

// https://github.com/lightpanda-io/browser/issues/3215
test "cdp.frame: first navigation replaces the bootstrap about:blank global" {
    var ctx = try testing.context();
    defer ctx.deinit();

    // A fresh, attached target sitting on its bootstrap about:blank document.
    try ctx.processMessage(.{ .id = 69, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.processMessage(.{ .id = 70, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    const bc = &ctx.cdp().browser_context.?;
    {
        const frame = bc.mainFrame() orelse unreachable;
        try testing.expectEqualSlices(u8, "about:blank", frame.url);
    }

    // A client runs JS on the blank page before navigating. This must go
    // through the CDP Runtime domain: that is what marks the bootstrap main
    // world as touched and disables the in-place navigation fast path.
    try ctx.processMessage(.{
        .id = 71,
        .method = "Runtime.evaluate",
        .params = .{ .expression = "window.leak = 'set-on-about-blank'; window.leak" },
        .sessionId = bc.session_id.?,
    });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "set-on-about-blank" } }, .{ .id = 71 });
    {
        const frame = bc.mainFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("window.leak === 'set-on-about-blank'", null);
        try testing.expect(v.toBool());
    }

    // First real navigation. It must NOT inherit the about:blank global.
    try ctx.processMessage(.{
        .id = 72,
        .method = "Page.navigate",
        .params = .{ .url = "http://127.0.0.1:9582/src/browser/tests/cdp/dom1.html" },
        .sessionId = bc.session_id.?,
    });
    try testing.waitForPage(bc);

    const frame = bc.mainFrame() orelse unreachable;
    try testing.expect(std.mem.endsWith(u8, frame.url, "/cdp/dom1.html"));

    // The leaked global must be gone: the navigation created a fresh global.
    var ls2: js.Local.Scope = undefined;
    frame.js.localScope(&ls2);
    defer ls2.deinit();
    const v2 = try ls2.local.exec("window.leak === undefined", null);
    try testing.expect(v2.toBool());
}

test "cdp.frame: first navigation of a pristine bootstrap about:blank navigates in place" {
    // Counterpart of the #3215 test: with no client JS on the bootstrap page,
    // the first Page.navigate keeps the in-place fast path (no pending Page).
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-PRS", .target_id = "TID-PRS-000000".* });
    bc.session_id = "SID-PRS";
    _ = try bc.session.createPage();
    const before = bc.mainFrame() orelse unreachable;
    try testing.expectEqualSlices(u8, "about:blank", before.url);

    try ctx.processMessage(.{
        .id = 73,
        .method = "Page.navigate",
        .params = .{ .url = "http://127.0.0.1:9582/src/browser/tests/cdp/dom1.html" },
    });
    try testing.waitForPage(bc);

    const after = bc.mainFrame() orelse unreachable;
    try testing.expect(before == after);
    try testing.expect(std.mem.endsWith(u8, after.url, "/cdp/dom1.html"));
}

test "cdp.frame: anchor click sends Referer matching the originating page" {
    // HTML Living Standard "navigate" algorithm + Fetch §4.5 "request's referrer":
    // when a navigation is initiated by a hyperlink click (or form submit, or
    // location.href assignment), the resulting request carries a Referer
    // header equal to the originating document's URL.
    var ctx = try testing.context();
    defer ctx.deinit();

    const cdp_inst = ctx.cdp();
    _ = try cdp_inst.createBrowserContext();
    var bc = &cdp_inst.browser_context.?;
    bc.id = "BID-A18";
    bc.session_id = "SID-A18";
    bc.target_id = "TID-A18-000000".*;

    // Initial navigation to the page hosting the anchor — driven directly via
    // Frame.navigate(.address_bar), so this request itself has no Referer.
    {
        const page = try bc.session.createPage();
        try page.navigate("http://127.0.0.1:9582/referer_link.html", .{});
        try testing.waitForPage(bc);
    }

    // Click the anchor via JS. The click goes through Frame.scheduleNavigation
    // (.reason = .script), which must capture the originating frame's URL as
    // the Referer for the queued navigation.
    {
        const f = bc.mainFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec("document.getElementById('link').click()", null);
        try testing.waitForPage(bc);
    }

    // After the click navigation completes, the loaded page is /echo_referer
    // and its body echoes the Referer header the server actually saw.
    {
        const f = bc.mainFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec(
            "document.body.innerText.includes('referer=http://127.0.0.1:9582/referer_link.html')",
            null,
        );
        try testing.expect(v.toBool());
    }
}

test "cdp.frame: address-bar Page.navigate sends no Referer" {
    // Regression guard: navigations initiated by the user agent itself (CDP
    // Page.navigate, address-bar typed URLs, Page.reload) must not leak the
    // previous page's URL as Referer. Matches Chrome.
    var ctx = try testing.context();
    defer ctx.deinit();

    const cdp_inst = ctx.cdp();
    _ = try cdp_inst.createBrowserContext();
    var bc = &cdp_inst.browser_context.?;
    bc.id = "BID-A18B";
    bc.session_id = "SID-A18B";
    bc.target_id = "TID-A18B-00000".*;

    {
        const page = try bc.session.createPage();
        try page.navigate("http://127.0.0.1:9582/echo_referer", .{});
        try testing.waitForPage(bc);
    }

    {
        const f = bc.mainFrame() orelse unreachable;
        var ls: js.Local.Scope = undefined;
        f.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("document.body.innerText.includes('referer=NONE')", null);
        try testing.expect(v.toBool());
    }
}

test "cdp.frame: addScriptToEvaluateOnNewDocument" {
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    {
        // Register a script — should return unique identifier "1"
        try ctx.processMessage(.{ .id = 20, .method = "Page.addScriptToEvaluateOnNewDocument", .params = .{ .source = "window.__test = 1" } });
        try ctx.expectSentResult(.{
            .identifier = "1",
        }, .{ .id = 20 });
    }

    {
        // Register another script — should return identifier "2"
        try ctx.processMessage(.{ .id = 21, .method = "Page.addScriptToEvaluateOnNewDocument", .params = .{ .source = "window.__test2 = 2" } });
        try ctx.expectSentResult(.{
            .identifier = "2",
        }, .{ .id = 21 });
    }

    {
        // Remove the first script — should succeed
        try ctx.processMessage(.{ .id = 22, .method = "Page.removeScriptToEvaluateOnNewDocument", .params = .{ .identifier = "1" } });
        try ctx.expectSentResult(null, .{ .id = 22 });
    }

    {
        // Remove a non-existent identifier — should succeed silently
        try ctx.processMessage(.{ .id = 23, .method = "Page.removeScriptToEvaluateOnNewDocument", .params = .{ .identifier = "999" } });
        try ctx.expectSentResult(null, .{ .id = 23 });
    }

    {
        try ctx.processMessage(.{ .id = 34, .method = "Page.reload" });
        // wait for this event, which is sent after we've run the registered scripts
        try ctx.expectSentEvent("Page.frameNavigated", .{
            .frame = .{ .loaderId = "LID-0000000002" },
        }, .{});

        const frame = bc.mainFrame() orelse unreachable;

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const test_val = try ls.local.exec("window.__test2", null);
        try testing.expectEqual(2, try test_val.toI32());
    }
}

test "cdp.frame: getNavigationHistory + navigateToHistoryEntry" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        // No browser context — should error.
        try ctx.processMessage(.{ .id = 10, .method = "Page.getNavigationHistory" });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }
    {
        try ctx.processMessage(.{ .id = 11, .method = "Page.navigateToHistoryEntry", .params = .{ .entryId = 0 } });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 11 });
    }

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-B2", .url = "cdp/dom1.html", .target_id = "TID-B2-0000000".* });

    // Build up history: dom1.html (from loadBrowserContext) → dom2.html → dom3.html.
    {
        try ctx.processMessage(.{
            .id = 20,
            .method = "Page.navigate",
            .params = .{ .url = "http://127.0.0.1:9582/src/browser/tests/cdp/dom2.html" },
        });
        try testing.waitForPage(bc);
    }
    {
        try ctx.processMessage(.{
            .id = 21,
            .method = "Page.navigate",
            .params = .{ .url = "http://127.0.0.1:9582/src/browser/tests/cdp/dom3.html" },
        });
        try testing.waitForPage(bc);
    }

    // Three entries (ids 0, 1, 2), currentIndex points at the most-recent.
    {
        try ctx.processMessage(.{ .id = 30, .method = "Page.getNavigationHistory" });
        try ctx.expectSentResult(.{
            .currentIndex = 2,
            .entries = &[_]NavigationEntry{
                .{
                    .id = 0,
                    .url = "http://127.0.0.1:9582/src/browser/tests/cdp/dom1.html",
                    .userTypedURL = "http://127.0.0.1:9582/src/browser/tests/cdp/dom1.html",
                    .title = "",
                    .transitionType = "other",
                },
                .{
                    .id = 1,
                    .url = "http://127.0.0.1:9582/src/browser/tests/cdp/dom2.html",
                    .userTypedURL = "http://127.0.0.1:9582/src/browser/tests/cdp/dom2.html",
                    .title = "",
                    .transitionType = "other",
                },
                .{
                    .id = 2,
                    .url = "http://127.0.0.1:9582/src/browser/tests/cdp/dom3.html",
                    .userTypedURL = "http://127.0.0.1:9582/src/browser/tests/cdp/dom3.html",
                    .title = "",
                    .transitionType = "other",
                },
            },
        }, .{ .id = 30 });
    }

    // Traverse back to the first entry.
    {
        try ctx.processMessage(.{
            .id = 40,
            .method = "Page.navigateToHistoryEntry",
            .params = .{ .entryId = 0 },
        });
        try testing.waitForPage(bc);

        const f = bc.mainFrame() orelse unreachable;
        try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/src/browser/tests/cdp/dom1.html", f.url);
    }

    // Traverse forward to the middle entry.
    {
        try ctx.processMessage(.{
            .id = 41,
            .method = "Page.navigateToHistoryEntry",
            .params = .{ .entryId = 1 },
        });
        try testing.waitForPage(bc);

        const f = bc.mainFrame() orelse unreachable;
        try testing.expectEqualSlices(u8, "http://127.0.0.1:9582/src/browser/tests/cdp/dom2.html", f.url);
    }

    // Unknown entryId — InvalidParams.
    {
        try ctx.processMessage(.{
            .id = 42,
            .method = "Page.navigateToHistoryEntry",
            .params = .{ .entryId = 9999 },
        });
        try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 42 });
    }
}

test "cdp.frame: history.pushState emits Page.navigatedWithinDocument" {
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-9", .url = "hi.html", .target_id = "FID-000000000X".* });

    const frame = bc.mainFrame() orelse unreachable;

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec("history.pushState({}, '', '/next')", null);
    }

    // Same-document navigation must surface as Page.navigatedWithinDocument
    // (not a full Page.frameNavigated), carrying the new URL and the
    // history-API navigation type. The main frame is assigned the internal
    // id FID-0000000001.
    try ctx.expectSentEvent("Page.navigatedWithinDocument", .{
        .frameId = "FID-0000000001",
        .navigationType = "historyApi",
        .url = "http://127.0.0.1:9582/next",
    }, .{});
}
