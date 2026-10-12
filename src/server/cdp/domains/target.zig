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

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");

const URL = @import("../../../browser/URL.zig");
const js = @import("../../../browser/js/js.zig");

const log = lp.log;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        getTargets,
        attachToTarget,
        attachToBrowserTarget,
        closeTarget,
        createBrowserContext,
        createTarget,
        detachFromTarget,
        disposeBrowserContext,
        getBrowserContexts,
        getTargetInfo,
        sendMessageToTarget,
        setAutoAttach,
        setDiscoverTargets,
        activateTarget,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .getTargets => return getTargets(cmd),
        .attachToTarget => return attachToTarget(cmd),
        .attachToBrowserTarget => return attachToBrowserTarget(cmd),
        .closeTarget => return closeTarget(cmd),
        .createBrowserContext => return createBrowserContext(cmd),
        .createTarget => return createTarget(cmd),
        .detachFromTarget => return detachFromTarget(cmd),
        .disposeBrowserContext => return disposeBrowserContext(cmd),
        .getBrowserContexts => return getBrowserContexts(cmd),
        .getTargetInfo => return getTargetInfo(cmd),
        .sendMessageToTarget => return sendMessageToTarget(cmd),
        .setAutoAttach => return setAutoAttach(cmd),
        .setDiscoverTargets => return setDiscoverTargets(cmd),
        .activateTarget => return cmd.sendResult(null, .{}),
    }
}

fn getTargets(cmd: *CDP.Command) !void {
    // If no context available, return an empty array.
    const bc = cmd.browser_context orelse {
        return cmd.sendResult(.{
            .targetInfos = [_]TargetInfo{},
        }, .{});
    };

    var infos: std.ArrayList(TargetInfo) = .empty;
    for (bc.targets.items) |target| {
        const info = targetInfo(target) orelse continue;
        try infos.append(cmd.arena, info);
    }
    return cmd.sendResult(.{ .targetInfos = infos.items }, .{});
}

fn targetInfo(target: *const CDP.Target) ?TargetInfo {
    const target_id = if (target.target_id) |*tid| tid else return null;
    return .{
        .targetId = target_id,
        .title = target.getTitle() orelse "",
        .url = target.getURL() orelse "about:blank",
        .browserContextId = target.bc.id,
    };
}

/// Clients such as Browser Use track a tab's URL and title only through this
/// event, as Chrome sends it whenever either changes.
pub fn sendTargetInfoChanged(target: *const CDP.Target, frame_id: u32) !void {
    if (!target.cdp.target_discover) return;
    const main = target.mainFrame() orelse return;
    if (main._frame_id != frame_id) return;
    const info = targetInfo(target) orelse return;
    try target.cdp.sendEvent("Target.targetInfoChanged", .{ .targetInfo = info }, .{});
}

fn getBrowserContexts(cmd: *CDP.Command) !void {
    var browser_context_ids: []const []const u8 = undefined;
    if (cmd.browser_context) |bc| {
        browser_context_ids = &.{bc.id};
    } else {
        browser_context_ids = &.{};
    }

    return cmd.sendResult(.{
        .browserContextIds = browser_context_ids,
    }, .{});
}

fn createBrowserContext(cmd: *CDP.Command) !void {
    const params = try cmd.params(struct {
        disposeOnDetach: bool = false,
        proxyServer: ?[:0]const u8 = null,
        proxyBypassList: ?[]const u8 = null,
        originsWithUniversalNetworkAccess: ?[]const []const u8 = null,
    });
    if (params) |p| {
        if (p.disposeOnDetach or p.proxyBypassList != null or p.originsWithUniversalNetworkAccess != null) {
            log.debug(.not_implemented, "Target.createBrowserContext", .{ .disposeOnDetach = p.disposeOnDetach, .has_proxyBypassList = p.proxyBypassList != null, .has_originsWithUniversalNetworkAccess = p.originsWithUniversalNetworkAccess != null });
        }
    }

    const bc = cmd.createBrowserContext() catch |err| switch (err) {
        error.AlreadyExists => return cmd.sendError(-32000, "Cannot have more than one browser context at a time", .{}),
        else => return err,
    };

    if (params) |p| {
        if (p.proxyServer) |proxy| {
            // For now the http client is not in the browser context so we assume there is just 1.
            try cmd.cdp.browser.http_client.changeProxy(proxy);
            bc.http_proxy_changed = true;
        }
    }

    return cmd.sendResult(.{
        .browserContextId = bc.id,
    }, .{});
}

fn disposeBrowserContext(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        browserContextId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse {
        return cmd.sendError(-32602, "No browser context with the given id found", .{});
    };
    if (std.mem.eql(u8, bc.id, params.browserContextId) == false) {
        return cmd.sendError(-32602, "No browser context with the given id found", .{});
    }

    // Disposing a context closes its targets; drivers wait on those events.
    while (bc.firstTarget()) |target| {
        try bc.closeTarget(target);
    }
    cmd.cdp.disposeBrowserContext();
    try cmd.sendResult(null, .{});
}

