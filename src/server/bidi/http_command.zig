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

// The HTTP session's commands, a second entry point onto the BiDi driver.
// The loop parses a request into a Command and parks its connection; the
// worker runs it as a BiDi.Command, which answers the parked request.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../../browser/Frame.zig");

const Method = @import("../http.zig").Connection.Method;

const BiDi = @import("BiDi.zig");
const input = @import("input.zig");
const browsing_context = @import("browsing_context.zig");

const Allocator = std.mem.Allocator;

// The key of a WebDriver element reference: {"element-6066-…": "<sharedId>"}
pub const element_key = "element-6066-11e4-a52e-4f735466cecf";

pub const Command = union(enum) {
    navigate_to: NavigateTo,
    get_current_url,
    refresh,
    get_title,
    get_window_handle,
    get_window_handles,
    get_page_source,
    take_screenshot,
    perform_actions: PerformActions,
    release_actions,
};

pub const NavigateTo = struct {
    url: [:0]const u8,
};

pub const PerformActions = struct {
    actions: []const std.json.Value,
};

const Route = struct {
    method: Method,
    // what follows /session/{id}
    path: []const u8,
    command: std.meta.Tag(Command),
};

const routes = [_]Route{
    .{ .method = .POST, .path = "/url", .command = .navigate_to },
    .{ .method = .GET, .path = "/url", .command = .get_current_url },
    .{ .method = .POST, .path = "/refresh", .command = .refresh },
    .{ .method = .GET, .path = "/title", .command = .get_title },
    .{ .method = .GET, .path = "/window", .command = .get_window_handle },
    .{ .method = .GET, .path = "/window/handles", .command = .get_window_handles },
    .{ .method = .GET, .path = "/source", .command = .get_page_source },
    .{ .method = .GET, .path = "/screenshot", .command = .take_screenshot },
    .{ .method = .POST, .path = "/actions", .command = .perform_actions },
    .{ .method = .DELETE, .path = "/actions", .command = .release_actions },
};

pub const ParseError = error{
    UnknownCommand,
    UnknownMethod,
    InvalidArgument,
    OutOfMemory,
};

// Loop. Everything the command references is allocated in `arena`.
pub fn parse(arena: Allocator, method: Method, path: []const u8, body: []const u8) ParseError!Command {
    var path_matched = false;
    inline for (routes) |route| {
        if (std.mem.eql(u8, route.path, path)) {
            if (route.method == method) {
                const name = @tagName(route.command);
                return @unionInit(Command, name, try parseBody(@FieldType(Command, name), arena, body));
            }
            path_matched = true;
        }
    }
    if (path_matched) {
        return error.UnknownMethod;
    }
    return error.UnknownCommand;
}

fn parseBody(comptime T: type, arena: Allocator, body: []const u8) ParseError!T {
    if (T == void) {
        // POSTs without parameters still send a body ("{}"); nothing to read
        return {};
    }
    return std.json.parseFromSliceLeaky(T, arena, body, .{
        .ignore_unknown_fields = true,
        // body is the connection's read buffer, reused once the request is parked
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArgument,
    };
}

// Worker.
pub fn process(cmd: *BiDi.Command) !void {
    switch (cmd.input.http) {
        .navigate_to => |p| return navigateTo(cmd, p),
        .get_current_url => return getCurrentUrl(cmd),
        .refresh => return refresh(cmd),
        .get_title => return getTitle(cmd),
        .get_window_handle => return getWindowHandle(cmd),
        .get_window_handles => return getWindowHandles(cmd),
        .get_page_source => return getPageSource(cmd),
        .take_screenshot => return takeScreenshot(cmd),
        .perform_actions => |p| return performActions(cmd, p),
        .release_actions => return releaseActions(cmd),
    }
}

// POST /session/{id}/url.
fn navigateTo(cmd: *BiDi.Command, p: NavigateTo) !void {
    const ctx = (try currentContext(cmd)) orelse return;
    return browsing_context.navigate(cmd, ctx, .{ .url = p.url, .wait = .complete });
}

// GET /session/{id}/url
fn getCurrentUrl(cmd: *BiDi.Command) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    return cmd.sendResult(frame.url);
}

