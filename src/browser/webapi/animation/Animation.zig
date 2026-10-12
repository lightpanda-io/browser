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
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");

const EventTarget = @import("../EventTarget.zig");
const AnimationPlaybackEvent = @import("../event/AnimationPlaybackEvent.zig");

const log = lp.log;

const Animation = @This();

pub const Proto = EventTarget;

const PlayState = enum {
    idle,
    running,
    paused,
    finished,
};

_rc: lp.RC = .{},
_proto: *EventTarget,
_frame: *Frame,
_arena: *lp.Arena,

_effect: ?js.Object.Global = null,
_timeline: ?js.Object.Global = null,
_ready_resolver: ?js.PromiseResolver.Global = null,
_finished_resolver: ?js.PromiseResolver.Global = null,
_startTime: ?f64 = null,
_onFinish: ?js.Function.Global = null,
_onCancel: ?js.Function.Global = null,
_playState: PlayState = .idle,

// Fake the animation by passing the states:
// .idle => .running once play() is called.
// .running => .finished after 10ms when update() is callback.
//
// TODO add support for effect and timeline
pub fn init(frame: *Frame) !*Animation {
    const arena = try frame.getArena(.tiny, "Animation");
    errdefer arena.release();

    return frame._factory.eventTargetWithAllocator(arena.allocator(), Animation{
        ._proto = undefined,
        ._frame = frame,
        ._arena = arena,
    });
}

pub fn deinit(self: *Animation, page: *Page) void {
    page.event_listeners.removeTarget(self.asEventTarget());
    self._arena.release();
}

pub fn releaseRef(self: *Animation, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *Animation) void {
    self._rc.acquire();
}

pub fn asEventTarget(self: *Animation) *EventTarget {
    return self._proto;
}

pub fn play(self: *Animation, frame: *Frame) !void {
    if (self._playState == .running) {
        return;
    }

    // transition to running.
    self._playState = .running;

    // Schedule the transition from .running => .finished in 10ms.
    self.acquireRef();
    errdefer self.releaseRef(frame.page);
    try frame.js.scheduler.add(
        self,
        Animation.update,
        10,
        .{ .name = "animation.update", .finalizer = Animation.cancelled },
    );
}

// The scheduler drops pending tasks when the context is torn down.
fn cancelled(ctx: *anyopaque) void {
    const self: *Animation = @ptrCast(@alignCast(ctx));
    self.releaseRef(self._frame.page);
}

pub fn pause(self: *Animation) void {
    self._playState = .paused;
}

pub fn cancel(self: *Animation, frame: *Frame) !void {
    if (self._playState == .idle) {
        return;
    }
    // Transition to idle. If the animation was .running, the already-scheduled
    // update() callback will fire but see .idle state, skip the finish
    // transition, and release the strong ref via weakRef() as normal.
    self._playState = .idle;

    if (self._finished_resolver) |global| {
        // reject the current finished promised
        self._finished_resolver = null;
        defer global.release();
        const resolver = frame.js.local.?.toLocal(global);
        // prevent it from reporting as unhandled
        resolver.promise().markAsHandled();
        resolver.rejectError("Animation.cancel", .{ .dom_exception = .{ .err = error.AbortError } });
    }
    return self.queuePlaybackEvent(.cancel);
}

pub fn finish(self: *Animation, frame: *Frame) !void {
    if (self._playState == .finished) {
        return;
    }

    self._playState = .finished;

    // resolve finished
    if (self._finished_resolver) |resolver| {
        frame.js.local.?.toLocal(resolver).resolve("Animation.getFinished", self);
    }
    return self.queuePlaybackEvent(.finish);
}

const PlaybackEventType = enum { finish, cancel };

fn queuePlaybackEvent(self: *Animation, comptime typ: PlaybackEventType) !void {
    self.acquireRef();
    errdefer self.releaseRef(self._frame.page);
    try self._frame.js.scheduler.add(self, struct {
        fn run(ctx: *anyopaque) !?u32 {
            const animation: *Animation = @ptrCast(@alignCast(ctx));
            defer animation.releaseRef(animation._frame.page);
            const handler = switch (typ) {
                .finish => animation._onFinish,
                .cancel => animation._onCancel,
            };
            try animation.dispatchPlaybackEvent(comptime .wrap(@tagName(typ)), handler);
            return null;
        }
    }.run, 0, .{ .name = "animation." ++ @tagName(typ), .finalizer = Animation.cancelled });
}

