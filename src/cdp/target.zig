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

const log = std.log.scoped(.cdp);

// TODO: hard coded IDs
const LOADER_ID = "LOADERID42AA389647D702B4D805F49A";

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        attachToTarget,
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
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .attachToTarget => return attachToTarget(cmd),
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
    }
}

fn getBrowserContexts(cmd: anytype) !void {
    var browser_context_ids: []const []const u8 = undefined;
    if (cmd.browser_context) |bc| {
        browser_context_ids = &.{bc.id};
    } else {
        browser_context_ids = &.{};
    }

    return cmd.sendResult(.{
        .browserContextIds = browser_context_ids,
    }, .{ .include_session_id = false });
}

fn createBrowserContext(cmd: anytype) !void {
    const bc = cmd.createBrowserContext() catch |err| switch (err) {
        error.AlreadyExists => return cmd.sendError(-32000, "Cannot have more than one browser context at a time"),
        else => return err,
    };

    return cmd.sendResult(.{
        .browserContextId = bc.id,
    }, .{});
}

fn disposeBrowserContext(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        browserContextId: []const u8,
    })) orelse return error.InvalidParams;

    if (cmd.cdp.disposeBrowserContext(params.browserContextId) == false) {
        return cmd.sendError(-32602, "No browser context with the given id found");
    }
    try cmd.sendResult(null, .{});
}

fn createTarget(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        // url: []const u8,
        // width: ?u64 = null,
        // height: ?u64 = null,
        browserContextId: ?[]const u8 = null,
        // enableBeginFrameControl: bool = false,
        // newWindow: bool = false,
        // background: bool = false,
        // forTab: ?bool = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    if (bc.target_id != null) {
        return error.TargetAlreadyLoaded;
    }
    if (params.browserContextId) |param_browser_context_id| {
        if (std.mem.eql(u8, param_browser_context_id, bc.id) == false) {
            return error.UnknownBrowserContextId;
        }
    }

    // if target_id is null, we should never have a page
    std.debug.assert(bc.session.page == null);

    // if target_id is null, we should never have a session_id
    std.debug.assert(bc.session_id == null);

    const page = try bc.session.createPage();
    const target_id = cmd.cdp.target_id_gen.next();

    // change CDP state
    bc.url = "about:blank";
    bc.security_origin = "://";
    bc.secure_context_type = "InsecureScheme";
    bc.loader_id = LOADER_ID;

    // start the js env
    const aux_data = try std.fmt.allocPrint(
        cmd.arena,
        // NOTE: we assume this is the default web page
        "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}",
        .{target_id},
    );
    try page.start(aux_data);

    // send targetCreated event
    // TODO: should this only be sent when Target.setDiscoverTargets
    // has been enabled?
    try cmd.sendEvent("Target.targetCreated", .{
        .targetInfo = TargetInfo{
            .url = bc.url,
            .targetId = target_id,
            .title = "about:blank",
            .browserContextId = bc.id,
            .attached = false,
        },
    }, .{});

    // only if setAutoAttach is true?
    try doAttachtoTarget(cmd, target_id);
    bc.target_id = target_id;

    try cmd.sendResult(.{
        .targetId = target_id,
    }, .{});
}

fn attachToTarget(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        targetId: []const u8,
        flatten: bool = true,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const target_id = bc.target_id orelse return error.TargetNotLoaded;
    if (std.mem.eql(u8, target_id, params.targetId) == false) {
        return error.UnknownTargetId;
    }

    if (bc.session_id != null) {
        return error.SessionAlreadyLoaded;
    }

    try doAttachtoTarget(cmd, target_id);

    return cmd.sendResult(
        .{ .sessionId = bc.session_id },
        .{ .include_session_id = false },
    );
}

fn closeTarget(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        targetId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const target_id = bc.target_id orelse return error.TargetNotLoaded;
    if (std.mem.eql(u8, target_id, params.targetId) == false) {
        return error.UnknownTargetId;
    }

    // can't be null if we have a target_id
    std.debug.assert(bc.session.page != null);

    try cmd.sendResult(.{ .success = true }, .{ .include_session_id = false });

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

    bc.session.currentPage().?.end();
    bc.target_id = null;
}

