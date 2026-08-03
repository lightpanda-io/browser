// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

//! Worker-owned state for a bounded interactive render snapshot.

const std = @import("std");
const lp = @import("lightpanda");
const js = @import("../browser/js/js.zig");
const Node = @import("../browser/webapi/Node.zig");

const LiveSession = @This();

pub const idle_timeout_ms = 5 * 60 * 1000;
pub const max_value_bytes = 2_048;
pub const max_value_updates = 256;
pub const max_value_update_bytes = 256 * 1024;

pub const OpenOpts = struct {
    url: [:0]const u8,
    width: u32,
    height: u32,
    wait_ms: u32,
};

allocator: std.mem.Allocator,
browser: *lp.Browser,
notification: ?*lp.Notification = null,
page: ?lp.Session.PageHandle = null,
snapshot_page: ?*lp.Page = null,
targets: std.ArrayListUnmanaged(lp.dump.LiveTargets.Target) = .empty,
token: [16]u8 = undefined,
version: u64 = 0,
dom_version: usize = 0,
last_activity_ms: u64 = 0,
value_updates: usize = 0,
value_update_bytes: usize = 0,

pub fn init(allocator: std.mem.Allocator, browser: *lp.Browser) LiveSession {
    return .{ .allocator = allocator, .browser = browser };
}

pub fn deinit(self: *LiveSession) void {
    self.close();
    self.targets.deinit(self.allocator);
}

pub fn isActive(self: *const LiveSession) bool {
    return self.page != null;
}

pub fn idleWaitMs(self: *const LiveSession) u64 {
    return self.idleWaitMsAt(lp.datetime.milliTimestamp(.boot));
}

pub fn idleWaitMsAt(self: *const LiveSession, now_ms: u64) u64 {
    if (!self.isActive()) return 0;
    const elapsed = now_ms -| self.last_activity_ms;
    return idle_timeout_ms -| elapsed;
}

pub fn tokenText(self: *const LiveSession) [32]u8 {
    return std.fmt.bytesToHex(self.token, .lower);
}

pub fn open(self: *LiveSession, opts: OpenOpts, writer: *std.Io.Writer) !void {
    if (self.isActive()) return error.LiveSessionActive;

    self.browser.viewport_override = .{ .width = opts.width, .height = opts.height };
    const notification = try lp.Notification.init(self.allocator);
    errdefer notification.deinit();

    const session = try self.browser.newSession(notification);
    errdefer self.browser.closeSession();

    if (self.browser.app.config.cookieFile()) |cookie_path| {
        lp.cookies.loadFromFile(session, cookie_path);
    }

    const page = try session.createPage();
    const frame = page.frame() orelse return error.FrameNotLoaded;
    const url = try lp.URL.resolveNavigation(frame.call_arena, opts.url, .{});
    try frame.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } });

    var runner = session.runner(.{});
    try runner.waitForFrame(page.frame_id, opts.wait_ms, .{ .until = .domcontentloaded });

    self.notification = notification;
    self.page = page;
    errdefer {
        self.notification = null;
        self.page = null;
        self.snapshot_page = null;
        self.targets.deinit(self.allocator);
        self.targets = .empty;
    }
    lp.io.random(&self.token);
    self.version = 0;
    self.dom_version = 0;
    self.value_updates = 0;
    self.value_update_bytes = 0;
    try self.snapshot(writer);
    self.last_activity_ms = lp.datetime.milliTimestamp(.boot);
}

