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
const Frame = @import("../../../browser/Frame.zig");
const Touch = @import("../../../browser/webapi/event/Touch.zig");

const dom_button = Frame.user_input.mouse_button;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        dispatchKeyEvent,
        dispatchMouseEvent,
        dispatchTouchEvent,
        insertText,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .dispatchKeyEvent => return dispatchKeyEvent(cmd),
        .dispatchMouseEvent => return dispatchMouseEvent(cmd),
        .dispatchTouchEvent => return dispatchTouchEvent(cmd),
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
        text: []const u8 = "",
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
    // Keys go to the focused frame, which is an iframe's when one has focus.
    const frame = Frame.user_input.focusedFrame(bc.mainFrame() orelse return);

    // Chrome types text only for an event carrying it: a keyDown with `text`
    // (Puppeteer, Playwright) or a `char` (chromedp, after a text-less keyDown).
    // Puppeteer and Playwright send rawKeyDown, which never types text, for keys
    // like Backspace, the arrows and Escape.
    const text: ?[]const u8 = if (params.text.len == 0 or params.type == .rawKeyDown) null else params.text;
    const KeyboardEvent = @import("../../../browser/webapi/event/KeyboardEvent.zig");
    const modifiers = cdpModifiers(params.modifiers);
    const opts: KeyboardEvent.Options = .{
        .key = if (params.key.len > 0) params.key else params.text,
        .code = params.code,
        .altKey = modifiers.alt,
        .ctrlKey = modifiers.ctrl,
        .metaKey = modifiers.meta,
        .shiftKey = modifiers.shift,
    };

    switch (params.type) {
        .keyDown, .rawKeyDown => {
            const event = try KeyboardEvent.initTrusted(comptime .wrap("keydown"), opts, frame);
            const prevented = try Frame.user_input.triggerKeyDown(frame, event, text);
            bc.suppress_next_char = prevented and text == null;
        },
        .keyUp => {
            const event = try KeyboardEvent.initTrusted(comptime .wrap("keyup"), opts, frame);
            try Frame.user_input.triggerKeyUp(frame, event);
        },
        .char => {
            const t = text orelse return;
            if (bc.suppress_next_char) {
                bc.suppress_next_char = false;
                return;
            }
            const target = Frame.user_input.focusedElement(frame) orelse return;
            const event = try KeyboardEvent.initTrusted(comptime .wrap("keypress"), opts, frame);
            try Frame.user_input.typeChar(frame, target, event, t);
        },
    }
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
    const frame = bc.mainFrame() orelse return;

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
        .mousePressed => try Frame.user_input.triggerMousePress(frame, params.x, params.y, button, params.clickCount),
        .mouseReleased => try Frame.user_input.triggerMouseRelease(frame, params.x, params.y, button, params.clickCount),
        .mouseMoved => try Frame.user_input.triggerMouseMove(frame, params.x, params.y),
        .mouseWheel => try Frame.user_input.triggerMouseWheel(frame, params.x, params.y, params.deltaX, params.deltaY),
    }
    // result already sent
}

/// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-dispatchTouchEvent
///
/// Single contact only: more than one point is InvalidParams, where Chrome
/// would open more contacts. touchEnd takes zero or one point (Playwright
/// sends none, Puppeteer the released one); touchCancel must be empty, as in
/// Chrome. Touch.identifier is an i32, so a fractional or out-of-range id
/// fails to parse, where Chrome truncates.
fn dispatchTouchEvent(cmd: *CDP.Command) !void {
    const params = (cmd.params(struct {
        type: Type,
        modifiers: u4 = 0,
        touchPoints: []const Touch.Point,

        const Type = enum {
            touchStart,
            touchMove,
            touchEnd,
            touchCancel,
        };
    }) catch return error.InvalidParams) orelse return error.InvalidParams;

    switch (params.type) {
        .touchStart, .touchMove => if (params.touchPoints.len != 1) return error.InvalidParams,
        .touchEnd => if (params.touchPoints.len > 1) return error.InvalidParams,
        .touchCancel => if (params.touchPoints.len != 0) return error.InvalidParams,
    }

    const bc = cmd.browser_context orelse {
        try cmd.sendResult(null, .{});
        return;
    };
    const frame = bc.mainFrame() orelse {
        try cmd.sendResult(null, .{});
        return;
    };

    switch (params.type) {
        .touchStart => {
            if (frame.page.input_touch_contact != null) return error.InvalidParams;
        },
        .touchMove, .touchEnd, .touchCancel => {
            const contact = frame.page.input_touch_contact orelse return error.InvalidParams;
            if (params.touchPoints.len == 1 and params.touchPoints[0].id != contact.point.id) {
                return error.InvalidParams;
            }
        },
    }

    try cmd.sendResult(null, .{});

    const point: ?Touch.Point = if (params.touchPoints.len == 1) params.touchPoints[0] else null;
    const modifiers = cdpModifiers(params.modifiers);

    switch (params.type) {
        .touchStart => try Frame.user_input.touchStart(frame, null, point.?, modifiers),
        .touchMove => try Frame.user_input.touchMove(frame, null, point.?, modifiers),
        .touchEnd => try Frame.user_input.touchEnd(frame, point, modifiers, null),
        .touchCancel => try Frame.user_input.touchCancel(frame, modifiers),
    }
}

fn cdpModifiers(bits: u4) Frame.user_input.Modifiers {
    return .{
        .alt = bits & 1 != 0,
        .ctrl = bits & 2 != 0,
        .meta = bits & 4 != 0,
        .shift = bits & 8 != 0,
    };
}

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-insertText
fn insertText(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        text: []const u8, // The text to insert
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return;
    const frame = Frame.user_input.focusedFrame(bc.mainFrame() orelse return);

    try Frame.user_input.insertText(frame, params.text);

    try cmd.sendResult(null, .{});
}

const lp = @import("lightpanda");
const testing = @import("../testing.zig");

test "cdp.input: insertText is a user edit for tooLong" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\const inp = document.getElementById('inp');
        \\inp.maxLength = 3;
        \\inp.value = 'abcdef';
        \\inp.focus();
    , null);
    try testing.expect((try ls.local.compileAndRun("inp.validity.tooLong === false", null)).isTrue());

    try ctx.processMessage(.{ .id = 1, .method = "Input.insertText", .params = .{ .text = "g" } });
    try testing.expect((try ls.local.compileAndRun("inp.value === 'abcdefg' && inp.validity.tooLong === true", null)).isTrue());

    _ = try ls.local.compileAndRun("inp.value = 'abcdefgh'", null);
    try testing.expect((try ls.local.compileAndRun("inp.validity.tooLong === false", null)).isTrue());
}

test "cdp.input: rawKeyDown dispatches keydown for keys without text" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\const inp = document.getElementById('inp');
        \\inp.value = 'abc';
        \\inp.focus();
        \\inp.setSelectionRange(3, 3);
        \\window.keys = [];
        \\inp.addEventListener('keydown', (e) => keys.push(e.key));
    , null);

    // What Puppeteer and Playwright send for keyboard.press('Backspace').
    try ctx.processMessage(.{ .id = 1, .method = "Input.dispatchKeyEvent", .params = .{ .type = "rawKeyDown", .key = "Backspace", .code = "Backspace" } });
    try ctx.processMessage(.{ .id = 2, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyUp", .key = "Backspace", .code = "Backspace" } });
    try testing.expect((try ls.local.compileAndRun("keys.join() === 'Backspace' && inp.value === 'ab'", null)).isTrue());
}

test "cdp.input: insertText replaces select()ed value of email and number inputs" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // What Playwright's fill() does: select() then Input.insertText.
    _ = try ls.local.compileAndRun(
        \\const inp = document.getElementById('inp');
        \\inp.type = 'email';
        \\inp.value = 'old@example.com';
        \\inp.select();
        \\inp.focus();
    , null);
    try ctx.processMessage(.{ .id = 1, .method = "Input.insertText", .params = .{ .text = "new@example.com" } });
    try testing.expect((try ls.local.compileAndRun("inp.value === 'new@example.com'", null)).isTrue());

    _ = try ls.local.compileAndRun("inp.type = 'number'; inp.value = '12'; inp.select();", null);
    try ctx.processMessage(.{ .id = 2, .method = "Input.insertText", .params = .{ .text = "345" } });
    try testing.expect((try ls.local.compileAndRun("inp.value === '345'", null)).isTrue());

    // The caret lands at the end of the sanitized value, not of the inserted text.
    _ = try ls.local.compileAndRun("inp.type = 'text'; inp.value = 'ab'; inp.select();", null);
    try ctx.processMessage(.{ .id = 3, .method = "Input.insertText", .params = .{ .text = "c\nd" } });
    try testing.expect((try ls.local.compileAndRun("inp.value === 'cd' && inp.selectionStart === 2", null)).isTrue());
}

test "cdp.input: keyboard input goes to the focused element inside an iframe" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/input_focused_frame.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun("document.getElementById('f').contentDocument.getElementById('inner').focus()", null);

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.insertText",
        .params = .{ .text = "ab" },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "c", .text = "c" },
    });
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyUp", .key = "c" },
    });

    const inner = try ls.local.compileAndRun("document.getElementById('f').contentDocument.getElementById('inner').value", null);
    try testing.expectEqual("abc", try inner.toStringSlice());
    const outer = try ls.local.compileAndRun("document.getElementById('outer').value", null);
    try testing.expectEqual("", try outer.toStringSlice());
}

test "cdp.input: dispatchMouseEvent mouseMoved fires hover events" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

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
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

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

test "cdp.input: dispatchMouseEvent button activation events match Chrome" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\window.clicks = [];
        \\for (const t of ['mousedown', 'mouseup', 'click', 'auxclick', 'contextmenu']) {
        \\  document.getElementById('hoverTarget')
        \\    .addEventListener(t, (e) => { window.clicks.push(t + ':' + e.button); });
        \\}
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    const presses = [_]struct { button: []const u8, click_count: i32, expected: []const u8 }{
        .{ .button = "middle", .click_count = 1, .expected = "mousedown:1 mouseup:1 auxclick:1" },
        .{ .button = "right", .click_count = 1, .expected = "mousedown:2 contextmenu:2 mouseup:2 auxclick:2" },
        .{ .button = "back", .click_count = 1, .expected = "mousedown:3 mouseup:3 auxclick:3" },
        .{ .button = "forward", .click_count = 1, .expected = "mousedown:4 mouseup:4 auxclick:4" },
        .{ .button = "left", .click_count = 0, .expected = "mousedown:0 mouseup:0" },
        .{ .button = "right", .click_count = 0, .expected = "mousedown:2 contextmenu:2 mouseup:2" },
    };
    var id: u32 = 1;
    for (presses) |press| {
        _ = try ls.local.compileAndRun("window.clicks = []", null);
        try ctx.processMessage(.{
            .id = id,
            .method = "Input.dispatchMouseEvent",
            .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = press.button, .clickCount = press.click_count },
        });
        try ctx.processMessage(.{
            .id = id + 1,
            .method = "Input.dispatchMouseEvent",
            .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = press.button, .clickCount = press.click_count },
        });
        id += 2;

        const got = try (try ls.local.compileAndRun("window.clicks.join(' ')", null)).toStringSlice();
        try testing.expectEqual(press.expected, got);
    }
}

