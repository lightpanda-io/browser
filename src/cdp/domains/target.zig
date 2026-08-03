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

const URL = @import("../../browser/URL.zig");
const js = @import("../../browser/js/js.zig");

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

    const target_id = &(bc.target_id orelse {
        return cmd.sendResult(.{
            .targetInfos = [_]TargetInfo{},
        }, .{});
    });

    return cmd.sendResult(.{
        .targetInfos = [_]TargetInfo{.{
            .targetId = target_id,
            .type = "page",
            .title = bc.getTitle() orelse "",
            .url = bc.getURL() orelse "about:blank",
            .attached = bc.session_id != null,
            .canAccessOpener = false,
        }},
    }, .{});
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
            log.warn(.not_implemented, "Target.createBrowserContext", .{ .disposeOnDetach = p.disposeOnDetach, .has_proxyBypassList = p.proxyBypassList != null, .has_originsWithUniversalNetworkAccess = p.originsWithUniversalNetworkAccess != null });
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
    if (!std.mem.eql(u8, bc.id, params.browserContextId)) {
        return cmd.sendError(-32602, "No browser context with the given id found", .{});
    }
    if (bc.target_id) |target_id| {
        try cmd.cdp.targetDestroyed(&target_id);
    }
    try detachPageSession(cmd, bc);

    if (cmd.cdp.disposeBrowserContext(params.browserContextId) == false) {
        unreachable;
    }
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

    if (bc.target_id != null) {
        return error.TargetAlreadyLoaded;
    }
    if (params.browserContextId) |param_browser_context_id| {
        if (std.mem.eql(u8, param_browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }

    // if target_id is null, we should never have a blank frame
    lp.assert(!bc.session.hasPage(), "CDP.target.createTarget not null page", .{});

    // if target_id is null, we should never have a session_id
    lp.assert(bc.session_id == null, "CDP.target.createTarget not null session_id", .{});

    const page = try bc.session.createPage();
    const frame = page.frame().?;

    // the target_id == the frame_id of the "root" frame
    const frame_id = id.toFrameId(page.frame_id);
    bc.target_id = frame_id;
    const target_id = &bc.target_id.?;
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const aux_data = try std.fmt.allocPrint(cmd.arena, "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}", .{target_id});
        bc.inspector_session.inspector.contextCreated(
            &ls.local,
            "",
            "", // @ZIGDOM
            // try frame.origin(arena),
            aux_data,
            true,
        );
    }

    // change CDP state
    bc.security_origin = "://";
    bc.secure_context_type = "InsecureScheme";

    if (cmd.cdp.target_discovery) {
        try cmd.sendEvent("Target.targetCreated", .{
            .targetInfo = TargetInfo{
                .attached = false,
                .targetId = target_id,
                .title = "",
                .browserContextId = bc.id,
                .url = "about:blank",
            },
        }, .{ .session_id = cmd.cdp.target_discovery_session_id });
    }

    // attach to the target only if auto attach is set.
    if (cmd.cdp.target_auto_attach) {
        try doAttachtoTarget(cmd, target_id, cmd.cdp.target_auto_attach_session_id);
    }

    if (!std.mem.eql(u8, "about:blank", params.url)) {
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

fn attachToTarget(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        targetId: []const u8,
        flatten: bool = true,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const target_id = &(bc.target_id orelse return error.TargetNotLoaded);
    if (std.mem.eql(u8, target_id, params.targetId) == false) {
        return error.UnknownTargetId;
    }
    if (bc.session_id != null) {
        return cmd.sendError(-32000, "Target is already attached", .{});
    }

    try doAttachtoTarget(cmd, target_id, sessionIdForCommand(cmd));

    return cmd.sendResult(.{ .sessionId = bc.session_id }, .{});
}

fn attachToBrowserTarget(cmd: *CDP.Command) !void {
    const cdp = cmd.cdp;
    // Browser-target sessions are independent from page-target sessions and
    // can be created before a browser context exists.
    if (cdp.browser_session_id != null) {
        return cmd.sendError(-32000, "Only one browser target session is supported", .{});
    }

    const session_id = cdp.browser_session_id_gen.next();

    // Keep the established CDP contract: attaching to the browser target
    // announces that target before returning the new session id.
    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = session_id,
        .targetInfo = TargetInfo{
            .targetId = "browser",
            .title = "",
            .url = "",
            .type = "browser",
            // Chrome does not send a browserContextId for the browser target.
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
    const target_id = &(bc.target_id orelse return error.TargetNotLoaded);
    if (std.mem.eql(u8, target_id, params.targetId) == false) {
        return error.UnknownTargetId;
    }

    // can't be null if we have a target_id
    lp.assert(bc.session.hasPage(), "CDP.target.closeTarget null frame", .{});

    try cmd.sendResult(.{ .success = true }, .{});
    try cmd.cdp.targetDestroyed(target_id);

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
        }, .{ .session_id = bc.parent_session_id });

        cmd.cdp.clearTargetSessionState(session_id);
        bc.session_id = null;
        bc.parent_session_id = null;
    }

    if (bc.page_handle) |handle| {
        handle.close();
        bc.page_handle = null;
    }
    for (bc.isolated_worlds.items) |world| {
        world.deinit();
    }
    bc.isolated_worlds.clearRetainingCapacity();
    bc.target_id = null;
}

