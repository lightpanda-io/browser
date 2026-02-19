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

const std = @import("std");
const log = @import("../../../log.zig");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Allocator = std.mem.Allocator;

const Animation = @This();

const PlayState = enum {
    idle,
    running,
    paused,
    finished,
};

_page: *Page,
_arena: Allocator,

_effect: ?js.Object.Global = null,
_timeline: ?js.Object.Global = null,
_ready_resolver: ?js.PromiseResolver.Global = null,
_finished_resolver: ?js.PromiseResolver.Global = null,
_startTime: ?f64 = null,
_onFinish: ?js.Function.Temp = null,
_playState: PlayState = .idle,

// Fake the animation by passing the states:
// .idle => .running once play() is called.
// .running => .finished after 10ms when update() is callback.
//
// TODO add support for effect and timeline
pub fn init(page: *Page) !*Animation {
    const arena = try page.getArena(.{ .debug = "Animation" });
    errdefer page.releaseArena(arena);

    const self = try page._factory.create(Animation{
        ._page = page,
        ._arena = arena,
    });

    return self;
}

pub fn play(self: *Animation, page: *Page) !void {
    if (self._playState == .running) {
        return;
    }

    // transition to running.
    self._playState = .running;

    // Schedule the transition from .running => .finished in 10ms.
    page.js.strongRef(self);
    try page.js.scheduler.add(
        self,
        Animation.update,
        10,
        .{ .name = "animation.update" },
    );
}

pub fn pause(self: *Animation) void {
    self._playState = .paused;
}

pub fn cancel(_: *Animation) void {
    log.warn(.not_implemented, "Animation.cancel", .{});
}

pub fn finish(self: *Animation, page: *Page) void {
    if (self._playState == .finished) {
        return;
    }

    self._playState = .finished;

    // resolve finished
    if (self._finished_resolver) |resolver| {
        page.js.local.?.toLocal(resolver).resolve("Animation.getFinished", self);
    }
    // call onfinish
    if (self._onFinish) |func| {
        page.js.local.?.toLocal(func).call(void, .{}) catch |err| {
            log.warn(.js, "Animation._onFinish", .{ .err = err });
        };
    }
}

pub fn reverse(_: *Animation) void {
    log.warn(.not_implemented, "Animation.reverse", .{});
}

pub fn getFinished(self: *Animation, page: *Page) !js.Promise {
    if (self._finished_resolver == null) {
        const resolver = page.js.local.?.createPromiseResolver();
        self._finished_resolver = try resolver.persist();
        return resolver.promise();
    }
    return page.js.toLocal(self._finished_resolver).?.promise();
}

// The ready promise is immediately resolved.
pub fn getReady(self: *Animation, page: *Page) !js.Promise {
    if (self._ready_resolver == null) {
        const resolver = page.js.local.?.createPromiseResolver();
        resolver.resolve("Animation.getReady", self);
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

pub fn getStartTime(self: *const Animation) ?f64 {
    return self._startTime;
}

pub fn setStartTime(self: *Animation, value: ?f64, page: *Page) !void {
    self._startTime = value;

    // if the startTime is null, don't play the animation.
    if (value == null) {
        return;
    }

    return self.play(page);
}

pub fn getOnFinish(self: *const Animation) ?js.Function.Temp {
    return self._onFinish;
}

pub fn deinit(self: *Animation, _: bool) void {
    self._page.releaseArena(self._arena);
}

// callback function transitionning from a state to another
fn update(ctx: *anyopaque) !?u32 {
    const self: *Animation = @ptrCast(@alignCast(ctx));

    switch (self._playState) {
        .running => {
            // transition to finished.
            self._playState = .finished;

            var ls: js.Local.Scope = undefined;
            self._page.js.localScope(&ls);
            defer ls.deinit();

            // resolve finished
            if (self._finished_resolver) |resolver| {
                ls.toLocal(resolver).resolve("Animation.getFinished", self);
            }
            // call onfinish
            if (self._onFinish) |func| {
                ls.toLocal(func).call(void, .{}) catch |err| {
                    log.warn(.js, "Animation._onFinish", .{ .err = err });
                };
            }
        },
        .idle, .paused, .finished => {},
    }

    // No future change scheduled, set the object weak for garbage collection.
    self._page.js.weakRef(self);
    return null;
}

pub fn setOnFinish(self: *Animation, cb: ?js.Function.Temp) !void {
    self._onFinish = cb;
}

pub fn playState(self: *const Animation) []const u8 {
    return @tagName(self._playState);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Animation);

    pub const Meta = struct {
        pub const name = "Animation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(Animation.deinit);
    };

    pub const play = bridge.function(Animation.play, .{});
    pub const pause = bridge.function(Animation.pause, .{});
    pub const cancel = bridge.function(Animation.cancel, .{});
    pub const finish = bridge.function(Animation.finish, .{});
    pub const reverse = bridge.function(Animation.reverse, .{});
    pub const playState = bridge.accessor(Animation.playState, null, .{});
    pub const pending = bridge.property(false, .{ .template = false });
    pub const finished = bridge.accessor(Animation.getFinished, null, .{});
    pub const ready = bridge.accessor(Animation.getReady, null, .{});
    pub const effect = bridge.accessor(Animation.getEffect, Animation.setEffect, .{});
    pub const timeline = bridge.accessor(Animation.getTimeline, Animation.setTimeline, .{});
    pub const startTime = bridge.accessor(Animation.getStartTime, Animation.setStartTime, .{});
    pub const onfinish = bridge.accessor(Animation.getOnFinish, Animation.setOnFinish, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Animation" {
    try testing.htmlRunner("animation/animation.html", .{});
}