test "cdp.input: dispatchMouseEvent mousePressed honors preventDefault for focus" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // The toolbar idiom: preventDefault() on mousedown keeps focus where it is.
    _ = try ls.local.compileAndRun(
        \\document.getElementById('hoverTarget')
        \\  .addEventListener('mousedown', (e) => { e.preventDefault(); });
        \\document.getElementById('inp').focus();
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });

    const kept = try ls.local.compileAndRun("document.activeElement.id === 'inp'", null);
    try testing.expect(kept.isTrue());

    // Without preventDefault the same press moves focus, so the assertion above
    // is testing the gate and not just an inert default action.
    const focus_x = try (try ls.local.compileAndRun("document.getElementById('focusTarget').getBoundingClientRect().x", null)).toF64();
    const focus_y = try (try ls.local.compileAndRun("document.getElementById('focusTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = focus_x, .y = focus_y, .button = "left", .clickCount = 1 },
    });

    const moved = try ls.local.compileAndRun("document.activeElement.id === 'focusTarget'", null);
    try testing.expect(moved.isTrue());
}

test "cdp.input: dispatchMouseEvent mouseWheel fires wheel event" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

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

test "cdp.input: dispatchMouseEvent mouseWheel cancelability follows listener passivity" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    // Only passive listeners: the event is non-cancelable, preventDefault is
    // inert and the scroll happens. Blink's legacy mousewheel fires only on a
    // target with no wheel listener, and sees the event under that name.
    _ = try ls.local.compileAndRun(
        \\const box = document.getElementById('scrollbox');
        \\box.addEventListener('wheel', (e) => { window.passiveCancelable = e.cancelable; e.preventDefault(); }, { passive: true });
        \\box.addEventListener('mousewheel', () => { window.boxLegacy = true; });
        \\document.body.addEventListener('mousewheel', (e) => { window.legacyType = e.type; window.legacyDeltaY = e.deltaY; });
        \\window.bodyWheel = (e) => { window.bodyType = e.type; };
        \\document.body.addEventListener('wheel', window.bodyWheel, { passive: true });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('scrollbox').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('scrollbox').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = rect_x, .y = rect_y, .deltaY = 40 },
    });
    var result = try ls.local.compileAndRun("window.passiveCancelable === false && window.boxLegacy === undefined && window.bodyType === 'wheel' && window.legacyType === undefined && document.getElementById('scrollbox').scrollTop === 40", null);
    try testing.expect(result.isTrue());

    // Without a wheel listener the body runs its mousewheel listener instead.
    _ = try ls.local.compileAndRun(
        \\document.body.removeEventListener('wheel', window.bodyWheel);
        \\window.bodyType = undefined;
    , null);
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = rect_x, .y = rect_y, .deltaY = 40 },
    });
    result = try ls.local.compileAndRun("window.bodyType === undefined && window.legacyType === 'mousewheel' && window.legacyDeltaY === 40 && document.getElementById('scrollbox').scrollTop === 80", null);
    try testing.expect(result.isTrue());

    // A non-passive listener makes it cancelable, and preventDefault stops the scroll.
    _ = try ls.local.compileAndRun(
        \\document.getElementById('scrollbox').addEventListener('wheel', (e) => { window.activeCancelable = e.cancelable; e.preventDefault(); });
    , null);
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = rect_x, .y = rect_y, .deltaY = 40 },
    });
    result = try ls.local.compileAndRun("window.activeCancelable === true && document.getElementById('scrollbox').scrollTop === 80", null);
    try testing.expect(result.isTrue());

    // A mousewheel listener standing in for wheel is a listener like any
    // other: non-passive, it makes the event cancelable and can cancel the scroll.
    _ = try ls.local.compileAndRun(
        \\document.getElementById('sheetscroll').addEventListener('mousewheel', (e) => { window.sheetCancelable = e.cancelable; e.preventDefault(); });
    , null);
    const sheet_x = try (try ls.local.compileAndRun("document.getElementById('sheetleaf').getBoundingClientRect().x", null)).toF64();
    const sheet_y = try (try ls.local.compileAndRun("document.getElementById('sheetleaf').getBoundingClientRect().y", null)).toF64();
    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = sheet_x, .y = sheet_y, .deltaY = 40 },
    });
    result = try ls.local.compileAndRun("window.sheetCancelable === true && document.getElementById('sheetscroll').scrollTop === 0", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchMouseEvent mouseWheel scrolls a scroll container, not the viewport" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('scrollbox').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('scrollbox').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = rect_x, .y = rect_y, .deltaY = 40 },
    });

    const box = try ls.local.compileAndRun("document.getElementById('scrollbox').scrollTop === 40 && window.scrollY === 0", null);
    try testing.expect(box.isTrue());

    // The scroll event is scheduled, not fired inline with the wheel.
    var runner = bc.session.runner(.{});
    try runner.waitForScript(frame._frame_id, "window.scrolled === true", 1000);

    // Per axis: x is not scrollable on the box, so it goes to the viewport.
    _ = try ls.local.compileAndRun("document.getElementById('scrollbox').style.overflow = 'hidden scroll'", null);
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = rect_x, .y = rect_y, .deltaX = 30, .deltaY = 10 },
    });
    const split = try ls.local.compileAndRun("document.getElementById('scrollbox').scrollTop === 50 && document.getElementById('scrollbox').scrollLeft === 0 && window.scrollX === 30 && window.scrollY === 0", null);
    try testing.expect(split.isTrue());

    // The container may be declared in a stylesheet rather than inline.
    const sheet_x = try (try ls.local.compileAndRun("document.getElementById('sheetleaf').getBoundingClientRect().x", null)).toF64();
    const sheet_y = try (try ls.local.compileAndRun("document.getElementById('sheetleaf').getBoundingClientRect().y", null)).toF64();
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = sheet_x, .y = sheet_y, .deltaY = 40 },
    });
    const sheet = try ls.local.compileAndRun("document.getElementById('sheetscroll').scrollTop === 40 && document.getElementById('sheetleaf').scrollTop === 0 && window.scrollY === 0", null);
    try testing.expect(sheet.isTrue());
    try runner.waitForScript(frame._frame_id, "window.sheetScrolled === true", 1000);
}

test "cdp.input: dispatchMouseEvent mouseWheel chains once the container is saturated" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const leaf_x = try (try ls.local.compileAndRun("document.getElementById('innerleaf').getBoundingClientRect().x", null)).toF64();
    const leaf_y = try (try ls.local.compileAndRun("document.getElementById('innerleaf').getBoundingClientRect().y", null)).toF64();

    // #outerscroll is a 100px box over 500px of content. A wheel latches to one
    // scroller: the container takes the whole delta and keeps what doesn't fit,
    // rather than passing the rest on.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = leaf_x, .y = leaf_y, .deltaY = 1000 },
    });
    const latched = try ls.local.compileAndRun("document.getElementById('outerscroll').scrollTop === 400 && window.scrollY === 0", null);
    try testing.expect(latched.isTrue());

    // Saturated now, so the next wheel latches to the viewport instead.
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = leaf_x, .y = leaf_y, .deltaY = 100 },
    });
    const chained = try ls.local.compileAndRun("document.getElementById('outerscroll').scrollTop === 400 && window.scrollY === 100", null);
    try testing.expect(chained.isTrue());

    // overscroll-behavior keeps the latch on a container that can't move, so
    // nothing scrolls at all.
    _ = try ls.local.compileAndRun("document.getElementById('outerscroll').style.overscrollBehavior = 'contain'", null);
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = leaf_x, .y = leaf_y, .deltaY = 100 },
    });
    const contained = try ls.local.compileAndRun("document.getElementById('outerscroll').scrollTop === 400 && window.scrollY === 100", null);
    try testing.expect(contained.isTrue());

    // Reversing direction latches back to the container, which can move again.
    // The 100 it can't give back stays unscrolled: no split here either.
    _ = try ls.local.compileAndRun("document.getElementById('outerscroll').style.overscrollBehavior = 'auto'", null);
    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = leaf_x, .y = leaf_y, .deltaY = -500 },
    });
    const upward = try ls.local.compileAndRun("document.getElementById('outerscroll').scrollTop === 0 && window.scrollY === 100", null);
    try testing.expect(upward.isTrue());
}

test "cdp.input: dispatchMouseEvent mouseWheel on page content scrolls the viewport" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = rect_x, .y = rect_y, .deltaX = 5, .deltaY = 600 },
    });
    var result = try ls.local.compileAndRun("window.scrollX === 5 && window.scrollY === 600", null);
    try testing.expect(result.isTrue());

    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = rect_x, .y = rect_y, .deltaY = -200 },
    });
    result = try ls.local.compileAndRun("window.scrollY === 400", null);
    try testing.expect(result.isTrue());

    // No element under the point.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseWheel", .x = 100_000, .y = 100_000, .deltaY = 100 },
    });
    result = try ls.local.compileAndRun("window.scrollY === 500", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchMouseEvent right button fires contextmenu, double-click fires dblclick" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('mousedown', (e) => { window.downButton ??= e.button; });
        \\t.addEventListener('contextmenu', (e) => { window.ctxButton = e.button; });
        \\t.addEventListener('dblclick', () => { window.dbl = true; });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    // Right button: press carries button=2 and fires contextmenu.
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
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 2 },
    });
    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 2 },
    });

    const result = try ls.local.compileAndRun("window.downButton === 2 && window.ctxButton === 2 && window.dbl === true", null);
    try testing.expect(result.isTrue());
}

// A CDP press/release pair fires the full pointer/mouse sequence, with
// mousedown carrying the message's clickCount as its detail (matches Chrome).
test "cdp.input: dispatchMouseEvent mousePressed/mouseReleased fires the full pointer/mouse sequence" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });

    const result = try ls.local.compileAndRun(
        \\JSON.stringify(window.seq) === JSON.stringify([
        \\  'pointerdown:0:1:0:mouse:true', 'mousedown:0:1:1::true',
        \\  'pointerup:0:0:0:mouse:true', 'mouseup:0:0:1::true', 'click:0:0:1:mouse:true'
        \\])
    , null);
    try testing.expect(result.isTrue());
}