fn getTargetInfo(cmd: *CDP.Command) !void {
    const Params = struct {
        targetId: ?[]const u8 = null,
    };
    const params = (try cmd.params(Params)) orelse Params{};

    if (params.targetId) |param_target_id| {
        const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
        const target_id = &(bc.target_id orelse return error.TargetNotLoaded);
        if (std.mem.eql(u8, target_id, param_target_id) == false) {
            return error.UnknownTargetId;
        }

        return cmd.sendResult(.{
            .targetInfo = TargetInfo{
                .targetId = target_id,
                .type = "page",
                .title = bc.getTitle() orelse "",
                .url = bc.getURL() orelse "about:blank",
                .attached = bc.session_id != null,
                .canAccessOpener = false,
            },
        }, .{});
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
    if (bc.target_id == null) {
        return error.TargetNotLoaded;
    }

    const session_id = bc.session_id orelse return error.UnknownSessionId;
    if (std.mem.eql(u8, session_id, params.sessionId) == false) {
        // Is this right? Is the params.sessionId meant to be the active
        // sessionId? What else could it be? We have no other session_id.
        return error.UnknownSessionId;
    }

    var aw = std.Io.Writer.Allocating.init(cmd.arena);
    cmd.cdp.dispatch(cmd.arena, .{ .capture = &aw.writer }, params.message) catch |err| {
        log.err(.cdp, "internal dispatch error", .{ .err = err, .id = cmd.input.id, .message = params.message });
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

    if (params.sessionId) |session_id| {
        if (cmd.cdp.browser_session_id) |browser_session_id| {
            if (std.mem.eql(u8, browser_session_id, session_id)) {
                if (cmd.browser_context) |bc| {
                    if (bc.parent_session_id) |parent_session_id| {
                        if (std.mem.eql(u8, parent_session_id, session_id)) {
                            try detachPageSession(cmd, bc);
                        }
                    }
                }

                cmd.cdp.clearTargetSessionState(session_id);

                try cmd.sendEvent("Target.detachedFromTarget", .{
                    .sessionId = session_id,
                }, .{});
                cmd.cdp.browser_session_id = null;
                return cmd.sendResult(null, .{});
            }
        }

        const bc = cmd.browser_context orelse {
            return cmd.sendError(-32001, "Unknown sessionId", .{});
        };
        const page_session_id = bc.session_id orelse {
            return cmd.sendError(-32001, "Unknown sessionId", .{});
        };
        if (!std.mem.eql(u8, page_session_id, session_id)) {
            return cmd.sendError(-32001, "Unknown sessionId", .{});
        }
        try detachPageSession(cmd, bc);
        return cmd.sendResult(null, .{});
    }

    if (params.targetId) |target_id| {
        const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
        const active_target_id = &(bc.target_id orelse return error.TargetNotLoaded);
        if (!std.mem.eql(u8, active_target_id, target_id)) {
            return error.UnknownTargetId;
        }
        try detachPageSession(cmd, bc);
        return cmd.sendResult(null, .{});
    }

    if (cmd.browser_context) |bc| {
        try detachPageSession(cmd, bc);
    }

    return cmd.sendResult(null, .{});
}

fn setDiscoverTargets(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        discover: bool,
    })) orelse return error.InvalidParams;

    const discovery_session_id = sessionIdForCommand(cmd);
    if (cmd.cdp.target_discovery) {
        if (!sessionIdsEqual(cmd.cdp.target_discovery_session_id, discovery_session_id)) {
            return cmd.sendError(-32000, "Target discovery is controlled by another session", .{});
        }
        if (params.discover) {
            return cmd.sendResult(null, .{});
        }
        cmd.cdp.target_discovery = false;
        cmd.cdp.target_discovery_session_id = null;
        return cmd.sendResult(null, .{});
    }

    if (!params.discover) {
        return cmd.sendResult(null, .{});
    }

    cmd.cdp.target_discovery = true;
    cmd.cdp.target_discovery_session_id = discovery_session_id;

    // Enabling discovery reports targets that already exist, so clients can
    // construct their initial target list without racing target creation.
    if (cmd.browser_context) |bc| {
        if (bc.target_id) |target_id| {
            try cmd.sendEvent("Target.targetCreated", .{
                .targetInfo = TargetInfo{
                    .targetId = &target_id,
                    .title = bc.getTitle() orelse "",
                    .url = bc.getURL() orelse "about:blank",
                    .attached = bc.session_id != null,
                    .browserContextId = bc.id,
                },
            }, .{ .session_id = discovery_session_id });
        }
    }

    return cmd.sendResult(null, .{});
}

