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
const cdp = @import("cdp.zig");

const log = std.log.scoped(.cdp);

// TODO: hard coded IDs
const CONTEXT_ID = "CONTEXTIDDCCDD11109E2D4FEFBE4F89";
const PAGE_TARGET_ID = "PAGETARGETIDB638E9DC0F52DDC";
const BROWSER_TARGET_ID = "browser9-targ-et6f-id0e-83f3ab73a30c";
const BROWER_CONTEXT_ID = "BROWSERCONTEXTIDA95049E9DFE95EA9";
const TARGET_ID = "TARGETID460A8F29706A2ADF14316298";
const LOADER_ID = "LOADERID42AA389647D702B4D805F49A";

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        setDiscoverTargets,
        setAutoAttach,
        attachToTarget,
        getTargetInfo,
        getBrowserContexts,
        createBrowserContext,
        disposeBrowserContext,
        createTarget,
        closeTarget,
        sendMessageToTarget,
        detachFromTarget,
    }, cmd.action) orelse return error.UnknownMethod;

    switch (action) {
        .setDiscoverTargets => return setDiscoverTargets(cmd),
        .setAutoAttach => return setAutoAttach(cmd),
        .attachToTarget => return attachToTarget(cmd),
        .getTargetInfo => return getTargetInfo(cmd),
        .getBrowserContexts => return getBrowserContexts(cmd),
        .createBrowserContext => return createBrowserContext(cmd),
        .disposeBrowserContext => return disposeBrowserContext(cmd),
        .createTarget => return createTarget(cmd),
        .closeTarget => return closeTarget(cmd),
        .sendMessageToTarget => return sendMessageToTarget(cmd),
        .detachFromTarget => return detachFromTarget(cmd),
    }
}
// TODO: noop method
fn setDiscoverTargets(cmd: anytype) !void {
    return cmd.sendResult(null, .{});
}

const AttachToTarget = struct {
    sessionId: []const u8,
    targetInfo: TargetInfo,
    waitingForDebugger: bool = false,
};

const TargetCreated = struct {
    sessionId: []const u8,
    targetInfo: TargetInfo,
};

const TargetInfo = struct {
    targetId: []const u8,
    type: []const u8 = "page",
    title: []const u8,
    url: []const u8,
    attached: bool = true,
    canAccessOpener: bool = false,
    browserContextId: []const u8,
};

// TODO: noop method
fn setAutoAttach(cmd: anytype) !void {
    // const TargetFilter = struct {
    //     type: ?[]const u8 = null,
    //     exclude: ?bool = null,
    // };

    // const params = (try cmd.params(struct {
    //     autoAttach: bool,
    //     waitForDebuggerOnStart: bool,
    //     flatten: bool = true,
    //     filter: ?[]TargetFilter = null,
    // })) orelse return error.InvalidParams;

    // attachedToTarget event
    if (cmd.session_id == null) {
        try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
            .sessionId = cdp.BROWSER_SESSION_ID,
            .targetInfo = .{
                .targetId = PAGE_TARGET_ID,
                .title = "about:blank",
                .url = cdp.URL_BASE,
                .browserContextId = BROWER_CONTEXT_ID,
            },
        }, .{});
    }

    return cmd.sendResult(null, .{});
}

// TODO: noop method
fn attachToTarget(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        targetId: []const u8,
        flatten: bool = true,
    })) orelse return error.InvalidParams;

    // attachedToTarget event
    if (cmd.session_id == null) {
        try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
            .sessionId = cdp.BROWSER_SESSION_ID,
            .targetInfo = .{
                .targetId = params.targetId,
                .title = "about:blank",
                .url = cdp.URL_BASE,
                .browserContextId = BROWER_CONTEXT_ID,
            },
        }, .{});
    }

    return cmd.sendResult(
        .{ .sessionId = cmd.session_id orelse cdp.BROWSER_SESSION_ID },
        .{ .include_session_id = false },
    );
}

fn getTargetInfo(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     targetId: ?[]const u8 = null,
    // })) orelse return error.InvalidParams;

    return cmd.sendResult(.{
        .targetId = BROWSER_TARGET_ID,
        .type = "browser",
        .title = "",
        .url = "",
        .attached = true,
        .canAccessOpener = false,
    }, .{ .include_session_id = false });
}

// Browser context are not handled and not in the roadmap for now
// The following methods are "fake"

// TODO: noop method
fn getBrowserContexts(cmd: anytype) !void {
    var context_ids: []const []const u8 = undefined;
    if (cmd.cdp.context_id) |context_id| {
        context_ids = &.{context_id};
    } else {
        context_ids = &.{};
    }

    return cmd.sendResult(.{
        .browserContextIds = context_ids,
    }, .{ .include_session_id = false });
}