// clickCount 0 (omitted) is preserved as mousedown's detail, not forced to 1:
// Chrome and Firefox both fire detail 0 there, distinct from a detail-1 click.
test "cdp.input: dispatchMouseEvent mousePressed's mousedown detail matches the message's clickCount" {
    const cases = .{
        .{ .click_count = 0, .expect_detail = 0 },
        .{ .click_count = 1, .expect_detail = 1 },
        .{ .click_count = 2, .expect_detail = 2 },
    };
    inline for (cases) |case| {
        var ctx = try testing.context();
        defer ctx.deinit();

        const bc = try ctx.loadBrowserContext(.{});
        const page = try bc.session.createPage();
        const frame = page.frame().?;

        const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
        try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
        try testing.waitForPage(bc);

        var ls: lp.js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        var try_catch: lp.js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const rect_x = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().x", null)).toF64();
        const rect_y = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().y", null)).toF64();

        try ctx.processMessage(.{
            .id = 1,
            .method = "Input.dispatchMouseEvent",
            .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = case.click_count },
        });

        const expected = std.fmt.comptimePrint("'pointerdown:0:1:0:mouse:true', 'mousedown:0:1:{d}::true'", .{case.expect_detail});
        const script = std.fmt.comptimePrint(
            "JSON.stringify(window.seq) === JSON.stringify([{s}])",
            .{expected},
        );
        const result = try ls.local.compileAndRun(script, null);
        try testing.expect(result.isTrue());
    }
}

// clickCount reaches the release half too: a clickCount-2 pair carries
// detail 2 on mousedown/mouseup/click and fires dblclick.
test "cdp.input: clickCount 2 on press and release puts detail 2 on mousedown, mouseup, click and fires dblclick" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\window.sawDbl = false;
        \\document.getElementById('btn').addEventListener('dblclick', () => { window.sawDbl = true; });
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 2 },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 2 },
    });

    const result = try ls.local.compileAndRun(
        \\JSON.stringify(window.seq) === JSON.stringify([
        \\  'pointerdown:0:1:0:mouse:true', 'mousedown:0:1:2::true',
        \\  'pointerup:0:0:0:mouse:true', 'mouseup:0:0:2::true', 'click:0:0:2:mouse:true'
        \\]) && window.sawDbl === true
    , null);
    try testing.expect(result.isTrue());
}

// clickCount must reach the chorded-press mousedown, not only the first press.
test "cdp.input: a chorded mousedown carries the press message's clickCount as its detail" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "right", .clickCount = 2 },
    });

    const result = try ls.local.compileAndRun(
        \\JSON.stringify(window.seq) === JSON.stringify([
        \\  'pointerdown:0:1:0:mouse:true', 'mousedown:0:1:1::true',
        \\  'mousedown:2:3:2::true'
        \\])
    , null);
    try testing.expect(result.isTrue());
}

// A pointerdown cancelled on the press message must still suppress mouseup on
// the separate release message, with no state carried by the caller.
test "cdp.input: a cancelled pointerdown suppresses mousedown and mouseup across the split mousePressed/mouseReleased calls" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('btnPreventDefault').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('btnPreventDefault').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });

    const result = try ls.local.compileAndRun(
        \\JSON.stringify(window.seqPrevented) === JSON.stringify(['pointerdown', 'pointerup', 'click'])
    , null);
    try testing.expect(result.isTrue());
}

// A disabled control gets the pointer events, contextmenu and auxclick, but no
// mouse events or click. Matches Chrome.
test "cdp.input: a disabled button gets only pointer and context events" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('btnDisabled').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('btnDisabled').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "right", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "right", .clickCount = 1 },
    });

    const result = try ls.local.compileAndRun(
        \\JSON.stringify(window.disabledEvents) === JSON.stringify([
        \\  'pointerdown', 'pointerup', 'pointerdown', 'contextmenu', 'pointerup', 'auxclick'
        \\])
    , null);
    try testing.expect(result.isTrue());
}

// The pointerdown is cancelled, so no compat mouse events fire. Matches Chrome.
test "cdp.input: a mouse chord fires pointermove for the mid-gesture button change, not a second pointerdown/pointerup" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('btnChord').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('btnChord').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "right", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "right", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });

    const result = try ls.local.compileAndRun(
        \\JSON.stringify(window.seqChord) === JSON.stringify([
        \\  'pointerdown:1', 'pointermove:3', 'contextmenu:3', 'pointermove:1', 'auxclick:1', 'pointerup:0'
        \\])
    , null);
    try testing.expect(result.isTrue());
}

// A primary release mid-chord reports the still-held mask on its click, not 0
// (confirmed against Chrome and Firefox).
test "cdp.input: a primary click fired mid-chord carries the still-held buttons mask" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('btnChord').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('btnChord').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mousePressed", .x = rect_x, .y = rect_y, .button = "right", .clickCount = 1 },
    });
    // Left releases first this time, while right is still held.
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "left", .clickCount = 1 },
    });
    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchMouseEvent",
        .params = .{ .type = "mouseReleased", .x = rect_x, .y = rect_y, .button = "right", .clickCount = 1 },
    });

    const result = try ls.local.compileAndRun(
        \\JSON.stringify(window.seqChord) === JSON.stringify([
        \\  'pointerdown:1', 'pointermove:3', 'contextmenu:3', 'pointermove:2', 'click:2', 'pointerup:0'
        \\])
    , null);
    try testing.expect(result.isTrue());
}

test "cdp.input: chorded mousedown focuses its target unless pointerdown or mousedown was cancelled" {
    inline for (.{ "none", "mousedown", "pointerdown" }) |cancel| {
        var ctx = try testing.context();
        defer ctx.deinit();

        const bc = try ctx.loadBrowserContext(.{});
        const page = try bc.session.createPage();
        const frame = page.frame().?;
        try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
        try testing.waitForPage(bc);

        var ls: lp.js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        var try_catch: lp.js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        _ = try ls.local.compileAndRun("window.cancelAt = '" ++ cancel ++ "';" ++
            \\document.getElementById('inp').focus();
            \\document.getElementById('inp').addEventListener('pointerdown', e => {
            \\  if (window.cancelAt === 'pointerdown') e.preventDefault();
            \\});
            \\window.chordMouseDowns = 0;
            \\document.getElementById('keyTarget').addEventListener('mousedown', e => {
            \\  window.chordMouseDowns++;
            \\  if (window.cancelAt === 'mousedown') e.preventDefault();
            \\});
        , null);

        const first_x = try (try ls.local.compileAndRun("document.getElementById('inp').getBoundingClientRect().x", null)).toF64();
        const first_y = try (try ls.local.compileAndRun("document.getElementById('inp').getBoundingClientRect().y", null)).toF64();
        const second_x = try (try ls.local.compileAndRun("document.getElementById('keyTarget').getBoundingClientRect().x", null)).toF64();
        const second_y = try (try ls.local.compileAndRun("document.getElementById('keyTarget').getBoundingClientRect().y", null)).toF64();
        try ctx.processMessage(.{
            .id = 1,
            .method = "Input.dispatchMouseEvent",
            .params = .{ .type = "mousePressed", .x = first_x, .y = first_y, .button = "left" },
        });
        try ctx.processMessage(.{
            .id = 2,
            .method = "Input.dispatchMouseEvent",
            .params = .{ .type = "mousePressed", .x = second_x, .y = second_y, .button = "right" },
        });

        // Check before any release/click activation can change focus.
        const result = try ls.local.compileAndRun(
            \\document.activeElement.id === (window.cancelAt === 'none' ? 'keyTarget' : 'inp') &&
            \\window.chordMouseDowns === (window.cancelAt === 'pointerdown' ? 0 : 1)
        , null);
        try testing.expect(result.isTrue());
    }
}

// Puppeteer sends radius and force 0.5; Chrome passes them through unchanged.
test "cdp.input: dispatchTouchEvent reports the client's radius, angle and force" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\window.seen = [];
        \\const target = document.getElementById('hoverTarget');
        \\for (const type of ['touchstart', 'touchend']) {
        \\  target.addEventListener(type, e => {
        \\    const t = e.changedTouches[0];
        \\    seen.push([t.radiusX, t.radiusY, t.rotationAngle, t.force]);
        \\  });
        \\}
    , null);
    const x = try (try ls.local.compileAndRun("target.getBoundingClientRect().x", null)).toF64();
    const y = try (try ls.local.compileAndRun("target.getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{
            .{ .x = x, .y = y, .radiusX = 0.5, .radiusY = 0.5, .force = 0.5 },
        } },
    });

    // Chrome defaults each omitted radius independently to 1.
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{
            .{ .x = x, .y = y, .radiusX = 3, .rotationAngle = 45 },
        } },
    });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{
            .{ .x = x, .y = y, .radiusY = 4 },
        } },
    });

    try testing.expect((try ls.local.compileAndRun(
        \\JSON.stringify(seen) === JSON.stringify([[0.5, 0.5, 0, 0.5], [3, 1, 45, 1], [1, 4, 0, 1]])
    , null)).isTrue());
}

test "cdp.input: dispatchTouchEvent touchStart populates touches/targetTouches/changedTouches" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('touchstart', (e) => {
        \\  const touch = e.touches[0];
        \\  window.result = e.touches.length === 1 &&
        \\    e.targetTouches.length === 1 &&
        \\    e.changedTouches.length === 1 &&
        \\    touch.target === t &&
        \\    touch === e.changedTouches[0] &&
        \\    e.touches !== e.targetTouches &&
        \\    touch.pageX === touch.clientX &&
        \\    touch.pageY === touch.clientY &&
        \\    touch.screenX === touch.clientX &&
        \\    touch.screenY === touch.clientY &&
        \\    touch.radiusX === 1 &&
        \\    touch.radiusY === 1 &&
        \\    touch.rotationAngle === 0 &&
        \\    touch.force === 1;
        \\  window.touchX = touch.clientX;
        \\  window.touchY = touch.clientY;
        \\});
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = rect_x, .y = rect_y }} },
    });

    const result = try ls.local.compileAndRun("window.result === true && window.touchX === document.getElementById('hoverTarget').getBoundingClientRect().x && window.touchY === document.getElementById('hoverTarget').getBoundingClientRect().y", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchTouchEvent preserves each event's modifier keys" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\window.touchModifiers = [];
        \\for (const type of ['touchstart', 'touchmove', 'touchend', 'touchcancel']) {
        \\  document.addEventListener(type, e => {
        \\    touchModifiers.push([e.type, e.altKey, e.ctrlKey, e.metaKey, e.shiftKey]);
        \\  });
        \\}
    , null);

    const steps = .{
        .{ "touchStart", 1 },
        .{ "touchMove", 2 },
        .{ "touchEnd", 4 },
        .{ "touchStart", 15 },
        .{ "touchCancel", 8 },
    };
    inline for (steps, 1..) |step, id| {
        const is_lift = comptime std.mem.eql(u8, step[0], "touchEnd") or std.mem.eql(u8, step[0], "touchCancel");
        try ctx.processMessage(.{
            .id = id,
            .method = "Input.dispatchTouchEvent",
            .params = .{ .type = step[0], .modifiers = step[1], .touchPoints = if (is_lift) &.{} else &.{.{ .x = 0, .y = 0 }} },
        });
    }
    // Omitted modifiers reset to false, even after a modified gesture.
    try ctx.processMessage(.{
        .id = 6,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = 0, .y = 0 }} },
    });

    try testing.expect((try ls.local.compileAndRun(
        \\JSON.stringify(touchModifiers) === JSON.stringify([
        \\  ['touchstart', true, false, false, false],
        \\  ['touchmove', false, true, false, false],
        \\  ['touchend', false, false, true, false],
        \\  ['touchstart', true, true, true, true],
        \\  ['touchcancel', false, false, false, true],
        \\  ['touchstart', false, false, false, false]
        \\])
    , null)).isTrue());
}

