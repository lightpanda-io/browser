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

// https://webaudio.github.io/web-audio-api/#BaseAudioContext

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const Wavetable = @import("dsp/PeriodicWave.zig");
const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const GainNode = @import("GainNode.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const PeriodicWave = @import("PeriodicWave.zig");
const OscillatorNode = @import("OscillatorNode.zig");
const ConstantSourceNode = @import("ConstantSourceNode.zig");
const OfflineAudioContext = @import("OfflineAudioContext.zig");
const AudioBufferSourceNode = @import("AudioBufferSourceNode.zig");
const AudioDestinationNode = @import("AudioDestinationNode.zig");
const DynamicsCompressorNode = @import("DynamicsCompressorNode.zig");
const AudioScheduledSourceNode = @import("AudioScheduledSourceNode.zig");

const log = lp.log;

const BaseAudioContext = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_type: Type,
// Held by the context's wrapper, every node and param wrapper, and pending
// tasks. The whole graph lives in _arena.
_rc: lp.RC = .{},
_arena: *lp.Arena,
// where tasks run and events dispatch
_frame: *Frame,
// for releasing refs: teardown can outlive the frame
_page: *Page,
_sample_rate: f32,
// the first frame of the next quantum to render
_current_frame: u64 = 0,
_render_count: u64 = 0,
_state: State = .suspended,
_destination: *AudioDestinationNode = undefined,
_nodes: std.ArrayList(*AudioNode) = .empty,
_waves: [@typeInfo(Wavetable.Shape).@"enum".field_names.len]?*Wavetable = @splat(null),
// sources that finished in the quanta rendered since the last `ended` events
_finished: std.ArrayList(*AudioScheduledSourceNode) = .empty,
_silence: Bus = .{},

pub const Type = enum(u8) {
    offline,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .offline => OfflineAudioContext,
    };
}

pub fn subtype(self: *const BaseAudioContext, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, BaseAudioContext);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub const State = enum { suspended, running, closed };

pub fn init(typ: Type, arena: *lp.Arena, sample_rate: f32, frame: *Frame) BaseAudioContext {
    return .{
        ._proto = undefined,
        ._type = typ,
        ._arena = arena,
        ._frame = frame,
        ._page = frame.page,
        ._sample_rate = sample_rate,
    };
}

pub fn deinit(self: *BaseAudioContext, page: *Page) void {
    for (self._nodes.items) |node| {
        if (node._type == .scheduled_source) {
            const source = node.subtype(AudioScheduledSourceNode);
            switch (source._type) {
                .oscillator => source.subtype(OscillatorNode).deinit(page),
                .buffer_source => source.subtype(AudioBufferSourceNode).deinit(page),
                .constant_source => {},
            }
        }
        page.removeTarget(node.asEventTarget());
    }
    switch (self._type) {
        .offline => self.subtype(OfflineAudioContext).deinit(page),
    }
    page.removeTarget(self.asEventTarget());
    self._arena.release();
}

pub fn acquireRef(self: *BaseAudioContext) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *BaseAudioContext, page: *Page) void {
    self._rc.release(self, page);
}

pub fn asEventTarget(self: *BaseAudioContext) *EventTarget {
    return self._proto;
}

pub fn currentTime(self: *const BaseAudioContext) f64 {
    return @as(f64, @floatFromInt(self._current_frame)) / self._sample_rate;
}

pub fn registerNode(self: *BaseAudioContext, node: *AudioNode) !void {
    try self._nodes.append(self._arena.allocator(), node);
}

// The built-in waveforms' tables, built on first use.
pub fn basicWave(self: *BaseAudioContext, shape: Wavetable.Shape) !*const Wavetable {
    const slot = &self._waves[@backingInt(shape)];
    if (slot.*) |wave| {
        return wave;
    }
    const allocator = self._arena.allocator();
    const wave = try allocator.create(Wavetable);
    wave.* = try .initBasic(allocator, self._sample_rate, shape);
    slot.* = wave;
    return wave;
}

// Renders the next quantum; the destination's input is the result.
pub fn renderQuantum(self: *BaseAudioContext, local: *const js.Local) !*const Bus {
    self._render_count += 1;
    if (self._silence.channels == 0) {
        try self._silence.setChannels(self._arena.allocator(), 1);
        self._silence.zero();
    }
    var quantum: render.Quantum = .{
        .index = self._render_count,
        .frame = self._current_frame,
        .sample_rate = self._sample_rate,
        .allocator = self._arena.allocator(),
        .local = local,
        .finished = &self._finished,
        .silence = &self._silence,
    };
    const destination = self._destination.asNode();
    _ = try destination.pull(&quantum);

    // Sources play (and end) whether or not they reach the destination.
    for (self._nodes.items) |node| {
        if (node._type != .scheduled_source or node._rendered == quantum.index) {
            continue;
        }
        const state = node.subtype(AudioScheduledSourceNode)._state;
        if (state == .scheduled or state == .playing) {
            _ = try node.pull(&quantum);
        }
    }
    self._current_frame += Bus.quantum;
    return &destination._input;
}

