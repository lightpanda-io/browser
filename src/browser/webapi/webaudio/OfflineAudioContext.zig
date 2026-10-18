// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// https://webaudio.github.io/web-audio-api/#OfflineAudioContext

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioDestinationNode = @import("AudioDestinationNode.zig");
const OfflineAudioCompletionEvent = @import("OfflineAudioCompletionEvent.zig");

const log = lp.log;

const OfflineAudioContext = @This();

pub const Proto = BaseAudioContext;

// Quanta rendered per task, so a long render doesn't hog the event loop.
const quanta_per_task = 1024;

_proto: *BaseAudioContext,
_length: u32,
_channels: u32,
_started: bool = false,
_render_scheduled: bool = false,
_complete: ?js.PromiseResolver.Global = null,
_rendered: ?*AudioBuffer = null,
// suspend() promises, by frame (a multiple of the quantum size)
_suspends: std.ArrayList(Suspend) = .empty,

const Suspend = struct {
    frame: u64,
    resolver: js.PromiseResolver.Global,
};

const Options = struct {
    length: u32,
    numberOfChannels: u32 = 1,
    sampleRate: f32,
};

const OptionsOrChannels = union(enum) {
    options: Options,
    channels: u32,
};

fn constructor(first: OptionsOrChannels, length_: ?u32, sample_rate_: ?f32, frame: *Frame) !*OfflineAudioContext {
    const options: Options = switch (first) {
        .options => |o| o,
        .channels => |channels| .{
            .numberOfChannels = channels,
            .length = length_ orelse return error.TypeError,
            .sampleRate = sample_rate_ orelse return error.TypeError,
        },
    };
    try AudioBuffer.validate(options.numberOfChannels, options.length, options.sampleRate);

    const arena = try frame.getArena(.medium, "OfflineAudioContext");
    errdefer arena.release();

    const self = try Factory.chainedWithAllocator(arena.allocator(), .{
        EventTarget{ ._type = .base_audio_context },
        BaseAudioContext.init(.offline, arena, options.sampleRate, frame),
        OfflineAudioContext{
            ._proto = undefined,
            ._length = options.length,
            ._channels = options.numberOfChannels,
        },
    });
    const base = self._proto;
    base._destination = try AudioDestinationNode.createOffline(base, options.numberOfChannels);
    return self;
}

pub fn deinit(self: *OfflineAudioContext, page: *Page) void {
    if (self._complete) |resolver| {
        resolver.release();
    }
    for (self._suspends.items) |s| {
        s.resolver.release();
    }
    if (self._rendered) |buffer| {
        buffer.releaseRef(page);
    }
}

pub fn asEventTarget(self: *OfflineAudioContext) *EventTarget {
    return self._proto._proto;
}

fn getLength(self: *const OfflineAudioContext) u32 {
    return self._length;
}

fn startRendering(self: *OfflineAudioContext, frame: *Frame) !js.Promise {
    const base = self._proto;
    if (base._state == .closed or self._started) {
        return error.InvalidStateError;
    }

    const local = frame.js.local.?;
    const buffer = try AudioBuffer.create(self._channels, self._length, base._sample_rate, local, frame.page);
    buffer.acquireRef();
    errdefer buffer.releaseRef(frame.page);

    const resolver = local.createPromiseResolver();
    const global = try resolver.persist();
    errdefer global.release();

    // statechange is queued ahead of the render
    base.setState(.running);
    errdefer base._state = .suspended;
    try self.scheduleRender();
    self._rendered = buffer;
    self._complete = global;
    self._started = true;
    return resolver.promise();
}

fn suspendContext(self: *OfflineAudioContext, when: f64, frame: *Frame) !js.Promise {
    const base = self._proto;
    if (base._state == .closed) {
        return error.InvalidStateError;
    }
    if (std.math.isFinite(when) == false) {
        return error.TypeError;
    }
    // In f32, as Chrome: a suspend at exactly the duration can pass, and
    // then never resolves.
    const duration: f32 = @as(f32, @floatFromInt(self._length)) / base._sample_rate;
    if (when < 0 or when >= duration) {
        return error.InvalidStateError;
    }

    const exact: u64 = @intFromFloat(when * base._sample_rate);
    const at = std.mem.alignForward(u64, exact, Bus.quantum);
    if (at < base._current_frame) {
        return error.InvalidStateError;
    }

    var index: usize = self._suspends.items.len;
    for (self._suspends.items, 0..) |s, i| {
        if (s.frame == at) return error.InvalidStateError;
        if (s.frame > at) {
            index = i;
            break;
        }
    }

    const resolver = frame.js.local.?.createPromiseResolver();
    const global = try resolver.persist();
    errdefer global.release();
    try self._suspends.insert(base._arena.allocator(), index, .{ .frame = at, .resolver = global });
    return resolver.promise();
}

fn resumeContext(self: *OfflineAudioContext, frame: *Frame) !js.Promise {
    const base = self._proto;
    if (self._started == false or base._state == .closed) {
        return error.InvalidStateError;
    }
    if (base._state == .suspended) {
        base.setState(.running);
        try self.scheduleRender();
    }
    return frame.js.local.?.resolvePromise(js.Undefined{});
}