test "cdp.input: dispatchTouchEvent touchEnd empties touches but keeps changedTouches" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('touchend', (e) => {
        \\  window.result = e.touches.length === 0 &&
        \\    e.targetTouches.length === 0 &&
        \\    e.changedTouches.length === 1 &&
        \\    e.changedTouches[0].target === t &&
        \\    e.changedTouches[0].clientX === t.getBoundingClientRect().x &&
        \\    e.changedTouches[0].clientY === t.getBoundingClientRect().y;
        \\});
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = rect_x, .y = rect_y }} },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{} },
    });

    const result = try ls.local.compileAndRun("window.result === true", null);
    try testing.expect(result.isTrue());
}

// Playwright's touchscreen.tap(400, 3000) on a short page; Chrome completes
// the sequence.
test "cdp.input: dispatchTouchEvent a touchStart past every element still opens a contact" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = 0, .y = 3000 }} },
    });
    try testing.expect(frame.page.input_touch_contact != null);

    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{} },
    });
    try testing.expect(frame.page.input_touch_contact == null);
}

test "cdp.input: dispatchTouchEvent empty touchStart is InvalidParams" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{} },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 1 });
}

test "cdp.input: dispatchTouchEvent a multi-contact touchStart/touchMove is InvalidParams" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 } } },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchMove", .touchPoints = &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 } } },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 2 });
}

test "cdp.input: dispatchTouchEvent empty touchEnd with no active contact is InvalidParams" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{} },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 1 });
}

test "cdp.input: dispatchTouchEvent touchMove with no active contact is InvalidParams" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    _ = try bc.session.createPage();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchMove", .touchPoints = &.{.{ .x = 0, .y = 0 }} },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 1 });
}

test "cdp.input: dispatchTouchEvent tracks the client's chosen id and rejects mismatches" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\window.touchEvents = [];
        \\const target = document.getElementById('hoverTarget');
        \\for (const type of ['touchstart', 'touchmove', 'touchend']) {
        \\  target.addEventListener(type, e => {
        \\    const t = e.changedTouches[0];
        \\    touchEvents.push([e.type, t.identifier, t.clientX, t.clientY]);
        \\  });
        \\}
    , null);
    const x = try (try ls.local.compileAndRun("target.getBoundingClientRect().x", null)).toF64();
    const y = try (try ls.local.compileAndRun("target.getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = x, .y = y, .id = 0.5 }} },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 1 });
    try testing.expect(frame.page.input_touch_contact == null);

    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = x, .y = y, .id = 7 }} },
    });
    try testing.expectEqual(@as(i32, 7), frame.page.input_touch_contact.?.point.id);

    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchMove", .touchPoints = &.{.{ .x = x + 100, .y = y + 100, .id = 8 }} },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 3 });
    try testing.expectEqual(x, frame.page.input_touch_contact.?.point.x);
    try testing.expectEqual(y, frame.page.input_touch_contact.?.point.y);

    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchMove", .touchPoints = &.{.{ .x = x + 1, .y = y + 2, .id = 7 }} },
    });

    try ctx.processMessage(.{
        .id = 5,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{.{ .x = x + 1, .y = y + 2, .id = 8 }} },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 5 });
    try testing.expect(frame.page.input_touch_contact != null);

    try ctx.processMessage(.{
        .id = 6,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{.{ .x = x + 1, .y = y + 2, .id = 7 }} },
    });
    try testing.expect(frame.page.input_touch_contact == null);
    try testing.expect((try ls.local.compileAndRun(
        \\JSON.stringify(touchEvents) === JSON.stringify([
        \\  ['touchstart', 7, target.getBoundingClientRect().x, target.getBoundingClientRect().y],
        \\  ['touchmove', 7, target.getBoundingClientRect().x + 1, target.getBoundingClientRect().y + 2],
        \\  ['touchend', 7, target.getBoundingClientRect().x + 1, target.getBoundingClientRect().y + 2]
        \\])
    , null)).isTrue());
}

test "cdp.input: dispatchTouchEvent a second touchStart while a contact is active is InvalidParams" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\document.getElementById('hoverTarget')
        \\  .addEventListener('touchstart', () => { window.starts = (window.starts || 0) + 1; });
    , null);

    const first_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const first_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();
    const other_x = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().x", null)).toF64();
    const other_y = try (try ls.local.compileAndRun("document.getElementById('btn').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = first_x, .y = first_y }} },
    });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = other_x, .y = other_y }} },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 2 });

    _ = try ls.local.compileAndRun(
        \\document.getElementById('hoverTarget')
        \\  .addEventListener('touchend', (e) => {
        \\    window.endedOnOriginal = e.changedTouches[0].clientX === document.getElementById('hoverTarget').getBoundingClientRect().x;
        \\  });
    , null);
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{} },
    });

    const result = try ls.local.compileAndRun("window.starts === 1 && window.endedOnOriginal === true", null);
    try testing.expect(result.isTrue());
}

// Puppeteer releases without an intervening touchMove.
test "cdp.input: dispatchTouchEvent a touchEnd carrying the released point is accepted" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('touchend', (e) => {
        \\  const touch = e.changedTouches[0];
        \\  window.endTarget = touch.target === t;
        \\  window.endX = touch.clientX;
        \\  window.endY = touch.clientY;
        \\});
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();
    const end_x = rect_x + 5;
    const end_y = rect_y + 9;

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = rect_x, .y = rect_y }} },
    });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{.{ .x = end_x, .y = end_y }} },
    });
    try testing.expect(frame.page.input_touch_contact == null);

    const result = try ls.local.compileAndRun(
        "window.endTarget === true && window.endX === " ++ "document.getElementById('hoverTarget').getBoundingClientRect().x + 5" ++
            " && window.endY === document.getElementById('hoverTarget').getBoundingClientRect().y + 9",
        null,
    );
    try testing.expect(result.isTrue());

    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = rect_x, .y = rect_y }} },
    });
    try testing.expect(frame.page.input_touch_contact != null);
}

test "cdp.input: dispatchTouchEvent an empty touchEnd uses the stored position" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('touchend', (e) => {
        \\  const touch = e.changedTouches[0];
        \\  window.endX = touch.clientX;
        \\  window.endY = touch.clientY;
        \\});
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = rect_x, .y = rect_y }} },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{} },
    });

    const result = try ls.local.compileAndRun("window.endX === document.getElementById('hoverTarget').getBoundingClientRect().x && window.endY === document.getElementById('hoverTarget').getBoundingClientRect().y", null);
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchTouchEvent rejects populated touchCancel without lifting contact" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\const t = document.getElementById('hoverTarget');
        \\t.addEventListener('touchcancel', (e) => {
        \\  const touch = e.changedTouches[0];
        \\  window.cancelable = e.cancelable;
        \\  window.cancelX = touch.clientX;
        \\  window.cancelY = touch.clientY;
        \\});
    , null);

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();
    const cancel_x = rect_x + 3;
    const cancel_y = rect_y + 4;

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = rect_x, .y = rect_y }} },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchCancel", .touchPoints = &.{.{ .x = cancel_x, .y = cancel_y }} },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 2 });
    try testing.expect(frame.page.input_touch_contact != null);

    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchCancel", .touchPoints = &.{} },
    });
    try testing.expect(frame.page.input_touch_contact == null);

    const result = try ls.local.compileAndRun(
        "window.cancelable === false && window.cancelX === " ++ "document.getElementById('hoverTarget').getBoundingClientRect().x" ++
            " && window.cancelY === document.getElementById('hoverTarget').getBoundingClientRect().y",
        null,
    );
    try testing.expect(result.isTrue());
}

test "cdp.input: dispatchTouchEvent a multi-point touchEnd/touchCancel is InvalidParams" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const rect_x = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().x", null)).toF64();
    const rect_y = try (try ls.local.compileAndRun("document.getElementById('hoverTarget').getBoundingClientRect().y", null)).toF64();

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = rect_x, .y = rect_y }} },
    });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{ .{ .x = rect_x, .y = rect_y }, .{ .x = rect_x, .y = rect_y, .id = 1 } } },
    });
    try ctx.expectSentError(-31998, "InvalidParams", .{ .id = 2 });
}

test "cdp.input: dispatchKeyEvent Tab runs sequential focus navigation" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

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

test "cdp.input: dispatchKeyEvent beforeinput can veto the edit" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // A listener that rejects every keystroke, the way masked-input libraries
    // do. Records what it saw so we can assert the event was cancelable.
    _ = try ls.local.compileAndRun(
        \\const inp = document.getElementById('inp');
        \\inp.value = 'ab';
        \\inp.focus();
        \\window.seen = [];
        \\inp.addEventListener('beforeinput', (e) => {
        \\  window.seen.push(['beforeinput', e.cancelable].join(':'));
        \\  e.preventDefault();
        \\  window.seen.push(['defaultPrevented', e.defaultPrevented].join(':'));
        \\});
        \\inp.addEventListener('input', () => window.seen.push('input'));
    , null);

    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "c", .text = "c" },
    });

    // The veto held: no character inserted and no `input` event followed.
    try testing.expect((try ls.local.compileAndRun(
        \\inp.value === 'ab' &&
        \\window.seen.join(',') === 'beforeinput:true,defaultPrevented:true'
    , null)).isTrue());

    // Backspace goes through the same pre-edit gate.
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "Backspace", .code = "Backspace" },
    });
    try testing.expect((try ls.local.compileAndRun("inp.value === 'ab'", null)).isTrue());

    // Without the veto, the edit goes through and `input` is dispatched — and
    // `input` itself is not cancelable.
    _ = try ls.local.compileAndRun(
        \\const clone = inp.cloneNode(true);
        \\inp.replaceWith(clone);
        \\clone.focus();
        \\window.seen = [];
        \\clone.addEventListener('input', (e) => window.seen.push(['input', e.cancelable].join(':')));
    , null);

    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "c", .text = "c" },
    });
    try testing.expect((try ls.local.compileAndRun(
        \\clone.value === 'abc' && window.seen.join(',') === 'input:false'
    , null)).isTrue());
}