// POST /session/{id}/refresh.
fn refresh(cmd: *BiDi.Command) !void {
    const ctx = (try currentContext(cmd)) orelse return;
    return browsing_context.reload(cmd, ctx, .complete);
}

// GET /session/{id}/title
fn getTitle(cmd: *BiDi.Command) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    return cmd.sendResult((try frame.getTitle()) orelse "");
}

// GET /session/{id}/window. The handle is the BiDi context id
fn getWindowHandle(cmd: *BiDi.Command) !void {
    const ctx = (try currentContext(cmd)) orelse return;
    return cmd.sendResult(&ctx.id);
}

// GET /session/{id}/window/handles
fn getWindowHandles(cmd: *BiDi.Command) !void {
    const ctx = (try currentContext(cmd)) orelse return;
    return cmd.sendResult(&[_][]const u8{&ctx.id});
}

// GET /session/{id}/source
fn getPageSource(cmd: *BiDi.Command) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    var aw: std.Io.Writer.Allocating = .init(cmd.arena);
    try lp.dump.root(frame.window._document, .{ .shadow = .skip }, &aw.writer, frame);
    return cmd.sendResult(aw.written());
}

// GET /session/{id}/screenshot.
fn takeScreenshot(cmd: *BiDi.Command) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const opts: lp.screenshot.Opts = .fromViewport(cmd.bidi.browser.getViewport(), false);
    const shot = try lp.screenshot.preparePng(cmd.arena, .{ .root = frame.window._document.asNode() }, opts, frame);
    return cmd.sendResult(shot);
}

// POST /session/{id}/actions.
fn performActions(cmd: *BiDi.Command, p: PerformActions) !void {
    _ = (try currentContext(cmd)) orelse return;
    return input.perform(cmd, p.actions);
}

// DELETE /session/{id}/actions
fn releaseActions(cmd: *BiDi.Command) !void {
    _ = (try currentContext(cmd)) orelse return;
    return input.release(cmd);
}

fn currentContext(cmd: *BiDi.Command) !?*browsing_context.Context {
    if (cmd.bidi.browsing_context) |*ctx| {
        return ctx;
    }
    return browsing_context.openContext(cmd.bidi) catch |err| switch (err) {
        error.CreatePage => {
            try cmd.sendError("unknown error", "failed to create page");
            return null;
        },
        else => return err,
    };
}

fn currentFrame(cmd: *BiDi.Command) !?*Frame {
    _ = (try currentContext(cmd)) orelse return null;
    return cmd.bidi.user_context.session.currentFrame() orelse {
        try cmd.sendError("no such window", "no frame");
        return null;
    };
}

const testing = @import("testing.zig");
test "bidi.http_command: parse" {
    const arena = testing.arena;

    {
        const command = try parse(arena, .POST, "/url", "{\"url\":\"about:blank\",\"extra\":1}");
        try testing.expectEqual("about:blank", command.navigate_to.url);
    }

    {
        // parameterless commands ignore the body
        const command = try parse(arena, .POST, "/refresh", "{}");
        try testing.expect(command == .refresh);
    }

    {
        const command = try parse(arena, .POST, "/actions", "{\"actions\":[{\"type\":\"none\",\"id\":\"n\",\"actions\":[]}]}");
        try testing.expectEqual(1, command.perform_actions.actions.len);
    }

    try testing.expect(try parse(arena, .GET, "/url", "") == .get_current_url);
    try testing.expect(try parse(arena, .GET, "/window/handles", "") == .get_window_handles);
    try testing.expect(try parse(arena, .DELETE, "/actions", "") == .release_actions);

    try testing.expectError(error.UnknownMethod, parse(arena, .PUT, "/url", ""));
    try testing.expectError(error.UnknownMethod, parse(arena, .POST, "/title", "{}"));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/actions", "{}"));
    try testing.expectError(error.UnknownCommand, parse(arena, .POST, "/nope", "{}"));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/url", "not json"));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/url", "{}"));
}