fn setAutoAttach(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        autoAttach: bool,
        waitForDebuggerOnStart: bool,
        flatten: bool = true,
        // filter: ?[]TargetFilter = null,
    })) orelse return error.InvalidParams;

    const auto_attach_session_id = sessionIdForCommand(cmd);
    if (cmd.cdp.target_auto_attach and
        !sessionIdsEqual(cmd.cdp.target_auto_attach_session_id, auto_attach_session_id))
    {
        return cmd.sendError(-32000, "Target auto-attach is controlled by another session", .{});
    }

    if (!params.autoAttach) {
        if (!cmd.cdp.target_auto_attach) {
            return cmd.sendResult(null, .{});
        }
        cmd.cdp.target_auto_attach = false;
        cmd.cdp.target_auto_attach_session_id = null;
        // detach from all currently attached targets.
        if (cmd.browser_context) |bc| {
            try detachPageSession(cmd, bc);
        }
        try cmd.sendResult(null, .{});
        return;
    }

    cmd.cdp.target_auto_attach = true;
    cmd.cdp.target_auto_attach_session_id = auto_attach_session_id;

    // autoAttach is set to true, we must attach to all existing targets.
    if (cmd.browser_context) |bc| {
        if (bc.target_id) |*target_id| {
            if (bc.session_id == null) {
                try doAttachtoTarget(cmd, target_id, cmd.cdp.target_auto_attach_session_id);
            }
        } else {
            if (bc.mainFrame()) |frame| {
                // the target_id == the frame_id of the "root" frame
                bc.target_id = id.toFrameId(frame._frame_id);
                try doAttachtoTarget(cmd, &bc.target_id.?, cmd.cdp.target_auto_attach_session_id);
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
    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = "STARTUP",
        .targetInfo = TargetInfo{
            .type = "page",
            .targetId = "TID-STARTUP",
            .title = "",
            .url = "about:blank",
            .browserContextId = "BID-STARTUP",
        },
    }, .{ .session_id = cmd.input.session_id });

    try cmd.sendResult(null, .{});
}