test "cdp.input: editing keys honor the selection of a default-valued textarea" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // This <textarea>'s value comes from its child text node — nothing assigns
    // to `value` — so the selection has to clamp against the parsed text.
    _ = try ls.local.compileAndRun(
        \\document.body.innerHTML = '<textarea id="ta">abcdef</textarea>';
        \\const ta = document.getElementById('ta');
        \\ta.focus();
        \\ta.setSelectionRange(2, 4);
    , null);
    try testing.expect((try ls.local.compileAndRun("ta.selectionStart === 2 && ta.selectionEnd === 4", null)).isTrue());

    // Backspace over a range deletes the range, leaving the caret at its start.
    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "Backspace", .code = "Backspace" },
    });
    try testing.expect((try ls.local.compileAndRun("ta.value === 'abef'", null)).isTrue());
    try testing.expect((try ls.local.compileAndRun("ta.selectionStart === 2 && ta.selectionEnd === 2", null)).isTrue());

    // Collapsed caret: Backspace removes the character on its left.
    _ = try ls.local.compileAndRun("ta.setSelectionRange(3, 3)", null);
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "Backspace", .code = "Backspace" },
    });
    try testing.expect((try ls.local.compileAndRun("ta.value === 'abf'", null)).isTrue());
}

test "cdp.input: dispatchKeyEvent caret movement keys move the text entry cursor" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;

    const url = "http://localhost:9582/src/browser/tests/mcp_actions.html";
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    _ = try ls.local.compileAndRun(
        \\document.body.innerHTML = '<input id="t" type="text"><textarea id="ta"></textarea>';
        \\const t = document.getElementById('t');
        \\const ta = document.getElementById('ta');
        \\const sel = (e) => [e.selectionStart, e.selectionEnd, e.selectionDirection].join(',');
        \\t.focus(); t.value = 'abcdef'; t.setSelectionRange(6, 6);
    , null);

    const Step = struct { key: []const u8, modifiers: u4 = 0, expect: []const u8 };
    const shift = 8;

    // <input>: plain moves collapse, Shift extends from the anchor, a plain
    // arrow on a selection collapses to its edge, ArrowUp/ArrowDown reach the
    // ends of a single-line value.
    const input_steps = [_]Step{
        .{ .key = "ArrowLeft", .expect = "5,5,none" },
        .{ .key = "ArrowRight", .expect = "6,6,none" },
        .{ .key = "Home", .expect = "0,0,none" },
        .{ .key = "End", .expect = "6,6,none" },
        .{ .key = "ArrowUp", .expect = "0,0,none" },
        .{ .key = "ArrowDown", .expect = "6,6,none" },
        .{ .key = "ArrowRight", .expect = "6,6,none" },
        .{ .key = "ArrowLeft", .modifiers = shift, .expect = "5,6,backward" },
        .{ .key = "Home", .modifiers = shift, .expect = "0,6,backward" },
        .{ .key = "ArrowLeft", .expect = "0,0,none" },
        .{ .key = "ArrowLeft", .expect = "0,0,none" },
        .{ .key = "End", .modifiers = shift, .expect = "0,6,forward" },
        .{ .key = "ArrowLeft", .modifiers = shift, .expect = "0,5,forward" },
        .{ .key = "ArrowRight", .expect = "5,5,none" },
    };
    var id: u32 = 1;
    for (input_steps) |step| {
        try ctx.processMessage(.{
            .id = id,
            .method = "Input.dispatchKeyEvent",
            .params = .{ .type = "keyDown", .key = step.key, .code = step.key, .modifiers = step.modifiers },
        });
        id += 1;
        const got = try (try ls.local.compileAndRun("sel(t)", null)).toStringSlice();
        try testing.expectEqualSlices(u8, step.expect, got);
    }

    // Type-then-correct: move back two characters and insert in the middle.
    _ = try ls.local.compileAndRun("t.setSelectionRange(6, 6)", null);
    for (0..2) |_| {
        try ctx.processMessage(.{
            .id = id,
            .method = "Input.dispatchKeyEvent",
            .params = .{ .type = "keyDown", .key = "ArrowLeft", .code = "ArrowLeft" },
        });
        id += 1;
    }
    try ctx.processMessage(.{ .id = id, .method = "Input.insertText", .params = .{ .text = "X" } });
    id += 1;
    try testing.expect((try ls.local.compileAndRun("t.value === 'abcdXef' && sel(t) === '5,5,none'", null)).isTrue());

    // Moves step over whole UTF-8 sequences, never landing inside one.
    _ = try ls.local.compileAndRun("t.value = 'aé'; t.setSelectionRange(t.value.length, t.value.length)", null);
    try ctx.processMessage(.{
        .id = id,
        .method = "Input.dispatchKeyEvent",
        .params = .{ .type = "keyDown", .key = "ArrowLeft", .code = "ArrowLeft" },
    });
    id += 1;
    try ctx.processMessage(.{ .id = id, .method = "Input.insertText", .params = .{ .text = "X" } });
    id += 1;
    try testing.expect((try ls.local.compileAndRun("t.value === 'aXé'", null)).isTrue());

    // <textarea>: Home/End stop at the enclosing line break, ArrowLeft crosses it.
    _ = try ls.local.compileAndRun("ta.focus(); ta.value = 'ab\\ncd'; ta.setSelectionRange(5, 5)", null);
    const textarea_steps = [_]Step{
        .{ .key = "Home", .expect = "3,3,none" },
        .{ .key = "End", .expect = "5,5,none" },
        .{ .key = "Home", .modifiers = shift, .expect = "3,5,backward" },
        .{ .key = "ArrowLeft", .expect = "3,3,none" },
        .{ .key = "ArrowLeft", .expect = "2,2,none" },
    };
    for (textarea_steps) |step| {
        try ctx.processMessage(.{
            .id = id,
            .method = "Input.dispatchKeyEvent",
            .params = .{ .type = "keyDown", .key = step.key, .code = step.key, .modifiers = step.modifiers },
        });
        id += 1;
        const got = try (try ls.local.compileAndRun("sel(ta)", null)).toStringSlice();
        try testing.expectEqualSlices(u8, step.expect, got);
    }
}

// chromedp's SendKeys shape: a text-less keyDown, the char with the text, keyUp.
test "cdp.input: dispatchKeyEvent text-less keyDown then char types once" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .url = "mcp_actions.html" });
    const frame = bc.mainFrame().?;

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\const inp = document.getElementById('inp');
        \\inp.value = '';
        \\inp.focus();
        \\window.events = [];
        \\for (const t of ['keydown', 'keypress', 'input', 'keyup']) {
        \\  inp.addEventListener(t, (e) => window.events.push(t + ':' + (e.key ?? inp.value)));
        \\}
    , null);

    try ctx.processMessage(.{ .id = 1, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "h", .code = "KeyH" } });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try testing.expect((try ls.local.compileAndRun("inp.value === '' && window.events.join(',') === 'keydown:h'", null)).isTrue());

    try ctx.processMessage(.{ .id = 2, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = "h", .text = "h" } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try ctx.processMessage(.{ .id = 3, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyUp", .key = "h", .code = "KeyH" } });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try testing.expect((try ls.local.compileAndRun(
        \\inp.value === 'h' && window.events.join(',') === 'keydown:h,keypress:h,input:h,keyup:h'
    , null)).isTrue());

    // A char without text has nothing to type.
    try ctx.processMessage(.{ .id = 4, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = "Enter" } });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try testing.expect((try ls.local.compileAndRun("inp.value === 'h' && window.events.length === 4", null)).isTrue());

    // A keyDown with text but no key (Puppeteer's shape for some keys) types it.
    try ctx.processMessage(.{ .id = 5, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .text = "z" } });
    try ctx.expectSentResult(null, .{ .id = 5 });
    try testing.expect((try ls.local.compileAndRun("inp.value === 'hz'", null)).isTrue());

    // Enter's char is "\r": a line break in a <textarea>, never a literal "\r".
    _ = try ls.local.compileAndRun(
        \\const ta = document.createElement('textarea');
        \\document.body.appendChild(ta);
        \\ta.value = 'one';
        \\ta.focus();
        \\ta.addEventListener('input', (e) => window.taInput = e.inputType + ':' + e.data);
    , null);
    try ctx.processMessage(.{ .id = 6, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "Enter", .code = "Enter" } });
    try ctx.expectSentResult(null, .{ .id = 6 });
    try ctx.processMessage(.{ .id = 7, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = "Enter", .text = "\r" } });
    try ctx.expectSentResult(null, .{ .id = 7 });
    try ctx.processMessage(.{ .id = 8, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyUp", .key = "Enter", .code = "Enter" } });
    try ctx.expectSentResult(null, .{ .id = 8 });
    try testing.expect((try ls.local.compileAndRun("ta.value === 'one\\n' && window.taInput === 'insertLineBreak:null'", null)).isTrue());
}

test "cdp.input: a readonly textarea fires beforeinput for typed text only, a disabled one nothing" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .url = "mcp_actions.html" });
    const frame = bc.mainFrame().?;

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // As in Chrome, typed text reaches beforeinput before the readonly
    // control refuses it; Backspace and Enter fire no edit event.
    _ = try ls.local.compileAndRun(
        \\const ta = document.createElement('textarea');
        \\document.body.appendChild(ta);
        \\ta.value = 'ro';
        \\ta.readOnly = true;
        \\ta.focus();
        \\window.edits = [];
        \\for (const t of ['beforeinput', 'input']) ta.addEventListener(t, (e) => window.edits.push(t + ':' + e.inputType));
    , null);
    try ctx.processMessage(.{ .id = 1, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "x", .text = "x" } });
    try ctx.processMessage(.{ .id = 2, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "Backspace", .code = "Backspace" } });
    try ctx.processMessage(.{ .id = 3, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "Enter", .code = "Enter", .text = "\r" } });
    try ctx.processMessage(.{ .id = 4, .method = "Input.insertText", .params = .{ .text = "y" } });
    try testing.expect((try ls.local.compileAndRun(
        \\ta.value === 'ro' && window.edits.join() === 'beforeinput:insertText,beforeinput:insertText'
    , null)).isTrue());

    // A disabled control fires nothing, not even for typed text.
    _ = try ls.local.compileAndRun("ta.readOnly = false; ta.disabled = true; window.edits = [];", null);
    try ctx.processMessage(.{ .id = 5, .method = "Input.insertText", .params = .{ .text = "z" } });
    try testing.expect((try ls.local.compileAndRun("ta.value === 'ro' && window.edits.length === 0", null)).isTrue());
}