fn createTarget(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        url: [:0]const u8 = "about:blank",
        // width: ?u64 = null,
        // height: ?u64 = null,
        browserContextId: ?[]const u8 = null,
        // enableBeginFrameControl: bool = false,
        // newWindow: bool = false,
        // background: bool = false,
        // forTab: ?bool = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse cmd.createBrowserContext() catch |err| switch (err) {
        error.AlreadyExists => unreachable,
        else => return err,
    };

    if (params.browserContextId) |param_browser_context_id| {
        if (std.mem.eql(u8, param_browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }

    if (bc.targets.items.len >= CDP.Target.max_targets) {
        const message = try cmd.arena.print("Cannot have more than {d} targets at a time", .{CDP.Target.max_targets});
        return cmd.sendError(-32000, message, .{});
    }

    // Creating the page creates its target, see BrowserContext.onFrameCreated.
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    const target = bc.findTargetByFrameId(page.frame_id) orelse {
        lp.assert(false, "CDP.target.createTarget no target", .{ .frame_id = page.frame_id });
    };

    // the target_id == the frame_id of the "root" frame
    target.target_id = id.toFrameId(page.frame_id);
    const target_id = &target.target_id.?;
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const aux_data = try cmd.arena.print("{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}", .{target_id});
        bc.inspector().contextCreated(
            target.group_id,
            &ls.local,
            "",
            "", // @ZIGDOM
            // try frame.origin(arena),
            aux_data,
            true,
        );
    }

    // change CDP state
    target.security_origin = "://";
    target.secure_context_type = "InsecureScheme";

    // send targetCreated event
    // TODO: should this only be sent when Target.setDiscoverTargets
    // has been enabled?
    try cmd.sendEvent("Target.targetCreated", .{
        .targetInfo = TargetInfo{
            .attached = false,
            .targetId = target_id,
            .title = "",
            .browserContextId = bc.id,
            .url = "about:blank",
        },
    }, .{});

    // attach to the target only if auto attach is set.
    if (cmd.cdp.target_auto_attach) {
        try doAttachtoTarget(cmd, target);
    }

    if (URL.isAboutBlank(params.url) == false) {
        const encoded_url = try URL.resolveNavigation(frame.call_arena, params.url, .{});
        try frame.navigate(
            encoded_url,
            .{ .reason = .address_bar, .kind = .{ .push = null } },
        );
    }

    try cmd.sendResult(.{
        .targetId = target_id,
    }, .{});
}

// The target the client knows by `target_id`. TargetNotLoaded when it knows
// of none.
fn findTarget(bc: *const CDP.BrowserContext, target_id: []const u8) !*CDP.Target {
    if (bc.findTarget(target_id)) |target| {
        return target;
    }
    for (bc.targets.items) |target| {
        if (target.target_id != null) {
            return error.UnknownTargetId;
        }
    }
    return error.TargetNotLoaded;
}

fn attachToTarget(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        targetId: []const u8,
        flatten: bool = true,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const target = try findTarget(bc, params.targetId);

    // The first attach becomes the page's primary session, which all
    // Page/Network/... events are emitted to. Later attaches — e.g.
    // Playwright's browserContext.newCDPSession(page), sent through its
    // browser session while the page session is live — get a distinct
    // auxiliary session so they don't collide with the primary one.
    if (target.session_id == null) {
        try doAttachtoTarget(cmd, target);
        return cmd.sendResult(.{ .sessionId = target.session_id }, .{});
    }

    const parent_id = if (cmd.input.session_id) |session_id|
        cmd.cdp.resolveSessionId(session_id) orelse return error.UnknownSessionId
    else
        null;
    const session = try bc.attachSession(target, cmd.cdp.session_id_gen.next(), parent_id);

    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = session.id,
        .targetInfo = targetInfo(target).?,
    }, .{ .session_id = parent_id });

    return cmd.sendResult(.{ .sessionId = session.id }, .{});
}

fn attachToBrowserTarget(cmd: *CDP.Command) !void {
    const cdp = cmd.cdp;
    // Browser-target sessions are independent from page-target sessions and
    // can be created before a browser context exists.
    const session_id = cdp.browser_session_id orelse cdp.browser_session_id_gen.next();

    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = session_id,
        .targetInfo = TargetInfo{
            .targetId = "browser",
            .title = "",
            .url = "",
            .type = "browser",
            // Chrome doesn't send a browserContextId in this case.
            .browserContextId = null,
        },
    }, .{});

    cdp.browser_session_id = session_id;

    return cmd.sendResult(.{ .sessionId = session_id }, .{});
}

fn closeTarget(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        targetId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const target = try findTarget(bc, params.targetId);

    try cmd.sendResult(.{ .success = true }, .{});
    try bc.closeTarget(target);
}

fn getTargetInfo(cmd: *CDP.Command) !void {
    const Params = struct {
        targetId: ?[]const u8 = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    if (params.targetId) |param_target_id| {
        const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
        const target = try findTarget(bc, param_target_id);
        return cmd.sendResult(.{ .targetInfo = targetInfo(target).? }, .{});
    }

    return cmd.sendResult(.{
        .targetInfo = TargetInfo{
            .targetId = "TID-STARTUP",
            .type = "browser",
            .title = "",
            .url = "about:blank",
            .attached = true,
            .canAccessOpener = false,
        },
    }, .{});
}

fn sendMessageToTarget(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        message: []const u8,
        sessionId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    if (bc.firstTarget() == null) {
        return error.TargetNotLoaded;
    }
    if (bc.attached_sessions.contains(params.sessionId) == false) {
        return error.UnknownSessionId;
    }

    var aw = std.Io.Writer.Allocating.init(cmd.arena);
    cmd.cdp.dispatch(cmd.arena, .{ .capture = &aw.writer }, params.message, params.sessionId) catch |err| {
        log.debug(.cdp, "internal dispatch error", .{ .err = err, .id = cmd.input.id, .message = params.message });
        return err;
    };

    try cmd.sendEvent("Target.receivedMessageFromTarget", .{
        .message = aw.written(),
        .sessionId = params.sessionId,
    }, .{});
}

fn detachFromTarget(cmd: *CDP.Command) !void {
    const Params = struct {
        sessionId: ?[]const u8 = null,
        targetId: ?[]const u8 = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    if (cmd.browser_context) |bc| {
        // Without a sessionId, detach the target's primary session (if any).
        const primary_session_id: ?[]const u8 = blk: {
            const target = if (params.targetId) |target_id| bc.findTarget(target_id) else bc.firstTarget();
            break :blk (target orelse break :blk null).session_id;
        };
        if (params.sessionId orelse primary_session_id) |requested_session_id| {
            const session = bc.attached_sessions.get(requested_session_id) orelse return error.UnknownSessionId;
            const session_id = session.id;
            const parent_id = session.parent_id;

            session.target.fetchDisableForSession(session_id);
            try cmd.sendEvent("Target.detachedFromTarget", .{
                .sessionId = session_id,
            }, .{ .session_id = parent_id });
            _ = bc.detachSession(session_id);
        }
    }

    return cmd.sendResult(null, .{});
}

fn setDiscoverTargets(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        discover: bool,
        filter: ?[]const TargetFilter = null,
    })) orelse return error.InvalidParams;

    cmd.cdp.target_discover = params.discover and filterIncludesPage(params.filter);
    return cmd.sendResult(null, .{});
}

