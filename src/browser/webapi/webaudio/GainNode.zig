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

// https://webaudio.github.io/web-audio-api/#GainNode

const std = @import("std");

const js = @import("../../js/js.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const AudioParam = @import("AudioParam.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const GainNode = @This();

pub const Proto = AudioNode;

_proto: *AudioNode,
_gain: *AudioParam,

const Options = struct {
    channelCount: ?u32 = null,
    channelCountMode: ?AudioNode.ChannelCountMode = null,
    channelInterpretation: ?AudioNode.ChannelInterpretation = null,
    gain: f32 = 1,
};

fn constructor(context: *BaseAudioContext, options_: ?Options) !*GainNode {
    return create(context, options_ orelse .{});
}

pub fn create(context: *BaseAudioContext, options: Options) !*GainNode {
    const self = try Factory.chainedWithAllocator(context._arena.allocator(), .{
        EventTarget{ ._type = .audio_node },
        AudioNode.init(context, .{ .type = .gain, .inputs = 1, .outputs = 1 }),
        GainNode{ ._proto = undefined, ._gain = try AudioParam.init(context, .{ .default = 1 }) },
    });
    try self._gain.setInitial(options.gain);
    try self._proto.setup(.{
        .channelCount = options.channelCount,
        .channelCountMode = options.channelCountMode,
        .channelInterpretation = options.channelInterpretation,
    });
    return self;
}

fn getGain(self: *const GainNode) *AudioParam {
    return self._gain;
}

pub fn process(self: *GainNode, r: *render.Quantum, input: *const Bus, output: *Bus) !void {
    try output.setChannels(r.allocator, input.channels);
    var gains: [Bus.quantum]f32 = undefined;
    try self._gain.sampleAccurateValues(r, &gains);
    for (0..input.channels) |c| {
        const in = input.constChannel(c);
        const out = output.channel(c);
        for (out, in, gains) |*o, i, g| o.* = i * g;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GainNode);

    pub const Meta = struct {
        pub const name = "GainNode";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(GainNode.constructor, .{});
    pub const gain = bridge.accessor(GainNode.getGain, null, .{});
};