// TODO: noop method
fn createBrowserContext(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //    disposeOnDetach: bool = false,
    //    proxyServer: ?[]const u8 = null,
    //    proxyBypassList: ?[]const u8 = null,
    //    originsWithUniversalNetworkAccess: ?[][]const u8 = null,
    // })) orelse return error.InvalidParams;

    cmd.cdp.context_id = CONTEXT_ID;

    const Response = struct {
        browserContextId: []const u8,

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.writeAll("cdp.target.createBrowserContext { ");
            try writer.writeAll(".browserContextId = ");
            try std.fmt.formatText(self.browserContextId, "s", options, writer);
            try writer.writeAll(" }");
        }
    };

    return cmd.sendResult(Response{
        .browserContextId = CONTEXT_ID,
    }, .{});
}

fn disposeBrowserContext(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //    browserContextId: []const u8,
    //    proxyServer: ?[]const u8 = null,
    //    proxyBypassList: ?[]const u8 = null,
    //    originsWithUniversalNetworkAccess: ?[][]const u8 = null,
    // })) orelse return error.InvalidParams;

    try cmd.cdp.newSession();
    try cmd.sendResult(null, .{});
}

fn createTarget(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        url: []const u8,
        width: ?u64 = null,
        height: ?u64 = null,
        browserContextId: ?[]const u8 = null,
        enableBeginFrameControl: bool = false,
        newWindow: bool = false,
        background: bool = false,
        forTab: ?bool = null,
    })) orelse return error.InvalidParams;

    // change CDP state
    var state = cmd.cdp;
    state.frame_id = TARGET_ID;
    state.url = "about:blank";
    state.security_origin = "://";
    state.secure_context_type = "InsecureScheme";
    state.loader_id = LOADER_ID;

    if (cmd.session_id) |s| {
        state.session_id = try cdp.SessionID.parse(s);
    }

    // TODO stop the previous page instead?
    if (cmd.session.page != null) {
        return error.pageAlreadyExists;
    }

    // create the page
    const p = try cmd.session.createPage();
    state.execution_context_id += 1;

    // start the js env
    const aux_data = try std.fmt.allocPrint(
        cmd.arena,
        // NOTE: we assume this is the default web page
        "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}",
        .{state.frame_id},
    );
    try p.start(aux_data);

    const browser_context_id = params.browserContextId orelse CONTEXT_ID;

    // send targetCreated event
    try cmd.sendEvent("Target.targetCreated", TargetCreated{
        .sessionId = cdp.CONTEXT_SESSION_ID,
        .targetInfo = .{
            .targetId = state.frame_id,
            .title = "about:blank",
            .url = state.url,
            .browserContextId = browser_context_id,
            .attached = true,
        },
    }, .{ .session_id = cmd.session_id });

    // send attachToTarget event
    try cmd.sendEvent("Target.attachedToTarget", AttachToTarget{
        .sessionId = cdp.CONTEXT_SESSION_ID,
        .waitingForDebugger = true,
        .targetInfo = .{
            .targetId = state.frame_id,
            .title = "about:blank",
            .url = state.url,
            .browserContextId = browser_context_id,
            .attached = true,
        },
    }, .{ .session_id = cmd.session_id });

    const Response = struct {
        targetId: []const u8 = TARGET_ID,

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.writeAll("cdp.target.createTarget { ");
            try writer.writeAll(".targetId = ");
            try std.fmt.formatText(self.targetId, "s", options, writer);
            try writer.writeAll(" }");
        }
    };
    return cmd.sendResult(Response{}, .{});
}

fn closeTarget(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        targetId: []const u8,
    })) orelse return error.InvalidParams;

    try cmd.sendResult(.{
        .success = true,
    }, .{ .include_session_id = false });

    const session_id = cmd.session_id orelse cdp.CONTEXT_SESSION_ID;

    // Inspector.detached event
    try cmd.sendEvent("Inspector.detached", .{
        .reason = "Render process gone.",
    }, .{ .session_id = session_id });

    // detachedFromTarget event
    try cmd.sendEvent("Target.detachedFromTarget", .{
        .sessionId = session_id,
        .targetId = params.targetId,
        .reason = "Render process gone.",
    }, .{});

    if (cmd.session.page) |*page| {
        page.end();
    }
}

fn sendMessageToTarget(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        message: []const u8,
        sessionId: []const u8,
    })) orelse return error.InvalidParams;

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
        log.err("send message {d} ({s}): {any}", .{ cmd.id orelse -1, params.message, err });
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