fn scheduleRender(self: *OfflineAudioContext) !void {
    if (self._render_scheduled) {
        return;
    }
    const base = self._proto;
    const frame = base._frame;
    const task = try frame._factory.create(RenderTask{ .context = self });
    errdefer frame._factory.destroy(task);
    base.acquireRef();
    errdefer base.releaseRef(frame.page);
    try frame.js.scheduler.add(task, RenderTask.run, 0, .{
        .name = "OfflineAudioContext.render",
        .finalizer = RenderTask.cancelled,
    });
    self._render_scheduled = true;
}

const RenderTask = struct {
    context: *OfflineAudioContext,

    fn run(ctx: *anyopaque) !?u32 {
        const task: *RenderTask = @ptrCast(@alignCast(ctx));
        const self = task.context;
        const base = self._proto;
        const frame = base._frame;
        frame._factory.destroy(task);
        defer base.releaseRef(frame.page);

        self._render_scheduled = false;
        if (base._state != .running) {
            return null;
        }

        const outcome = self.renderSome() catch |err| {
            log.warn(.js, "OfflineAudioContext render", .{ .err = err });
            self.fail(err);
            return null;
        };
        base.dispatchEnded();
        switch (outcome) {
            .more => self.scheduleRender() catch |err| self.fail(err),
            .suspended => self.suspendNow(),
            .done => self.complete(),
        }
        return null;
    }

    fn cancelled(ctx: *anyopaque) void {
        const task: *RenderTask = @ptrCast(@alignCast(ctx));
        const self = task.context;
        const base = self._proto;
        const frame = base._frame;
        frame._factory.destroy(task);
        self._render_scheduled = false;
        base.releaseRef(frame.page);
    }
};

const Outcome = enum { more, suspended, done };

fn renderSome(self: *OfflineAudioContext) !Outcome {
    const base = self._proto;
    var ls: js.Local.Scope = undefined;
    base._frame.js.localScope(&ls);
    defer ls.deinit();
    const local = &ls.local;

    // No script runs until this slice is done (`ended` fires after it), so
    // these views of the buffer's channel arrays stay valid throughout.
    const buffer = self._rendered.?;
    var outputs: [AudioBuffer.max_channels][]f32 = undefined;
    for (0..self._channels) |c| {
        outputs[c] = buffer.channelData(c, local);
    }

    for (0..quanta_per_task) |_| {
        const start = base._current_frame;
        if (start >= self._length) {
            return .done;
        }
        if (self._suspends.items.len > 0 and self._suspends.items[0].frame == start) {
            return .suspended;
        }
        const bus = try base.renderQuantum(local);
        const n: usize = @intCast(@min(Bus.quantum, self._length - start));
        for (0..@min(bus.channels, self._channels)) |c| {
            const out = outputs[c];
            // a detached channel array just isn't written
            if (out.len < start + n) continue;
            @memcpy(out[start..][0..n], bus.constChannel(c)[0..n]);
        }
    }
    return if (base._current_frame >= self._length) .done else .more;
}

fn suspendNow(self: *OfflineAudioContext) void {
    const base = self._proto;
    base.setState(.suspended);
    const s = self._suspends.orderedRemove(0);
    defer s.resolver.release();

    var ls: js.Local.Scope = undefined;
    base._frame.js.localScope(&ls);
    defer ls.deinit();
    s.resolver.local(&ls.local).resolve("OfflineAudioContext.suspend", js.Undefined{});
}

// The context closes, `complete` fires, then the promise resolves.
fn complete(self: *OfflineAudioContext) void {
    const base = self._proto;
    const frame = base._frame;
    base.setState(.closed);

    const buffer = self._rendered.?;
    const target = base.asEventTarget();
    if (frame._event_manager.hasDirectListeners(target, "complete")) blk: {
        const event = OfflineAudioCompletionEvent.initTrusted(buffer, frame.page) catch |err| {
            log.warn(.js, "OfflineAudioContext complete", .{ .err = err });
            break :blk;
        };
        frame._event_manager.dispatchDirect(target, event.asEvent(), .{ .context = "OfflineAudioContext complete" }) catch |err| {
            log.debug(.js, "OfflineAudioContext complete", .{ .err = err });
        };
    }

    const resolver = self._complete orelse return;
    self._complete = null;
    defer resolver.release();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    resolver.local(&ls.local).resolve("OfflineAudioContext.startRendering", buffer);
}

fn fail(self: *OfflineAudioContext, err: anyerror) void {
    const base = self._proto;
    base.setState(.closed);

    const resolver = self._complete orelse return;
    self._complete = null;
    defer resolver.release();

    var ls: js.Local.Scope = undefined;
    base._frame.js.localScope(&ls);
    defer ls.deinit();
    const rejection: anyerror = if (err == error.OutOfMemory) error.NotSupported else error.InvalidStateError;
    resolver.local(&ls.local).rejectError("OfflineAudioContext.startRendering", .{ .dom_exception = .{ .err = rejection } });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OfflineAudioContext);

    pub const Meta = struct {
        pub const name = "OfflineAudioContext";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(OfflineAudioContext.constructor, .{});
    pub const length = bridge.accessor(OfflineAudioContext.getLength, null, .{});
    pub const oncomplete = EventTarget.handlerAccessor(OfflineAudioContext, "complete");
    pub const startRendering = bridge.function(OfflineAudioContext.startRendering, .{});
    pub const @"suspend" = bridge.function(OfflineAudioContext.suspendContext, .{});
    pub const @"resume" = bridge.function(OfflineAudioContext.resumeContext, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: webaudio" {
    try testing.htmlRunner("webaudio", .{});
}
