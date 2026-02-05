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
        code: ?[]const u8 = null,
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

    const KeyboardEvent = @import("../../browser/webapi/event/KeyboardEvent.zig");
    const keyboard_event = try KeyboardEvent.initTrusted("keydown", .{
        .key = params.key,
        .code = params.code,
        .altKey = params.modifiers & 1 == 1,
        .ctrlKey = params.modifiers & 2 == 2,
        .metaKey = params.modifiers & 4 == 4,
        .shiftKey = params.modifiers & 8 == 8,
    }, page);
    try page.triggerKeyboard(keyboard_event);
    // result already sent
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-dispatchMouseEvent
fn dispatchMouseEvent(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        x: f64,
        y: f64,
        type: Type,
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
        .mouseMoved, .mouseWheel, .mouseReleased => return,
        else => {},
    }

    const bc = cmd.browser_context orelse return;
    const page = bc.session.currentPage() orelse return;
    try page.triggerMouseClick(params.x, params.y);
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

    var url_buf: std.ArrayList(u8) = .{};
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
