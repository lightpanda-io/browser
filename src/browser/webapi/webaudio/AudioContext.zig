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

// https://webaudio.github.io/web-audio-api/#AudioContext
//
// There's no audio device, so nothing renders: the graph is built and
// validated, and currentTime follows the wall clock while running. Sources
// never play, so they never fire `ended`.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioDestinationNode = @import("AudioDestinationNode.zig");

const AudioContext = @This();

pub const Proto = BaseAudioContext;

// A common device rate.
const default_sample_rate = 48000;

_proto: *BaseAudioContext,
// frames that elapsed in earlier running spans
_elapsed_frames: u64 = 0,
// when the current running span began, in microseconds
_running_since: ?u64 = null,

const Options = struct {
    sampleRate: ?f32 = null,
};

fn constructor(options_: ?Options, frame: *Frame) !*AudioContext {
    const options = options_ orelse Options{};
    const sample_rate = options.sampleRate orelse default_sample_rate;
    if (std.math.isNan(sample_rate) or sample_rate < AudioBuffer.min_sample_rate or sample_rate > AudioBuffer.max_sample_rate) {
        return error.NotSupported;
    }

    const arena = try frame.getArena(.medium, "AudioContext");
    errdefer arena.release();

    const self = try Factory.chainedWithAllocator(arena.allocator(), .{
        EventTarget{ ._type = .base_audio_context },
        BaseAudioContext.init(.realtime, arena, sample_rate, frame),
        AudioContext{ ._proto = undefined },
    });
    const base = self._proto;
    base._destination = try AudioDestinationNode.createRealtime(base);

    // As in Chrome when autoplay is allowed: running right away, with
    // `statechange` fired later.
    base.setState(.running);
    return self;
}

pub fn asEventTarget(self: *AudioContext) *EventTarget {
    return self._proto._proto;
}

// Snapped to the quantum, as a rendering device would advance it.
pub fn currentFrame(self: *const AudioContext) u64 {
    var frames = self._elapsed_frames;
    if (self._running_since) |since| {
        frames += self.framesSince(since);
    }
    return std.mem.alignBackward(u64, frames, Bus.quantum);
}

fn framesSince(self: *const AudioContext, since: u64) u64 {
    const micros = lp.datetime.microTimestamp(.boot) -| since;
    const seconds = @as(f64, @floatFromInt(micros)) / std.time.us_per_s;
    return @intFromFloat(seconds * self._proto._sample_rate);
}

// Starts or stops the clock; BaseAudioContext.setState calls it.
pub fn clockState(self: *AudioContext, state: BaseAudioContext.State) void {
    if (state == .running) {
        if (self._running_since == null) {
            self._running_since = lp.datetime.microTimestamp(.boot);
        }
    } else if (self._running_since) |since| {
        self._elapsed_frames += self.framesSince(since);
        self._running_since = null;
    }
}

fn getBaseLatency(self: *const AudioContext) f64 {
    return 2.0 * Bus.quantum / self._proto._sample_rate;
}

fn getOutputLatency(_: *const AudioContext) f64 {
    return 0;
}

fn resumeContext(self: *AudioContext, frame: *Frame) !js.Promise {
    return self.transition(.running, frame);
}

fn suspendContext(self: *AudioContext, frame: *Frame) !js.Promise {
    return self.transition(.suspended, frame);
}

fn close(self: *AudioContext, frame: *Frame) !js.Promise {
    return self.transition(.closed, frame);
}

fn transition(self: *AudioContext, state: BaseAudioContext.State, frame: *Frame) !js.Promise {
    const local = frame.js.local.?;
    if (self._proto._state == .closed) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.InvalidStateError } });
    }
    self._proto.setState(state);
    return local.resolvePromise(js.Undefined{});
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioContext);

    pub const Meta = struct {
        pub const name = "AudioContext";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AudioContext.constructor, .{});
    pub const baseLatency = bridge.accessor(AudioContext.getBaseLatency, null, .{});
    pub const outputLatency = bridge.accessor(AudioContext.getOutputLatency, null, .{});
    pub const @"resume" = bridge.function(AudioContext.resumeContext, .{});
    pub const @"suspend" = bridge.function(AudioContext.suspendContext, .{});
    pub const close = bridge.function(AudioContext.close, .{});
};
