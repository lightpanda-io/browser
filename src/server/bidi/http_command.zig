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

const Method = @import("../http.zig").Connection.Method;

const BiDi = @import("BiDi.zig");
const browsing_context = @import("browsing_context.zig");

const Allocator = std.mem.Allocator;

pub const Command = union(enum) {
    navigate_to: NavigateTo,
};

pub const NavigateTo = struct {
    url: [:0]const u8,
};

const Route = struct {
    method: Method,
    // what follows /session/{id}
    path: []const u8,
    command: std.meta.Tag(Command),
};

const routes = [_]Route{
    .{ .method = .POST, .path = "/url", .command = .navigate_to },
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
    }
}

// POST /session/{id}/url. Answers once the page has loaded (the "normal"
// page load strategy).
fn navigateTo(cmd: *BiDi.Command, p: NavigateTo) !void {
    const ctx = currentContext(cmd.bidi) catch |err| switch (err) {
        error.CreatePage => return cmd.sendError("unknown error", "failed to create page"),
        else => return err,
    };
    return browsing_context.navigate(cmd, ctx, .{ .url = p.url, .wait = .complete });
}

// An HTTP session always has a top-level browsing context; it's opened on
// first use.
fn currentContext(bidi: *BiDi) !*browsing_context.Context {
    if (bidi.browsing_context) |*ctx| {
        return ctx;
    }
    return browsing_context.openContext(bidi);
}

const testing = @import("testing.zig");
test "bidi.http_command: parse" {
    const arena = testing.arena;

    {
        const command = try parse(arena, .POST, "/url", "{\"url\":\"about:blank\",\"extra\":1}");
        try testing.expectEqual("about:blank", command.navigate_to.url);
    }

    try testing.expectError(error.UnknownMethod, parse(arena, .GET, "/url", ""));
    try testing.expectError(error.UnknownCommand, parse(arena, .POST, "/nope", "{}"));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/url", "not json"));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/url", "{}"));
}
