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

// https://webaudio.github.io/web-audio-api/#ConstantSourceNode

const js = @import("../../js/js.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const render = @import("render.zig");
const AudioNode = @import("AudioNode.zig");
const AudioParam = @import("AudioParam.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const AudioScheduledSourceNode = @import("AudioScheduledSourceNode.zig");

const ConstantSourceNode = @This();

pub const Proto = AudioScheduledSourceNode;

_proto: *AudioScheduledSourceNode,
_offset: *AudioParam,

const Options = struct {
    offset: f32 = 1,
};

fn constructor(context: *BaseAudioContext, options_: ?Options) !*ConstantSourceNode {
    return create(context, options_ orelse .{});
}

pub fn create(context: *BaseAudioContext, options: Options) !*ConstantSourceNode {
    const self = try Factory.chainedWithAllocator(context._arena.allocator(), .{
        EventTarget{ ._type = .audio_node },
        AudioNode.init(context, .{ .type = .scheduled_source, .inputs = 0, .outputs = 1 }),
        AudioScheduledSourceNode.init(.constant_source),
        ConstantSourceNode{ ._proto = undefined, ._offset = try AudioParam.init(context, .{ .default = 1 }) },
    });
    try self._offset.setInitial(options.offset);
    try self._proto._proto.setup(.{});
    return self;
}

fn getOffset(self: *const ConstantSourceNode) *AudioParam {
    return self._offset;
}

pub fn process(self: *ConstantSourceNode, r: *render.Quantum, output: *Bus) !void {
    try output.setChannels(r.allocator, 1);
    const schedule = try self._proto.schedule(r, output);
    if (schedule.frames == 0) {
        return;
    }
    var values: [Bus.quantum]f32 = undefined;
    try self._offset.sampleAccurateValues(r, &values);
    const start = schedule.offset;
    @memcpy(output.channel(0)[start..][0..schedule.frames], values[start..][0..schedule.frames]);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ConstantSourceNode);

    pub const Meta = struct {
        pub const name = "ConstantSourceNode";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ConstantSourceNode.constructor, .{});
    pub const offset = bridge.accessor(ConstantSourceNode.getOffset, null, .{});
};
