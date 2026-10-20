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

// https://webaudio.github.io/web-audio-api/#AudioBufferSourceNode

const std = @import("std");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const math = @import("dsp/math.zig");
const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const AudioParam = @import("AudioParam.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioScheduledSourceNode = @import("AudioScheduledSourceNode.zig");

const AudioBufferSourceNode = @This();

pub const Proto = AudioScheduledSourceNode;

// Chrome's bound on the computed playback rate.
const max_rate = 1024;

_proto: *AudioScheduledSourceNode,
_playback_rate: *AudioParam,
_detune: *AudioParam,
// holds a ref while set
_buffer: ?*AudioBuffer = null,
_buffer_set: bool = false,
_loop: bool = false,
_loop_start: f64 = 0,
_loop_end: f64 = 0,
// start()'s offset and duration, in seconds of buffer time
_offset: f64 = 0,
_duration: ?f64 = null,
// playhead, in buffer frames
_position: f64 = 0,
// buffer frames played so far, for the grain duration
_played: f64 = 0,
_started_playing: bool = false,
// started with no buffer: it ends right away, and a buffer set later is
// never played (as in Chrome)
_started_empty: bool = false,

const Options = struct {
    buffer: ?*AudioBuffer = null,
    detune: f32 = 0,
    loop: bool = false,
    loopEnd: f64 = 0,
    loopStart: f64 = 0,
    playbackRate: f32 = 1,
};

fn constructor(context: *BaseAudioContext, options_: ?Options) !*AudioBufferSourceNode {
    return create(context, options_ orelse .{});
}

pub fn create(context: *BaseAudioContext, options: Options) !*AudioBufferSourceNode {
    if (std.math.isFinite(options.loopStart) == false or std.math.isFinite(options.loopEnd) == false) {
        return error.TypeError;
    }
    const self = try Factory.chainedWithAllocator(context._arena.allocator(), .{
        EventTarget{ ._type = .audio_node },
        AudioNode.init(context, .{ .type = .scheduled_source, .inputs = 0, .outputs = 1 }),
        AudioScheduledSourceNode.init(.buffer_source),
        AudioBufferSourceNode{
            ._proto = undefined,
            ._playback_rate = try kRateParam(context, 1),
            ._detune = try kRateParam(context, 0),
            ._loop = options.loop,
            ._loop_start = options.loopStart,
            ._loop_end = options.loopEnd,
        },
    });
    try self._playback_rate.setInitial(options.playbackRate);
    try self._detune.setInitial(options.detune);
    try self.asNode().setup(.{});
    if (options.buffer) |buffer| {
        try self.setBuffer(buffer);
    }
    return self;
}

fn kRateParam(context: *BaseAudioContext, default: f32) !*AudioParam {
    return AudioParam.init(context, .{ .default = default, .rate = .@"k-rate", .fixed_rate = true });
}

fn asNode(self: *AudioBufferSourceNode) *AudioNode {
    return self._proto._proto;
}

// The context releases what its nodes hold when it goes away.
pub fn deinit(self: *AudioBufferSourceNode, page: *Page) void {
    self.releaseBuffer(page);
}

fn releaseBuffer(self: *AudioBufferSourceNode, page: *Page) void {
    if (self._buffer) |buffer| {
        self._buffer = null;
        buffer.releaseRef(page);
    }
}

fn getBuffer(self: *const AudioBufferSourceNode) ?*AudioBuffer {
    return self._buffer;
}

fn setBuffer(self: *AudioBufferSourceNode, buffer_: ?*AudioBuffer) !void {
    const buffer = buffer_ orelse {
        self.releaseBuffer(self.asNode()._context._page);
        return;
    };
    if (self._buffer_set) {
        return error.InvalidStateError;
    }
    self._buffer_set = true;
    buffer.acquireRef();
    self.releaseBuffer(self.asNode()._context._page);
    self._buffer = buffer;
}

fn getPlaybackRate(self: *const AudioBufferSourceNode) *AudioParam {
    return self._playback_rate;
}

fn getDetune(self: *const AudioBufferSourceNode) *AudioParam {
    return self._detune;
}

fn getLoop(self: *const AudioBufferSourceNode) bool {
    return self._loop;
}

fn setLoop(self: *AudioBufferSourceNode, loop: bool) void {
    self._loop = loop;
}

fn getLoopStart(self: *const AudioBufferSourceNode) f64 {
    return self._loop_start;
}

fn setLoopStart(self: *AudioBufferSourceNode, value: f64) !void {
    if (std.math.isFinite(value) == false) return error.TypeError;
    self._loop_start = value;
}

fn getLoopEnd(self: *const AudioBufferSourceNode) f64 {
    return self._loop_end;
}

fn setLoopEnd(self: *AudioBufferSourceNode, value: f64) !void {
    if (std.math.isFinite(value) == false) return error.TypeError;
    self._loop_end = value;
}

fn start(self: *AudioBufferSourceNode, when: ?f64, offset_: ?f64, duration: ?f64) !void {
    const offset = offset_ orelse 0;
    if (std.math.isFinite(offset) == false) return error.TypeError;
    if (offset < 0) return error.RangeError;
    if (duration) |d| {
        if (std.math.isFinite(d) == false) return error.TypeError;
        if (d < 0) return error.RangeError;
    }
    try self._proto.start(when);
    self._offset = offset;
    self._duration = duration;
    self._started_empty = self._buffer == null;
}

pub fn process(self: *AudioBufferSourceNode, r: *render.Quantum, output: *Bus) !void {
    const base = self._proto;
    // Started without a buffer, or had it cleared since: it ends right away.
    if (base._state != .unscheduled and (self._started_empty or self._buffer == null)) {
        try base.finish(r);
    }
    // A source that isn't playing a buffer outputs one silent channel.
    const buffer = self._buffer orelse return silence(r, output);
    if (base._state == .finished) {
        return silence(r, output);
    }

    const channel_count = buffer.numberOfChannels();
    try output.setChannels(r.allocator, channel_count);
    const schedule = try base.schedule(r, output);
    if (schedule.frames == 0) {
        return;
    }

    var channels: [AudioBuffer.max_channels][]const f32 = undefined;
    var length: usize = buffer.frameCount();
    for (0..channel_count) |c| {
        channels[c] = buffer.channelData(c, r.local);
        // detached arrays read as silence
        length = @min(length, channels[c].len);
    }
    const end = schedule.offset + schedule.frames;
    if (length == 0) {
        output.zeroFrames(schedule.offset, end);
        return base.finish(r);
    }

    const buffer_rate: f64 = buffer.sampleRate();
    const len_f: f64 = @floatFromInt(length);
    const rate = try self.computeRate(r, buffer_rate);
    if (self._started_playing == false) {
        self._started_playing = true;
        const offset = @min(self._offset * buffer_rate, len_f);
        // at the native rate, start on a whole frame rather than interpolate
        self._position = if (rate == 1) @round(offset) else offset;
    }

    const loop = self.loopFrames(buffer_rate, len_f);
    if (loop) |l| {
        if (@abs(rate) > l.end - l.start) {
            output.zeroFrames(schedule.offset, end);
            return;
        }
        if (rate >= 0 and self._position >= l.end) {
            self._position = @min(l.start, len_f - 1);
        } else if (rate < 0 and self._position < l.start) {
            self._position = l.start;
        }
    }
    const grain_frames: ?f64 = if (self._duration) |d| d * buffer_rate else null;

    var frame = schedule.offset;
    while (frame < end) : (frame += 1) {
        if (grain_frames) |g| {
            if (self._played >= g) break;
        }
        var position = self._position;
        if (loop) |l| {
            if (rate >= 0 and position >= l.end) {
                position -= l.end - l.start;
            } else if (rate < 0 and position < l.start) {
                position += l.end - l.start;
            }
        } else if ((rate >= 0 and position >= len_f) or position < 0) {
            break;
        }

        const index: usize = @intFromFloat(@floor(position));
        const fraction: f32 = @floatCast(position - @floor(position));
        const next = if (loop) |l| blk: {
            const loop_end: usize = @intFromFloat(@ceil(l.end));
            break :blk if (index + 1 < loop_end) index + 1 else @as(usize, @intFromFloat(l.start));
        } else @min(index + 1, length - 1);
        for (0..channel_count) |c| {
            const data = channels[c];
            if (index >= length) {
                output.channel(c)[frame] = 0;
                continue;
            }
            const s0 = data[index];
            const s1 = data[@min(next, length - 1)];
            output.channel(c)[frame] = s0 + (s1 - s0) * fraction;
        }

        self._position = position + rate;
        self._played += @abs(rate);
    }

    if (frame < end) {
        output.zeroFrames(frame, Bus.quantum);
        try base.finish(r);
    }
}

fn silence(r: *render.Quantum, output: *Bus) !void {
    try output.setChannels(r.allocator, 1);
    output.zero();
}

fn computeRate(self: *AudioBufferSourceNode, r: *render.Quantum, buffer_rate: f64) !f64 {
    const playback_rate = try self._playback_rate.finalValue(r);
    const detune = try self._detune.finalValue(r);
    const sample_rate_factor = buffer_rate / r.sample_rate;
    var rate = sample_rate_factor * playback_rate * math.exp2f(detune / 1200);
    if (std.math.isFinite(rate) == false) {
        rate = 0;
    }
    return std.math.clamp(rate, -max_rate, max_rate);
}

const Loop = struct { start: f64, end: f64 };

// The loop region in buffer frames: loopStart and loopEnd clamped to the
// buffer (a loopEnd of 0 meaning its end), or the whole buffer when that's
// empty.
fn loopFrames(self: *const AudioBufferSourceNode, buffer_rate: f64, length: f64) ?Loop {
    if (self._loop == false) {
        return null;
    }
    const loop_start = std.math.clamp(self._loop_start * buffer_rate, 0, length);
    const loop_end = if (self._loop_end == 0) length else std.math.clamp(self._loop_end * buffer_rate, 0, length);
    if (loop_start < loop_end) {
        return .{ .start = loop_start, .end = loop_end };
    }
    return .{ .start = 0, .end = length };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioBufferSourceNode);

    pub const Meta = struct {
        pub const name = "AudioBufferSourceNode";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AudioBufferSourceNode.constructor, .{});
    pub const buffer = bridge.accessor(AudioBufferSourceNode.getBuffer, AudioBufferSourceNode.setBuffer, .{});
    pub const playbackRate = bridge.accessor(AudioBufferSourceNode.getPlaybackRate, null, .{});
    pub const detune = bridge.accessor(AudioBufferSourceNode.getDetune, null, .{});
    pub const loop = bridge.accessor(AudioBufferSourceNode.getLoop, AudioBufferSourceNode.setLoop, .{});
    pub const loopStart = bridge.accessor(AudioBufferSourceNode.getLoopStart, AudioBufferSourceNode.setLoopStart, .{});
    pub const loopEnd = bridge.accessor(AudioBufferSourceNode.getLoopEnd, AudioBufferSourceNode.setLoopEnd, .{});
    pub const start = bridge.function(AudioBufferSourceNode.start, .{});
};