fn dispatchPlaybackEvent(self: *Animation, typ: lp.String, handler: ?js.Function.Global) !void {
    const frame = self._frame;
    const target = self.asEventTarget();
    if (frame.hasDirectListeners(target, typ.str(), handler) == false) {
        return;
    }
    const event = try AnimationPlaybackEvent.initTrusted(typ, null, frame);
    return frame.dispatch(target, event.asEvent(), handler, .{ .context = "Animation" });
}

// The property handler for a JS-side dispatchEvent (see EventManager.dispatch).
pub fn inlineHandler(self: *const Animation, typ: lp.String) ?js.Function.Global {
    if (typ.eql(comptime .wrap("finish"))) {
        return self._onFinish;
    }
    if (typ.eql(comptime .wrap("cancel"))) {
        return self._onCancel;
    }
    return null;
}

pub fn reverse(_: *Animation) void {
    log.debug(.not_implemented, "Animation.reverse", .{});
}

pub fn getFinished(self: *Animation, frame: *Frame) !js.Promise {
    if (self._finished_resolver == null) {
        const resolver = frame.js.local.?.createPromiseResolver();
        self._finished_resolver = try resolver.persist();
        return resolver.promise();
    }
    return frame.js.toLocal(self._finished_resolver).?.promise();
}

// The ready promise is immediately resolved.
pub fn getReady(self: *Animation, frame: *Frame) !js.Promise {
    if (self._ready_resolver == null) {
        const resolver = frame.js.local.?.createPromiseResolver();
        resolver.resolve("Animation.getReady", self);
        self._ready_resolver = try resolver.persist();
        return resolver.promise();
    }
    return frame.js.toLocal(self._ready_resolver).?.promise();
}

fn getEffect(self: *const Animation) ?js.Object.Global {
    return self._effect;
}

fn setEffect(self: *Animation, effect: ?js.Object.Global) !void {
    self._effect = effect;
}

fn getTimeline(self: *const Animation) ?js.Object.Global {
    return self._timeline;
}

fn setTimeline(self: *Animation, timeline: ?js.Object.Global) !void {
    self._timeline = timeline;
}

pub fn getStartTime(self: *const Animation) ?f64 {
    return self._startTime;
}

fn setStartTime(self: *Animation, value: ?f64, frame: *Frame) !void {
    self._startTime = value;

    // if the startTime is null, don't play the animation.
    if (value == null) {
        return;
    }

    return self.play(frame);
}

fn getOnFinish(self: *const Animation) ?js.Function.Global {
    return self._onFinish;
}

// callback function transitioning from a state to another
fn update(ctx: *anyopaque) !?u32 {
    const self: *Animation = @ptrCast(@alignCast(ctx));
    defer self.releaseRef(self._frame.page);

    switch (self._playState) {
        .running => {
            // transition to finished.
            self._playState = .finished;

            var ls: js.Local.Scope = undefined;
            self._frame.js.localScope(&ls);
            defer ls.deinit();

            // resolve finished
            if (self._finished_resolver) |resolver| {
                ls.toLocal(resolver).resolve("Animation.getFinished", self);
            }
            try self.dispatchPlaybackEvent(comptime .wrap("finish"), self._onFinish);
        },
        .idle, .paused, .finished => {},
    }
    return null;
}

fn setOnFinish(self: *Animation, cb: ?js.Function.Global) !void {
    self._onFinish = cb;
}

fn getOnCancel(self: *const Animation) ?js.Function.Global {
    return self._onCancel;
}

fn setOnCancel(self: *Animation, cb: ?js.Function.Global) !void {
    self._onCancel = cb;
}

fn playState(self: *const Animation) []const u8 {
    return @tagName(self._playState);
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
    pub const playState = bridge.accessor(Animation.playState, null, .{});
    pub const pending = bridge.property(false, .{ .template = false });
    pub const finished = bridge.accessor(Animation.getFinished, null, .{});
    pub const ready = bridge.accessor(Animation.getReady, null, .{});
    pub const effect = bridge.accessor(Animation.getEffect, Animation.setEffect, .{});
    pub const timeline = bridge.accessor(Animation.getTimeline, Animation.setTimeline, .{});
    pub const startTime = bridge.accessor(Animation.getStartTime, Animation.setStartTime, .{});
    pub const onfinish = bridge.accessor(Animation.getOnFinish, Animation.setOnFinish, .{});
    pub const oncancel = bridge.accessor(Animation.getOnCancel, Animation.setOnCancel, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Animation" {
    try testing.htmlRunner("animation/animation.html", .{});
}
