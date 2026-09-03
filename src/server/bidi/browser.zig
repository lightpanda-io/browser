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
const lp = @import("lightpanda");

const uuidv4 = @import("../../id.zig").uuidv4;

const BiDi = @import("BiDi.zig");
const browsing_context = @import("browsing_context.zig");

const log = lp.log;

pub fn processMessage(cmd: *const BiDi.Command) !void {
    const command = std.meta.stringToEnum(enum {
        close,
        getUserContexts,
        createUserContext,
        removeUserContext,
    }, cmd.action) orelse return error.UnknownCommand;

    switch (command) {
        .close => return close(cmd),
        .getUserContexts => return getUserContexts(cmd),
        .createUserContext => return createUserContext(cmd),
        .removeUserContext => return removeUserContext(cmd),
    }
}

fn close(cmd: *const BiDi.Command) !void {
    try cmd.sendResult(struct {}{});

    const bidi = cmd.bidi;
    const arena = try bidi.browser.arena_pool.acquire(.tiny, "bidi browser close");
    bidi.conn.inbox.push(arena, .close);
}

const UserContextInfo = struct { userContext: []const u8 };

fn getUserContexts(cmd: *const BiDi.Command) !void {
    const bidi = cmd.bidi;
    var infos: [2]UserContextInfo = .{ .{ .userContext = "default" }, undefined };
    var len: usize = 1;
    if (bidi.user_context.isDefault() == false) {
        len = 2;
        infos[1] = .{ .userContext = bidi.user_context.id() };
    }
    return cmd.sendResult(.{ .userContexts = infos[0..len] });
}

fn createUserContext(cmd: *const BiDi.Command) !void {
    const p = try cmd.params(struct {
        proxy: ?std.json.Value = null,
        acceptInsecureCerts: ?bool = null,
        unhandledPromptBehavior: ?std.json.Value = null,
    });
    if (p.proxy != null or p.acceptInsecureCerts != null or p.unhandledPromptBehavior != null) {
        log.warn(.not_implemented, "bidi.createUserContext", .{ .proxy = p.proxy != null, .acceptInsecureCerts = p.acceptInsecureCerts, .unhandledPromptBehavior = p.unhandledPromptBehavior != null });
        return cmd.sendError("unsupported operation", "user context options are not supported");
    }

    const bidi = cmd.bidi;
    if (bidi.user_context.isDefault() == false) {
        log.warn(.not_implemented, "bidi.createUserContext", .{ .feature = "multiple user contexts" });
        return cmd.sendError("unsupported operation", "only one user context can exist besides the default");
    }

    if (bidi.browsing_context != null) {
        // Can't create a new UserContext (Session) if we have a browing context (Page) already opened
        return cmd.sendError("unsupported operation", "close the browsing context first");
    }

    var id: [36]u8 = undefined;
    uuidv4(&id);
    try bidi.replaceSession(&id);

    return cmd.sendResult(.{ .userContext = &id });
}

fn removeUserContext(cmd: *const BiDi.Command) !void {
    const p = try cmd.params(struct {
        userContext: []const u8,
    });

    if (std.mem.eql(u8, p.userContext, "default")) {
        return cmd.sendError("invalid argument", "the default user context cannot be removed");
    }

    const bidi = cmd.bidi;
    if (std.mem.eql(u8, p.userContext, bidi.user_context.id()) == false) {
        return cmd.sendError("no such user context", "unknown user context");
    }

    if (bidi.browsing_context) |*ctx| {
        try browsing_context.destroy(cmd, ctx);
    }
    try bidi.replaceSession("default");

    return cmd.sendResult(struct {}{});
}

const testing = @import("testing.zig");
test "bidi.browser: user contexts" {
    testing.silenceLog(&.{.not_implemented});
    var ctx = try testing.context();
    defer ctx.deinit();

    try ctx.startSession();
    try ctx.processMessage(.{
        .id = 1,
        .method = "session.subscribe",
        .params = .{ .events = .{"browsingContext"} },
    });

    try ctx.processMessage(.{ .id = 2, .method = "browser.getUserContexts" });
    try ctx.expectSentResult(.{ .userContexts = .{.{ .userContext = "default" }} }, .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "browser.createUserContext", .params = struct {}{} });
    const user_context = try testing.arena.dupe(u8, ctx.bidi().user_context.id());
    try ctx.expectSentResult(.{ .userContext = user_context }, .{ .id = 3 });

    try ctx.processMessage(.{ .id = 4, .method = "browser.getUserContexts" });
    try ctx.expectSentResult(.{
        .userContexts = .{ .{ .userContext = "default" }, .{ .userContext = user_context } },
    }, .{ .id = 4 });

    // A user context is the browser's one Session, so a second one can't
    // exist alongside it, and neither can a page in the default.
    try ctx.processMessage(.{ .id = 5, .method = "browser.createUserContext", .params = struct {}{} });
    try ctx.expectSentError("unsupported operation", null, .{ .id = 5 });

    try ctx.processMessage(.{
        .id = 6,
        .method = "browsingContext.create",
        .params = .{ .type = "tab", .userContext = "default" },
    });
    try ctx.expectSentError("no such user context", null, .{ .id = 6 });

    try ctx.processMessage(.{
        .id = 7,
        .method = "browsingContext.create",
        .params = .{ .type = "tab", .userContext = user_context },
    });
    const context_id = try testing.arena.dupe(u8, &(ctx.bidi().browsing_context orelse return error.NoBrowsingContext).id);
    try ctx.expectSentResult(.{ .context = context_id }, .{ .id = 7 });
    try ctx.expectSentEvent("browsingContext.contextCreated", .{ .context = context_id, .userContext = user_context });

    try ctx.processMessage(.{
        .id = 8,
        .method = "script.evaluate",
        .params = .{ .expression = "1 + 1", .target = .{ .context = context_id } },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "number", .value = 2 } }, .{ .id = 8 });

    try ctx.processMessage(.{
        .id = 9,
        .method = "browser.removeUserContext",
        .params = .{ .userContext = "default" },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 9 });

    // Removal takes the browsing context with it and restores the default.
    try ctx.processMessage(.{
        .id = 10,
        .method = "browser.removeUserContext",
        .params = .{ .userContext = user_context },
    });
    try ctx.expectSentResult(null, .{ .id = 10 });
    try ctx.expectSentEvent("browsingContext.contextDestroyed", .{ .context = context_id, .userContext = user_context });
    try testing.expectEqual(null, ctx.bidi().browsing_context);
    try testing.expectEqual(true, ctx.bidi().user_context.isDefault());

    try ctx.processMessage(.{
        .id = 11,
        .method = "browser.removeUserContext",
        .params = .{ .userContext = user_context },
    });
    try ctx.expectSentError("no such user context", null, .{ .id = 11 });

    try ctx.processMessage(.{ .id = 12, .method = "browsingContext.create", .params = .{ .type = "tab" } });
    try ctx.expectSentEvent("browsingContext.contextCreated", .{ .userContext = "default" });
    try ctx.processMessage(.{
        .id = 13,
        .method = "script.evaluate",
        .params = .{ .expression = "2 + 2", .target = .{ .context = &(ctx.bidi().browsing_context orelse return error.NoBrowsingContext).id } },
    });
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "number", .value = 4 } }, .{ .id = 13 });

    // With a page open in the default, its Session can't be swapped out.
    try ctx.processMessage(.{ .id = 14, .method = "browser.createUserContext", .params = struct {}{} });
    try ctx.expectSentError("unsupported operation", null, .{ .id = 14 });
}
