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

// https://webaudio.github.io/web-audio-api/#OscillatorNode

const std = @import("std");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const math = @import("dsp/math.zig");
const oscillator = @import("dsp/oscillator.zig");
const Wavetable = @import("dsp/PeriodicWave.zig");
const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const AudioParam = @import("AudioParam.zig");
const PeriodicWave = @import("PeriodicWave.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioScheduledSourceNode = @import("AudioScheduledSourceNode.zig");

const OscillatorNode = @This();

pub const Proto = AudioScheduledSourceNode;

// 1200 * log2(FLT_MAX)
const max_detune: f32 = 153600;

_proto: *AudioScheduledSourceNode,
_frequency: *AudioParam,
_detune: *AudioParam,
_type: OscillatorType = .sine,
_table: *const Wavetable,
// holds a ref while set
_custom: ?*PeriodicWave = null,
_virtual_read_index: f64 = 0,

pub const OscillatorType = enum {
    sine,
    square,
    sawtooth,
    triangle,
    custom,

    pub const js_enum_from_string = true;
};

const Options = struct {
    channelCount: ?u32 = null,
    channelCountMode: ?AudioNode.ChannelCountMode = null,
    channelInterpretation: ?AudioNode.ChannelInterpretation = null,
    detune: f32 = 0,
    frequency: f32 = 440,
    periodicWave: ?*PeriodicWave = null,
    type: OscillatorType = .sine,
};

fn constructor(context: *BaseAudioContext, options_: ?Options) !*OscillatorNode {
    return create(context, options_ orelse .{});
}

pub fn create(context: *BaseAudioContext, options: Options) !*OscillatorNode {
    if (options.type == .custom and options.periodicWave == null) {
        return error.InvalidStateError;
    }
    const nyquist = context._sample_rate / 2;
    const self = try Factory.chainedWithAllocator(context._arena.allocator(), .{
        EventTarget{ ._type = .audio_node },
        AudioNode.init(context, .{ .type = .scheduled_source, .inputs = 0, .outputs = 1 }),
        AudioScheduledSourceNode.init(.oscillator),
        OscillatorNode{
            ._proto = undefined,
            ._frequency = try AudioParam.init(context, .{ .default = 440, .min = -nyquist, .max = nyquist }),
            ._detune = try AudioParam.init(context, .{ .default = 0, .min = -max_detune, .max = max_detune }),
            ._table = undefined,
        },
    });
    try self._frequency.setInitial(options.frequency);
    try self._detune.setInitial(options.detune);
    if (options.periodicWave) |wave| {
        self.setPeriodicWave(wave);
    } else {
        try self.setBasicType(options.type);
    }
    try self.asNode().setup(.{
        .channelCount = options.channelCount,
        .channelCountMode = options.channelCountMode,
        .channelInterpretation = options.channelInterpretation,
    });
    return self;
}

fn asNode(self: *OscillatorNode) *AudioNode {
    return self._proto._proto;
}

fn audioContext(self: *OscillatorNode) *BaseAudioContext {
    return self.asNode()._context;
}

fn getType(self: *const OscillatorNode) []const u8 {
    return @tagName(self._type);
}

// An unknown enum value is ignored, as for any IDL enum attribute.
fn setType(self: *OscillatorNode, value: []const u8) !void {
    const typ = std.meta.stringToEnum(OscillatorType, value) orelse return;
    if (typ == .custom) {
        return error.InvalidStateError;
    }
    try self.setBasicType(typ);
}

fn setBasicType(self: *OscillatorNode, typ: OscillatorType) !void {
    const shape: Wavetable.Shape = switch (typ) {
        .sine => .sine,
        .square => .square,
        .sawtooth => .sawtooth,
        .triangle => .triangle,
        .custom => unreachable,
    };
    self._table = try self.audioContext().basicWave(shape);
    self.releaseCustom(self.audioContext()._page);
    self._type = typ;
}

fn setPeriodicWave(self: *OscillatorNode, wave: *PeriodicWave) void {
    wave.acquireRef();
    self.releaseCustom(self.audioContext()._page);
    self._custom = wave;
    self._table = &wave._table;
    self._type = .custom;
}

fn releaseCustom(self: *OscillatorNode, page: *Page) void {
    if (self._custom) |wave| {
        self._custom = null;
        wave.releaseRef(page);
    }
}

// The context releases what its nodes hold when it goes away.
pub fn deinit(self: *OscillatorNode, page: *Page) void {
    self.releaseCustom(page);
}

fn getFrequency(self: *const OscillatorNode) *AudioParam {
    return self._frequency;
}

fn getDetune(self: *const OscillatorNode) *AudioParam {
    return self._detune;
}

pub fn process(self: *OscillatorNode, r: *render.Quantum, output: *Bus) !void {
    try output.setChannels(r.allocator, 1);
    const schedule = try self._proto.schedule(r, output);
    if (schedule.frames == 0) {
        return;
    }

    const table = self._table;
    const nyquist = r.sample_rate / 2;

    var increments: [Bus.quantum]f32 = undefined;
    var frequency: f32 = 0;
    const sample_accurate = try self.phaseIncrements(r, &increments, &frequency);
    frequency = if (sample_accurate) 0 else clampFrequency(frequency, nyquist);

    var index = self._virtual_read_index;
    var destination_index = schedule.offset;
    var n = schedule.frames;
    if (schedule.start_frame_offset > 0) {
        destination_index += 1;
        n -= 1;
        index += (1 - schedule.start_frame_offset) * frequency * table.rate_scale;
    } else if (schedule.start_frame_offset < 0) {
        index = -schedule.start_frame_offset * frequency * table.rate_scale;
    }
    // a negative frequency moves the start index below 0
    const size: f64 = @floatFromInt(table.size);
    index -= @floor(index / size) * size;

    const destination = output.channel(0)[destination_index..][0..n];
    if (sample_accurate) {
        // Chrome reads the increments from the quantum's first frame even
        // when the source starts part way in.
        index = oscillator.processARate(table, destination, index, increments[0..n]);
    } else {
        index = oscillator.processKRate(table, destination, index, frequency);
    }
    self._virtual_read_index = index;
}

// Port of Chrome's OscillatorHandler::CalculateSampleAccuratePhaseIncrements.
// When neither param needs per-frame values, `frequency` gets the k-rate
// (detuned) frequency instead.
fn phaseIncrements(self: *OscillatorNode, r: *render.Quantum, increments: *[Bus.quantum]f32, frequency: *f32) !bool {
    var sample_accurate = false;
    var frequency_changes = false;
    var final_scale = self._table.rate_scale;

    if (self._frequency.isAudioRate() and self._frequency.hasSampleAccurateValues(r)) {
        sample_accurate = true;
        frequency_changes = true;
        try self._frequency.sampleAccurateValues(r, increments);
    } else {
        frequency.* = try self._frequency.finalValue(r);
        final_scale *= frequency.*;
    }

    if (self._detune.isAudioRate() and self._detune.hasSampleAccurateValues(r)) {
        sample_accurate = true;
        var detunes: [Bus.quantum]f32 = undefined;
        const values = if (frequency_changes) &detunes else increments;
        try self._detune.sampleAccurateValues(r, values);
        const k: f32 = 1.0 / 1200.0;
        for (values) |*v| v.* = math.exp2f(v.* * k);
        if (frequency_changes) {
            for (increments, detunes) |*inc, d| inc.* = d * inc.*;
        }
    } else {
        const multiplier = math.exp2f(try self._detune.finalValue(r) / 1200);
        final_scale *= multiplier;
        frequency.* *= multiplier;
    }

    if (sample_accurate) {
        const nyquist = r.sample_rate / 2;
        for (increments) |*inc| inc.* = clampFrequency(inc.*, nyquist) * final_scale;
    }
    return sample_accurate;
}

fn clampFrequency(frequency: f32, nyquist: f32) f32 {
    if (std.math.isNan(frequency)) {
        return nyquist;
    }
    return std.math.clamp(frequency, -nyquist, nyquist);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OscillatorNode);

    pub const Meta = struct {
        pub const name = "OscillatorNode";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(OscillatorNode.constructor, .{});
    pub const @"type" = bridge.accessor(OscillatorNode.getType, OscillatorNode.setType, .{});
    pub const frequency = bridge.accessor(OscillatorNode.getFrequency, null, .{});
    pub const detune = bridge.accessor(OscillatorNode.getDetune, null, .{});
    pub const setPeriodicWave = bridge.function(OscillatorNode.setPeriodicWave, .{});
};
