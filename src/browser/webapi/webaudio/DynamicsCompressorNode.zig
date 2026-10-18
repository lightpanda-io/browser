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

// https://webaudio.github.io/web-audio-api/#DynamicsCompressorNode

const std = @import("std");

const js = @import("../../js/js.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const Compressor = @import("dsp/Compressor.zig");
const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const AudioParam = @import("AudioParam.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const DynamicsCompressorNode = @This();

pub const Proto = AudioNode;

_proto: *AudioNode,
_threshold: *AudioParam,
_knee: *AudioParam,
_ratio: *AudioParam,
_attack: *AudioParam,
_release: *AudioParam,
_kernel: Compressor,
_reduction: f32 = 0,

const Options = struct {
    attack: f32 = 0.003,
    channelCount: ?u32 = null,
    channelCountMode: ?AudioNode.ChannelCountMode = null,
    channelInterpretation: ?AudioNode.ChannelInterpretation = null,
    knee: f32 = 30,
    ratio: f32 = 12,
    release: f32 = 0.25,
    threshold: f32 = -24,
};

fn constructor(context: *BaseAudioContext, options_: ?Options) !*DynamicsCompressorNode {
    return create(context, options_ orelse .{});
}

pub fn create(context: *BaseAudioContext, options: Options) !*DynamicsCompressorNode {
    const self = try Factory.chainedWithAllocator(context._arena.allocator(), .{
        EventTarget{ ._type = .audio_node },
        AudioNode.init(context, .{
            .type = .dynamics_compressor,
            .inputs = 1,
            .outputs = 1,
            .channel_count_mode = .@"clamped-max",
            .rules = .{ .max_channel_count = 2, .no_max_mode = true },
        }),
        DynamicsCompressorNode{
            ._proto = undefined,
            ._threshold = try param(context, -24, -100, 0),
            ._knee = try param(context, 30, 0, 40),
            ._ratio = try param(context, 12, 1, 20),
            ._attack = try param(context, 0.003, 0, 1),
            ._release = try param(context, 0.25, 0, 1),
            ._kernel = .init(context._sample_rate),
        },
    });
    try self._threshold.setInitial(options.threshold);
    try self._knee.setInitial(options.knee);
    try self._ratio.setInitial(options.ratio);
    try self._attack.setInitial(options.attack);
    try self._release.setInitial(options.release);
    try self._proto.setup(.{
        .channelCount = options.channelCount,
        .channelCountMode = options.channelCountMode,
        .channelInterpretation = options.channelInterpretation,
    });
    return self;
}

fn param(context: *BaseAudioContext, default: f32, min: f32, max: f32) !*AudioParam {
    return AudioParam.init(context, .{ .default = default, .min = min, .max = max, .rate = .@"k-rate", .fixed_rate = true });
}

fn getThreshold(self: *const DynamicsCompressorNode) *AudioParam {
    return self._threshold;
}

fn getKnee(self: *const DynamicsCompressorNode) *AudioParam {
    return self._knee;
}

fn getRatio(self: *const DynamicsCompressorNode) *AudioParam {
    return self._ratio;
}

fn getAttack(self: *const DynamicsCompressorNode) *AudioParam {
    return self._attack;
}

fn getRelease(self: *const DynamicsCompressorNode) *AudioParam {
    return self._release;
}

fn getReduction(self: *const DynamicsCompressorNode) f32 {
    return self._reduction;
}

// The kernel runs two channels whatever the input, as Chrome's does.
pub fn process(self: *DynamicsCompressorNode, r: *render.Quantum, input: *const Bus, output: *Bus) !void {
    const params: Compressor.Params = .{
        .threshold = try self._threshold.finalValue(r),
        .knee = try self._knee.finalValue(r),
        .ratio = try self._ratio.finalValue(r),
        .attack = try self._attack.finalValue(r),
        .release = try self._release.finalValue(r),
    };

    try output.setChannels(r.allocator, Compressor.channels);
    var source: [Compressor.channels][]const f32 = undefined;
    for (0..@min(input.channels, Compressor.channels)) |c| {
        source[c] = input.constChannel(c);
    }
    const destination: [Compressor.channels][]f32 = .{ output.channel(0), output.channel(1) };
    self._kernel.process(source[0..@min(input.channels, Compressor.channels)], &destination, params);
    self._reduction = self._kernel.reduction();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DynamicsCompressorNode);

    pub const Meta = struct {
        pub const name = "DynamicsCompressorNode";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(DynamicsCompressorNode.constructor, .{});
    pub const threshold = bridge.accessor(DynamicsCompressorNode.getThreshold, null, .{});
    pub const knee = bridge.accessor(DynamicsCompressorNode.getKnee, null, .{});
    pub const ratio = bridge.accessor(DynamicsCompressorNode.getRatio, null, .{});
    pub const attack = bridge.accessor(DynamicsCompressorNode.getAttack, null, .{});
    pub const release = bridge.accessor(DynamicsCompressorNode.getRelease, null, .{});
    pub const reduction = bridge.accessor(DynamicsCompressorNode.getReduction, null, .{});
};