fn doAttachtoTarget(cmd: *CDP.Command, target_id: []const u8, parent_session_id: ?[]const u8) !void {
    const bc = cmd.browser_context.?;
    const session_id = bc.session_id orelse cmd.cdp.session_id_gen.next();

    if (bc.session_id == null) {
        // extra_headers should not be kept on a new frame or tab,
        // currently we have only 1 frame, we clear it just in case
        bc.extra_headers.clearRetainingCapacity();
        bc.parent_session_id = parent_session_id;
    }

    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = session_id,
        .targetInfo = TargetInfo{
            .targetId = target_id,
            .title = bc.getTitle() orelse "",
            .url = bc.getURL() orelse "about:blank",
            .browserContextId = bc.id,
        },
    }, .{ .session_id = parent_session_id });

    bc.session_id = session_id;
}

fn detachPageSession(cmd: *CDP.Command, bc: *CDP.BrowserContext) !void {
    const session_id = bc.session_id orelse return;
    try cmd.sendEvent("Target.detachedFromTarget", .{
        .sessionId = session_id,
    }, .{ .session_id = bc.parent_session_id });
    cmd.cdp.clearTargetSessionState(session_id);
    bc.session_id = null;
    bc.parent_session_id = null;
}

fn sessionIdForCommand(cmd: *const CDP.Command) ?[]const u8 {
    const input_session_id = cmd.input.session_id orelse return null;
    if (cmd.cdp.browser_session_id) |browser_session_id| {
        if (std.mem.eql(u8, input_session_id, browser_session_id)) {
            return browser_session_id;
        }
    }
    if (cmd.browser_context) |bc| {
        if (bc.session_id) |page_session_id| {
            if (std.mem.eql(u8, input_session_id, page_session_id)) {
                return page_session_id;
            }
        }
    }
    if (std.mem.eql(u8, input_session_id, "STARTUP")) {
        return "STARTUP";
    }
    return null;
}

fn sessionIdsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    const a_session_id = a orelse return b == null;
    const b_session_id = b orelse return false;
    return std.mem.eql(u8, a_session_id, b_session_id);
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

test "cdp.target: browser session commands echo session id" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentResult(.{ .sessionId = "BSID-1" }, .{ .id = 1 });

    try ctx.processMessage(.{ .id = 2, .method = "Target.createTarget", .sessionId = "BSID-1", .params = .{ .url = "about:blank" } });
    const bc = &ctx.cdp().browser_context.?;
    const target_id = &bc.target_id.?;
    try ctx.expectSentResult(.{ .targetId = target_id }, .{ .id = 2, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 3, .method = "Target.getTargets", .sessionId = "BSID-1" });
    try ctx.expectSentResult(.{ .targetInfos = &.{.{ .targetId = target_id, .type = "page", .title = "", .url = "about:blank", .attached = false, .canAccessOpener = false }} }, .{ .id = 3, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 4, .method = "Target.getBrowserContexts", .sessionId = "BSID-1" });
    try ctx.expectSentResult(.{ .browserContextIds = &.{bc.id} }, .{ .id = 4, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 5, .method = "Target.getTargetInfo", .sessionId = "BSID-1", .params = .{ .targetId = target_id } });
    try ctx.expectSentResult(.{ .targetInfo = .{ .targetId = target_id, .type = "page", .title = "", .url = "about:blank", .attached = false, .canAccessOpener = false } }, .{ .id = 5, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 6, .method = "Target.attachToTarget", .sessionId = "BSID-1", .params = .{ .targetId = target_id } });
    const page_session_id = bc.session_id.?;
    try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = page_session_id, .targetInfo = .{ .targetId = target_id, .type = "page", .title = "", .url = "about:blank", .attached = true, .canAccessOpener = false, .browserContextId = bc.id } }, .{ .session_id = "BSID-1" });
    try ctx.expectSentResult(.{ .sessionId = page_session_id }, .{ .id = 6, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 7, .method = "Target.getTargets", .sessionId = "BSID-1" });
    try ctx.expectSentResult(.{ .targetInfos = &.{.{ .targetId = target_id, .type = "page", .title = "", .url = "about:blank", .attached = true, .canAccessOpener = false }} }, .{ .id = 7, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 8, .method = "Target.getTargetInfo", .sessionId = "BSID-1", .params = .{ .targetId = target_id } });
    try ctx.expectSentResult(.{ .targetInfo = .{ .targetId = target_id, .type = "page", .title = "", .url = "about:blank", .attached = true, .canAccessOpener = false } }, .{ .id = 8, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 9, .method = "Target.closeTarget", .sessionId = "BSID-1", .params = .{ .targetId = target_id } });
    try ctx.expectSentResult(.{ .success = true }, .{ .id = 9, .session_id = "BSID-1" });
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
    const target_id_1 = ctx.cdp().browser_context.?.target_id.?;
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
    const target_id_2 = ctx.cdp().browser_context.?.target_id.?;

    try testing.expect(!std.mem.eql(u8, &target_id_1, &target_id_2));
}

