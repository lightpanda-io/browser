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
const CDP = @import("../CDP.zig");

const dom_button = @import("../../browser/Frame.zig").mouse_button;

pub fn processMessage(cmd: *CDP.Command) !void {
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
fn dispatchKeyEvent(cmd: *CDP.Command) !void {
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

    // rawKeyDown is a Chrome-internal event type not used for JS dispatch
    if (params.type == .rawKeyDown) return;

    const bc = cmd.browser_context orelse return;
    const frame = bc.session.currentFrame() orelse return;

    const KeyboardEvent = @import("../../browser/webapi/event/KeyboardEvent.zig");
    const keyboard_event = try KeyboardEvent.initTrusted(switch (params.type) {
        .keyDown => comptime .wrap("keydown"),
        .keyUp => comptime .wrap("keyup"),
        .char => comptime .wrap("keypress"),
        .rawKeyDown => unreachable,
    }, .{
        .key = params.key,
        .code = params.code,
        .altKey = params.modifiers & 1 == 1,
        .ctrlKey = params.modifiers & 2 == 2,
        .metaKey = params.modifiers & 4 == 4,
        .shiftKey = params.modifiers & 8 == 8,
    }, frame);
    try frame.triggerKeyboard(keyboard_event);
    // result already sent
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-dispatchMouseEvent
fn dispatchMouseEvent(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        x: f64,
        y: f64,
        type: Type,
        button: Button = .none,
        clickCount: i32 = 0,
        deltaX: f64 = 0,
        deltaY: f64 = 0,
        // Many optional parameters are not implemented yet, see documentation url.

        const Type = enum {
            mousePressed,
            mouseReleased,
            mouseMoved,
            mouseWheel,
        };

        // https://chromedevtools.github.io/devtools-protocol/tot/Input/#type-MouseButton
        const Button = enum {
            none,
            left,
            middle,
            right,
            back,
            forward,
        };
    })) orelse return error.InvalidParams;

    try cmd.sendResult(null, .{});

    const bc = cmd.browser_context orelse return;
    const frame = bc.session.currentFrame() orelse return;

    // Map the CDP button name to the DOM MouseEvent.button value.
    // https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/button
    const button: i32 = switch (params.button) {
        .none, .left => dom_button.main,
        .middle => dom_button.auxiliary,
        .right => dom_button.secondary,
        .back => dom_button.fourth,
        .forward => dom_button.fifth,
    };

    switch (params.type) {
        .mousePressed => try frame.triggerMousePress(params.x, params.y, button),
        .mouseReleased => try frame.triggerMouseRelease(params.x, params.y, button, params.clickCount),
        .mouseMoved => try frame.triggerMouseMove(params.x, params.y),
        .mouseWheel => try frame.triggerMouseWheel(params.x, params.y, params.deltaX, params.deltaY),
    }
    // result already sent
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-insertText
fn insertText(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        text: []const u8, // The text to insert
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return;
    const frame = bc.session.currentFrame() orelse return;

    try frame.insertText(params.text);

    try cmd.sendResult(null, .{});
}

const lp = @import("lightpanda");
const testing = @import("../testing.zig");

test "cdp.input: dispatchMouseEvent mouseMoved fires hover events" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const frame = try bc.session.createPage();
    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    var runner = try bc.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // Register listeners for the full enter sequence on #hoverTarget, then read
    // its (faux-layout) position so we can target it precisely.
    _ = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('mousemove', () => { window.moved = true; });
        \\t.addEventListener('mouseenter', () => { window.entered = true; });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseMoved", .x = rect_x, .y = rect_y },
    });

    const result = try ls.local.compileAndRun("window.hovered === true && window.entered === true && window.moved === true", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchMouseEvent mouseReleased fires mouseup" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const frame = try bc.session.createPage();
    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    var runner = try bc.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\document.getElementById('hoverTarget')
        \\  .addEventListener('mouseup', () => { window.released = true; });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y },
    });

    const result = try ls.local.compileAndRun("window.released === true", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchMouseEvent mouseWheel fires wheel event" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const frame = try bc.session.createPage();
    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    var runner = try bc.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\document.getElementById('scrollbox')
        \\  .addEventListener('wheel', (e) => { window.wheelDeltaY = e.deltaY; });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('scrollbox').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('scrollbox').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = rect_x, .y = rect_y, .deltaY = 40 },
    });

    const result = try ls.local.compileAndRun("window.wheelDeltaY === 40", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchMouseEvent right button fires contextmenu, double-click fires dblclick" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const frame = try bc.session.createPage();
    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    var runner = try bc.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('mousedown', (e) => { window.downButton = e.button; });
        \\t.addEventListener('contextmenu', (e) => { window.ctxButton = e.button; });
        \\t.addEventListener('dblclick', () => { window.dbl = true; });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    // Right button: press carries button=2, release fires contextmenu (not click).
    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "right" },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "right" },
    });

    // Left button with clickCount 2 fires dblclick.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 2 },
    });

    const result = try ls.local.compileAndRun("window.downButton === 2 && window.ctxButton === 2 && window.dbl === true", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchKeyEvent Tab runs sequential focus navigation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const frame = try bc.session.createPage();
    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    var runner = try bc.session.runner(.{});
    try runner.wait(.{ .ms = 2000 });

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // Three controls whose tabindex order (1, 2, 3) differs from document
    // order (2, 1, 3): focus order must follow tabindex, not the tree.
    _ = try ls.local.compileAndRun(
        \\document.body.innerHTML =
        \\  '<input id="i2" tabindex="2">' +
        \\  '<button id="b1" tabindex="1">b</button>' +
        \\  '<select id="s3" tabindex="3"></select>';
    , null);

    // Nothing focused yet → activeElement is <body>.
    try testing.expect((try ls.local.compileAndRun("document.activeElement === document.body", null)).isTrue());

    // First Tab → lowest positive tabindex (#b1), regardless of document order.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "Tab", .code = "Tab" },
    });
    try testing.expect((try ls.local.compileAndRun("document.activeElement.id === 'b1'", null)).isTrue());

    // Second Tab → next in tabindex order (#i2).
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "Tab", .code = "Tab" },
    });
    try testing.expect((try ls.local.compileAndRun("document.activeElement.id === 'i2'", null)).isTrue());

    // Shift+Tab (modifiers bit 8) walks backward → back to #b1.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "Tab", .code = "Tab", .modifiers = 8 },
    });
    try testing.expect((try ls.local.compileAndRun("document.activeElement.id === 'b1'", null)).isTrue());
}
