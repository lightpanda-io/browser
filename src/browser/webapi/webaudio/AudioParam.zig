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

// https://webaudio.github.io/web-audio-api/#AudioParam

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Bus = @import("dsp/Bus.zig");
const Timeline = @import("dsp/Timeline.zig");
const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const AudioContext = @import("AudioContext.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const AudioParam = @This();

// Lives in its context's arena; a wrapper keeps the whole context alive.
_context: *BaseAudioContext,
_default: f32,
_min: f32,
_max: f32,
_rate: Rate,
_fixed_rate: bool,
// [[current value]]: what `value` reads. Rendering updates it.
_intrinsic: f32,
// realtime only: the quantum _intrinsic was last brought up to
_rendered_frame: u64 = 0,
_timeline: Timeline = .{},
// nodes connected to this param
_sources: std.ArrayList(*AudioNode) = .empty,
_sum: Bus = .{},

pub const Rate = enum { @"a-rate", @"k-rate" };

pub const Descriptor = struct {
    default: f32,
    min: f32 = -std.math.floatMax(f32),
    max: f32 = std.math.floatMax(f32),
    rate: Rate = .@"a-rate",
    // a rate the spec doesn't let script change
    fixed_rate: bool = false,
};

pub fn init(context: *BaseAudioContext, descriptor: Descriptor) !*AudioParam {
    const param = try context._arena.allocator().create(AudioParam);
    param.* = .{
        ._context = context,
        ._default = descriptor.default,
        ._min = descriptor.min,
        ._max = descriptor.max,
        ._rate = descriptor.rate,
        ._fixed_rate = descriptor.fixed_rate,
        ._intrinsic = descriptor.default,
    };
    if (context._type == .realtime) {
        param._rendered_frame = context.subtype(AudioContext).currentFrame();
    }
    return param;
}

pub fn acquireRef(self: *AudioParam) void {
    self._context.acquireRef();
}

pub fn releaseRef(self: *AudioParam, page: *Page) void {
    self._context.releaseRef(page);
}

// For a node's options dictionary: the initial value, as if set before any
// automation (no event is scheduled).
pub fn setInitial(self: *AudioParam, value: f32) !void {
    try finite(value);
    self._intrinsic = std.math.clamp(value, self._min, self._max);
}

fn getValue(self: *AudioParam) f32 {
    self.catchUp();
    return self._intrinsic;
}

// An AudioContext doesn't render, so _intrinsic is brought up to what
// rendering the quanta elapsed since the last catch-up would have left in it,
// as computeValues does. Automation for the current quantum shows once it has
// passed, as in Chrome.
fn catchUp(self: *AudioParam) void {
    if (self._context._type != .realtime) {
        return;
    }
    const frame = self._context.subtype(AudioContext).currentFrame();
    if (frame == self._rendered_frame) {
        return;
    }
    self._rendered_frame = frame;
    if (self._timeline.isEmpty()) {
        return;
    }
    // a-rate leaves the quantum's last frame, k-rate its first
    const last = switch (self._rate) {
        .@"a-rate" => frame - 1,
        .@"k-rate" => frame - Bus.quantum,
    };
    const sample_rate: f64 = self._context._sample_rate;
    const t = @as(f64, @floatFromInt(last)) / sample_rate;
    self._intrinsic = std.math.clamp(self._timeline.valueAt(t, self._intrinsic), self._min, self._max);
}

fn setValue(self: *AudioParam, value: f32) !void {
    try finite(value);
    self.catchUp();
    self._intrinsic = std.math.clamp(value, self._min, self._max);
    _ = try self.setValueAtTime(self._intrinsic, self._context.currentTime());
}

fn getAutomationRate(self: *const AudioParam) []const u8 {
    return @tagName(self._rate);
}

// An unknown enum value is ignored, as for any IDL enum attribute.
fn setAutomationRate(self: *AudioParam, value: []const u8) !void {
    const rate = std.meta.stringToEnum(Rate, value) orelse return;
    if (self._fixed_rate and rate != self._rate) {
        return error.InvalidStateError;
    }
    self._rate = rate;
}

fn getDefaultValue(self: *const AudioParam) f32 {
    return self._default;
}

fn getMinValue(self: *const AudioParam) f32 {
    return self._min;
}

fn getMaxValue(self: *const AudioParam) f32 {
    return self._max;
}

fn setValueAtTime(self: *AudioParam, value: f32, start_time: f64) !*AudioParam {
    try finite(value);
    const time = try self.eventTime(start_time);
    try self.insert(.{ .kind = .set_value, .time = time, .value = value });
    return self;
}

fn linearRampToValueAtTime(self: *AudioParam, value: f32, end_time: f64) !*AudioParam {
    try finite(value);
    const time = try self.eventTime(end_time);
    try self.insert(self.ramp(.linear_ramp, value, time));
    return self;
}

fn exponentialRampToValueAtTime(self: *AudioParam, value: f32, end_time: f64) !*AudioParam {
    try finite(value);
    if (value == 0) {
        return error.RangeError;
    }
    const time = try self.eventTime(end_time);
    try self.insert(self.ramp(.exponential_ramp, value, time));
    return self;
}

fn setTargetAtTime(self: *AudioParam, target: f32, start_time: f64, time_constant: f32) !*AudioParam {
    try finite(target);
    try finite(time_constant);
    if (time_constant < 0) {
        return error.RangeError;
    }
    const time = try self.eventTime(start_time);
    try self.insert(.{ .kind = .set_target, .time = time, .value = target, .time_constant = time_constant });
    return self;
}

fn setValueCurveAtTime(self: *AudioParam, values: []const f32, start_time: f64, duration: f64) !*AudioParam {
    for (values) |v| try finite(v);
    if (values.len < 2) {
        return error.InvalidStateError;
    }
    if (std.math.isFinite(duration) == false) {
        return error.TypeError;
    }
    if (duration <= 0) {
        return error.RangeError;
    }
    const time = try self.eventTime(start_time);
    const curve = try self._context._arena.allocator().dupe(f32, values);
    try self.insert(.{ .kind = .set_value_curve, .time = time, .duration = duration, .end_time = time + duration, .curve = curve });
    return self;
}

fn cancelScheduledValues(self: *AudioParam, cancel_time: f64) !*AudioParam {
    const time = try self.eventTime(cancel_time);
    self.catchUp();
    self._timeline.cancelScheduledValues(time);
    return self;
}

fn cancelAndHoldAtTime(self: *AudioParam, cancel_time: f64) !*AudioParam {
    const time = try self.eventTime(cancel_time);
    self.catchUp();
    try self._timeline.cancelAndHoldAtTime(self._context._arena.allocator(), time);
    return self;
}

// Times must be finite and non-negative; past times mean "now".
fn eventTime(self: *const AudioParam, time: f64) !f64 {
    if (std.math.isFinite(time) == false) {
        return error.TypeError;
    }
    if (time < 0) {
        return error.RangeError;
    }
    return @max(time, self._context.currentTime());
}

fn ramp(self: *AudioParam, kind: Timeline.Kind, value: f32, time: f64) Timeline.Event {
    self.catchUp();
    return .{
        .kind = kind,
        .time = time,
        .value = value,
        .start_time = self._context.currentTime(),
        .start_value = self._intrinsic,
    };
}

fn insert(self: *AudioParam, event: Timeline.Event) !void {
    self.catchUp();
    // Rendering prunes as it goes; without it, the past is dropped here.
    if (self._context._type == .realtime) {
        self._timeline.prune(self._context.currentTime());
    }
    return self._timeline.insert(self._context._arena.allocator(), event, self._intrinsic);
}

fn finite(value: f32) !void {
    if (std.math.isFinite(value) == false) {
        return error.TypeError;
    }
}

pub fn connect(self: *AudioParam, source: *AudioNode) !void {
    for (self._sources.items) |s| {
        if (s == source) return;
    }
    try self._sources.append(self._context._arena.allocator(), source);
}

pub fn disconnect(self: *AudioParam, source: *AudioNode) bool {
    for (self._sources.items, 0..) |s, i| {
        if (s == source) {
            _ = self._sources.orderedRemove(i);
            return true;
        }
    }
    return false;
}

// Whether this quantum needs per-frame values. Nodes with a cheaper path for
// a constant value (the oscillator) check this first.
pub fn hasSampleAccurateValues(self: *AudioParam, r: *const render.Quantum) bool {
    if (self._sources.items.len > 0) {
        return true;
    }
    const sample_rate: f64 = r.sample_rate;
    const start: f64 = @floatFromInt(r.frame);
    self._timeline.prune(start / sample_rate);
    return self._timeline.hasSampleAccurateValues(start / sample_rate, (start + Bus.quantum) / sample_rate);
}

pub fn isAudioRate(self: *const AudioParam) bool {
    return self._rate == .@"a-rate";
}

// The k-rate value: the timeline at the quantum's start, plus the inputs'
// first frame.
pub fn finalValue(self: *AudioParam, r: *render.Quantum) !f32 {
    var values: [1]f32 = undefined;
    try self.computeValues(r, &values, false);
    return values[0];
}

// The computedValue for each frame of the quantum (`values.len` frames), or
// one value repeated when not sample accurate.
pub fn sampleAccurateValues(self: *AudioParam, r: *render.Quantum, values: *[Bus.quantum]f32) !void {
    try self.computeValues(r, values, self.isAudioRate() and self.hasSampleAccurateValues(r));
}

fn computeValues(self: *AudioParam, r: *render.Quantum, values: []f32, sample_accurate: bool) !void {
    const sample_rate: f64 = r.sample_rate;
    const now = @as(f64, @floatFromInt(r.frame)) / sample_rate;
    const timeline = &self._timeline;
    timeline.prune(now);

    if (sample_accurate) {
        for (values, 0..) |*v, i| {
            const t = @as(f64, @floatFromInt(r.frame + i)) / sample_rate;
            v.* = std.math.clamp(timeline.valueAt(t, self._intrinsic), self._min, self._max);
        }
        self._intrinsic = values[values.len - 1];
    } else {
        var value = self._intrinsic;
        if (timeline.isEmpty() == false) {
            value = std.math.clamp(timeline.valueAt(now, value), self._min, self._max);
        }
        @memset(values, value);
        self._intrinsic = value;
    }

    if (self._sources.items.len == 0) {
        return;
    }

    // Connected outputs are summed in, down-mixed to mono.
    try self._sum.setChannels(r.allocator, 1);
    self._sum.zero();
    for (self._sources.items) |source| {
        self._sum.sumFrom(try source.pull(r), .speakers);
    }
    const sum = self._sum.channel(0);
    if (sample_accurate) {
        for (values, sum[0..values.len]) |*v, s| v.* += s;
    } else {
        const first = values[0] + sum[0];
        @memset(values, first);
    }
    for (values) |*v| {
        if (std.math.isNan(v.*)) v.* = self._default;
        v.* = std.math.clamp(v.*, self._min, self._max);
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioParam);

    pub const Meta = struct {
        pub const name = "AudioParam";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const value = bridge.accessor(AudioParam.getValue, AudioParam.setValue, .{});
    pub const automationRate = bridge.accessor(AudioParam.getAutomationRate, AudioParam.setAutomationRate, .{});
    pub const defaultValue = bridge.accessor(AudioParam.getDefaultValue, null, .{});
    pub const minValue = bridge.accessor(AudioParam.getMinValue, null, .{});
    pub const maxValue = bridge.accessor(AudioParam.getMaxValue, null, .{});
    pub const setValueAtTime = bridge.function(AudioParam.setValueAtTime, .{});
    pub const linearRampToValueAtTime = bridge.function(AudioParam.linearRampToValueAtTime, .{});
    pub const exponentialRampToValueAtTime = bridge.function(AudioParam.exponentialRampToValueAtTime, .{});
    pub const setTargetAtTime = bridge.function(AudioParam.setTargetAtTime, .{});
    pub const setValueCurveAtTime = bridge.function(AudioParam.setValueCurveAtTime, .{});
    pub const cancelScheduledValues = bridge.function(AudioParam.cancelScheduledValues, .{});
    pub const cancelAndHoldAtTime = bridge.function(AudioParam.cancelAndHoldAtTime, .{});
};
