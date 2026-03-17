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
        text: []const u8 = "",
        code: ?[]const u8 = null,
        modifiers: u4 = 0,
        autoRepeat: bool = false,
        // Many optional parameters are not implemented yet, see documentation url.

        const Type = enum {
            keyDown,
            keyUp,
            rawKeyDown,
            char,
        };
    })) orelse return error.InvalidParams;

    try cmd.sendResult(null, .{});

    const bc = cmd.browser_context orelse return;
    const current_page = bc.session.currentPage() orelse return;

    const mods = Page.KeyboardModifiers{
        .alt = params.modifiers & 1 == 1,
        .ctrl = params.modifiers & 2 == 2,
        .meta = params.modifiers & 4 == 4,
        .shift = params.modifiers & 8 == 8,
    };

    switch (params.type) {
        .keyDown, .rawKeyDown => {
            if (params.key.len == 0 and params.text.len == 0) return;
            const key = if (params.key.len > 0) params.key else params.text;
            _ = try current_page.triggerKeyboardKeyDownWithRepeat(key, mods, params.autoRepeat);
        },
        .keyUp => {
            if (params.key.len == 0 and params.text.len == 0) return;
            const key = if (params.key.len > 0) params.key else params.text;
            _ = try current_page.triggerKeyboardKeyUp(key, mods);
        },
        .char => {
            if (params.text.len > 0) {
                try current_page.insertText(params.text);
            } else if (params.key.len > 0) {
                try current_page.insertText(params.key);
            }
        },
    }
    // result already sent
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-dispatchMouseEvent
fn dispatchMouseEvent(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        x: f64,
        y: f64,
        type: Type,
        button: ?[]const u8 = null,
        buttons: ?u16 = null,
        deltaX: ?f64 = null,
        deltaY: ?f64 = null,
        modifiers: u4 = 0,
        // Many optional parameters are not implemented yet, see documentation url.

        const Type = enum {
            mousePressed,
            mouseReleased,
            mouseMoved,
            mouseWheel,
        };
    })) orelse return error.InvalidParams;

    try cmd.sendResult(null, .{});

    const bc = cmd.browser_context orelse return;
    const current_page = bc.session.currentPage() orelse return;

    const btn = parseMouseButton(params.button);
    const mods = Page.MouseModifiers{
        .alt = params.modifiers & 1 == 1,
        .ctrl = params.modifiers & 2 == 2,
        .meta = params.modifiers & 4 == 4,
        .shift = params.modifiers & 8 == 8,
        .buttons = params.buttons orelse 0,
    };

    switch (params.type) {
        .mouseMoved => try current_page.triggerMouseMove(params.x, params.y, mods),
        .mousePressed => try current_page.triggerMouseDown(params.x, params.y, btn, mods),
        .mouseReleased => {
            try current_page.triggerMouseUp(params.x, params.y, btn, mods);
            if (btn == .main) {
                try current_page.triggerMouseClickWithModifiers(params.x, params.y, .main, mods);
            }
        },
        .mouseWheel => _ = try current_page.triggerMouseWheel(
            params.x,
            params.y,
            params.deltaX orelse 0,
            params.deltaY orelse 0,
            mods,
        ),
    }
    // result already sent
}

fn parseMouseButton(button: ?[]const u8) Page.MouseButton {
    const raw = button orelse return .main;
    if (std.mem.eql(u8, raw, "left")) return .main;
    if (std.mem.eql(u8, raw, "right")) return .secondary;
    if (std.mem.eql(u8, raw, "middle")) return .auxiliary;
    if (std.mem.eql(u8, raw, "back")) return .fourth;
    if (std.mem.eql(u8, raw, "forward")) return .fifth;
    return .main;
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

const testing = @import("../testing.zig");
const Page = @import("../../browser/Page.zig");

test "cdp.input: parseMouseButton variants" {
    try testing.expectEqual(Page.MouseButton.main, parseMouseButton(null));
    try testing.expectEqual(Page.MouseButton.main, parseMouseButton("left"));
    try testing.expectEqual(Page.MouseButton.secondary, parseMouseButton("right"));
    try testing.expectEqual(Page.MouseButton.auxiliary, parseMouseButton("middle"));
    try testing.expectEqual(Page.MouseButton.fourth, parseMouseButton("back"));
    try testing.expectEqual(Page.MouseButton.fifth, parseMouseButton("forward"));
    try testing.expectEqual(Page.MouseButton.main, parseMouseButton("unknown"));
}