test "cdp.target: createTarget" {
    {
        var ctx = try testing.context();
        defer ctx.deinit();
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });

        const bc = ctx.cdp().browser_context.?;
        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 10 });
        try ctx.expectSentCount(1);
    }

    {
        var ctx = try testing.context();
        defer ctx.deinit();
        try ctx.processMessage(.{ .id = 8, .method = "Target.setDiscoverTargets", .params = .{ .discover = true } });
        // active auto attach to get the Target.attachedToTarget event.
        try ctx.processMessage(.{ .id = 9, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });

        // should create a browser context
        const bc = ctx.cdp().browser_context.?;
        try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = false, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{});
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = bc.session_id.?, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{});
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
        try testing.expectEqual(true, bc.target_id != null);
        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 10 });
    }
}

// A browser-target session (Target.attachToBrowserTarget) is distinct from
// the page-target session. It used to be stored in bc.session_id, which broke
// the "no target => no session_id" invariant asserted in createTarget.
test "cdp.target: attachToBrowserTarget routes target events to browser session" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = "BSID-1", .targetInfo = .{ .targetId = "browser", .title = "", .url = "", .attached = true, .type = "browser", .canAccessOpener = false } }, .{ .index = 0 });
    try ctx.expectSentResult(.{ .sessionId = "BSID-1" }, .{ .id = 1 });
    try ctx.expectSentCount(2);
    try testing.expectEqual(null, ctx.cdp().browser_context);

    {
        try ctx.processMessage(.{ .id = 2, .method = "Target.setAutoAttach", .sessionId = "BSID-1", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = "STARTUP", .targetInfo = .{ .targetId = "TID-STARTUP", .title = "", .url = "about:blank", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = "BID-STARTUP" } }, .{ .session_id = "BSID-1" });
        try ctx.expectSentResult(null, .{ .id = 2, .session_id = "BSID-1" });
    }

    try ctx.processMessage(.{ .id = 3, .method = "Target.createBrowserContext", .sessionId = "BSID-1" });
    const bc = &ctx.cdp().browser_context.?;
    try ctx.expectSentResult(.{ .browserContextId = bc.id }, .{ .id = 3, .session_id = "BSID-1" });
    try testing.expectEqual(null, bc.session_id);

    {
        try ctx.processMessage(.{ .id = 4, .method = "Target.createTarget", .sessionId = "BSID-1", .params = .{ .url = "about:blank", .browserContextId = bc.id } });
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = bc.session_id.?, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{ .session_id = "BSID-1" });
        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 4, .session_id = "BSID-1" });
    }

    {
        try ctx.processMessage(.{ .id = 5, .method = "Target.setDiscoverTargets", .sessionId = "BSID-1", .params = .{ .discover = true } });
        try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{ .session_id = "BSID-1" });
        try ctx.expectSentResult(null, .{ .id = 5, .session_id = "BSID-1" });
    }

    {
        // unknown session ids are still rejected
        try ctx.processMessage(.{ .id = 6, .method = "Target.setDiscoverTargets", .sessionId = "SID-NOPE", .params = .{ .discover = true } });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{ .id = 6 });
    }
}