pub fn activate(
    self: *LiveSession,
    session_token: []const u8,
    expected_version: u64,
    target_index: usize,
    wait_ms: u32,
    writer: *std.Io.Writer,
) !void {
    if (!self.isActive() or !self.matchesToken(session_token)) return error.InvalidSession;
    if (expected_version != self.version) {
        self.close();
        return error.StaleSnapshot;
    }

    const page = self.page.?;
    const current_page = page.page() orelse {
        self.close();
        return error.StaleSnapshot;
    };
    const snapshot_page = self.snapshot_page orelse {
        self.close();
        return error.StaleSnapshot;
    };
    if (current_page != snapshot_page or current_page.dom_version != self.dom_version) {
        self.close();
        return error.StaleSnapshot;
    }
    if (target_index >= self.targets.items.len) return error.UnsupportedTarget;

    const target = self.targets.items[target_index];
    if (target.kind != .activate) return error.UnsupportedTarget;
    const frame = page.frame() orelse {
        self.close();
        return error.StaleSnapshot;
    };
    const target_arena = frame.getArena(.small, "render-live-targets") catch |err| {
        self.close();
        return err;
    };
    defer target_arena.release();
    const listener_targets = lp.interactive.buildListenerTargetMap(frame, target_arena.allocator()) catch |err| {
        self.close();
        return err;
    };
    const valid_target = lp.dump.isLiveTarget(target.element, frame, listener_targets) catch |err| {
        self.close();
        return err;
    };
    if (!target.element.asNode().isConnected() or !valid_target) {
        self.close();
        return error.StaleSnapshot;
    }

    lp.actions.click(target.element.asNode(), frame) catch |err| {
        self.close();
        return err;
    };
    var runner = page.session.runner(.{});
    runner.waitForFrame(page.frame_id, wait_ms, .{ .until = .domcontentloaded }) catch |err| {
        self.close();
        return err;
    };

    self.snapshot(writer) catch |err| {
        self.close();
        return err;
    };
    self.last_activity_ms = lp.datetime.milliTimestamp(.boot);
}

pub fn setValue(
    self: *LiveSession,
    session_token: []const u8,
    expected_version: u64,
    target_index: usize,
    value: []const u8,
    selected_index: ?u32,
    wait_ms: u32,
    writer: *std.Io.Writer,
) !void {
    if (!self.isActive() or !self.matchesToken(session_token)) return error.InvalidSession;
    if (expected_version != self.version) {
        self.close();
        return error.StaleSnapshot;
    }
    if (value.len > max_value_bytes or !std.unicode.utf8ValidateSlice(value) or
        self.value_updates >= max_value_updates or
        value.len > max_value_update_bytes -| self.value_update_bytes)
    {
        self.close();
        return error.ValueLimit;
    }

    const page = self.page.?;
    const current_page = page.page() orelse {
        self.close();
        return error.StaleSnapshot;
    };
    const snapshot_page = self.snapshot_page orelse {
        self.close();
        return error.StaleSnapshot;
    };
    if (current_page != snapshot_page or current_page.dom_version != self.dom_version) {
        self.close();
        return error.StaleSnapshot;
    }
    if (target_index >= self.targets.items.len) return error.UnsupportedTarget;

    const target = self.targets.items[target_index];
    if (target.kind != .value) return error.UnsupportedTarget;
    const frame = page.frame() orelse {
        self.close();
        return error.StaleSnapshot;
    };
    if (!target.element.asNode().isConnected() or !lp.dump.isLiveValueTarget(target.element)) {
        self.close();
        return error.StaleSnapshot;
    }
    const select = target.element.is(Node.Element.Html.Select);
    if (select) |select_element| {
        const index = selected_index orelse return error.UnsupportedTarget;
        if (!try validSelectValue(select_element, index, value, frame)) return error.UnsupportedTarget;
    } else if (selected_index != null) {
        return error.UnsupportedTarget;
    }

    target.element.focus(frame) catch |err| {
        self.close();
        return err;
    };
    const focused_page = page.page() orelse {
        self.close();
        return error.StaleSnapshot;
    };
    if (focused_page != snapshot_page or focused_page.dom_version != self.dom_version or
        page.inCommit() or frame._queued_navigation != null or
        !target.element.asNode().isConnected() or !lp.dump.isLiveValueTarget(target.element))
    {
        self.close();
        return error.StaleSnapshot;
    }
    if (select) |select_element| {
        if (!try validSelectValue(select_element, selected_index.?, value, frame)) {
            self.close();
            return error.StaleSnapshot;
        }
    }

    self.value_updates += 1;
    self.value_update_bytes += value.len;
    if (select != null) {
        lp.actions.selectOptionAtIndexWithoutFocus(target.element.asNode(), selected_index.?, frame) catch |err| {
            self.close();
            return err;
        };
    } else {
        lp.actions.fillWithoutFocus(target.element.asNode(), value, frame) catch |err| {
            self.close();
            return err;
        };
    }

    var runner = page.session.runner(.{});
    runner.waitForFrame(page.frame_id, wait_ms, .{ .until = .domcontentloaded }) catch |err| {
        self.close();
        return err;
    };
    self.snapshot(writer) catch |err| {
        self.close();
        return err;
    };
    self.last_activity_ms = lp.datetime.milliTimestamp(.boot);
}

