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
const runtime = @import("runtime.zig");

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getFrameTree,
        setLifecycleEventsEnabled,
        addScriptToEvaluateOnNewDocument,
        createIsolatedWorld,
        navigate,
    }, cmd.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getFrameTree => return getFrameTree(cmd),
        .setLifecycleEventsEnabled => return setLifecycleEventsEnabled(cmd),
        .addScriptToEvaluateOnNewDocument => return addScriptToEvaluateOnNewDocument(cmd),
        .createIsolatedWorld => return createIsolatedWorld(cmd),
        .navigate => return navigate(cmd),
    }
}

const Frame = struct {
    id: []const u8,
    loaderId: []const u8,
    url: []const u8,
    domainAndRegistry: []const u8 = "",
    securityOrigin: []const u8,
    mimeType: []const u8 = "text/html",
    adFrameStatus: struct {
        adFrameType: []const u8 = "none",
    } = .{},
    secureContextType: []const u8,
    crossOriginIsolatedContextType: []const u8 = "NotIsolated",
    gatedAPIFeatures: [][]const u8 = &[0][]const u8{},
};

fn getFrameTree(cmd: anytype) !void {
    // output
    const FrameTree = struct {
        frameTree: struct {
            frame: Frame,
        },
        childFrames: ?[]@This() = null,

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.writeAll("cdp.page.getFrameTree { ");
            try writer.writeAll(".frameTree = { ");
            try writer.writeAll(".frame = { ");

            const frame = self.frameTree.frame;
            try writer.writeAll(".id = ");
            try std.fmt.formatText(frame.id, "s", options, writer);
            try writer.writeAll(", .loaderId = ");
            try std.fmt.formatText(frame.loaderId, "s", options, writer);
            try writer.writeAll(", .url = ");
            try std.fmt.formatText(frame.url, "s", options, writer);
            try writer.writeAll(" } } }");
        }
    };

    const state = cmd.cdp;
    return cmd.sendResult(FrameTree{
        .frameTree = .{
            .frame = .{
                .id = state.frame_id,
                .url = state.url,
                .securityOrigin = state.security_origin,
                .secureContextType = state.secure_context_type,
                .loaderId = state.loader_id,
            },
        },
    }, .{});
}

fn setLifecycleEventsEnabled(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     enabled: bool,
    // })) orelse return error.InvalidParams;

    cmd.cdp.page_life_cycle_events = true;
    return cmd.sendResult(null, .{});
}

// TODO: hard coded method
fn addScriptToEvaluateOnNewDocument(cmd: anytype) !void {
    // const params = (try cmd.params(struct {
    //     source: []const u8,
    //     worldName: ?[]const u8 = null,
    //     includeCommandLineAPI: bool = false,
    //     runImmediately: bool = false,
    // })) orelse return error.InvalidParams;

    const Response = struct {
        identifier: []const u8 = "1",

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.writeAll("cdp.page.addScriptToEvaluateOnNewDocument { ");
            try writer.writeAll(".identifier = ");
            try std.fmt.formatText(self.identifier, "s", options, writer);
            try writer.writeAll(" }");
        }
    };
    return cmd.sendResult(Response{}, .{});
}

// TODO: hard coded method
fn createIsolatedWorld(cmd: anytype) !void {
    const session_id = cmd.session_id orelse return error.SessionIdRequired;

    const params = (try cmd.params(struct {
        frameId: []const u8,
        worldName: []const u8,
        grantUniveralAccess: bool,
    })) orelse return error.InvalidParams;

    // noop executionContextCreated event
    try cmd.sendEvent("Runtime.executionContextCreated", .{
        .context = runtime.ExecutionContextCreated{
            .id = 0,
            .origin = "",
            .name = params.worldName,
            // TODO: hard coded ID
            .uniqueId = "7102379147004877974.3265385113993241162",
            .auxData = .{
                .isDefault = false,
                .type = "isolated",
                .frameId = params.frameId,
            },
        },
    }, .{ .session_id = session_id });

    return cmd.sendResult(.{
        .executionContextId = 0,
    }, .{});
}

