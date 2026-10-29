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

// https://webaudio.github.io/web-audio-api/#AudioDestinationNode

const js = @import("../../js/js.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const AudioNode = @import("AudioNode.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const AudioDestinationNode = @This();

pub const Proto = AudioNode;

_proto: *AudioNode,
_max_channel_count: u32,

// An OfflineAudioContext's destination. As in Chrome, script can change its
// channel count and mode: only the channels both the input and the rendered
// buffer have are written.
pub fn createOffline(context: *BaseAudioContext, channels: u32) !*AudioDestinationNode {
    return create(context, channels, channels, .{});
}

// An AudioContext's destination: a stereo device that renders nowhere.
pub fn createRealtime(context: *BaseAudioContext) !*AudioDestinationNode {
    return create(context, 2, 2, .{ .max_channel_count = 2 });
}

fn create(context: *BaseAudioContext, channels: u32, max_channel_count: u32, rules: AudioNode.ChannelRules) !*AudioDestinationNode {
    const self = try Factory.chainedWithAllocator(context._arena.allocator(), .{
        EventTarget{ ._type = .audio_node },
        AudioNode.init(context, .{
            .type = .destination,
            .inputs = 1,
            .outputs = 1,
            .channel_count = channels,
            .channel_count_mode = .explicit,
            .rules = rules,
        }),
        AudioDestinationNode{ ._proto = undefined, ._max_channel_count = max_channel_count },
    });
    try self._proto.setup(.{});
    return self;
}

pub fn asNode(self: *AudioDestinationNode) *AudioNode {
    return self._proto;
}

fn getMaxChannelCount(self: *const AudioDestinationNode) u32 {
    return self._max_channel_count;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioDestinationNode);

    pub const Meta = struct {
        pub const name = "AudioDestinationNode";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const maxChannelCount = bridge.accessor(AudioDestinationNode.getMaxChannelCount, null, .{});
};