fn validSelectValue(
    select: *Node.Element.Html.Select,
    selected_index: u32,
    value: []const u8,
    frame: *lp.Frame,
) !bool {
    const options = try select.getOptions(frame);
    const option_element = options.getAtIndex(selected_index, frame) orelse return false;
    const option = option_element.is(Node.Element.Html.Option) orelse return false;
    return !option_element.isDisabled() and std.mem.eql(u8, option.getValue(frame), value);
}

pub fn closeForToken(self: *LiveSession, session_token: []const u8) !void {
    if (!self.isActive() or !self.matchesToken(session_token)) return error.InvalidSession;
    self.close();
}

pub fn close(self: *LiveSession) void {
    const page = self.page;
    self.targets.deinit(self.allocator);
    self.targets = .empty;
    self.page = null;
    self.snapshot_page = null;
    self.version = 0;
    self.dom_version = 0;
    self.last_activity_ms = 0;
    self.value_updates = 0;
    self.value_update_bytes = 0;

    if (self.notification) |notification| {
        if (page) |active_page| {
            if (self.browser.app.config.cookieJarFile()) |cookie_jar_path| {
                lp.cookies.saveToFile(&active_page.session.cookie_jar, cookie_jar_path);
            }
        }
        self.notification = null;
        self.browser.closeSession();
        notification.deinit();
    }
}

fn snapshot(self: *LiveSession, writer: *std.Io.Writer) !void {
    const page = self.page orelse return error.FrameNotLoaded;
    const frame = page.frame() orelse return error.FrameNotLoaded;
    const target_arena = try frame.getArena(.small, "render-live-targets");
    defer target_arena.release();
    self.targets.clearRetainingCapacity();
    errdefer self.targets.clearRetainingCapacity();

    var targets: lp.dump.LiveTargets = .{
        .elements = &self.targets,
        .allocator = self.allocator,
        .listener_targets = try lp.interactive.buildListenerTargetMap(frame, target_arena.allocator()),
    };
    try lp.dump.root(frame.window._document, .{
        .with_base = true,
        .with_frames = false,
        .strip = .{ .js = true },
        .live_targets = &targets,
        .strip_refresh = true,
    }, writer, frame);

    self.snapshot_page = page.page() orelse return error.FrameNotLoaded;
    self.dom_version = self.snapshot_page.?.dom_version;
    self.version +%= 1;
}

fn matchesToken(self: *const LiveSession, candidate: []const u8) bool {
    if (candidate.len != 32) return false;
    const expected = self.tokenText();
    var difference: u8 = 0;
    for (candidate, expected) |actual, wanted| difference |= actual ^ wanted;
    return difference == 0;
}

const testing = @import("../testing.zig");

test "LiveSession: opaque token is 128-bit lowercase hex" {
    var token: [16]u8 = undefined;
    for (&token, 0..) |*byte, i| byte.* = @intCast(i);

    const live: LiveSession = .{
        .allocator = std.testing.allocator,
        .browser = undefined,
        .token = token,
    };
    const text = live.tokenText();
    try std.testing.expectEqualStrings("000102030405060708090a0b0c0d0e0f", &text);
}

