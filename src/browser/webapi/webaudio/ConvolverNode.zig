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

// https://webaudio.github.io/web-audio-api/#ConvolverNode

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const AudioBuffer = @import("AudioBuffer.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");

const ConvolverNode = @This();

pub const Proto = AudioNode;

_proto: *AudioNode,
_buffer: ?*AudioBuffer = null,
_normalize: bool = true,

const Options = struct {
    buffer: ?*AudioBuffer = null,
    channelCount: ?u32 = null,
    channelCountMode: ?AudioNode.ChannelCountMode = null,
    channelInterpretation: ?AudioNode.ChannelInterpretation = null,
    disableNormalization: bool = false,
};

fn constructor(context: *BaseAudioContext, options_: ?Options) !*ConvolverNode {
    return create(context, options_ orelse .{});
}

pub fn create(context: *BaseAudioContext, options: Options) !*ConvolverNode {
    const self = try Factory.chainedWithAllocator(context._arena.allocator(), .{
        EventTarget{ ._type = .audio_node },
        AudioNode.init(context, .{
            .type = .convolver,
            .inputs = 1,
            .outputs = 1,
            .channel_count_mode = .@"clamped-max",
            .rules = .{ .max_channel_count = 2, .no_max_mode = true },
        }),
        ConvolverNode{ ._proto = undefined, ._normalize = options.disableNormalization == false },
    });
    try self._proto.setup(.{
        .channelCount = options.channelCount,
        .channelCountMode = options.channelCountMode,
        .channelInterpretation = options.channelInterpretation,
    });
    if (options.buffer) |buffer| {
        try self.setBuffer(buffer);
    }
    return self;
}

// The context releases what its nodes hold when it goes away.
pub fn deinit(self: *ConvolverNode, page: *Page) void {
    self.releaseBuffer(page);
}

fn releaseBuffer(self: *ConvolverNode, page: *Page) void {
    if (self._buffer) |buffer| {
        self._buffer = null;
        buffer.releaseRef(page);
    }
}

fn getBuffer(self: *const ConvolverNode) ?*AudioBuffer {
    return self._buffer;
}

fn setBuffer(self: *ConvolverNode, buffer_: ?*AudioBuffer) !void {
    const page = self._proto._context._page;
    const buffer = buffer_ orelse {
        self.releaseBuffer(page);
        return;
    };
    switch (buffer.numberOfChannels()) {
        1, 2, 4 => {},
        else => return error.NotSupported,
    }
    if (buffer.sampleRate() != self._proto._context._sample_rate) {
        return error.NotSupported;
    }
    buffer.acquireRef();
    self.releaseBuffer(page);
    self._buffer = buffer;
}

fn getNormalize(self: *const ConvolverNode) bool {
    return self._normalize;
}

fn setNormalize(self: *ConvolverNode, normalize: bool) void {
    self._normalize = normalize;
}

// Silent without a response. With one, the input passes through unchanged.
// TODO(medium): convolve with the response.
pub fn process(self: *ConvolverNode, r: *render.Quantum, input: *const Bus, output: *Bus) !void {
    try output.setChannels(r.allocator, input.channels);
    if (self._buffer == null) {
        output.zero();
        return;
    }
    for (0..input.channels) |c| {
        output.channel(c).* = input.constChannel(c).*;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ConvolverNode);

    pub const Meta = struct {
        pub const name = "ConvolverNode";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ConvolverNode.constructor, .{});
    pub const buffer = bridge.accessor(ConvolverNode.getBuffer, ConvolverNode.setBuffer, .{});
    pub const normalize = bridge.accessor(ConvolverNode.getNormalize, ConvolverNode.setNormalize, .{});
};