test "cdp.target: browser target session is single and detachable" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = "BSID-1", .targetInfo = .{ .targetId = "browser", .title = "", .url = "", .attached = true, .type = "browser", .canAccessOpener = false } }, .{ .index = 0 });
    try ctx.expectSentResult(.{ .sessionId = "BSID-1" }, .{ .id = 1, .index = 1 });

    try ctx.processMessage(.{ .id = 2, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentError(-32000, "Only one browser target session is supported", .{ .id = 2, .index = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "Target.detachFromTarget", .params = .{ .sessionId = "BSID-1" } });
    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = "BSID-1" }, .{ .index = 3 });
    try ctx.expectSentResult(null, .{ .id = 3, .index = 4 });
    try testing.expectEqual(null, ctx.cdp().browser_session_id);

    try ctx.processMessage(.{ .id = 4, .method = "Target.getTargets", .sessionId = "BSID-1" });
    try ctx.expectSentError(-32001, "Unknown sessionId", .{ .id = 4, .index = 5 });

    try ctx.processMessage(.{ .id = 5, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = "BSID-2", .targetInfo = .{ .targetId = "browser", .title = "", .url = "", .attached = true, .type = "browser", .canAccessOpener = false } }, .{ .index = 6 });
    try ctx.expectSentResult(.{ .sessionId = "BSID-2" }, .{ .id = 5, .index = 7 });
}

test "cdp.target: repeated target discovery does not duplicate existing target" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = "BSID-1", .targetInfo = .{ .targetId = "browser", .title = "", .url = "", .attached = true, .type = "browser", .canAccessOpener = false } }, .{ .index = 0 });
    try ctx.expectSentResult(.{ .sessionId = "BSID-1" }, .{ .id = 1, .index = 1 });

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-9",
        .target_id = "TID-000000000D".*,
    });

    try ctx.processMessage(.{ .id = 2, .method = "Target.setDiscoverTargets", .sessionId = "BSID-1", .params = .{ .discover = true } });
    try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = false, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{ .index = 2, .session_id = "BSID-1" });
    try ctx.expectSentResult(null, .{ .id = 2, .index = 3, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 3, .method = "Target.setDiscoverTargets", .sessionId = "BSID-1", .params = .{ .discover = true } });
    try ctx.expectSentResult(null, .{ .id = 3, .index = 4, .session_id = "BSID-1" });
    try ctx.expectSentCount(5);
}