test "cdp.input: dispatchKeyEvent char honors keypress and beforeinput vetoes" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .url = "mcp_actions.html" });
    const frame = bc.mainFrame().?;

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    // keypress fires before beforeinput, so it sees the digits the latter vetoes.
    _ = try ls.local.compileAndRun(
        \\const inp = document.getElementById('inp');
        \\inp.value = '';
        \\inp.focus();
        \\window.keypresses = [];
        \\inp.addEventListener('keypress', (e) => {
        \\  window.keypresses.push(e.key);
        \\  if (e.key === 'x') e.preventDefault();
        \\});
        \\inp.addEventListener('beforeinput', (e) => {
        \\  if (/[0-9]/.test(e.data)) e.preventDefault();
        \\});
    , null);

    var id: u32 = 1;
    for ("a1x2b") |c| {
        const key: []const u8 = &.{c};
        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = key } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;
        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = key, .text = key } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;
    }
    try testing.expect((try ls.local.compileAndRun(
        \\inp.value === 'ab' && window.keypresses.join('') === 'a1x2b'
    , null)).isTrue());
}

test "cdp.input: dispatchKeyEvent cancelled keyDown suppresses its char" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .url = "mcp_actions.html" });
    const frame = bc.mainFrame().?;

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\const inp = document.getElementById('inp');
        \\inp.value = '';
        \\inp.focus();
        \\window.keypresses = [];
        \\inp.addEventListener('keydown', (e) => { if (e.key === 'x') e.preventDefault(); });
        \\inp.addEventListener('keypress', (e) => window.keypresses.push(e.key));
    , null);

    // The char in the same message (keyDown with text) and in the next one
    // (chromedp) are both dropped.
    try ctx.processMessage(.{ .id = 1, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "x", .text = "x" } });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try ctx.processMessage(.{ .id = 2, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "x" } });
    try ctx.expectSentResult(null, .{ .id = 2 });
    try ctx.processMessage(.{ .id = 3, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = "x", .text = "x" } });
    try ctx.expectSentResult(null, .{ .id = 3 });
    try testing.expect((try ls.local.compileAndRun("inp.value === '' && window.keypresses.length === 0", null)).isTrue());

    try ctx.processMessage(.{ .id = 4, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "y" } });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try ctx.processMessage(.{ .id = 5, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = "y", .text = "y" } });
    try ctx.expectSentResult(null, .{ .id = 5 });
    try testing.expect((try ls.local.compileAndRun("inp.value === 'y' && window.keypresses.join('') === 'y'", null)).isTrue());
}

// Enter, as chromedp sends it: keyDown, a "\r" char, keyUp. Buttons click
// after their keypress; the form submits at most once.
test "cdp.input: dispatchKeyEvent Enter clicks buttons and submits once" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .url = "mcp_actions.html" });
    const frame = bc.mainFrame().?;

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\document.body.insertAdjacentHTML('beforeend', '<form id=f>' +
        \\  '<input id=text><input id=check type=checkbox><input id=submit type=submit>' +
        \\  '<button id=button>go</button><input id=ibutton type=button><input id=reset type=reset></form>');
        \\const form = document.getElementById('f');
        \\form.addEventListener('submit', (e) => {
        \\  e.preventDefault();
        \\  window.events.push('submit');
        \\});
        \\// Only the focused control's keypress and click are recorded.
        \\for (const t of ['keypress', 'click']) {
        \\  form.addEventListener(t, (e) => {
        \\    if (e.target === document.activeElement) window.events.push(t);
        \\  }, true);
        \\}
        \\window.arm = (id) => {
        \\  window.events = [];
        \\  document.getElementById(id).focus();
        \\};
    , null);

    const cases = [_]struct { id: []const u8, expect: []const u8 }{
        .{ .id = "text", .expect = "keypress submit" },
        .{ .id = "check", .expect = "keypress submit" },
        .{ .id = "submit", .expect = "keypress click submit" },
        .{ .id = "button", .expect = "keypress click submit" },
        .{ .id = "ibutton", .expect = "keypress click" },
        .{ .id = "reset", .expect = "keypress click" },
    };

    var id: u32 = 1;
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        _ = try ls.local.compileAndRun(try std.mem.print(&buf, "arm('{s}')", .{c.id}), null);

        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "Enter", .code = "Enter" } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;
        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = "Enter", .text = "\r" } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;
        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyUp", .key = "Enter", .code = "Enter" } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;

        const got = try (try ls.local.compileAndRun("window.events.join(' ')", null)).toStringSlice();
        try testing.expectEqualSlices(u8, c.expect, got);
    }
}

// Enter in a text field clicks the form's default button (its first submit
// button in tree order), which then submits with itself as the submitter.
// Without a default button the form submits itself, unless more than one
// field blocks implicit submission.
test "cdp.input: dispatchKeyEvent Enter in a field submits through the default button" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .url = "mcp_actions.html" });
    const frame = bc.mainFrame().?;

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\document.body.insertAdjacentHTML('beforeend',
        \\  '<form id=a><input id=a_text name=q><input id=a_go type=submit name=search value=Go><button id=a_go2>2</button></form>' +
        \\  '<form id=b><input id=b_text><button id=b_go disabled>go</button></form>' +
        \\  '<form id=c><fieldset disabled><button id=c_go>go</button></fieldset><input id=c_text></form>' +
        \\  '<form id=d><input id=d_text name=q><input type=checkbox><input type=hidden></form>' +
        \\  '<form id=e><input id=e_text><input type=email></form>' +
        \\  '<input id=f_go type=submit form=f name=out value=1><form id=f><input id=f_text><button id=f_go2>2</button></form>');
        \\window.events = [];
        \\document.addEventListener('click', (e) => window.events.push('click:' + e.target.id), true);
        \\document.addEventListener('submit', (e) => {
        \\  e.preventDefault();
        \\  const s = e.submitter;
        \\  const entries = Array.from(new FormData(e.target, s)).map(([k, v]) => k + '=' + v).join('&');
        \\  window.events.push('submit:' + (s ? s.id : 'null') + ':' + entries);
        \\}, true);
        \\window.arm = (id) => {
        \\  window.events = [];
        \\  document.getElementById(id).focus();
        \\};
    , null);

    const cases = [_]struct { id: []const u8, expect: []const u8 }{
        .{ .id = "a_text", .expect = "click:a_go submit:a_go:q=&search=Go" },
        .{ .id = "b_text", .expect = "" },
        .{ .id = "c_text", .expect = "" },
        .{ .id = "d_text", .expect = "submit:null:q=" },
        .{ .id = "e_text", .expect = "" },
        .{ .id = "f_text", .expect = "click:f_go submit:f_go:out=1" },
    };

    var id: u32 = 1;
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        _ = try ls.local.compileAndRun(try std.mem.print(&buf, "arm('{s}')", .{c.id}), null);

        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "Enter", .code = "Enter" } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;
        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = "Enter", .text = "\r" } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;
        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyUp", .key = "Enter", .code = "Enter" } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;

        const got = try (try ls.local.compileAndRun("window.events.join(' ')", null)).toStringSlice();
        try testing.expectEqualSlices(u8, c.expect, got);
    }
}

// Enter on a checkbox or a radio clicks the form's default button like a text
// field does, but without a default button it never submits the form: only a
// text field can trigger the submission. Enter on a select never submits.
// Expectations match Chrome.
test "cdp.input: dispatchKeyEvent Enter on a checkbox, radio or select" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .url = "mcp_actions.html" });
    const frame = bc.mainFrame().?;

    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    _ = try ls.local.compileAndRun(
        \\document.body.insertAdjacentHTML('beforeend',
        \\  '<form id=g><input id=g_text name=q><input id=g_cb type=checkbox name=c checked><input id=g_radio type=radio name=r value=1 checked><select id=g_sel name=s><option>x</option></select></form>' +
        \\  '<form id=h><input id=h_cb type=checkbox name=c checked><input id=h_radio type=radio name=r value=1 checked><select id=h_sel name=s><option>x</option></select><button id=h_go name=go value=1>go</button></form>' +
        \\  '<form id=i><input id=i_cb type=checkbox name=c checked><input id=i_radio type=radio name=r value=1 checked><select id=i_sel name=s><option>x</option></select></form>');
        \\window.events = [];
        \\document.addEventListener('click', (e) => window.events.push('click:' + e.target.id), true);
        \\document.addEventListener('submit', (e) => {
        \\  e.preventDefault();
        \\  const s = e.submitter;
        \\  const entries = Array.from(new FormData(e.target, s)).map(([k, v]) => k + '=' + v).join('&');
        \\  window.events.push('submit:' + (s ? s.id : 'null') + ':' + entries);
        \\}, true);
        \\window.arm = (id) => {
        \\  window.events = [];
        \\  document.getElementById(id).focus();
        \\};
    , null);

    const cases = [_]struct { id: []const u8, expect: []const u8 }{
        // no default button, one text field
        .{ .id = "g_text", .expect = "submit:null:q=&c=on&r=1&s=x" },
        .{ .id = "g_cb", .expect = "" },
        .{ .id = "g_radio", .expect = "" },
        .{ .id = "g_sel", .expect = "" },
        // a default button
        .{ .id = "h_cb", .expect = "click:h_go submit:h_go:c=on&r=1&s=x&go=1" },
        .{ .id = "h_radio", .expect = "click:h_go submit:h_go:c=on&r=1&s=x&go=1" },
        .{ .id = "h_sel", .expect = "" },
        // no default button, no text field
        .{ .id = "i_cb", .expect = "" },
        .{ .id = "i_radio", .expect = "" },
        .{ .id = "i_sel", .expect = "" },
    };

    var id: u32 = 1;
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        _ = try ls.local.compileAndRun(try std.mem.print(&buf, "arm('{s}')", .{c.id}), null);

        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "Enter", .code = "Enter" } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;
        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = "Enter", .text = "\r" } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;
        try ctx.processMessage(.{ .id = id, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyUp", .key = "Enter", .code = "Enter" } });
        try ctx.expectSentResult(null, .{ .id = id });
        id += 1;

        const got = try (try ls.local.compileAndRun("window.events.join(' ')", null)).toStringSlice();
        try testing.expectEqualSlices(u8, c.expect, got);
    }
}

