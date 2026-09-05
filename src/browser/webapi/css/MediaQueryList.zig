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
_frame: *Frame,
_media: []const u8,
// What listeners last observed; `change` fires when the viewport flips it.
_matches: bool,
_on_change: ?js.Function.Global = null,

pub fn init(query: []const u8, frame: *Frame) !*MediaQueryList {
    const media = try frame.dupeString(query);
    const self = try frame._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = media,
        ._frame = frame,
        ._matches = MediaQuery.matches(media, frame._page.getViewport()),
    });
    try frame._media_query_lists.append(frame.arena, self);
    return self;
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

    const frame = self._frame;
    if (!frame.hasDirectListeners(self.asEventTarget(), "change", self._on_change)) return;
    self.dispatchChange(matches) catch |err| {
        log.warn(.browser, "matchMedia change", .{ .err = err, .media = self._media });
    };
}

fn dispatchChange(self: *MediaQueryList, matches: bool) !void {
    const frame = self._frame;
    const event = try MediaQueryListEvent.initTrusted(comptime .wrap("change"), .{
        .matches = matches,
        .media = self._media,
    }, frame);
    try frame.dispatch(self.asEventTarget(), event.asEvent(), self._on_change, .{ .context = "MediaQueryList change" });
}

// The property handler for a JS-side dispatchEvent (see EventManager.dispatch).
pub fn inlineHandler(self: *const MediaQueryList, typ: lp.String) ?js.Function.Global {
    if (typ.eql(comptime .wrap("change"))) return self._on_change;
    return null;
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

pub fn setOnChange(self: *MediaQueryList, cb: ?js.Function.Global) void {
    self._on_change = cb;
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

test "WebApi: MediaQueryList change survives iframe renavigation" {
    const page = try testing.pageTest("runner/iframe_idle.html", .{});
    defer page.close();

    var runner = page.session.runner(.{});
    const frame = page.frame().?;
    const child = frame.child_frames.items[1];
    {
        var ls: js.Local.Scope = undefined;
        child.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec("matchMedia('(max-width: 500px)').addListener(() => {});", null);
    }
    try testing.expectEqual(1, child._media_query_lists.items.len);

    // Re-navigating the iframe re-inits the Frame in place and destroys its
    // JS context; the old document's lists must go with it.
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec("document.querySelectorAll('iframe')[1].src = 'runner1.html';", null);
    }
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });
    try testing.expectEqual(true, child == frame.child_frames.items[1]);
    try testing.expectEqual(0, child._media_query_lists.items.len);

    {
        var ls: js.Local.Scope = undefined;
        child.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec(
            \\window.fired = [];
            \\matchMedia('(max-width: 500px)').addListener(e => fired.push(e.matches));
        , null);
    }
    page.session.browser.setViewportOverride(.{ .width = 400, .height = 800, .scale = 1 });
    defer page.session.browser.setViewportOverride(null);

    var ls: js.Local.Scope = undefined;
    child.js.localScope(&ls);
    defer ls.deinit();
    const v = try ls.local.exec("fired.join() === 'true'", null);
    try testing.expect(v.toBool());
}

test "WebApi: MediaQueryList created during a change listener waits for the next change" {
    const page = try testing.pageTest("hi.html", .{});
    defer page.close();

    const frame = page.frame().?;
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec(
            \\window.fired = [];
            \\matchMedia('(max-width: 500px)').addListener(e => {
            \\  fired.push('outer:' + e.matches);
            \\  matchMedia('(max-width: 600px)').addListener(e => fired.push('inner:' + e.matches));
            \\});
        , null);
    }

    const browser = page.session.browser;
    defer browser.setViewportOverride(null);

    // The inner list is created at 400px, where it already matches.
    browser.setViewportOverride(.{ .width = 400, .height = 800, .scale = 1 });
    try testing.expectEqual(2, frame._media_query_lists.items.len);
    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        const v = try ls.local.exec("fired.join() === 'outer:true'", null);
        try testing.expect(v.toBool());
    }

    // Both flip at 700px. The outer listener creates a third list which,
    // again, has nothing to report.
    browser.setViewportOverride(.{ .width = 700, .height = 800, .scale = 1 });
    try testing.expectEqual(3, frame._media_query_lists.items.len);
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const v = try ls.local.exec("fired.join() === 'outer:true,outer:false,inner:false'", null);
    try testing.expect(v.toBool());
}