fn navigate(cmd: anytype) !void {
    const session_id = cmd.session_id orelse return error.SessionIdRequired;

    const params = (try cmd.params(struct {
        url: []const u8,
        referrer: ?[]const u8 = null,
        transitionType: ?[]const u8 = null, // TODO: enum
        frameId: ?[]const u8 = null,
        referrerPolicy: ?[]const u8 = null, // TODO: enum
    })) orelse return error.InvalidParams;

    // change state
    var state = cmd.cdp;
    state.reset();
    state.url = params.url;

    // TODO: hard coded ID
    state.loader_id = "AF8667A203C5392DBE9AC290044AA4C2";

    const LifecycleEvent = struct {
        frameId: []const u8,
        loaderId: ?[]const u8,
        name: []const u8,
        timestamp: f32,
    };

    var life_event = LifecycleEvent{
        .frameId = state.frame_id,
        .loaderId = state.loader_id,
        .name = "init",
        .timestamp = 343721.796037,
    };

    // frameStartedLoading event
    // TODO: event partially hard coded
    try cmd.sendEvent("Page.frameStartedLoading", .{
        .frameId = state.frame_id,
    }, .{ .session_id = session_id });

    if (state.page_life_cycle_events) {
        try cmd.sendEvent("Page.lifecycleEvent", life_event, .{ .session_id = session_id });
    }

    // output
    const Response = struct {
        frameId: []const u8,
        loaderId: ?[]const u8,
        errorText: ?[]const u8 = null,

        pub fn format(
            self: @This(),
            comptime _: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.writeAll("cdp.page.navigate.Resp { ");
            try writer.writeAll(".frameId = ");
            try std.fmt.formatText(self.frameId, "s", options, writer);
            if (self.loaderId) |loaderId| {
                try writer.writeAll(", .loaderId = '");
                try std.fmt.formatText(loaderId, "s", options, writer);
            }
            try writer.writeAll(" }");
        }
    };

    try cmd.sendResult(Response{
        .frameId = state.frame_id,
        .loaderId = state.loader_id,
    }, .{});

    // TODO: at this point do we need async the following actions to be async?

    // Send Runtime.executionContextsCleared event
    // TODO: noop event, we have no env context at this point, is it necesarry?
    try cmd.sendEvent("Runtime.executionContextsCleared", null, .{ .session_id = session_id });

    // Launch navigate, the page must have been created by a
    // target.createTarget.
    var p = cmd.session.page orelse return error.NoPage;
    state.execution_context_id += 1;

    const aux_data = try std.fmt.allocPrint(
        cmd.arena,
        // NOTE: we assume this is the default web page
        "{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}",
        .{state.frame_id},
    );
    try p.navigate(params.url, aux_data);

    // Events

    // lifecycle init event
    // TODO: partially hard coded
    if (state.page_life_cycle_events) {
        life_event.name = "init";
        life_event.timestamp = 343721.796037;
        try cmd.sendEvent("Page.lifecycleEvent", life_event, .{ .session_id = session_id });
    }


    try cmd.sendEvent("DOM.documentUpdated", null, .{.session_id = session_id});

    // frameNavigated event
    try cmd.sendEvent("Page.frameNavigated", .{
        .type = "Navigation",
        .frame = Frame{
            .id = state.frame_id,
            .url = state.url,
            .securityOrigin = state.security_origin,
            .secureContextType = state.secure_context_type,
            .loaderId = state.loader_id,
        },
    }, .{ .session_id = session_id });

    // domContentEventFired event
    // TODO: partially hard coded
    try cmd.sendEvent(
        "Page.domContentEventFired",
        cdp.TimestampEvent{ .timestamp = 343721.803338 },
        .{ .session_id = session_id },
    );

    // lifecycle DOMContentLoaded event
    // TODO: partially hard coded
    if (state.page_life_cycle_events) {
        life_event.name = "DOMContentLoaded";
        life_event.timestamp = 343721.803338;
        try cmd.sendEvent("Page.lifecycleEvent", life_event, .{ .session_id = session_id });
    }

    // loadEventFired event
    // TODO: partially hard coded
    try cmd.sendEvent(
        "Page.loadEventFired",
        cdp.TimestampEvent{ .timestamp = 343721.824655 },
        .{ .session_id = session_id },
    );

    // lifecycle DOMContentLoaded event
    // TODO: partially hard coded
    if (state.page_life_cycle_events) {
        life_event.name = "load";
        life_event.timestamp = 343721.824655;
        try cmd.sendEvent("Page.lifecycleEvent", life_event, .{ .session_id = session_id });
    }

    // frameStoppedLoading
    return cmd.sendEvent("Page.frameStoppedLoading", .{
        .frameId = state.frame_id,
    }, .{ .session_id = session_id });
}
