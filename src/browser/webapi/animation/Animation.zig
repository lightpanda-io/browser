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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Animation = @This();

_effect: ?js.Object.Global = null,
_timeline: ?js.Object.Global = null,
_ready_resolver: ?js.PromiseResolver.Global = null,
_finished_resolver: ?js.PromiseResolver.Global = null,

pub fn init(page: *Page) !*Animation {
    return page._factory.create(Animation{});
}

pub fn play(_: *Animation) void {}
pub fn pause(_: *Animation) void {}
pub fn cancel(_: *Animation) void {}
pub fn finish(_: *Animation) void {}
pub fn reverse(_: *Animation) void {}

pub fn getPlayState(_: *const Animation) []const u8 {
    return "finished";
}

pub fn getPending(_: *const Animation) bool {
    return false;
}

pub fn getFinished(self: *Animation, page: *Page) !js.Promise {
    if (self._finished_resolver == null) {
        const resolver = page.js.local.?.createPromiseResolver();
        resolver.resolve("Animation.getFinished", self);
        self._finished_resolver = try resolver.persist();
        return resolver.promise();
    }
    return page.js.toLocal(self._finished_resolver).?.promise();
}

pub fn getReady(self: *Animation, page: *Page) !js.Promise {
    // never resolved, because we're always "finished"
    if (self._ready_resolver == null) {
        const resolver = page.js.local.?.createPromiseResolver();
        self._ready_resolver = try resolver.persist();
        return resolver.promise();
    }
    return page.js.toLocal(self._ready_resolver).?.promise();
}

pub fn getEffect(self: *const Animation) ?js.Object.Global {
    return self._effect;
}

pub fn setEffect(self: *Animation, effect: ?js.Object.Global) !void {
    self._effect = effect;
}

pub fn getTimeline(self: *const Animation) ?js.Object.Global {
    return self._timeline;
}

pub fn setTimeline(self: *Animation, timeline: ?js.Object.Global) !void {
    self._timeline = timeline;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Animation);

    pub const Meta = struct {
        pub const name = "Animation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const play = bridge.function(Animation.play, .{});
    pub const pause = bridge.function(Animation.pause, .{});
    pub const cancel = bridge.function(Animation.cancel, .{});
    pub const finish = bridge.function(Animation.finish, .{});
    pub const reverse = bridge.function(Animation.reverse, .{});
    pub const playState = bridge.accessor(Animation.getPlayState, null, .{});
    pub const pending = bridge.accessor(Animation.getPending, null, .{});
    pub const finished = bridge.accessor(Animation.getFinished, null, .{});
    pub const ready = bridge.accessor(Animation.getReady, null, .{});
    pub const effect = bridge.accessor(Animation.getEffect, Animation.setEffect, .{});
    pub const timeline = bridge.accessor(Animation.getTimeline, Animation.setTimeline, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Animation" {
    try testing.htmlRunner("animation/animation.html", .{});
}