test "cdp.target: target state cannot be replaced by another session" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentResult(.{ .sessionId = "BSID-1" }, .{ .id = 1 });

    try ctx.processMessage(.{ .id = 2, .method = "Target.setDiscoverTargets", .params = .{ .discover = true } });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "Target.setDiscoverTargets", .sessionId = "BSID-1", .params = .{ .discover = true } });
    try ctx.expectSentError(-32000, "Target discovery is controlled by another session", .{ .id = 3 });
    try ctx.processMessage(.{ .id = 4, .method = "Target.setDiscoverTargets", .sessionId = "BSID-1", .params = .{ .discover = false } });
    try ctx.expectSentError(-32000, "Target discovery is controlled by another session", .{ .id = 4 });
    try testing.expect(ctx.cdp().target_discovery);

    try ctx.processMessage(.{ .id = 5, .method = "Target.setDiscoverTargets", .params = .{ .discover = false } });
    try ctx.expectSentResult(null, .{ .id = 5 });

    try ctx.processMessage(.{ .id = 6, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.expectSentResult(null, .{ .id = 6 });

    try ctx.processMessage(.{ .id = 7, .method = "Target.setAutoAttach", .sessionId = "BSID-1", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.expectSentError(-32000, "Target auto-attach is controlled by another session", .{ .id = 7 });
    try ctx.processMessage(.{ .id = 8, .method = "Target.setAutoAttach", .sessionId = "BSID-1", .params = .{ .autoAttach = false, .waitForDebuggerOnStart = false } });
    try ctx.expectSentError(-32000, "Target auto-attach is controlled by another session", .{ .id = 8 });
    try testing.expect(ctx.cdp().target_auto_attach);

    try ctx.processMessage(.{ .id = 9, .method = "Target.setAutoAttach", .params = .{ .autoAttach = false, .waitForDebuggerOnStart = false } });
    try ctx.expectSentResult(null, .{ .id = 9 });
}

test "cdp.target: closing page-owned target state allows clean recreation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    const bc = &ctx.cdp().browser_context.?;
    try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 1 });

    try ctx.processMessage(.{ .id = 2, .method = "Target.attachToTarget", .params = .{ .targetId = bc.target_id.? } });
    const page_session_id = bc.session_id.?;
    try ctx.expectSentResult(.{ .sessionId = page_session_id }, .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "Target.setDiscoverTargets", .sessionId = page_session_id, .params = .{ .discover = true } });
    try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{ .session_id = page_session_id });
    try ctx.expectSentResult(null, .{ .id = 3, .session_id = page_session_id });

    try ctx.processMessage(.{ .id = 4, .method = "Target.setAutoAttach", .sessionId = page_session_id, .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    try ctx.expectSentResult(null, .{ .id = 4, .session_id = page_session_id });

    const old_target_id = bc.target_id.?;
    try ctx.processMessage(.{ .id = 5, .method = "Target.closeTarget", .sessionId = page_session_id, .params = .{ .targetId = old_target_id } });
    try ctx.expectSentResult(.{ .success = true }, .{ .id = 5, .session_id = page_session_id });
    try ctx.expectSentEvent("Target.targetDestroyed", .{ .targetId = old_target_id }, .{ .session_id = page_session_id });
    try testing.expect(!ctx.cdp().target_discovery);
    try testing.expect(!ctx.cdp().target_auto_attach);
    try testing.expectEqual(null, bc.session_id);

    try ctx.processMessage(.{ .id = 6, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
    try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 6 });
    try testing.expectEqual(null, bc.session_id);
}

test "cdp.target: every target teardown reports destruction" {
    {
        var ctx = try testing.context();
        defer ctx.deinit();

        try ctx.processMessage(.{ .id = 1, .method = "Target.setDiscoverTargets", .params = .{ .discover = true } });
        try ctx.processMessage(.{ .id = 2, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
        const target_id = ctx.cdp().browser_context.?.target_id.?;

        try ctx.processMessage(.{ .id = 3, .method = "Page.close" });
        try ctx.expectSentEvent("Target.targetDestroyed", .{ .targetId = target_id }, .{});
    }

    {
        var ctx = try testing.context();
        defer ctx.deinit();

        try ctx.processMessage(.{ .id = 1, .method = "Target.setDiscoverTargets", .params = .{ .discover = true } });
        try ctx.processMessage(.{ .id = 2, .method = "Target.createTarget", .params = .{ .url = "about:blank" } });
        const bc = &ctx.cdp().browser_context.?;
        const target_id = bc.target_id.?;

        try ctx.processMessage(.{ .id = 3, .method = "Target.disposeBrowserContext", .params = .{ .browserContextId = bc.id } });
        try ctx.expectSentEvent("Target.targetDestroyed", .{ .targetId = target_id }, .{});
    }
}

test "cdp.target: page session events use browser parent session" {
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.processMessage(.{ .id = 1, .method = "Target.attachToBrowserTarget" });
    try ctx.expectSentResult(.{ .sessionId = "BSID-1" }, .{ .id = 1 });

    const bc = try ctx.loadBrowserContext(.{
        .id = "BID-9",
        .target_id = "TID-000000000E".*,
    });

    try ctx.processMessage(.{ .id = 2, .method = "Target.setAutoAttach", .sessionId = "BSID-1", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    const first_page_session_id = bc.session_id.?;
    try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = first_page_session_id, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{ .session_id = "BSID-1" });
    try ctx.expectSentResult(null, .{ .id = 2, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 3, .method = "Target.detachFromTarget", .params = .{ .sessionId = "SID-NOPE" } });
    try ctx.expectSentError(-32001, "Unknown sessionId", .{ .id = 3 });
    try testing.expectEqual(first_page_session_id, bc.session_id.?);

    try ctx.processMessage(.{ .id = 4, .method = "Target.detachFromTarget", .params = .{ .sessionId = first_page_session_id } });
    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = first_page_session_id }, .{ .session_id = "BSID-1" });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try testing.expectEqual(null, bc.session_id);

    _ = try bc.session.createPage();
    try ctx.processMessage(.{ .id = 5, .method = "Target.setAutoAttach", .sessionId = "BSID-1", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
    const second_page_session_id = bc.session_id.?;
    try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = second_page_session_id, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{ .session_id = "BSID-1" });
    try ctx.expectSentResult(null, .{ .id = 5, .session_id = "BSID-1" });

    try ctx.processMessage(.{ .id = 6, .method = "Target.closeTarget", .sessionId = "BSID-1", .params = .{ .targetId = bc.target_id.? } });
    try ctx.expectSentEvent("Target.detachedFromTarget", .{ .targetId = "TID-000000000E", .sessionId = second_page_session_id, .reason = "Render process gone." }, .{ .session_id = "BSID-1" });
    try ctx.expectSentResult(.{ .success = true }, .{ .id = 6, .session_id = "BSID-1" });
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
    bc.target_id = "TID-000000000A".*;
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 11, .method = "Target.closeTarget", .params = .{ .targetId = "TID-000000000A" } });
        try ctx.expectSentResult(.{ .success = true }, .{ .id = 11 });
        try testing.expectEqual(false, bc.session.hasPage());
        try testing.expectEqual(null, bc.target_id);
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
    bc.target_id = "TID-000000000B".*;
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-8" } });
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-000000000B" } });
        const session_id = bc.session_id.?;
        try ctx.expectSentResult(.{ .sessionId = session_id }, .{ .id = 11 });
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = session_id, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = "BID-9", .targetId = bc.target_id.? } }, .{});

        try ctx.processMessage(.{ .id = 12, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-000000000B" } });
        try ctx.expectSentError(-32000, "Target is already attached", .{ .id = 12 });
        try testing.expectEqual(session_id, bc.session_id.?);
    }
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
    bc.target_id = "TID-000000000C".*;
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
                .attached = false,
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
        try testing.expectEqual(true, bc.target_id != null);
        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 10 });

        try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = bc.target_id.? } });
        const session_id = bc.session_id.?;
        try ctx.expectSentResult(.{ .sessionId = session_id }, .{ .id = 11 });
    }
}