/// One entry of Target.setAutoAttach's `filter`: `type`
/// selects the target type it matches (absent matches any
/// type), `exclude` turns the entry into an exclusion.
const TargetFilter = struct {
    type: ?[]const u8 = null,
    exclude: bool = false,
};

/// Does the client's target filter include page targets?
/// Entries are checked in order: the first entry matching the
/// target type decides; an absent type matches any type.
fn filterIncludesPage(filter: ?[]const TargetFilter) bool {
    for (filter orelse return true) |f| {
        const t = f.type orelse return !f.exclude;
        if (std.mem.eql(u8, t, "page")) return !f.exclude;
    }
    return false;
}

fn setAutoAttach(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        autoAttach: bool,
        waitForDebuggerOnStart: bool,
        flatten: bool = true,
        filter: ?[]const TargetFilter = null,
    })) orelse return error.InvalidParams;

    // set a flag to send Target.attachedToTarget events
    cmd.cdp.target_auto_attach = params.autoAttach;

    if (cmd.cdp.target_auto_attach == false) {
        // detach from all currently attached targets.
        if (cmd.browser_context) |bc| {
            for (bc.targets.items) |target| {
                const session_id = target.session_id orelse continue;
                target.fetchDisableForSession(session_id);
                try cmd.sendEvent("Target.detachedFromTarget", .{
                    .sessionId = session_id,
                }, .{});
                _ = bc.detachSession(session_id);
            }
        }
        try cmd.sendResult(null, .{});
        return;
    }

    // autoAttach is set to true, we must attach to all existing targets.
    if (cmd.browser_context) |bc| {
        for (bc.targets.items) |target| {
            if (target.target_id != null) {
                continue;
            }
            if (target.mainFrame()) |frame| {
                // the target_id == the frame_id of the "root" frame
                target.target_id = id.toFrameId(frame._frame_id);
                try doAttachtoTarget(cmd, target);
            }
        }
        try cmd.sendResult(null, .{});
        return;
    }

    // This is a hack. Puppeteer, and probably others, expect the Browser to
    // automatically started creating targets. Things like an empty tab, or
    // a blank frame. And they block until this happens. So we send an event
    // telling them that they've been attached to our Browser. Hopefully, the
    // first thing they'll do is create a real BrowserContext and progress from
    // there.
    // This hack requires the main cdp dispatch handler to special case
    // messages from this "STARTUP" session.
    //
    // A client that excluded page targets from auto-attach
    // (puppeteer does) must not hear about this placeholder:
    // navigating it would land on the page-less STARTUP session.
    if (filterIncludesPage(params.filter)) {
        try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
            .sessionId = "STARTUP",
            .targetInfo = TargetInfo{
                .type = "page",
                .targetId = "TID-STARTUP",
                .title = "",
                .url = "about:blank",
                .browserContextId = "BID-STARTUP",
            },
        }, .{});
    }

    try cmd.sendResult(null, .{});
}

fn doAttachtoTarget(cmd: *CDP.Command, target: *CDP.Target) !void {
    const parent_id = target.session_id;

    if (target.session_id == null) {
        // extra_headers should not be kept on a new frame or tab
        target.extra_headers.clearRetainingCapacity();
        _ = try target.attachPrimarySession(cmd.cdp.session_id_gen.next());
    }

    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = target.session_id.?,
        .targetInfo = targetInfo(target).?,
    }, .{ .session_id = parent_id });
}

const AttachToTarget = struct {
    sessionId: []const u8,
    targetInfo: TargetInfo,
    waitingForDebugger: bool = false,
};

const TargetInfo = struct {
    url: []const u8,
    title: []const u8,
    targetId: []const u8,
    attached: bool = true,
    type: []const u8 = "page",
    canAccessOpener: bool = false,
    browserContextId: ?[]const u8 = null,
};

const testing = @import("../testing.zig");
test "cdp.target: getBrowserContexts" {
    var ctx = try testing.context();
    defer ctx.deinit();

    // {
    //     // no browser context
    //     try ctx.processMessage(.{.id = 4, .method = "Target.getBrowserContexts"});

    //     try ctx.expectSentResult(.{
    //         .browserContextIds = &.{},
    //     }, .{ .id = 4, .session_id = null });
    // }

    {
        // with a browser context
        _ = try ctx.loadBrowserContext(.{ .id = "BID-X" });
        try ctx.processMessage(.{ .id = 5, .method = "Target.getBrowserContexts" });

        try ctx.expectSentResult(.{
            .browserContextIds = &.{"BID-X"},
        }, .{ .id = 5, .session_id = null });
    }
}

test "cdp.target: createBrowserContext" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 4, .method = "Target.createBrowserContext" });
        try ctx.expectSentResult(.{
            .browserContextId = ctx.cdp().browser_context.?.id,
        }, .{ .id = 4, .session_id = null });
    }

    {
        // we already have one now
        try ctx.processMessage(.{ .id = 5, .method = "Target.createBrowserContext" });
        try ctx.expectSentError(-32000, "Cannot have more than one browser context at a time", .{ .id = 5 });
    }
}