fn getTargetInfo(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        targetId: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    if (params.targetId) |param_target_id| {
        const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
        const target_id = bc.target_id orelse return error.TargetNotLoaded;
        if (std.mem.eql(u8, target_id, param_target_id) == false) {
            return error.UnknownTargetId;
        }

        return cmd.sendResult(.{
            .targetId = target_id,
            .type = "page",
            .title = "",
            .url = "",
            .attached = true,
            .canAccessOpener = false,
        }, .{ .include_session_id = false });
    }

    return cmd.sendResult(.{
        .type = "browser",
        .title = "",
        .url = "",
        .attached = true,
        .canAccessOpener = false,
    }, .{ .include_session_id = false });
}

fn sendMessageToTarget(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        message: []const u8,
        sessionId: []const u8,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    if (bc.target_id == null) {
        return error.TargetNotLoaded;
    }

    std.debug.assert(bc.session_id != null);
    if (std.mem.eql(u8, bc.session_id.?, params.sessionId) == false) {
        // Is this right? Is the params.sessionId meant to be the active
        // sessionId? What else could it be? We have no other session_id.
        return error.UnknownSessionId;
    }

    const Capture = struct {
        allocator: std.mem.Allocator,
        buf: std.ArrayListUnmanaged(u8),

        pub fn sendJSON(self: *@This(), message: anytype) !void {
            return std.json.stringify(message, .{
                .emit_null_optional_fields = false,
            }, self.buf.writer(self.allocator));
        }
    };

    var capture = Capture{
        .buf = .{},
        .allocator = cmd.arena,
    };

    cmd.cdp.dispatch(cmd.arena, &capture, params.message) catch |err| {
        log.err("send message {d} ({s}): {any}", .{ cmd.input.id orelse -1, params.message, err });
        return err;
    };

    try cmd.sendEvent("Target.receivedMessageFromTarget", .{
        .message = capture.buf.items,
        .sessionId = params.sessionId,
    }, .{});
}

// noop
fn detachFromTarget(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn setDiscoverTargets(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

fn setAutoAttach(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     autoAttach: bool,
    //     waitForDebuggerOnStart: bool,
    //     flatten: bool = true,
    //     filter: ?[]TargetFilter = null,
    // })) orelse return error.InvalidParams;

    // TODO: should set a flag to send Target.attachedToTarget events

    try cmd.sendResult(null, .{});

    if (cmd.browser_context) |bc| {
        if (bc.target_id == null) {
            // hasn't attached  yet
            const target_id = cmd.cdp.target_id_gen.next();
            try doAttachtoTarget(cmd, target_id);
            bc.target_id = target_id;
        }
        // should we send something here?
        return;
    }

    // This is a hack. Puppeteer, and probably others, expect the Browser to
    // automatically started creating targets. Things like an empty tab, or
    // a blank page. And they block until this happens. So we send an event
    // telling them that they've been attached to our Broswer. Hopefully, the
    // first thing they'll do is create a real BrowserContext and progress from
    // there.
    // This hack requires the main cdp dispatch handler to special case
    // messages from this "STARTUP" session.
    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = "STARTUP",
        .targetInfo = TargetInfo{
            .type = "browser",
            .targetId = "TID-STARTUP",
            .title = "about:blank",
            .url = "chrome://newtab/",
            .browserContextId = "BID-STARTUP",
        },
    }, .{});
}

fn doAttachtoTarget(cmd: anytype, target_id: []const u8) !void {
    const bc = cmd.browser_context.?;
    std.debug.assert(bc.session_id == null);
    const session_id = cmd.cdp.session_id_gen.next();

    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = session_id,
        .targetInfo = TargetInfo{
            .targetId = target_id,
            .title = "about:blank",
            .url = "chrome://newtab/",
            .browserContextId = bc.id,
        },
    }, .{});

    bc.session_id = session_id;
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
    browserContextId: []const u8,
};

