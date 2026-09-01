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

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const EventTarget = @import("../EventTarget.zig");
const MediaQuery = @import("../../css/MediaQuery.zig");
const MediaQueryListEvent = @import("../event/MediaQueryListEvent.zig");

const log = lp.log;

const MediaQueryList = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_media: []const u8,
_frame: *Frame,
_exec: *const js.Execution,
// What listeners last observed; `change` fires when the viewport flips it.
_matches: bool,
_on_change: ?js.Function.Global = null,

pub fn init(query: []const u8, exec: *const js.Execution) !*MediaQueryList {
    const frame = switch (exec.js.global) {
        .frame => |f| f,
        .worker => unreachable,
    };
    const media = try frame.dupeString(query);
    const self = try exec._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = media,
        ._frame = frame,
        ._exec = exec,
        ._matches = MediaQuery.matches(media, frame._page.getViewport()),
    });
    try frame._page.media_query_lists.append(frame._page.frame_arena, self);
    return self;
}

pub fn deinit(self: *MediaQueryList) void {
    if (self._on_change) |f| f.release();
}

pub fn asEventTarget(self: *MediaQueryList) *EventTarget {
    return self._proto;
}

pub fn getMedia(self: *const MediaQueryList) []const u8 {
    return self._media;
}

/// Re-evaluates the stored query against the current viewport on every call
/// so the result stays in sync with viewport emulation. The viewport comes
/// from the page (overridable via Emulation.setDeviceMetricsOverride),
/// matching `Window.innerWidth` / `innerHeight`.
pub fn getMatches(self: *const MediaQueryList) bool {
    return MediaQuery.matches(self._media, self._frame._page.getViewport());
}

pub fn viewportChanged(self: *MediaQueryList) void {
    const matches = self.getMatches();
    if (matches == self._matches) return;
    self._matches = matches;

    const target = self.asEventTarget();
    if (!self._exec.hasDirectListeners(target, "change", @as(?js.Function.Global, null))) return;
    self.dispatchChange(matches) catch |err| {
        log.warn(.browser, "matchMedia change", .{ .err = err, .media = self._media });
    };
}

fn dispatchChange(self: *MediaQueryList, matches: bool) !void {
    const event = try MediaQueryListEvent.initTrusted(comptime .wrap("change"), .{
        .matches = matches,
        .media = self._media,
    }, self._frame);
    try self._exec.dispatch(self.asEventTarget(), event.asEvent(), @as(?js.Function.Global, null), .{ .context = "MediaQueryList change" });
}

pub fn addListener(self: *MediaQueryList, cb_: ?js.Function, exec: *js.Execution) !void {
    const cb = cb_ orelse return;
    try self._proto.addEventListener("change", .{ .value = .{ .function = cb } }, null, exec);
}

pub fn removeListener(self: *MediaQueryList, cb_: ?js.Function, exec: *js.Execution) !void {
    const cb = cb_ orelse return;
    try self._proto.removeEventListener("change", .{ .value = .{ .function = cb } }, null, exec);
}

pub fn getOnChange(self: *const MediaQueryList) ?js.Function.Global {
    return self._on_change;
}

// Registered as a listener so JS-side dispatchEvent reaches it too.
pub fn setOnChange(self: *MediaQueryList, cb_: ?js.Function, exec: *js.Execution) !void {
    if (self._on_change) |old| {
        try self._proto.removeEventListener("change", .{ .value = .{ .function = old.local(exec.js.local.?) } }, null, exec);
        old.release();
        self._on_change = null;
    }
    const cb = cb_ orelse return;
    try self._proto.addEventListener("change", .{ .value = .{ .function = cb } }, null, exec);
    self._on_change = try cb.persist();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaQueryList);

    pub const Meta = struct {
        pub const name = "MediaQueryList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const media = bridge.accessor(MediaQueryList.getMedia, null, .{});
    pub const matches = bridge.accessor(MediaQueryList.getMatches, null, .{});
    pub const addListener = bridge.function(MediaQueryList.addListener, .{});
    pub const removeListener = bridge.function(MediaQueryList.removeListener, .{});
    pub const onchange = bridge.accessor(MediaQueryList.getOnChange, MediaQueryList.setOnChange, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaQueryList" {
    try testing.htmlRunner("css/media_query_list.html", .{});
}

test "WebApi: media @-rule cascade" {
    try testing.htmlRunner("css/media_at_rule_cascade.html", .{});
}