test "cdp.target: disposeBrowserContext" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 7, .method = "Target.disposeBrowserContext" });
        try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 7 });
    }

    {
        try ctx.processMessage(.{
            .id = 8,
            .method = "Target.disposeBrowserContext",
            .params = .{ .browserContextId = "BID-10" },
        });
        try ctx.expectSentError(-32602, "No browser context with the given id found", .{ .id = 8 });
    }

    {
        _ = try ctx.loadBrowserContext(.{ .id = "BID-20" });
        try ctx.processMessage(.{
            .id = 9,
            .method = "Target.disposeBrowserContext",
            .params = .{ .browserContextId = "BID-20" },
        });
        try ctx.expectSentResult(null, .{ .id = 9 });
        try testing.expectEqual(null, ctx.cdp().browser_context);
    }
}

test "cdp.target: disposeBrowserContext detaches target sessions" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.processMessage(.{ .id = 2, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    const bc = &ctx.cdp().browser_context.?;
    const target_id = bc.firstTarget().?.target_id.?;
    const context_id = try testing.arena_allocator.dupe(u8, bc.id);
    const primary_id = try testing.arena_allocator.dupe(u8, bc.firstTarget().?.session_id.?);
    try ctx.processMessage(.{ .id = 3, .method = "Target.attachToBrowserTarget" });
    try ctx.processMessage(.{
        .id = 4,
        .method = "Target.attachToTarget",
        .sessionId = "BSID-1",
        .params = .{ .targetId = target_id },
    });
    // the primary is attached first, the auxiliary session after it
    try testing.expectEqual(2, bc.attached_sessions.count());
    const auxiliary_id = try testing.arena_allocator.dupe(u8, bc.attached_sessions.keys()[1]);

    try ctx.processMessage(.{
        .id = 5,
        .method = "Target.disposeBrowserContext",
        .params = .{ .browserContextId = context_id },
    });
    // Playwright waits for detachedFromTarget to resolve Page.closedPromise,
    // even if Target.disposeBrowserContext itself has already replied.
    try ctx.expectSentEvent("Target.detachedFromTarget", .{
        .targetId = target_id,
        .sessionId = auxiliary_id,
        .reason = "Render process gone.",
    }, .{ .session_id = "BSID-1" });
    try ctx.expectSentEvent("Target.detachedFromTarget", .{
        .targetId = target_id,
        .sessionId = primary_id,
        .reason = "Render process gone.",
    }, .{});
    try ctx.expectSentEvent("Target.targetDestroyed", .{ .targetId = target_id }, .{});
    try ctx.expectSentResult(null, .{ .id = 5 });
    try testing.expectEqual(null, ctx.cdp().browser_context);

    // The connection remains usable; stale target/session IDs are not reused.
    try ctx.processMessage(.{ .id = 6, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    try testing.expect(!std.mem.eql(u8, &target_id, &ctx.cdp().browser_context.?.firstTarget().?.target_id.?));
    try testing.expect(!std.mem.eql(u8, primary_id, ctx.cdp().browser_context.?.firstTarget().?.session_id.?));
}

test "cdp.target: disposeBrowserContext destroys an unattached target" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    const bc = &ctx.cdp().browser_context.?;
    const target_id = bc.firstTarget().?.target_id.?;
    const context_id = try testing.arena_allocator.dupe(u8, bc.id);

    // An invalid context ID must leave the live target untouched.
    try ctx.processMessage(.{ .id = 2, .method = "Target.disposeBrowserContext", .params = .{ .browserContextId = "BID-UNKNOWN" } });
    try ctx.expectSentError(-32602, "No browser context with the given id found", .{ .id = 2 });
    try ctx.expectSentCount(3);
    try testing.expectEqual(&target_id, bc.firstTarget().?.target_id.?);

    try ctx.processMessage(.{ .id = 3, .method = "Target.disposeBrowserContext", .params = .{ .browserContextId = context_id } });
    try ctx.expectSentEvent("Target.targetDestroyed", .{ .targetId = target_id }, .{ .index = 3 });
    try ctx.expectSentResult(null, .{ .id = 3, .index = 4 });
    try ctx.expectSentCount(5);
}

test "cdp.target: disposeBrowserContext after closeTarget does not repeat events" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    const bc = &ctx.cdp().browser_context.?;
    const target_id = bc.firstTarget().?.target_id.?;
    const context_id = try testing.arena_allocator.dupe(u8, bc.id);

    try ctx.processMessage(.{ .id = 2, .method = "Target.closeTarget", .params = .{ .targetId = target_id } });
    try ctx.expectSentEvent("Target.targetDestroyed", .{ .targetId = target_id }, .{ .index = 3 });
    try ctx.expectSentCount(4);
    try ctx.processMessage(.{ .id = 3, .method = "Target.disposeBrowserContext", .params = .{ .browserContextId = context_id } });
    try ctx.expectSentResult(null, .{ .id = 3, .index = 4 });
    try ctx.expectSentCount(5);
}

// Issue #2472: CDP target IDs (`FID-{d:0>10}`) must stay unique for the
// lifetime of a CDP connection. Before the fix, `Session.frame_id_gen`
// reset to 0 on `tearDownActivePage` AND fresh sessions also started
// from 0, so the second `Target.createTarget` after a dispose re-issued
// the same `FID-0000000001` and Playwright clients tripped on
// `Duplicate target FID-...`. The counter now lives on `Browser` and is
// monotonic across BrowserContexts.
test "cdp.target: createTarget assigns unique IDs across BrowserContexts (issue #2472)" {
    var ctx = try testing.context();
    defer ctx.deinit();

    // Cycle 1: create context + target, capture the assigned target_id.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Target.createTarget",
        .params = .{ .url = "about:blank" },
    });
    const target_id_1 = ctx.cdp().browser_context.?.firstTarget().?.target_id.?;
    const bc_id_1 = ctx.cdp().browser_context.?.id;

    // Dispose the first context.
    try ctx.processMessage(.{
        .id = 2,
        .method = "Target.disposeBrowserContext",
        .params = .{ .browserContextId = bc_id_1 },
    });
    try testing.expectEqual(null, ctx.cdp().browser_context);

    // Cycle 2: create another context + target. The new target_id must
    // differ from cycle 1's -- duplicates here are exactly what Playwright
    // asserts on with `Duplicate target FID-...`.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Target.createTarget",
        .params = .{ .url = "about:blank" },
    });
    const target_id_2 = ctx.cdp().browser_context.?.firstTarget().?.target_id.?;

    try testing.expect(!std.mem.eql(u8, &target_id_1, &target_id_2));
}

