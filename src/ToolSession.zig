// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

//! An isolated browsing context driven through `lp.tools`: its own Browser
//! (hence V8 isolate), Session, Notification and node Registry. `self` must
//! not move after `init` — Browser registers self-pointers.

const App = @import("App.zig");
const Browser = @import("browser/Browser.zig");
const Session = @import("browser/Session.zig");
const Notification = @import("Notification.zig");
const CDPNode = @import("cdp/Node.zig");

const ToolSession = @This();

browser: Browser,
session: *Session,
notification: *Notification,
registry: CDPNode.Registry,

/// Leaves the browser's isolate entered, like `Browser.init`; callers
/// sharing one thread between several isolates park it with
/// `exitIsolate` afterwards.
pub fn init(self: *ToolSession, app: *App) !void {
    self.notification = try .init(app.allocator);
    errdefer self.notification.deinit();

    self.registry = .init(app.allocator);
    errdefer self.registry.deinit();

    try self.browser.init(app, .{}, null);
    errdefer self.browser.deinit();

    try self.restartSession();
}

/// Replace the session with a fresh one on the same browser: page, cookies,
/// storage and history gone. The old `session` pointer is invalid afterwards.
pub fn restartSession(self: *ToolSession) !void {
    self.session = try self.browser.newSession(self.notification);
    try self.session.enableConsoleCapture();
}

/// The isolate must be current (`enterIsolate` if parked): Browser.deinit's
/// Env.deinit exit has to balance against this context's isolate.
pub fn deinit(self: *ToolSession) void {
    self.registry.deinit();
    self.browser.deinit();
    self.notification.deinit();
}

/// V8's "current isolate" is a per-thread stack: when several contexts
/// share a thread, bracket any use of the Browser/Session with
/// enterIsolate/exitIsolate and leave it un-entered otherwise.
pub fn enterIsolate(self: *ToolSession) void {
    self.browser.env.isolate.enter();
}

pub fn exitIsolate(self: *ToolSession) void {
    self.browser.env.isolate.exit();
}

const tools = @import("browser/tools.zig");
const testing = @import("testing.zig");

test "ToolSession: isolates interleave on one thread and tear down balanced" {
    const arena = testing.arena_allocator;

    var a: ToolSession = undefined;
    try a.init(testing.test_app);
    try loadBlank(&a);
    a.exitIsolate();

    var b: ToolSession = undefined;
    try b.init(testing.test_app);
    try loadBlank(&b);
    b.exitIsolate();

    a.enterIsolate();
    try testing.expectEqual("a", (try tools.evalScript(arena, a.session, &a.registry, "globalThis.tag = 'a'")).text);
    a.exitIsolate();

    b.enterIsolate();
    try testing.expectEqual("undefined", (try tools.evalScript(arena, b.session, &b.registry, "String(globalThis.tag)")).text);
    b.exitIsolate();

    a.enterIsolate();
    try testing.expectEqual("a", (try tools.evalScript(arena, a.session, &a.registry, "globalThis.tag")).text);
    a.deinit();

    b.enterIsolate();
    b.deinit();
}

fn loadBlank(ts: *ToolSession) !void {
    const page = try ts.session.createPage();
    try page.navigate("about:blank", .{});
    var runner = ts.session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });
}
