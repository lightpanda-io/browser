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
const Page = @import("../../browser/page.zig").Page;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        dispatchKeyEvent,
        dispatchMouseEvent,
        insertText,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .dispatchKeyEvent => return dispatchKeyEvent(cmd),
        .dispatchMouseEvent => return dispatchMouseEvent(cmd),
        .insertText => return insertText(cmd),
    }
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-dispatchKeyEvent
fn dispatchKeyEvent(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        type: Type,
        key: []const u8 = "",
        code: []const u8 = "",
        modifiers: u4 = 0,
        // Many optional parameters are not implemented yet, see documentation url.

        const Type = enum {
            keyDown,
            keyUp,
            rawKeyDown,
            char,
        };
    })) orelse return error.InvalidParams;

    try cmd.sendResult(null, .{});

    // quickly ignore types we know we don't handle
    switch (params.type) {
        .keyUp, .rawKeyDown, .char => return,
        .keyDown => {},
    }

    const bc = cmd.browser_context orelse return;
    const page = bc.session.currentPage() orelse return;

    const keyboard_event = Page.KeyboardEvent{
        .key = params.key,
        .code = params.code,
        .type = switch (params.type) {
            .keyDown => .keydown,
            else => unreachable,
        },
        .alt = params.modifiers & 1 == 1,
        .ctrl = params.modifiers & 2 == 2,
        .meta = params.modifiers & 4 == 4,
        .shift = params.modifiers & 8 == 8,
    };
    try page.keyboardEvent(keyboard_event);
    // result already sent
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-dispatchMouseEvent
fn dispatchMouseEvent(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        type: Type, // Type of the mouse event.
        x: f32, // X coordinate of the event relative to the main frame's viewport.
        y: f32, // Y coordinate of the event relative to the main frame's viewport. 0 refers to the top of the viewport and Y increases as it proceeds towards the bottom of the viewport.
        // Many optional parameters are not implemented yet, see documentation url.

        const Type = enum {
            mousePressed,
            mouseReleased,
            mouseMoved,
            mouseWheel,
        };
    })) orelse return error.InvalidParams;

    try cmd.sendResult(null, .{});

    // quickly ignore types we know we don't handle
    switch (params.type) {
        .mouseMoved, .mouseWheel => return,
        else => {},
    }

    const bc = cmd.browser_context orelse return;
    const page = bc.session.currentPage() orelse return;

    const mouse_event = Page.MouseEvent{
        .x = @intFromFloat(@floor(params.x)), // Decimal pixel values are not understood by netsurf or our renderer
        .y = @intFromFloat(@floor(params.y)), // So we convert them once at intake here. Using floor such that -0.5 becomes -1 and 0.5 becomes 0.
        .type = switch (params.type) {
            .mousePressed => .pressed,
            .mouseReleased => .released,
            else => unreachable,
        },
    };
    try page.mouseEvent(mouse_event);
    // result already sent
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-insertText
fn insertText(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        text: []const u8, // The text to insert
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return;
    const page = bc.session.currentPage() orelse return;

    try page.insertText(params.text);

    try cmd.sendResult(null, .{});
}

fn clickNavigate(cmd: anytype, uri: std.Uri) !void {
    const bc = cmd.browser_context.?;

    var url_buf: std.ArrayListUnmanaged(u8) = .{};
    try uri.writeToStream(.{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .port = true,
        .path = true,
        .query = true,
    }, url_buf.writer(cmd.arena));
    const url = url_buf.items;

    try cmd.sendEvent("Page.frameRequestedNavigation", .{
        .url = url,
        .frameId = bc.target_id.?,
        .reason = "anchorClick",
        .disposition = "currentTab",
    }, .{ .session_id = bc.session_id.? });

    try bc.session.removePage();
    _ = try bc.session.createPage(null);

    try @import("page.zig").navigateToUrl(cmd, url, false);
}