// Listeners run script, so the list is re-read after each one.
pub fn dispatchEnded(self: *BaseAudioContext) void {
    const frame = self._frame;
    while (self._finished.items.len > 0) {
        const source = self._finished.orderedRemove(0);
        const target = source.asEventTarget();
        if (frame._event_manager.hasDirectListeners(target, "ended") == false) {
            continue;
        }
        const event = Event.initTrusted(comptime .wrap("ended"), .{}, frame.page) catch |err| {
            log.warn(.js, "AudioScheduledSourceNode ended", .{ .err = err });
            continue;
        };
        frame._event_manager.dispatchDirect(target, event, .{ .context = "AudioScheduledSourceNode ended" }) catch |err| {
            log.debug(.js, "AudioScheduledSourceNode ended", .{ .err = err });
        };
    }
}

// The state changes now; the `statechange` event fires a task later.
pub fn setState(self: *BaseAudioContext, state: State) void {
    if (self._state == state) {
        return;
    }
    self._state = state;
    StateChangeTask.queue(self) catch |err| {
        log.warn(.js, "AudioContext statechange", .{ .err = err });
    };
}

const StateChangeTask = struct {
    context: *BaseAudioContext,

    fn queue(context: *BaseAudioContext) !void {
        const frame = context._frame;
        const task = try frame._factory.create(StateChangeTask{ .context = context });
        errdefer frame._factory.destroy(task);
        context.acquireRef();
        errdefer context.releaseRef(frame.page);
        try frame.js.scheduler.add(task, run, 0, .{
            .name = "AudioContext.statechange",
            .finalizer = cancelled,
        });
    }

    fn run(ctx: *anyopaque) !?u32 {
        const task: *StateChangeTask = @ptrCast(@alignCast(ctx));
        const context = task.context;
        const frame = context._frame;
        frame._factory.destroy(task);
        defer context.releaseRef(frame.page);

        const target = context.asEventTarget();
        if (frame._event_manager.hasDirectListeners(target, "statechange")) {
            const event = try Event.initTrusted(comptime .wrap("statechange"), .{}, frame.page);
            try frame._event_manager.dispatchDirect(target, event, .{ .context = "AudioContext statechange" });
        }
        return null;
    }

    fn cancelled(ctx: *anyopaque) void {
        const task: *StateChangeTask = @ptrCast(@alignCast(ctx));
        const context = task.context;
        const frame = context._frame;
        frame._factory.destroy(task);
        context.releaseRef(frame.page);
    }
};

fn getDestination(self: *const BaseAudioContext) *AudioDestinationNode {
    return self._destination;
}

fn getSampleRate(self: *const BaseAudioContext) f32 {
    return self._sample_rate;
}

fn getCurrentTime(self: *const BaseAudioContext) f64 {
    return self.currentTime();
}

fn getState(self: *const BaseAudioContext) []const u8 {
    return @tagName(self._state);
}

fn createBuffer(_: *BaseAudioContext, number_of_channels: u32, length: u32, sample_rate: f32, frame: *Frame) !*AudioBuffer {
    return AudioBuffer.create(number_of_channels, length, sample_rate, frame.js.local.?, frame.page);
}

fn createBufferSource(self: *BaseAudioContext) !*AudioBufferSourceNode {
    return AudioBufferSourceNode.create(self, .{});
}

fn createConstantSource(self: *BaseAudioContext) !*ConstantSourceNode {
    return ConstantSourceNode.create(self, .{});
}

fn createDynamicsCompressor(self: *BaseAudioContext) !*DynamicsCompressorNode {
    return DynamicsCompressorNode.create(self, .{});
}

fn createGain(self: *BaseAudioContext) !*GainNode {
    return GainNode.create(self, .{});
}

fn createOscillator(self: *BaseAudioContext) !*OscillatorNode {
    return OscillatorNode.create(self, .{});
}

const PeriodicWaveConstraints = struct {
    disableNormalization: bool = false,
};

fn createPeriodicWave(self: *BaseAudioContext, real: []const f32, imag: []const f32, constraints_: ?PeriodicWaveConstraints) !*PeriodicWave {
    const constraints = constraints_ orelse PeriodicWaveConstraints{};
    return PeriodicWave.create(self, .{
        .real = real,
        .imag = imag,
        .disableNormalization = constraints.disableNormalization,
    });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(BaseAudioContext);

    pub const Meta = struct {
        pub const name = "BaseAudioContext";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const destination = bridge.accessor(BaseAudioContext.getDestination, null, .{});
    pub const sampleRate = bridge.accessor(BaseAudioContext.getSampleRate, null, .{});
    pub const currentTime = bridge.accessor(BaseAudioContext.getCurrentTime, null, .{});
    pub const state = bridge.accessor(BaseAudioContext.getState, null, .{});
    pub const onstatechange = EventTarget.handlerAccessor(BaseAudioContext, "statechange");
    pub const createBuffer = bridge.function(BaseAudioContext.createBuffer, .{});
    pub const createBufferSource = bridge.function(BaseAudioContext.createBufferSource, .{});
    pub const createConstantSource = bridge.function(BaseAudioContext.createConstantSource, .{});
    pub const createDynamicsCompressor = bridge.function(BaseAudioContext.createDynamicsCompressor, .{});
    pub const createGain = bridge.function(BaseAudioContext.createGain, .{});
    pub const createOscillator = bridge.function(BaseAudioContext.createOscillator, .{});
    pub const createPeriodicWave = bridge.function(BaseAudioContext.createPeriodicWave, .{});
};