test "cdp.target: createTarget" {
    {
        var ctx = try testing.context();
        defer ctx.deinit();
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });

        // should create a browser context
        const bc = ctx.cdp().browser_context.?;
        try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = false, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.firstTarget().?.target_id.? } }, .{});
    }

    {
        var ctx = try testing.context();
        defer ctx.deinit();
        // active auto attach to get the Target.attachedToTarget event.
        try ctx.processMessage(.{ .id = 9, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });

        // should create a browser context
        const bc = ctx.cdp().browser_context.?;
        try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = false, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.firstTarget().?.target_id.? } }, .{});
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = bc.firstTarget().?.session_id.?, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.firstTarget().?.target_id.? } }, .{});
    }

    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-8" } });
        try ctx.expectSentError(-31998, "UnknownBrowserContextId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
        try testing.expectEqual(true, bc.firstTarget().?.target_id != null);
        try ctx.expectSentResult(.{ .targetId = bc.firstTarget().?.target_id.? }, .{ .id = 10 });
        try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = false, .type = "page", .canAccessOpener = false, .browserContextId = "BID-9", .targetId = bc.firstTarget().?.target_id.? } }, .{});
    }
}

// A freshly created blank target (the default CDP Target.createTarget) is
// left unnavigated until a real navigation happens, so Navigation._entries
// is empty. Reading history.state/navigation.currentEntry there used to hit
// the hard `lp.assert(len > 0, ...)` in Navigation.getCurrentEntry and crash
// the whole process instead of just failing the one command.
test "cdp.target: history.state on freshly created blank target doesn't crash" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 40, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.processMessage(.{ .id = 41, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    const bc = &ctx.cdp().browser_context.?;
    const session_id = bc.firstTarget().?.session_id.?;

    try ctx.processMessage(.{ .id = 42, .method = "Runtime.enable", .sessionId = session_id });
    try ctx.processMessage(.{ .id = 43, .method = "Runtime.evaluate", .sessionId = session_id, .params = .{
        .expression = "history.state",
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "object", .subtype = "null", .value = null } }, .{ .id = 43 });
}

test "cdp.target: navigation.currentEntry on freshly created blank target doesn't crash" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 40, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.processMessage(.{ .id = 41, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    const bc = &ctx.cdp().browser_context.?;
    const session_id = bc.firstTarget().?.session_id.?;

    try ctx.processMessage(.{ .id = 42, .method = "Runtime.enable", .sessionId = session_id });
    try ctx.processMessage(.{ .id = 43, .method = "Runtime.evaluate", .sessionId = session_id, .params = .{
        .expression = "navigation.currentEntry.url",
    } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "about:blank" } }, .{ .id = 43 });
}

// A browser-target session (Target.attachToBrowserTarget) is distinct from
// the page-target session. It used to be stored in bc.session_id, which broke
// the "no target => no session_id" invariant asserted in createTarget.
test "cdp.target: attachToBrowserTarget then createTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = "BSID-1", .targetInfo = .{ .targetId = "browser", .title = "", .url = "", .attached = true, .type = "browser", .canAccessOpener = false } }, .{});
    try ctx.expectSentResult(.{ .sessionId = "BSID-1" }, .{ .id = 1 });
    try testing.expectEqual(null, ctx.cdp().browser_context);

    try ctx.processMessage(.{ .id = 2, .method = "Target.createBrowserContext" });
    const bc = &ctx.cdp().browser_context.?;
    try ctx.expectSentResult(.{ .browserContextId = bc.id }, .{ .id = 2 });
    try testing.expectEqual(null, bc.firstTarget());

    {
        try ctx.processMessage(.{ .id = 3, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
        try ctx.expectSentResult(.{ .targetId = bc.firstTarget().?.target_id.? }, .{ .id = 3 });
    }

    {
        // the browser session id is valid on subsequent commands
        try ctx.processMessage(.{ .id = 4, .method = "Target.setDiscoverTargets", .sessionId = "BSID-1", .params = .{ .discover = true } });
        try ctx.expectSentResult(null, .{ .id = 4, .session_id = "BSID-1" });
    }

    {
        // unknown session ids are still rejected
        try ctx.processMessage(.{ .id = 5, .method = "Target.setDiscoverTargets", .sessionId = "SID-NOPE", .params = .{ .discover = true } });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{ .id = 5 });
    }
}

test "cdp.target: closeTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "X" } });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "TargetNotLoaded", .{ .id = 10 });
    }

    // pretend we createdTarget first
    _ = try bc.session.createPage();
    bc.firstTarget().?.target_id = "TID-000000000A".*;
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 11, .method = "Target.closeTarget", .params = .{ .targetId = "TID-000000000A" } });
        try ctx.expectSentResult(.{ .success = true }, .{ .id = 11 });
        try testing.expectEqual(false, bc.session.hasPage());
        try testing.expectEqual(null, bc.firstTarget());
    }
}

test "cdp.target: attachToTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "X" } });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "TargetNotLoaded", .{ .id = 10 });
    }

    // pretend we createdTarget first
    _ = try bc.session.createPage();
    bc.firstTarget().?.target_id = "TID-000000000B".*;
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        // the first attach becomes the primary session
        try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-000000000B" } });
        const session_id = bc.firstTarget().?.session_id.?;
        try ctx.expectSentResult(.{ .sessionId = session_id }, .{ .id = 11 });
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = session_id, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = "BID-9", .targetId = bc.firstTarget().?.target_id.? } }, .{});
        try testing.expectEqual(1, bc.attached_sessions.count());
        try testing.expect(bc.attached_sessions.contains(session_id));
    }
}