const LiveSessionTestResult = struct {
    err: ?anyerror = null,
};

fn runLiveSessionRoundTrip(result: *LiveSessionTestResult) void {
    liveSessionRoundTrip() catch |err| {
        result.err = err;
    };
}

fn liveSessionRoundTrip() !void {
    var browser: lp.Browser = undefined;
    try browser.init(testing.test_app, .{}, null);
    defer browser.deinit();

    var live = LiveSession.init(testing.test_app.allocator, &browser);
    defer live.deinit();

    const button_url: [:0]const u8 = "http://127.0.0.1:9582/src/browser/tests/render_live.html";
    const nav_url: [:0]const u8 = "http://127.0.0.1:9582/src/browser/tests/mcp_nav.html";
    var opened: std.Io.Writer.Allocating = .init(testing.test_app.allocator);
    defer opened.deinit();
    try live.open(.{ .url = button_url, .width = 640, .height = 480, .wait_ms = 2_000 }, &opened.writer);
    try testing.expect(live.isActive());
    try testing.expectEqual(@as(u64, 1), live.version);
    try testing.expectEqual(@as(usize, 13), live.targets.items.len);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<input id=\"toggle\" type=\"checkbox\" checked data-lp-live-target=\"1\" data-lp-live-kind=\"activate\">") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<input id=\"disabled\" type=\"checkbox\" disabled>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<input id=\"text\" value=\"input-before\" data-lp-live-target=\"4\" data-lp-live-kind=\"value\">") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<input id=\"file\" type=\"file\">") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<input id=\"submit\" type=\"submit\">") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<select id=\"select\" data-lp-live-target=\"5\" data-lp-live-kind=\"value\">") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<textarea id=\"textarea\" data-lp-live-target=\"6\" data-lp-live-kind=\"value\">textarea-before</textarea>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<input id=\"focus-invalidated\" value=\"focus-before\" data-lp-live-target=\"7\" data-lp-live-kind=\"value\">") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<input id=\"password\" type=\"password\">") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "current-secret") == null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<input id=\"readonly\" value=\"readonly\" readonly>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<textarea id=\"readonly-textarea\" readonly>readonly</textarea>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<select id=\"multiple-select\" multiple>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"editable\" contenteditable=\"\">editable</div>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "data-lp-live-target=\"8\" data-lp-live-kind=\"activate\">listener</div>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "data-lp-live-target=\"9\" data-lp-live-kind=\"activate\">inline</div>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "data-lp-live-target=\"10\" data-lp-live-kind=\"activate\">anchor</a>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "data-lp-live-target=\"11\" data-lp-live-kind=\"activate\">button</button>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "data-lp-live-target=\"12\" data-lp-live-kind=\"activate\">") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<span id=\"submit-script-child\" onclick=") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<label id=\"label-submit-script\" for=\"label-submit-control\" onclick=") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<input id=\"file-script\" type=\"file\" onclick=") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"delegated-update\">delegated</div>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<button id=\"disabled-script\" disabled onclick=") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"blocked-script\" style=\"pointer-events: none\" onclick=") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"hidden-listener\" hidden>hidden</div>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"visibility-hidden\" style=\"visibility: hidden\" onclick=") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"visibility-hidden-ancestor\" onclick=") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"display-hidden-ancestor\" onclick=") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"removed-listener\">removed</div>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"non-click-listener\">non-click</div>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<div id=\"uppercase-listener\">uppercase</div>") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), ">before<") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<script") == null);

    const token = live.tokenText();
    var activated: std.Io.Writer.Allocating = .init(testing.test_app.allocator);
    defer activated.deinit();
    try testing.expectError(error.UnsupportedTarget, live.activate(token[0..], live.version, 4, 2_000, &activated.writer));
    try testing.expect(live.isActive());
    try testing.expectError(error.UnsupportedTarget, live.setValue(token[0..], live.version, 0, "wrong", null, 2_000, &activated.writer));
    try testing.expect(live.isActive());
    try live.setValue(token[0..], live.version, 4, "input-after", null, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 2), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "<input id=\"text\" data-events=\"input,change\" value=\"input-after\" data-lp-live-target=\"4\" data-lp-live-kind=\"value\">") != null);

    activated.clearRetainingCapacity();
    try live.setValue(token[0..], live.version, 6, "textarea-after", null, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 3), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "data-events=\"input,change\" data-lp-live-target=\"6\" data-lp-live-kind=\"value\">textarea-after</textarea>") != null);

    activated.clearRetainingCapacity();
    try testing.expectError(error.UnsupportedTarget, live.setValue(token[0..], live.version, 5, "two", null, 2_000, &activated.writer));
    try testing.expectError(error.UnsupportedTarget, live.setValue(token[0..], live.version, 5, "one", 2, 2_000, &activated.writer));
    try testing.expect(live.isActive());
    try live.setValue(token[0..], live.version, 5, "two", 2, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 4), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "<option id=\"option-two-a\" value=\"two\">two-a</option>") != null);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "<option id=\"option-two-b\" value=\"two\" selected>two-b</option>") != null);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "<select id=\"select\" data-events=\"input,change\" data-lp-live-target=\"5\" data-lp-live-kind=\"value\">") != null);

    activated.clearRetainingCapacity();
    try live.activate(token[0..], live.version, 1, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 5), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "<input id=\"toggle\" type=\"checkbox\" data-lp-live-target=\"1\" data-lp-live-kind=\"activate\">") != null);
    try testing.expectEqual(@as(usize, 13), live.targets.items.len);

    activated.clearRetainingCapacity();
    try live.activate(token[0..], live.version, 3, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 6), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "<input id=\"radio-a\" type=\"radio\" name=\"choice\" data-lp-live-target=\"2\" data-lp-live-kind=\"activate\">") != null);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "<input id=\"radio-b\" type=\"radio\" name=\"choice\" checked data-lp-live-target=\"3\" data-lp-live-kind=\"activate\">") != null);

    activated.clearRetainingCapacity();
    try live.activate(token[0..], live.version, 0, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 7), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), ">after<") != null);

    activated.clearRetainingCapacity();
    try live.activate(token[0..], live.version, 8, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 8), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), ">listener<") != null);

    activated.clearRetainingCapacity();
    try live.activate(token[0..], live.version, 9, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 9), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), ">inline<") != null);

    activated.clearRetainingCapacity();
    try live.activate(token[0..], live.version, 10, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 10), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), ">anchor<") != null);

    activated.clearRetainingCapacity();
    try live.activate(token[0..], live.version, 11, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 11), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), ">button<") != null);

    activated.clearRetainingCapacity();
    try live.activate(token[0..], live.version, 12, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 12), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), ">input<") != null);
    try live.closeForToken(token[0..]);
    try testing.expect(!live.isActive());
    try testing.expectEqual(@as(usize, 0), live.targets.capacity);

    activated.clearRetainingCapacity();
    try live.open(.{ .url = button_url, .width = 640, .height = 480, .wait_ms = 2_000 }, &activated.writer);
    const navigation_token = live.tokenText();
    activated.clearRetainingCapacity();
    try live.setValue(navigation_token[0..], live.version, 4, "navigate", null, 2_000, &activated.writer);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "<base href=\"http://127.0.0.1:9582/src/browser/tests/mcp_nav.html\">") != null);
    try testing.expectEqual(@as(usize, 1), live.targets.items.len);
    try live.closeForToken(navigation_token[0..]);

    activated.clearRetainingCapacity();
    try live.open(.{ .url = button_url, .width = 640, .height = 480, .wait_ms = 2_000 }, &activated.writer);
    const focus_token = live.tokenText();
    try testing.expectError(error.StaleSnapshot, live.setValue(focus_token[0..], live.version, 7, "focus-after", null, 2_000, &opened.writer));
    try testing.expect(!live.isActive());

    activated.clearRetainingCapacity();
    try live.open(.{ .url = button_url, .width = 640, .height = 480, .wait_ms = 2_000 }, &activated.writer);
    const limit_token = live.tokenText();
    live.value_updates = max_value_updates;
    try testing.expectError(error.ValueLimit, live.setValue(limit_token[0..], live.version, 4, "", null, 2_000, &opened.writer));
    try testing.expect(!live.isActive());

    activated.clearRetainingCapacity();
    try live.open(.{ .url = button_url, .width = 640, .height = 480, .wait_ms = 2_000 }, &activated.writer);
    const byte_limit_token = live.tokenText();
    live.value_update_bytes = max_value_update_bytes;
    try testing.expectError(error.ValueLimit, live.setValue(byte_limit_token[0..], live.version, 4, "x", null, 2_000, &opened.writer));
    try testing.expect(!live.isActive());

    activated.clearRetainingCapacity();
    try live.open(.{ .url = button_url, .width = 640, .height = 480, .wait_ms = 2_000 }, &activated.writer);
    const size_limit_token = live.tokenText();
    var oversized_value: [max_value_bytes + 1]u8 = undefined;
    @memset(&oversized_value, 'x');
    try testing.expectError(error.ValueLimit, live.setValue(size_limit_token[0..], live.version, 4, &oversized_value, null, 2_000, &opened.writer));
    try testing.expect(!live.isActive());

    activated.clearRetainingCapacity();
    try live.open(.{ .url = button_url, .width = 640, .height = 480, .wait_ms = 2_000 }, &activated.writer);
    const value_stale_token = live.tokenText();
    try testing.expectError(error.StaleSnapshot, live.setValue(value_stale_token[0..], 0, 4, "stale", null, 2_000, &opened.writer));
    try testing.expect(!live.isActive());

    activated.clearRetainingCapacity();
    try live.open(.{ .url = button_url, .width = 640, .height = 480, .wait_ms = 2_000 }, &activated.writer);
    const stale_token = live.tokenText();
    const stale_frame = live.page.?.frame().?;
    const stale_dom_version = stale_frame._page.dom_version;
    {
        var ls: js.Local.Scope = undefined;
        stale_frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec("window.removeLiveListener()", null);
    }
    try testing.expectEqual(stale_dom_version, stale_frame._page.dom_version);
    try testing.expectError(error.StaleSnapshot, live.activate(stale_token[0..], live.version, 8, 2_000, &opened.writer));
    try testing.expect(!live.isActive());

    var reopened: std.Io.Writer.Allocating = .init(testing.test_app.allocator);
    defer reopened.deinit();
    try live.open(.{ .url = nav_url, .width = 640, .height = 480, .wait_ms = 2_000 }, &reopened.writer);
    const retry_token = live.tokenText();
    var wrong_token = retry_token;
    wrong_token[0] = if (wrong_token[0] == '0') '1' else '0';
    try testing.expectError(error.InvalidSession, live.activate(wrong_token[0..], live.version, 0, 2_000, &activated.writer));
    try testing.expect(live.isActive());
    activated.clearRetainingCapacity();
    try live.activate(retry_token[0..], live.version, 0, 2_000, &activated.writer);
    try testing.expect(std.mem.indexOf(u8, activated.written(), "<base href=\"about:blank\">") != null);
    try testing.expectEqual(@as(usize, 0), live.targets.items.len);
    try testing.expectError(error.StaleSnapshot, live.activate(retry_token[0..], 1, 0, 2_000, &activated.writer));
    try testing.expect(!live.isActive());
    try testing.expectEqual(@as(usize, 0), live.targets.capacity);
}

test "LiveSession: worker-owned page opens activates and closes" {
    var result: LiveSessionTestResult = .{};
    const thread = try std.Thread.spawn(.{}, runLiveSessionRoundTrip, .{&result});
    thread.join();
    if (result.err) |err| return err;
}
