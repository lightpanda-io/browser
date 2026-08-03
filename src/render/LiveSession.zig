// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.

//! Worker-owned state for a bounded interactive render snapshot.

const std = @import("std");
const lp = @import("lightpanda");
const Node = @import("../browser/webapi/Node.zig");

const LiveSession = @This();

pub const idle_timeout_ms = 5 * 60 * 1000;

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
targets: std.ArrayListUnmanaged(*Node.Element) = .empty,
token: [16]u8 = undefined,
version: u64 = 0,
dom_version: usize = 0,
last_activity_ms: u64 = 0,

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
    const frame = page.frame() orelse {
        self.close();
        return error.StaleSnapshot;
    };
    if (!target.asNode().isConnected() or !lp.dump.isLiveTarget(target, frame)) {
        self.close();
        return error.StaleSnapshot;
    }

    lp.actions.click(target.asNode(), frame) catch |err| {
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
    self.targets.clearRetainingCapacity();
    errdefer self.targets.clearRetainingCapacity();

    var targets: lp.dump.LiveTargets = .{
        .elements = &self.targets,
        .allocator = self.allocator,
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
    try testing.expectEqual(@as(usize, 1), live.targets.items.len);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "data-lp-live-target=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), ">before<") != null);
    try testing.expect(std.mem.indexOf(u8, opened.written(), "<script") == null);

    const token = live.tokenText();
    var activated: std.Io.Writer.Allocating = .init(testing.test_app.allocator);
    defer activated.deinit();
    try live.activate(token[0..], live.version, 0, 2_000, &activated.writer);
    try testing.expectEqual(@as(u64, 2), live.version);
    try testing.expect(std.mem.indexOf(u8, activated.written(), ">after<") != null);
    try testing.expectEqual(@as(usize, 1), live.targets.items.len);
    try live.closeForToken(token[0..]);
    try testing.expect(!live.isActive());
    try testing.expectEqual(@as(usize, 0), live.targets.capacity);

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