test "cdp.target: auxiliary session is unique and routed through its parent" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-9",
        .session_id = "SID-PRIMARY",
        .target_id = "TID-000000000B".*,
    });

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Target.attachToTarget",
        .sessionId = "BSID-1",
        .params = .{ .targetId = "TID-000000000B" },
    });

    // the primary is attached first, the auxiliary session after it
    try testing.expectEqual(2, bc.attached_sessions.count());
    const session_id = bc.attached_sessions.keys()[1];
    try testing.expect(!std.mem.eql(u8, session_id, bc.firstTarget().?.session_id.?));
    try ctx.expectSentEvent("Target.attachedToTarget", .{
        .sessionId = session_id,
        .targetInfo = .{
            .url = "about:blank",
            .title = "",
            .attached = true,
            .type = "page",
            .canAccessOpener = false,
            .browserContextId = "BID-9",
            .targetId = "TID-000000000B",
        },
    }, .{ .index = 2, .session_id = "BSID-1" });
    try ctx.expectSentResult(.{ .sessionId = session_id }, .{
        .id = 2,
        .session_id = "BSID-1",
    });
}

test "cdp.target: getTargetInfo" {
    var ctx = try testing.context();
    defer ctx.deinit();

    {
        try ctx.processMessage(.{ .id = 9, .method = "Target.getTargetInfo" });
        try ctx.expectSentResult(.{
            .targetInfo = .{
                .type = "browser",
                .title = "",
                .url = "about:blank",
                .attached = true,
                .canAccessOpener = false,
            },
        }, .{ .id = 9 });
    }

    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.getTargetInfo", .params = .{ .targetId = "X" } });
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.getTargetInfo", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "TargetNotLoaded", .{ .id = 10 });
    }

    // pretend we createdTarget first
    _ = try bc.session.createPage();
    bc.firstTarget().?.target_id = "TID-000000000C".*;
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.getTargetInfo", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 11, .method = "Target.getTargetInfo", .params = .{ .targetId = "TID-000000000C" } });
        try ctx.expectSentResult(.{
            .targetInfo = .{
                .targetId = "TID-000000000C",
                .type = "page",
                .title = "",
                .url = "about:blank",
                .attached = true,
                .canAccessOpener = false,
            },
        }, .{ .id = 11 });
    }
}

test "cdp.target: issue#474: attach to just created target" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
        try testing.expectEqual(true, bc.firstTarget().?.target_id != null);
        try ctx.expectSentResult(.{ .targetId = bc.firstTarget().?.target_id.? }, .{ .id = 10 });

        try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = bc.firstTarget().?.target_id.? } });
        const session_id = bc.firstTarget().?.session_id.?;
        try ctx.expectSentResult(.{ .sessionId = session_id }, .{ .id = 11 });
    }
}

test "cdp.target: detachFromTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
    try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = bc.firstTarget().?.target_id.? } });
    const session_id = bc.firstTarget().?.session_id.?;

    try ctx.processMessage(.{ .id = 12, .method = "Target.detachFromTarget", .params = .{ .sessionId = session_id } });

    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = session_id }, .{});
    try testing.expectEqual(null, bc.firstTarget().?.session_id);
    try ctx.expectSentResult(null, .{ .id = 12 });

    try ctx.processMessage(.{ .id = 13, .method = "Target.attachToTarget", .params = .{ .targetId = bc.firstTarget().?.target_id.? } });
    try testing.expect(!std.mem.eql(u8, session_id, bc.firstTarget().?.session_id.?));
    try ctx.expectSentResult(.{ .sessionId = bc.firstTarget().?.session_id.? }, .{ .id = 13 });
}

test "cdp.target: detachFromTarget auxiliary session" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-9",
        .session_id = "SID-PRIMARY",
        .target_id = "TID-000000000B".*,
    });

    try ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-000000000B" } });
    try testing.expectEqual(2, bc.attached_sessions.count());
    const session_id = bc.attached_sessions.keys()[1];
    try testing.expect(!std.mem.eql(u8, session_id, bc.firstTarget().?.session_id.?));

    try ctx.processMessage(.{ .id = 11, .method = "Target.detachFromTarget", .params = .{ .sessionId = session_id } });
    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = session_id }, .{});
    try testing.expectEqual(1, bc.attached_sessions.count());
    try testing.expectEqual(true, bc.firstTarget().?.session_id != null);
    try ctx.expectSentResult(null, .{ .id = 11 });
}

// A detached session's inspector session goes with it: commands on the old
// id are rejected up front and the primary is unaffected.
test "cdp.target: detachFromTarget releases the auxiliary session's inspector session" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-9",
        .url = "hi.html",
        .session_id = "SID-PRIMARY",
        .target_id = "TID-000000000B".*,
    });
    _ = try bc.attachSession(bc.firstTarget().?, "SID-AUX", null);

    try ctx.processMessage(.{ .id = 10, .method = "Runtime.evaluate", .sessionId = "SID-AUX", .params = .{ .expression = "1 + 1", .returnByValue = true } });
    try ctx.expectSentResult(.{ .result = .{ .type = "number", .value = 2 } }, .{ .id = 10, .session_id = "SID-AUX" });

    try ctx.processMessage(.{ .id = 11, .method = "Target.detachFromTarget", .params = .{ .sessionId = "SID-AUX" } });
    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = "SID-AUX" }, .{});
    try ctx.expectSentResult(null, .{ .id = 11 });
    try testing.expectEqual(1, bc.attached_sessions.count());

    try ctx.processMessage(.{ .id = 12, .method = "Runtime.evaluate", .sessionId = "SID-AUX", .params = .{ .expression = "1 + 1", .returnByValue = true } });
    try ctx.expectSentError(-32001, "Unknown sessionId", .{ .id = 12 });

    try ctx.processMessage(.{ .id = 13, .method = "Runtime.evaluate", .sessionId = "SID-PRIMARY", .params = .{ .expression = "2 + 2", .returnByValue = true } });
    try ctx.expectSentResult(.{ .result = .{ .type = "number", .value = 4 } }, .{ .id = 13, .session_id = "SID-PRIMARY" });
}

