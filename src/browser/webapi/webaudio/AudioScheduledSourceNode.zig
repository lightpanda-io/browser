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

// https://webaudio.github.io/web-audio-api/#AudioScheduledSourceNode

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const math = @import("dsp/math.zig");
const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const OscillatorNode = @import("OscillatorNode.zig");
const ConstantSourceNode = @import("ConstantSourceNode.zig");
const AudioBufferSourceNode = @import("AudioBufferSourceNode.zig");

const AudioScheduledSourceNode = @This();

pub const Proto = AudioNode;

_proto: *AudioNode,
_type: Type,
_state: State = .unscheduled,
_start_time: f64 = 0,
_end_time: ?f64 = null,

pub const Type = enum(u8) {
    buffer_source,
    constant_source,
    oscillator,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .buffer_source => AudioBufferSourceNode,
        .constant_source => ConstantSourceNode,
        .oscillator => OscillatorNode,
    };
}

pub fn subtype(self: *const AudioScheduledSourceNode, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, AudioScheduledSourceNode);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub const State = enum { unscheduled, scheduled, playing, finished };

pub fn init(typ: Type) AudioScheduledSourceNode {
    return .{ ._proto = undefined, ._type = typ };
}

pub fn asNode(self: *AudioScheduledSourceNode) *AudioNode {
    return self._proto;
}

pub fn asEventTarget(self: *AudioScheduledSourceNode) *EventTarget {
    return self._proto._proto;
}

pub fn start(self: *AudioScheduledSourceNode, when_: ?f64) !void {
    const when = when_ orelse 0;
    if (self._state != .unscheduled) {
        return error.InvalidStateError;
    }
    if (std.math.isFinite(when) == false) {
        return error.TypeError;
    }
    if (when < 0) {
        return error.RangeError;
    }
    self._start_time = when;
    self._state = .scheduled;
}

fn stop(self: *AudioScheduledSourceNode, when_: ?f64) !void {
    const when = when_ orelse 0;
    if (self._state == .unscheduled) {
        return error.InvalidStateError;
    }
    if (std.math.isFinite(when) == false) {
        return error.TypeError;
    }
    if (when < 0) {
        return error.RangeError;
    }
    self._end_time = when;
}

// Ends playback; the context fires `ended` once the quantum is done.
pub fn finish(self: *AudioScheduledSourceNode, r: *render.Quantum) !void {
    if (self._state == .finished) {
        return;
    }
    self._state = .finished;
    try r.finished.append(r.allocator, self);
}

// Which frames of this quantum play. Frames outside [offset, offset + frames)
// are already zeroed in `output`, which the source sized first.
pub const Schedule = struct {
    offset: usize,
    frames: usize,
    // How far before the first frame the exact start time is (<= 0), on the
    // quantum the source starts.
    start_frame_offset: f64,
};

// Port of Chrome's AudioScheduledSourceHandler::UpdateSchedulingInfo.
pub fn schedule(self: *AudioScheduledSourceNode, r: *render.Quantum, output: *Bus) !Schedule {
    const sample_rate: f64 = r.sample_rate;
    const quantum_start = r.frame;
    const quantum_end = quantum_start + Bus.quantum;
    const start_frame = math.timeToSampleFrame(self._start_time, sample_rate, .up);
    const end_frame: ?u64 = if (self._end_time) |end| math.timeToSampleFrame(end, sample_rate, .up) else null;

    if (end_frame) |end| {
        if (end <= quantum_start) {
            try self.finish(r);
        }
    }

    if (self._state == .unscheduled or self._state == .finished or start_frame >= quantum_end) {
        output.zero();
        return .{ .offset = 0, .frames = 0, .start_frame_offset = 0 };
    }

    var start_frame_offset: f64 = 0;
    if (self._state == .scheduled) {
        self._state = .playing;
        start_frame_offset = self._start_time * sample_rate - @as(f64, @floatFromInt(start_frame));
    }

    const offset: usize = @intCast(@min(if (start_frame > quantum_start) start_frame - quantum_start else 0, Bus.quantum));
    var frames = Bus.quantum - offset;
    if (frames == 0) {
        output.zero();
        return .{ .offset = offset, .frames = 0, .start_frame_offset = start_frame_offset };
    }
    if (offset > 0) {
        output.zeroFrames(0, offset);
    }

    if (end_frame) |end| {
        if (end >= quantum_start and end <= quantum_end) {
            if (end < quantum_end) {
                const zero_start: usize = @intCast(end - quantum_start);
                const zero_frames = Bus.quantum - zero_start;
                frames = if (zero_frames > frames) 0 else frames - zero_frames;
                output.zeroFrames(zero_start, Bus.quantum);
            }
            try self.finish(r);
        }
    }
    return .{ .offset = offset, .frames = frames, .start_frame_offset = start_frame_offset };
}

pub fn process(self: *AudioScheduledSourceNode, r: *render.Quantum, output: *Bus) !void {
    switch (self._type) {
        inline else => |tag| try self.subtype(Subtype(tag)).process(r, output),
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioScheduledSourceNode);

    pub const Meta = struct {
        pub const name = "AudioScheduledSourceNode";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const start = bridge.function(AudioScheduledSourceNode.start, .{});
    pub const stop = bridge.function(AudioScheduledSourceNode.stop, .{});
    pub const onended = EventTarget.handlerAccessor(AudioScheduledSourceNode, "ended");
};
