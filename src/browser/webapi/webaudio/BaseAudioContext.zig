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
const DOMException = @import("../DOMException.zig");
const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const wav = @import("dsp/wav.zig");
const Wavetable = @import("dsp/PeriodicWave.zig");

const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const GainNode = @import("GainNode.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const PeriodicWave = @import("PeriodicWave.zig");
const AudioContext = @import("AudioContext.zig");
const ConvolverNode = @import("ConvolverNode.zig");
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
    realtime,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .offline => OfflineAudioContext,
        .realtime => AudioContext,
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
        switch (node._type) {
            .scheduled_source => {
                const source = node.subtype(AudioScheduledSourceNode);
                switch (source._type) {
                    .oscillator => source.subtype(OscillatorNode).deinit(page),
                    .buffer_source => source.subtype(AudioBufferSourceNode).deinit(page),
                    .constant_source => {},
                }
            },
            .convolver => node.subtype(ConvolverNode).deinit(page),
            .destination, .dynamics_compressor, .gain => {},
        }
        page.removeTarget(node.asEventTarget());
    }
    switch (self._type) {
        .offline => self.subtype(OfflineAudioContext).deinit(page),
        .realtime => {},
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
    const frame = switch (self._type) {
        .offline => self._current_frame,
        .realtime => self.subtype(AudioContext).currentFrame(),
    };
    return @as(f64, @floatFromInt(frame)) / self._sample_rate;
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
    switch (self._type) {
        .offline => {},
        .realtime => self.subtype(AudioContext).clockState(state),
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

fn createConvolver(self: *BaseAudioContext) !*ConvolverNode {
    return ConvolverNode.create(self, .{});
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

// EncodingError for anything but WAV. This decodes now, but delivers the result
// via a task
fn decodeAudioData(self: *BaseAudioContext, audio_data: js.Value, success_: ?js.Function, error_: ?js.Function, frame: *Frame) !js.Promise {
    if (audio_data.isArrayBuffer() == false) {
        return error.TypeError;
    }
    const local = frame.js.local.?;
    const bytes = try audio_data.toZig(js.BufferSource);
    const buffer: ?*AudioBuffer = self.decode(bytes.bytes(), local) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };

    if (buffer) |b| {
        b.acquireRef();
    }
    errdefer if (buffer) |b| {
        b.releaseRef(frame.page);
    };

    const resolver = local.createPromiseResolver();
    const global = try resolver.persist();
    errdefer global.release();

    const success = if (success_) |f| try f.persist() else null;
    errdefer if (success) |f| {
        f.release();
    };

    const failure = if (error_) |f| try f.persist() else null;
    errdefer if (failure) |f| {
        f.release();
    };

    try DecodeTask.queue(.{
        .context = self,
        .resolver = global,
        .success = success,
        .failure = failure,
        .buffer = buffer,
    });
    return resolver.promise();
}

fn decode(self: *BaseAudioContext, bytes: []const u8, local: *const js.Local) !*AudioBuffer {
    const parsed = try wav.parse(bytes);
    if (parsed.channels > AudioBuffer.max_channels) {
        return error.EncodingError;
    }
    const length = parsed.resampledLength(self._sample_rate);
    const buffer = try AudioBuffer.create(parsed.channels, length, self._sample_rate, local, self._page);
    for (0..parsed.channels) |c| {
        parsed.resample(c, self._sample_rate, buffer.channelData(c, local));
    }
    return buffer;
}

const DecodeTask = struct {
    context: *BaseAudioContext,
    resolver: js.PromiseResolver.Global,
    success: ?js.Function.Global,
    failure: ?js.Function.Global,
    buffer: ?*AudioBuffer, // null when decoding failed

    // Once queued, the task owns the handles and the buffer ref.
    fn queue(task: DecodeTask) !void {
        const context = task.context;
        const frame = context._frame;
        const created = try frame._factory.create(task);
        errdefer frame._factory.destroy(created);

        context.acquireRef();
        errdefer context.releaseRef(frame.page);

        try frame.js.scheduler.add(created, run, 0, .{
            .name = "BaseAudioContext.decodeAudioData",
            .finalizer = cancelled,
        });
    }

    fn run(ctx: *anyopaque) !?u32 {
        const task: *DecodeTask = @ptrCast(@alignCast(ctx));
        defer task.destroy();
        const context = task.context;

        var ls: js.Local.Scope = undefined;
        context._frame.js.localScope(&ls);
        defer ls.deinit();
        const local = &ls.local;
        const resolver = task.resolver.local(local);

        // As in Chrome, the callback runs before the promise's reactions.
        if (task.buffer) |buffer| {
            if (task.success) |f| {
                ls.toLocal(f).callWithThisReport(context, .{buffer}) catch |err| {
                    log.debug(.js, "decodeAudioData callback", .{ .err = err });
                };
            }
            resolver.resolve("BaseAudioContext.decodeAudioData", buffer);
        } else {
            const exception = try local.zigValueToJs(DOMException.init("Unable to decode audio data", "EncodingError"), .{});
            if (task.failure) |f| {
                ls.toLocal(f).callWithThisReport(context, .{exception}) catch |err| {
                    log.debug(.js, "decodeAudioData callback", .{ .err = err });
                };
            }
            resolver.reject("BaseAudioContext.decodeAudioData", exception);
        }
        return null;
    }

    fn cancelled(ctx: *anyopaque) void {
        const task: *DecodeTask = @ptrCast(@alignCast(ctx));
        task.destroy();
    }

    fn destroy(task: *DecodeTask) void {
        const context = task.context;
        const frame = context._frame;
        task.resolver.release();

        if (task.success) |f| {
            f.release();
        }

        if (task.failure) |f| {
            f.release();
        }

        if (task.buffer) |b| {
            b.releaseRef(frame.page);
        }

        frame._factory.destroy(task);
        context.releaseRef(frame.page);
    }
};

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
    pub const createConvolver = bridge.function(BaseAudioContext.createConvolver, .{});
    pub const decodeAudioData = bridge.function(BaseAudioContext.decodeAudioData, .{});
    pub const createDynamicsCompressor = bridge.function(BaseAudioContext.createDynamicsCompressor, .{});
    pub const createGain = bridge.function(BaseAudioContext.createGain, .{});
    pub const createOscillator = bridge.function(BaseAudioContext.createOscillator, .{});
    pub const createPeriodicWave = bridge.function(BaseAudioContext.createPeriodicWave, .{});
};
