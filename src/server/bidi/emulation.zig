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

const std = @import("std");

const Viewport = @import("../../browser/Viewport.zig");

const BiDi = @import("BiDi.zig");
const browsing_context = @import("browsing_context.zig");

pub fn processMessage(cmd: *BiDi.Command, action: []const u8) !void {
    const command = std.meta.stringToEnum(enum {
        setScreenOrientationOverride,
    }, action) orelse return error.UnknownCommand;

    switch (command) {
        .setScreenOrientationOverride => return setScreenOrientationOverride(cmd),
    }
}

// Like the viewport, the orientation belongs to the Browser.
fn setScreenOrientationOverride(cmd: *BiDi.Command) !void {
    const p = try cmd.params(struct {
        screenOrientation: ?struct {
            natural: enum { portrait, landscape },
            type: Viewport.Orientation.Type,
        },
        contexts: ?[]const []const u8 = null,
        userContexts: ?[]const []const u8 = null,
    });
    if ((try requireTargets(cmd, p.contexts, p.userContexts)) == false) {
        return;
    }

    const browser = &cmd.bidi.browser;
    var viewport = browser.getViewport();
    viewport.orientation = if (p.screenOrientation) |o| .{
        .type = o.type,
        // quarter turns away from the natural orientation's primary
        .angle = switch (o.natural) {
            .portrait => switch (o.type) {
                .@"portrait-primary" => 0,
                .@"landscape-primary" => 90,
                .@"portrait-secondary" => 180,
                .@"landscape-secondary" => 270,
            },
            .landscape => switch (o.type) {
                .@"landscape-primary" => 0,
                .@"portrait-primary" => 90,
                .@"landscape-secondary" => 180,
                .@"portrait-secondary" => 270,
            },
        },
    } else null;
    browser.setViewportOverride(viewport);
    return cmd.sendDone();
}

fn requireTargets(cmd: *BiDi.Command, contexts: ?[]const []const u8, user_contexts: ?[]const []const u8) !bool {
    if (contexts != null and user_contexts != null) {
        try cmd.sendError("invalid argument", "contexts and userContexts are mutually exclusive");
        return false;
    }
    for (contexts orelse &.{}) |context| {
        _ = (try browsing_context.requireContext(cmd, context)) orelse return false;
    }
    for (user_contexts orelse &.{}) |user_context| {
        if (std.mem.eql(u8, user_context, cmd.bidi.user_context.id()) == false) {
            try cmd.sendError("no such user context", "unknown user context");
            return false;
        }
    }
    return true;
}

const testing = @import("testing.zig");
test "bidi.emulation: setScreenOrientationOverride" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const context_id = try ctx.createContext(.{ .url = "bidi/values.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "emulation.setScreenOrientationOverride",
        .params = .{ .contexts = .{context_id}, .screenOrientation = .{ .natural = "landscape", .type = "portrait-primary" } },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "script.evaluate",
        .params = .{ .expression = "`${screen.orientation.type}@${screen.orientation.angle}`", .awaitPromise = false, .target = .{ .context = context_id } },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "string", .value = "portrait-primary@90" } }, .{ .id = 2 });

    // null clears it
    try ctx.processMessage(.{ .id = 3, .method = "emulation.setScreenOrientationOverride", .params = .{ .screenOrientation = null } });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try testing.expectEqual(null, ctx.bidi().browser.getViewport().orientation);

    try ctx.processMessage(.{ .id = 4, .method = "emulation.setScreenOrientationOverride", .params = .{ .screenOrientation = null, .contexts = .{"nope"} } });
    try ctx.expectSentError("no such frame", null, .{ .id = 4 });
    try ctx.processMessage(.{
        .id = 5,
        .method = "emulation.setScreenOrientationOverride",
        .params = .{ .screenOrientation = .{ .natural = "portrait", .type = "sideways" } },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 5 });
}