// Stopping an inspector session fails its pending evaluations. The client was
// already told the session is detached, so, like Chrome, nothing more is sent.
test "cdp.target: detachFromTarget drops the auxiliary session's pending responses" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-9",
        .url = "hi.html",
        .session_id = "SID-PRIMARY",
        .target_id = "TID-000000000B".*,
    });
    _ = try bc.attachSession(bc.firstTarget().?, "SID-AUX", null);

    try ctx.processMessage(.{ .id = 10, .method = "Runtime.enable", .sessionId = "SID-AUX" });
    try ctx.expectSentResult(null, .{ .id = 10, .session_id = "SID-AUX" });
    try ctx.processMessage(.{ .id = 11, .method = "Runtime.evaluate", .sessionId = "SID-AUX", .params = .{ .expression = "({a: 1})" } });
    try ctx.expectSentResult(.{ .result = .{ .type = "object" } }, .{ .id = 11, .session_id = "SID-AUX" });
    try ctx.processMessage(.{ .id = 12, .method = "Runtime.evaluate", .sessionId = "SID-AUX", .params = .{ .expression = "new Promise(() => {})", .awaitPromise = true } });

    try ctx.processMessage(.{ .id = 13, .method = "Target.detachFromTarget", .params = .{ .sessionId = "SID-AUX" } });
    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = "SID-AUX" }, .{});
    try ctx.expectSentResult(null, .{ .id = 13 });

    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const msg_id = msg.object.get("id") orelse continue;
        try testing.expect(msg_id != .integer or msg_id.integer != 12);
    }

    try ctx.processMessage(.{ .id = 14, .method = "Runtime.evaluate", .sessionId = "SID-PRIMARY", .params = .{ .expression = "2 + 2", .returnByValue = true } });
    try ctx.expectSentResult(.{ .result = .{ .type = "number", .value = 4 } }, .{ .id = 14, .session_id = "SID-PRIMARY" });
}

test "cdp.target: detachFromTarget without session" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        // detach when no session is attached should not send event
        try ctx.processMessage(.{ .id = 10, .method = "Target.detachFromTarget" });
        try ctx.expectSentResult(null, .{ .id = 10 });
        try ctx.expectSentCount(1);
    }
}

test "cdp.target: setAutoAttach false sends detachedFromTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    try ctx.processMessage(.{ .id = 10, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.processMessage(.{ .id = 11, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
    const session_id = bc.firstTarget().?.session_id.?;

    try ctx.processMessage(.{ .id = 12, .method = "Target.setAutoAttach", .params = .{ .autoAttach = false, .waitForDebuggerOnStart = false } });

    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = session_id }, .{});
    try testing.expectEqual(null, bc.firstTarget().?.session_id);
    try ctx.expectSentResult(null, .{ .id = 12 });
}

test "cdp.target: targetInfoChanged reports the page's URL and title" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.setDiscoverTargets", .params = .{ .discover = true } });
    try ctx.expectSentResult(null, .{ .id = 1 });

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-TIC", .url = "cdp/accname.html", .target_id = "FID-000000000I".* });
    try ctx.expectSentEvent("Target.targetInfoChanged", .{ .targetInfo = .{
        .targetId = &bc.firstTarget().?.target_id.?,
        .url = bc.firstTarget().?.getURL().?,
        .title = "AccName Fixture",
        .browserContextId = "BID-TIC",
    } }, .{});
}

test "cdp.target: targetInfoChanged requires setDiscoverTargets" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .url = "cdp/accname.html" });
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const method = msg.object.get("method") orelse continue;
        try testing.expect(!std.mem.eql(u8, method.string, "Target.targetInfoChanged"));
    }
    try testing.expect(i > 0);
}

test "cdp.target: setAutoAttach with page-exclude filter sends no attachedToTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();

    // Puppeteer's filter: exclude page targets, include the rest.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Target.setAutoAttach",
        .params = .{
            .autoAttach = true,
            .waitForDebuggerOnStart = false,
            .filter = [_]TargetFilter{
                .{ .type = "page", .exclude = true },
                .{},
            },
        },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });
    // The STARTUP placeholder is a page target: with pages
    // excluded, only the result may be sent.
    try ctx.expectSentCount(1);
}

test "cdp.target: setAutoAttach without filter still sends startup attachedToTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Target.setAutoAttach",
        .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false },
    });
    try ctx.expectSentEvent("Target.attachedToTarget", .{
        .sessionId = "STARTUP",
        .targetInfo = .{
            .targetId = "TID-STARTUP",
            .type = "page",
            .title = "",
            .url = "about:blank",
            .browserContextId = "BID-STARTUP",
        },
    }, .{ .index = 0 });
    try ctx.expectSentResult(null, .{ .id = 1, .index = 1 });
    try ctx.expectSentCount(2);
}

// Creates `count` targets with auto-attach on, returning them in order.
fn createTargets(ctx: *testing.TestContext, count: usize) ![]*CDP.Target {
    try ctx.processMessage(.{ .id = 1, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    for (0..count) |i| {
        try ctx.processMessage(.{ .id = 100 + i, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    }
    const bc = &ctx.cdp().browser_context.?;
    try testing.expectEqual(count, bc.targets.items.len);
    return bc.targets.items;
}

fn navigateTarget(ctx: *testing.TestContext, target: *CDP.Target, msg_id: usize, comptime path: []const u8) !void {
    try ctx.processMessage(.{ .id = msg_id, .method = "Page.navigate", .sessionId = target.session_id.?, .params = .{
        .url = "http://127.0.0.1:9582/src/browser/tests/" ++ path,
    } });
    var runner = target.session.runner(.{});
    try runner.waitForFrame(target.frame_id.?, 2000, .{ .until = .done });
}

// The result of the command `msg_id`, if received.
fn sentResult(ctx: *testing.TestContext, msg_id: i64) !?std.json.Value {
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const msg_id_value = msg.object.get("id") orelse continue;
        if (msg_id_value.integer == msg_id) {
            return msg.object.get("result");
        }
    }
    return null;
}

// Every message of `method` received so far.
fn sentEvents(ctx: *testing.TestContext, method: []const u8) ![]std.json.Value {
    var events: std.ArrayList(std.json.Value) = .empty;
    var i: usize = 0;
    while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const m = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, m.string, method)) {
            try events.append(testing.arena_allocator, msg);
        }
    }
    return events.items;
}

