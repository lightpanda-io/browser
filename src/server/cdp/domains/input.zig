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

const dom_button = Frame.user_input.mouse_button;

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

    // rawKeyDown is a Chrome-internal event type not used for JS dispatch
    if (params.type == .rawKeyDown) return;

    const bc = cmd.browser_context orelse return;
    const frame = bc.mainFrame() orelse return;

    // Chrome types text only for an event carrying it: a keyDown with `text`
    // (Puppeteer, Playwright) or a `char` (chromedp, after a text-less keyDown).
    const text: ?[]const u8 = if (params.text.len == 0) null else params.text;
    const KeyboardEvent = @import("../../../browser/webapi/event/KeyboardEvent.zig");
    const opts: KeyboardEvent.Options = .{
        .key = if (params.key.len > 0) params.key else params.text,
        .code = params.code,
        .altKey = params.modifiers & 1 == 1,
        .ctrlKey = params.modifiers & 2 == 2,
        .metaKey = params.modifiers & 4 == 4,
        .shiftKey = params.modifiers & 8 == 8,
    };

    switch (params.type) {
        .rawKeyDown => unreachable,
        .keyDown => {
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

// https://chromedevtools.github.io/devtools-protocol/tot/Input/#method-insertText
fn insertText(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        text: []const u8, // The text to insert
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return;
    const frame = bc.mainFrame() orelse return;

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

// Asserts only the pointer events: pointerdown/pointerup fire at the mask's
// 0/nonzero transitions and a mid-gesture button change is a pointermove (the
// activation order below is a pre-existing, non-spec deviation from Chrome).
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
        \\  'pointerdown:1', 'pointermove:3', 'pointermove:1', 'contextmenu:1', 'pointerup:0', 'click:0'
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
        \\  'pointerdown:1', 'pointermove:3', 'pointermove:2', 'click:2', 'pointerup:0', 'contextmenu:0'
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
    , null);
    try ctx.processMessage(.{ .id = 6, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyDown", .key = "Enter", .code = "Enter" } });
    try ctx.expectSentResult(null, .{ .id = 6 });
    try ctx.processMessage(.{ .id = 7, .method = "Input.dispatchKeyEvent", .params = .{ .type = "char", .key = "Enter", .text = "\r" } });
    try ctx.expectSentResult(null, .{ .id = 7 });
    try ctx.processMessage(.{ .id = 8, .method = "Input.dispatchKeyEvent", .params = .{ .type = "keyUp", .key = "Enter", .code = "Enter" } });
    try ctx.expectSentResult(null, .{ .id = 8 });
    try testing.expect((try ls.local.compileAndRun("ta.value === 'one\\n'", null)).isTrue());
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
        _ = try ls.local.compileAndRun(try std.fmt.bufPrint(&buf, "arm('{s}')", .{c.id}), null);

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
