// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const EventTarget = @import("EventTarget.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const Notification = @This();

_rc: lp.RC = .{},
_arena: Allocator,
_proto: *EventTarget,
_title: []const u8,
_body: []const u8 = "",
_icon: []const u8 = "",
_image: []const u8 = "",
_badge: []const u8 = "",
_tag: []const u8 = "",
_lang: []const u8 = "",
_dir: []const u8 = "auto",
_silent: bool = false,
_require_interaction: bool = false,
_renotify: bool = false,

const Options = struct {
    body: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    image: ?[]const u8 = null,
    badge: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    silent: ?bool = null,
    requireInteraction: ?bool = null,
    renotify: ?bool = null,
};

pub fn init(title: []const u8, options_: ?Options, exec: *const Execution) !*Notification {
    const arena = try exec.getArena(.small, "Notification");
    errdefer exec.releaseArena(arena);

    const options = options_ orelse Options{};
    return exec._factory.eventTargetWithAllocator(arena, Notification{
        ._arena = arena,
        ._proto = undefined,
        ._title = try arena.dupe(u8, title),
        ._body = if (options.body) |v| try arena.dupe(u8, v) else "",
        ._icon = if (options.icon) |v| try arena.dupe(u8, v) else "",
        ._image = if (options.image) |v| try arena.dupe(u8, v) else "",
        ._badge = if (options.badge) |v| try arena.dupe(u8, v) else "",
        ._tag = if (options.tag) |v| try arena.dupe(u8, v) else "",
        ._lang = if (options.lang) |v| try arena.dupe(u8, v) else "",
        ._dir = if (options.dir) |d| try arena.dupe(u8, d) else "auto",
        ._silent = options.silent orelse false,
        ._require_interaction = options.requireInteraction orelse false,
        ._renotify = options.renotify orelse false,
    });
}

pub fn deinit(self: *Notification, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *Notification, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *Notification) void {
    self._rc.acquire();
}

pub fn close(_: *Notification) void {}

fn getPermission() []const u8 {
    return "default";
}

fn getMaxActions() u32 {
    return 2;
}

fn requestPermission(_: ?js.Function, exec: *const Execution) !js.Promise {
    return exec.js.local.?.resolvePromise("default");
}

fn getTitle(self: *const Notification) []const u8 {
    return self._title;
}
fn getBody(self: *const Notification) []const u8 {
    return self._body;
}
fn getIcon(self: *const Notification) []const u8 {
    return self._icon;
}
fn getImage(self: *const Notification) []const u8 {
    return self._image;
}
fn getBadge(self: *const Notification) []const u8 {
    return self._badge;
}
fn getTag(self: *const Notification) []const u8 {
    return self._tag;
}
fn getLang(self: *const Notification) []const u8 {
    return self._lang;
}
fn getDir(self: *const Notification) []const u8 {
    return self._dir;
}
fn getSilent(self: *const Notification) bool {
    return self._silent;
}
fn getRequireInteraction(self: *const Notification) bool {
    return self._require_interaction;
}
fn getRenotify(self: *const Notification) bool {
    return self._renotify;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Notification);

    pub const Meta = struct {
        pub const name = "Notification";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Notification.init, .{});

    pub const permission = bridge.accessor(getPermission, null, .{ .static = true });
    pub const maxActions = bridge.accessor(getMaxActions, null, .{ .static = true });
    pub const requestPermission = bridge.function(Notification.requestPermission, .{ .static = true });

    pub const close = bridge.function(Notification.close, .{ .noop = true });

    pub const title = bridge.accessor(getTitle, null, .{});
    pub const body = bridge.accessor(getBody, null, .{});
    pub const icon = bridge.accessor(getIcon, null, .{});
    pub const image = bridge.accessor(getImage, null, .{});
    pub const badge = bridge.accessor(getBadge, null, .{});
    pub const tag = bridge.accessor(getTag, null, .{});
    pub const lang = bridge.accessor(getLang, null, .{});
    pub const dir = bridge.accessor(getDir, null, .{});
    pub const silent = bridge.accessor(getSilent, null, .{});
    pub const requireInteraction = bridge.accessor(getRequireInteraction, null, .{});
    pub const renotify = bridge.accessor(getRenotify, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Notification" {
    try testing.htmlRunner("notification.html", .{});
}