test "cdp.target: several targets in one browser context" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const targets = try createTargets(&ctx, 2);
    const a = targets[0];
    const b = targets[1];
    try testing.expect(!std.mem.eql(u8, &a.target_id.?, &b.target_id.?));
    try testing.expect(!std.mem.eql(u8, a.session_id.?, b.session_id.?));
    try testing.expect(a.group_id != b.group_id);

    try ctx.processMessage(.{ .id = 2, .method = "Target.getTargets" });
    const result = (try sentResult(&ctx, 2)).?;
    try testing.expectEqual(2, result.object.get("targetInfos").?.array.items.len);

    try navigateTarget(&ctx, a, 3, "cdp/dom1.html");
    try navigateTarget(&ctx, b, 4, "cdp/dom2.html");

    // Each session evaluates in its own page.
    try ctx.processMessage(.{ .id = 5, .method = "Runtime.evaluate", .sessionId = a.session_id.?, .params = .{ .expression = "location.pathname" } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "/src/browser/tests/cdp/dom1.html" } }, .{ .id = 5 });
    try ctx.processMessage(.{ .id = 6, .method = "Runtime.evaluate", .sessionId = b.session_id.?, .params = .{ .expression = "location.pathname" } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "/src/browser/tests/cdp/dom2.html" } }, .{ .id = 6 });

    // Each page has its own history: the navigation replaced the initial
    // about:blank entry.
    try ctx.processMessage(.{ .id = 7, .method = "Runtime.evaluate", .sessionId = a.session_id.?, .params = .{ .expression = "history.length" } });
    try ctx.expectSentResult(.{ .result = .{ .type = "number", .value = 1 } }, .{ .id = 7 });
    try ctx.processMessage(.{ .id = 9, .method = "Runtime.evaluate", .sessionId = b.session_id.?, .params = .{ .expression = "history.length" } });
    try ctx.expectSentResult(.{ .result = .{ .type = "number", .value = 1 } }, .{ .id = 9 });

    // DOM node ids belong to their target.
    try ctx.processMessage(.{ .id = 8, .method = "DOM.getDocument", .sessionId = a.session_id.? });
    try ctx.expectSentResult(null, .{ .id = 8, .session_id = a.session_id.? });
    try testing.expect(a.node_registry.lookup_by_id.count() > 0);
    try testing.expectEqual(0, b.node_registry.lookup_by_id.count());
}

test "cdp.target: page events go to the session of their target" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const targets = try createTargets(&ctx, 2);
    const a = targets[0];
    const b = targets[1];

    try ctx.processMessage(.{ .id = 2, .method = "Network.enable", .sessionId = a.session_id.? });
    try ctx.processMessage(.{ .id = 3, .method = "Network.enable", .sessionId = b.session_id.? });
    try ctx.processMessage(.{ .id = 4, .method = "Runtime.enable", .sessionId = a.session_id.? });

    try navigateTarget(&ctx, b, 5, "cdp/dom2.html");

    const requests = try sentEvents(&ctx, "Network.requestWillBeSent");
    try testing.expect(requests.len > 0);
    for (requests) |msg| {
        try testing.expectEqual(b.session_id.?, msg.object.get("sessionId").?.string);
    }

    // Runtime is enabled on A only, which must not see B's contexts.
    const b_frame_id = &id.toFrameId(b.frame_id.?);
    for (try sentEvents(&ctx, "Runtime.executionContextCreated")) |msg| {
        const aux_data = msg.object.get("params").?.object.get("context").?.object.get("auxData").?;
        try testing.expect(!std.mem.eql(u8, b_frame_id, aux_data.object.get("frameId").?.string));
    }

    // Page events too.
    for (try sentEvents(&ctx, "Page.frameNavigated")) |msg| {
        try testing.expectEqual(b.session_id.?, msg.object.get("sessionId").?.string);
    }
}

test "cdp.target: closing a target keeps the others" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const targets = try createTargets(&ctx, 2);
    const a = targets[0];
    const b = targets[1];
    const a_target_id = a.target_id.?;
    const b_session_id = b.session_id.?;

    try ctx.processMessage(.{ .id = 2, .method = "Target.closeTarget", .params = .{ .targetId = &a_target_id } });
    try ctx.expectSentResult(.{ .success = true }, .{ .id = 2 });
    try ctx.expectSentEvent("Target.targetDestroyed", .{ .targetId = &a_target_id }, .{});

    const bc = &ctx.cdp().browser_context.?;
    try testing.expectEqual(1, bc.targets.items.len);
    try testing.expectEqual(b, bc.firstTarget().?);

    try navigateTarget(&ctx, b, 3, "cdp/dom1.html");
    try ctx.processMessage(.{ .id = 4, .method = "Runtime.evaluate", .sessionId = b_session_id, .params = .{ .expression = "location.pathname" } });
    try ctx.expectSentResult(.{ .result = .{ .type = "string", .value = "/src/browser/tests/cdp/dom1.html" } }, .{ .id = 4 });

    try ctx.processMessage(.{ .id = 5, .method = "Target.closeTarget", .params = .{ .targetId = &a_target_id } });
    try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 5 });
}

test "cdp.target: createTarget is capped" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try createTargets(&ctx, CDP.Target.max_targets);
    try ctx.processMessage(.{ .id = 2, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    try ctx.expectSentError(-32000, "Cannot have more than 16 targets at a time", .{ .id = 2 });
}