test "cdp.input: touch tap emits pointer and compatibility activation in order" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\window.tapEvents = [];
        \\const tapTarget = document.getElementById('btn');
        \\for (const type of ['pointerover', 'pointerenter', 'pointerdown', 'touchstart', 'pointerup', 'pointerout', 'pointerleave', 'touchend', 'mouseover', 'mouseenter', 'mousemove', 'mousedown', 'focus', 'mouseup', 'click']) {
        \\  tapTarget.addEventListener(type, e => tapEvents.push({type: e.type, pointerType: e.pointerType, id: e.pointerId, button: e.button, buttons: e.buttons, detail: e.detail, trusted: e.isTrusted, x: e.clientX, y: e.clientY, width: e.width, height: e.height, pressure: e.pressure, shift: e.shiftKey}));
        \\}
    , null);
    const x = try (try ls.local.compileAndRun("tapTarget.getBoundingClientRect().x + 1", null)).toF64();
    const y = try (try ls.local.compileAndRun("tapTarget.getBoundingClientRect().y + 1", null)).toF64();
    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .modifiers = 8, .touchPoints = &.{.{ .x = x, .y = y, .id = 7, .radiusX = 3, .radiusY = 4, .force = 0.7 }} },
    });
    try testing.expect((try ls.local.compileAndRun("!window.clicked && tapEvents.map(e => e.type).join(',') === 'pointerover,pointerenter,pointerdown,touchstart'", null)).isTrue());
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .modifiers = 8, .touchPoints = &.{} },
    });
    try testing.expect((try ls.local.compileAndRun(
        \\tapEvents.map(e => e.type).join(',') === 'pointerover,pointerenter,pointerdown,touchstart,pointerup,pointerout,pointerleave,touchend,mouseover,mouseenter,mousemove,mousedown,focus,mouseup,click' && window.clicked && document.activeElement === tapTarget &&
        \\tapEvents.every(e => e.trusted) &&
        \\tapEvents.filter(e => e.pointerType).every(e => e.pointerType === 'touch' && e.id === 2 && e.shift) &&
        \\tapEvents.find(e => e.type === 'pointerdown').width === 6 && tapEvents.find(e => e.type === 'pointerdown').height === 8 && tapEvents.find(e => e.type === 'pointerdown').pressure === 0.7 &&
        \\tapEvents.find(e => e.type === 'pointerup').buttons === 0 && tapEvents.find(e => e.type === 'pointerup').pressure === 0 &&
        \\tapEvents.find(e => e.type === 'mousedown').buttons === 1 && tapEvents.find(e => e.type === 'mousedown').detail === 1 &&
        \\tapEvents.find(e => e.type === 'mouseup').buttons === 0 && tapEvents.find(e => e.type === 'click').detail === 1
    , null)).isTrue());
    try testing.expect(frame.page.input_touch_contact == null);
    try testing.expectEqual(@as(u16, 0), frame.page.input_pointer.held);
}

test "cdp.input: touch tap cancellation distinguishes touch pointer and mouse defaults" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\const tapTarget = document.getElementById('chk');
        \\window.preventType = '';
        \\window.tapEvents = [];
        \\for (const type of ['pointerdown', 'pointerup', 'pointercancel', 'touchstart', 'touchmove', 'touchend', 'touchcancel', 'mousemove', 'mousedown', 'mouseup', 'click']) {
        \\  tapTarget.addEventListener(type, e => { tapEvents.push(e.type); if (e.type === preventType) e.preventDefault(); }, {passive: false});
        \\}
    , null);
    const x = try (try ls.local.compileAndRun("tapTarget.getBoundingClientRect().x + 1", null)).toF64();
    const y = try (try ls.local.compileAndRun("tapTarget.getBoundingClientRect().y + 1", null)).toF64();
    const cases = .{
        .{ "touchstart", "!tapTarget.checked && !tapEvents.includes('mousedown') && !tapEvents.includes('click')" },
        .{ "touchmove", "!tapTarget.checked && !tapEvents.includes('mousedown') && !tapEvents.includes('click')" },
        .{ "touchend", "!tapTarget.checked && !tapEvents.includes('mousedown') && !tapEvents.includes('click')" },
        .{ "pointerdown", "tapTarget.checked && tapEvents.includes('click') && !tapEvents.includes('mousedown') && !tapEvents.includes('mouseup') && !tapEvents.includes('mousemove') && document.activeElement.id === 'inp'" },
        .{ "pointerup", "tapTarget.checked && tapEvents.includes('mousedown') && tapEvents.includes('mouseup')" },
        .{ "mousedown", "tapTarget.checked && document.activeElement.id === 'inp'" },
        .{ "click", "!tapTarget.checked && tapEvents.includes('mousedown') && tapEvents.includes('mouseup')" },
        .{ "touchcancel", "!tapTarget.checked && tapEvents.includes('pointercancel') && !tapEvents.includes('pointerup') && !tapEvents.includes('mousedown') && !tapEvents.includes('click')" },
        .{ "", "tapTarget.checked && tapEvents.includes('mousedown') && tapEvents.includes('mouseup') && document.activeElement === tapTarget" },
    };
    inline for (cases) |case| {
        _ = try ls.local.compileAndRun("tapTarget.checked = false; tapEvents = []; document.getElementById('inp').focus(); preventType = '" ++ case[0] ++ "';", null);
        try ctx.processMessage(.{
            .id = 1,
            .method = "Input.dispatchTouchEvent",
            .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = x, .y = y }} },
        });
        if (comptime std.mem.eql(u8, case[0], "touchmove")) {
            try ctx.processMessage(.{
                .id = 2,
                .method = "Input.dispatchTouchEvent",
                .params = .{ .type = "touchMove", .touchPoints = &.{.{ .x = x + 1, .y = y }} },
            });
        }
        try ctx.processMessage(.{
            .id = 3,
            .method = "Input.dispatchTouchEvent",
            .params = .{ .type = if (comptime std.mem.eql(u8, case[0], "touchcancel")) "touchCancel" else "touchEnd", .touchPoints = &.{} },
        });
        const passed = (try ls.local.compileAndRun(case[1], null)).isTrue();
        if (!passed) std.debug.print("failed prevention case: {s}\n", .{case[0]});
        try testing.expect(passed);
        try testing.expect(frame.page.input_touch_contact == null);
    }
}

test "cdp.input: touch pointer retains its target while compatibility events hit test release" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\const startTarget = document.getElementById('btn');
        \\const releaseTarget = document.getElementById('inp');
        \\window.tapEvents = [];
        \\for (const type of ['pointerdown', 'pointermove', 'pointerup', 'touchstart', 'touchmove', 'touchend', 'mousedown', 'mouseup', 'click']) {
        \\  document.addEventListener(type, e => tapEvents.push(e.type + ':' + e.target.id), {passive: false});
        \\}
    , null);
    const x = try (try ls.local.compileAndRun("startTarget.getBoundingClientRect().x + 1", null)).toF64();
    const y = try (try ls.local.compileAndRun("startTarget.getBoundingClientRect().y + 1", null)).toF64();
    const release_x = try (try ls.local.compileAndRun("releaseTarget.getBoundingClientRect().x + 1", null)).toF64();
    const release_y = try (try ls.local.compileAndRun("releaseTarget.getBoundingClientRect().y + 1", null)).toF64();
    try ctx.processMessage(.{
        .id = 1,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = x, .y = y }} },
    });
    try ctx.processMessage(.{
        .id = 2,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{.{ .x = release_x, .y = release_y }} },
    });
    try testing.expect((try ls.local.compileAndRun("tapEvents.join(',') === 'pointerdown:btn,touchstart:btn,pointerup:btn,touchend:btn,mousedown:inp,mouseup:inp,click:inp'", null)).isTrue());

    // A drag retains pointer/touch delivery but must not activate on release.
    _ = try ls.local.compileAndRun("tapEvents = [];", null);
    try ctx.processMessage(.{
        .id = 3,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = x, .y = y }} },
    });
    try ctx.processMessage(.{
        .id = 4,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchMove", .touchPoints = &.{.{ .x = release_x, .y = release_y }} },
    });
    try ctx.processMessage(.{
        .id = 5,
        .method = "Input.dispatchTouchEvent",
        .params = .{ .type = "touchEnd", .touchPoints = &.{} },
    });
    try testing.expect((try ls.local.compileAndRun("tapEvents.join(',') === 'pointerdown:btn,touchstart:btn,pointermove:btn,touchmove:btn,pointerup:btn,touchend:btn'", null)).isTrue());
}

test "cdp.input: passive prevention and finger jitter do not suppress repeated taps" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\const tapTarget = document.getElementById('btn');
        \\window.clickIds = [];
        \\tapTarget.addEventListener('touchstart', e => e.preventDefault(), {passive: true});
        \\tapTarget.addEventListener('click', e => clickIds.push(e.pointerId));
    , null);
    const x = try (try ls.local.compileAndRun("tapTarget.getBoundingClientRect().x + 1", null)).toF64();
    const y = try (try ls.local.compileAndRun("tapTarget.getBoundingClientRect().y + 1", null)).toF64();
    for (0..2) |_| {
        try ctx.processMessage(.{
            .id = 1,
            .method = "Input.dispatchTouchEvent",
            .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = x, .y = y, .id = 2147483647 }} },
        });
        try ctx.processMessage(.{
            .id = 2,
            .method = "Input.dispatchTouchEvent",
            .params = .{ .type = "touchMove", .touchPoints = &.{.{ .x = x + 1, .y = y, .id = 2147483647 }} },
        });
        try ctx.processMessage(.{
            .id = 3,
            .method = "Input.dispatchTouchEvent",
            .params = .{ .type = "touchEnd", .touchPoints = &.{} },
        });
    }
    try testing.expect((try ls.local.compileAndRun("clickIds.join(',') === '2,3'", null)).isTrue());
}

test "cdp.input: touch tap respects disabled controls across compatibility handlers" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const cases = .{
        .{ "t.disabled = true;", "clicks === 0 && !t.checked && !events.includes('mousedown') && !events.includes('mouseup')", 1 },
        .{ "fieldset.disabled = true;", "clicks === 0 && !t.checked", 1 },
        .{ "fieldset.disabled = true; const legend = document.createElement('legend'); fieldset.prepend(legend); legend.append(t);", "clicks === 1 && t.checked", 1 },
        .{ "t.disabled = true; t.addEventListener('pointerdown', e => e.preventDefault());", "clicks === 0 && !t.checked", 1 },
        .{ "t.disabled = true; t.addEventListener('mousemove', () => t.disabled = false);", "clicks === 1 && t.checked", 1 },
        .{ "t.addEventListener('pointerup', () => t.disabled = true);", "clicks === 0 && !t.checked", 1 },
        .{ "t.addEventListener('touchend', () => t.disabled = true);", "clicks === 0 && !t.checked", 1 },
        .{ "t.addEventListener('mouseover', () => t.disabled = true);", "clicks === 0 && !t.checked", 1 },
        .{ "t.addEventListener('mousemove', () => t.disabled = true);", "clicks === 0 && !t.checked", 1 },
        .{ "t.addEventListener('mousedown', () => t.disabled = true);", "clicks === 0 && !t.checked && !events.includes('mouseup')", 1 },
        .{ "t.addEventListener('focus', () => t.disabled = true);", "clicks === 0 && !t.checked", 1 },
        .{ "t.addEventListener('mouseup', () => t.disabled = true);", "clicks === 0 && !t.checked", 1 },
        .{ "t.addEventListener('click', () => t.disabled = true);", "clicks === 1", 2 },
    };
    inline for (cases) |case| {
        _ = try ls.local.compileAndRun(
            \\document.body.innerHTML = '<fieldset id="fieldset"><input id="t" type="checkbox"></fieldset>';
            \\window.t = document.getElementById('t'); window.fieldset = document.getElementById('fieldset');
            \\window.clicks = 0; window.events = [];
            \\t.addEventListener('click', () => clicks++);
            \\for (const type of ['mousemove', 'mousedown', 'mouseup']) t.addEventListener(type, e => events.push(e.type));
        ++ case[0], null);
        const x = try (try ls.local.compileAndRun("t.getBoundingClientRect().x + 1", null)).toF64();
        const y = try (try ls.local.compileAndRun("t.getBoundingClientRect().y + 1", null)).toF64();
        for (0..case[2]) |_| {
            try ctx.processMessage(.{ .id = 1, .method = "Input.dispatchTouchEvent", .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = x, .y = y }} } });
            try ctx.processMessage(.{ .id = 2, .method = "Input.dispatchTouchEvent", .params = .{ .type = "touchEnd", .touchPoints = &.{} } });
        }
        const passed = (try ls.local.compileAndRun(case[1], null)).isTrue();
        if (!passed) std.debug.print("disabled tap case: {s}\n", .{case[0]});
        try testing.expect(passed);
        try testing.expect(frame.page.input_touch_contact == null);
    }
}

