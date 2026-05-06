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

const id = @import("../id.zig");
const CDP = @import("../CDP.zig");
const Notification = @import("../../Notification.zig");

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        clearMessages,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        .clearMessages => return cmd.sendResult(null, .{}),
    }
}

fn enable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.consoleEnable();
    return cmd.sendResult(null, .{});
}

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.consoleDisable();
    return cmd.sendResult(null, .{});
}

const ConsoleMessage = struct {
    source: []const u8,
    level: []const u8,
    text: []const u8,
    url: ?[]const u8 = null,
    line: ?u32 = null,
    columns: ?u32 = null,
};

pub fn consoleMessage(bc: *CDP.BrowserContext, event: *const Notification.ConsoleMessage) !void {
    const session_id = bc.session_id orelse return;

    // format values
    var aw: std.io.Writer.Allocating = .init(bc.notification_arena);
    const w = &aw.writer;
    for (event.values, 0..) |v, i| {
        if (i != 0) try w.writeByte(' ');

        const js_str = try v.toString();
        try js_str.format(w);
    }

    return bc.cdp.sendEvent("Console.messageAdded", ConsoleMessage{
        .source = @tagName(event.source),
        .level = @tagName(event.level),
        .text = aw.written(),
    }, .{ .session_id = session_id });
}