test "cdp.target: detachFromTarget" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
        try testing.expectEqual(true, bc.target_id != null);
        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 10 });

        try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = bc.target_id.? } });
        const session_id = bc.session_id.?;
        try ctx.expectSentResult(.{ .sessionId = session_id }, .{ .id = 11 });

        try ctx.processMessage(.{ .id = 12, .method = "Target.detachFromTarget", .params = .{ .targetId = bc.target_id.? } });
        try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = session_id }, .{});
        try testing.expectEqual(null, bc.session_id);
        try ctx.expectSentResult(null, .{ .id = 12 });

        try ctx.processMessage(.{ .id = 13, .method = "Target.attachToTarget", .params = .{ .targetId = bc.target_id.? } });
        try ctx.expectSentResult(.{ .sessionId = bc.session_id.? }, .{ .id = 13 });
    }
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
    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
        try testing.expectEqual(true, bc.target_id != null);
        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 10 });

        try ctx.processMessage(.{ .id = 11, .method = "Target.setAutoAttach", .params = .{ .autoAttach = true, .waitForDebuggerOnStart = false } });
        const session_id = bc.session_id.?;
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = session_id, .targetInfo = .{ .url = "about:blank", .title = "", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = bc.id, .targetId = bc.target_id.? } }, .{});
        try ctx.expectSentResult(null, .{ .id = 11 });

        // setAutoAttach false should fire detachedFromTarget event
        try ctx.processMessage(.{ .id = 12, .method = "Target.setAutoAttach", .params = .{ .autoAttach = false, .waitForDebuggerOnStart = false } });
        try ctx.expectSentEvent("Target.detachedFromTarget", .{ .sessionId = session_id }, .{});
        try testing.expectEqual(null, bc.session_id);
        try ctx.expectSentResult(null, .{ .id = 12 });
    }
}