const testing = @import("testing.zig");
test "cdp.target: getBrowserContexts" {
    var ctx = testing.context();
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
    var ctx = testing.context();
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
    var ctx = testing.context();
    defer ctx.deinit();

    {
        try testing.expectError(error.InvalidParams, ctx.processMessage(.{ .id = 7, .method = "Target.disposeBrowserContext" }));
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

test "cdp.target: createTarget" {
    var ctx = testing.context();
    defer ctx.deinit();

    {
        try testing.expectError(error.BrowserContextNotLoaded, ctx.processMessage(.{
            .id = 10,
            .method = "Target.createTarget",
            .params = struct {}{},
        }));
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try testing.expectError(error.UnknownBrowserContextId, ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-8" } }));
        try ctx.expectSentError(-31998, "UnknownBrowserContextId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 10, .method = "Target.createTarget", .params = .{ .browserContextId = "BID-9" } });
        try testing.expectEqual(true, bc.target_id != null);
        try testing.expectString(
            \\{"isDefault":true,"type":"default","frameId":"TID-1"}
        , bc.session.page.?.aux_data);

        try ctx.expectSentResult(.{ .targetId = bc.target_id.? }, .{ .id = 10 });
        try ctx.expectSentEvent("Target.targetCreated", .{ .targetInfo = .{ .url = "about:blank", .title = "about:blank", .attached = false, .type = "page", .canAccessOpener = false, .browserContextId = "BID-9", .targetId = bc.target_id.? } }, .{});

        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = bc.session_id.?, .targetInfo = .{ .url = "chrome://newtab/", .title = "about:blank", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = "BID-9", .targetId = bc.target_id.? } }, .{});
    }
}

test "cdp.target: closeTarget" {
    var ctx = testing.context();
    defer ctx.deinit();

    {
        try testing.expectError(error.BrowserContextNotLoaded, ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "X" } }));
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try testing.expectError(error.TargetNotLoaded, ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "TID-8" } }));
        try ctx.expectSentError(-31998, "TargetNotLoaded", .{ .id = 10 });
    }

    // pretend we createdTarget first
    _ = try bc.session.createPage();
    bc.target_id = "TID-A";
    {
        try testing.expectError(error.UnknownTargetId, ctx.processMessage(.{ .id = 10, .method = "Target.closeTarget", .params = .{ .targetId = "TID-8" } }));
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 11, .method = "Target.closeTarget", .params = .{ .targetId = "TID-A" } });
        try ctx.expectSentResult(.{ .success = true }, .{ .id = 11 });
        try testing.expectEqual(null, bc.session.page);
        try testing.expectEqual(null, bc.target_id);
    }
}

test "cdp.target: attachToTarget" {
    var ctx = testing.context();
    defer ctx.deinit();

    {
        try testing.expectError(error.BrowserContextNotLoaded, ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "X" } }));
        try ctx.expectSentError(-31998, "BrowserContextNotLoaded", .{ .id = 10 });
    }

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-9" });
    {
        try testing.expectError(error.TargetNotLoaded, ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-8" } }));
        try ctx.expectSentError(-31998, "TargetNotLoaded", .{ .id = 10 });
    }

    // pretend we createdTarget first
    _ = try bc.session.createPage();
    bc.target_id = "TID-B";
    {
        try testing.expectError(error.UnknownTargetId, ctx.processMessage(.{ .id = 10, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-8" } }));
        try ctx.expectSentError(-31998, "UnknownTargetId", .{ .id = 10 });
    }

    {
        try ctx.processMessage(.{ .id = 11, .method = "Target.attachToTarget", .params = .{ .targetId = "TID-B" } });
        const session_id = bc.session_id.?;
        try ctx.expectSentResult(.{ .sessionId = session_id }, .{ .id = 11 });
        try ctx.expectSentEvent("Target.attachedToTarget", .{ .sessionId = session_id, .targetInfo = .{ .url = "chrome://newtab/", .title = "about:blank", .attached = true, .type = "page", .canAccessOpener = false, .browserContextId = "BID-9", .targetId = bc.target_id.? } }, .{});
    }
}