test "cdp.input: touch tap revalidates targets between compatibility events" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const cases = .{
        .{ "t.addEventListener('mouseover', replace);", "clicks === 0 && replacementClicks === 1 && ups === 0" },
        .{ "t.addEventListener('mousemove', replace);", "clicks === 0 && replacementClicks === 1 && ups === 0" },
        .{ "t.addEventListener('mousedown', () => t.remove());", "clicks === 0 && replacementClicks === 0 && ups === 0" },
        .{ "t.addEventListener('mousedown', replace);", "clicks === 0 && replacementClicks === 0 && ups === 0" },
        .{ "t.addEventListener('focus', replace);", "clicks === 0 && replacementClicks === 0 && ups === 0" },
        .{ "old.focus(); old.addEventListener('blur', replace);", "clicks === 0 && replacementClicks === 0 && ups === 0" },
        .{ "t.addEventListener('mouseup', () => t.remove());", "clicks === 1 && replacementClicks === 0 && ups === 1" },
        .{ "t.addEventListener('mouseup', replace);", "clicks === 1 && replacementClicks === 0 && ups === 1" },
        .{ "t.addEventListener('mouseup', () => t.style.display = 'none');", "clicks === 1 && ups === 1" },
        .{ "t.addEventListener('mousedown', () => t.style.display = 'none');", "clicks === 0 && ups === 0" },
        .{ "t.addEventListener('mousedown', () => { const b = document.createElement('button'); b.textContent = 'New'; b.addEventListener('click', () => replacementClicks++); t.parentNode.append(b); t.style.display = 'none'; });", "clicks === 0 && replacementClicks === 0 && parentClicks === 1 && ups === 0" },
    };
    inline for (cases) |case| {
        _ = try ls.local.compileAndRun(
            \\document.body.innerHTML = '<input id="old"><div style="height:50px;width:200px"><button id="t">Send</button></div>';
            \\window.t = document.getElementById('t'); window.old = document.getElementById('old');
            \\window.clicks = 0; window.replacementClicks = 0; window.ups = 0; window.parentClicks = 0;
            \\t.addEventListener('click', () => clicks++); t.addEventListener('mouseup', () => ups++);
            \\t.parentNode.addEventListener('click', e => { if (e.target === e.currentTarget) parentClicks++; });
            \\window.replace = () => { const b = document.createElement('button'); b.textContent = 'New'; b.addEventListener('click', () => replacementClicks++); t.replaceWith(b); };
        ++ case[0], null);
        const x = try (try ls.local.compileAndRun("t.getBoundingClientRect().x + 1", null)).toF64();
        const y = try (try ls.local.compileAndRun("t.getBoundingClientRect().y + 1", null)).toF64();
        try ctx.processMessage(.{ .id = 1, .method = "Input.dispatchTouchEvent", .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = x, .y = y }} } });
        try ctx.processMessage(.{ .id = 2, .method = "Input.dispatchTouchEvent", .params = .{ .type = "touchEnd", .touchPoints = &.{} } });
        const passed = (try ls.local.compileAndRun(case[1], null)).isTrue();
        if (!passed) std.debug.print("mutating tap case: {s}\n", .{case[0]});
        try testing.expect(passed);
        try testing.expect(frame.page.input_touch_contact == null);
    }
}

test "cdp.input: touch cancellation retains last contact geometry through pointer leave" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(
        \\window.t = document.getElementById('btn'); window.events = [];
        \\for (const type of ['pointercancel', 'pointerout', 'pointerleave', 'click']) {
        \\  t.addEventListener(type, e => events.push({type: e.type, button: e.button, buttons: e.buttons, width: e.width, height: e.height, pressure: e.pressure, cancelable: e.cancelable, id: e.pointerId}));
        \\}
    , null);
    const x = try (try ls.local.compileAndRun("t.getBoundingClientRect().x + 1", null)).toF64();
    const y = try (try ls.local.compileAndRun("t.getBoundingClientRect().y + 1", null)).toF64();
    try ctx.processMessage(.{ .id = 1, .method = "Input.dispatchTouchEvent", .params = .{ .type = "touchStart", .touchPoints = &.{.{ .x = x, .y = y, .radiusX = 1, .radiusY = 2 }} } });
    try ctx.processMessage(.{ .id = 2, .method = "Input.dispatchTouchEvent", .params = .{ .type = "touchMove", .touchPoints = &.{.{ .x = x + 1, .y = y, .radiusX = 3, .radiusY = 4, .force = 0.7 }} } });
    try ctx.processMessage(.{ .id = 3, .method = "Input.dispatchTouchEvent", .params = .{ .type = "touchCancel", .touchPoints = &.{} } });
    try testing.expect((try ls.local.compileAndRun(
        \\events.map(e => e.type).join(',') === 'pointercancel,pointerout,pointerleave' &&
        \\events.every(e => e.button === -1 && e.buttons === 0 && e.width === 6 && e.height === 8 && e.pressure === 0 && e.id === 2) &&
        \\!events[0].cancelable && events[1].cancelable && !events[2].cancelable
    , null)).isTrue());
    try testing.expect(frame.page.input_touch_contact == null);
}

test "cdp.input: re-navigating an iframe drops the pointer state on its elements" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .url = "cdp/input_iframe.html" });
    const main = bc.mainFrame().?;
    const page = main.page;
    const child = main.child_frames.items[0];
    const text = child.document.getElementById("text", child) orelse unreachable;

    try lp.actions.click(text.asNode(), child);
    try page.input_pointer.press(child, text, .{});
    try testing.expect(page.input_hover_target == text);
    try testing.expect(page.input_pointer.down_target == text);

    var ls: lp.js.Local.Scope = undefined;
    main.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun("document.querySelector('iframe').src = 'iframe/input_child.html?again'", null);
    _ = try bc.session.processQueuedNavigation();

    try testing.expect(page.input_hover_target == null);
    try testing.expect(page.input_pointer.down_target == null);
    try testing.expectEqual(0, page.input_pointer.held);
}

test "cdp.input: mouse activation rechecks disabled state between events" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{});
    const page = try bc.session.createPage();
    const frame = page.frame().?;
    try frame.navigate("http://localhost:9582/src/browser/tests/mcp_actions.html", .{ .reason = .address_bar, .kind = .{ .push = null } });
    try testing.waitForPage(bc);
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const cases = .{
        .{ "t.disabled = true;", "clicks === 0 && !t.checked && events.join(',') === 'pointerdown,pointerup'", 1 },
        .{ "fieldset.disabled = true;", "clicks === 0 && !t.checked", 1 },
        .{ "fieldset.disabled = true; const legend = document.createElement('legend'); fieldset.prepend(legend); legend.append(t);", "clicks === 1 && t.checked", 1 },
        .{ "t.disabled = true; t.addEventListener('pointerdown', e => e.preventDefault());", "clicks === 0 && !t.checked", 1 },
        .{ "t.addEventListener('pointerdown', () => t.disabled = true);", "clicks === 0 && !t.checked && !events.includes('mousedown')", 1 },
        .{ "t.addEventListener('mousedown', () => t.disabled = true);", "clicks === 0 && !t.checked && !events.includes('mouseup')", 1 },
        .{ "t.addEventListener('pointerup', () => t.disabled = true);", "clicks === 0 && !t.checked && !events.includes('mouseup')", 1 },
        .{ "t.addEventListener('mouseup', () => t.disabled = true);", "clicks === 0 && !t.checked", 1 },
        .{ "t.disabled = true; t.addEventListener('pointerdown', () => t.disabled = false);", "clicks === 1 && t.checked && events.includes('mousedown')", 1 },
        .{ "t.disabled = true; t.addEventListener('pointerup', () => t.disabled = false);", "clicks === 1 && t.checked && !events.includes('mousedown') && events.includes('mouseup')", 1 },
        .{ "t.addEventListener('click', () => t.disabled = true);", "clicks === 1", 2 },
    };
    inline for (cases) |case| {
        _ = try ls.local.compileAndRun(
            \\document.body.innerHTML = '<fieldset id="fieldset"><input id="t" type="checkbox"></fieldset>';
            \\window.t = document.getElementById('t'); window.fieldset = document.getElementById('fieldset');
            \\window.clicks = 0; window.events = [];
            \\t.addEventListener('click', () => clicks++);
            \\for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) t.addEventListener(type, e => events.push(e.type));
        ++ case[0], null);
        const x = try (try ls.local.compileAndRun("t.getBoundingClientRect().x + 1", null)).toF64();
        const y = try (try ls.local.compileAndRun("t.getBoundingClientRect().y + 1", null)).toF64();
        for (0..case[2]) |_| {
            try ctx.processMessage(.{ .id = 1, .method = "Input.dispatchMouseEvent", .params = .{ .type = "mousePressed", .x = x, .y = y, .button = "left", .clickCount = 1 } });
            try ctx.processMessage(.{ .id = 2, .method = "Input.dispatchMouseEvent", .params = .{ .type = "mouseReleased", .x = x, .y = y, .button = "left", .clickCount = 1 } });
        }
        const passed = (try ls.local.compileAndRun(case[1], null)).isTrue();
        if (!passed) std.debug.print("disabled mouse case: {s}\n", .{case[0]});
        try testing.expect(passed);
        try testing.expectEqual(@as(u16, 0), frame.page.input_pointer.held);
        try testing.expect(frame.page.input_pointer.down_target == null);
    }
    // Explicit script dispatch is not trusted input and must still reach listeners.
    try testing.expect((try ls.local.compileAndRun("t.disabled = true; clicks = 0; t.dispatchEvent(new MouseEvent('click')); clicks === 1", null)).isTrue());
}
