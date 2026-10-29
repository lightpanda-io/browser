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

// https://webaudio.github.io/web-audio-api/#AudioNode

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Factory = @import("../../Factory.zig");

const EventTarget = @import("../EventTarget.zig");

const Bus = @import("dsp/Bus.zig");
const render = @import("render.zig");
const AudioParam = @import("AudioParam.zig");
const BaseAudioContext = @import("BaseAudioContext.zig");
const GainNode = @import("GainNode.zig");
const ConvolverNode = @import("ConvolverNode.zig");
const AudioDestinationNode = @import("AudioDestinationNode.zig");
const DynamicsCompressorNode = @import("DynamicsCompressorNode.zig");
const AudioScheduledSourceNode = @import("AudioScheduledSourceNode.zig");

const AudioNode = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_type: Type,
// Every node lives in its context's arena; a node's wrapper keeps the
// context alive.
_context: *BaseAudioContext,
_inputs: u8,
_outputs: u8,
_channel_count: u32,
_channel_count_mode: ChannelCountMode,
_channel_interpretation: Bus.Interpretation,
_rules: ChannelRules = .{},
// output 0's connections
_targets: std.ArrayList(Target) = .empty,
// input 0's connections
_sources: std.ArrayList(*AudioNode) = .empty,

_input: Bus = .{},
_output: Bus = .{},
_rendered: u64 = 0,
_pulling: bool = false,

pub const Type = enum(u8) {
    convolver,
    destination,
    dynamics_compressor,
    gain,
    scheduled_source,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .convolver => ConvolverNode,
        .destination => AudioDestinationNode,
        .dynamics_compressor => DynamicsCompressorNode,
        .gain => GainNode,
        .scheduled_source => AudioScheduledSourceNode,
    };
}

pub fn subtype(self: *const AudioNode, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, AudioNode);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub const ChannelCountMode = enum {
    max,
    @"clamped-max",
    explicit,

    pub const js_enum_from_string = true;
};

pub const ChannelInterpretation = enum {
    speakers,
    discrete,

    pub const js_enum_from_string = true;
};

// What a node lets script change, beyond the general 1..32 channel count.
pub const ChannelRules = struct {
    max_channel_count: u32 = Bus.max_channels,
    // channelCountMode "max" is rejected (NotSupportedError)
    no_max_mode: bool = false,
};

pub const Target = union(enum) {
    node: *AudioNode,
    param: *AudioParam,
};

// The AudioNodeOptions every node constructor takes.
pub const Options = struct {
    channelCount: ?u32 = null,
    channelCountMode: ?ChannelCountMode = null,
    channelInterpretation: ?ChannelInterpretation = null,
};

pub const Init = struct {
    type: Type,
    inputs: u8,
    outputs: u8,
    channel_count: u32 = 2,
    channel_count_mode: ChannelCountMode = .max,
    channel_interpretation: Bus.Interpretation = .speakers,
    rules: ChannelRules = .{},
};

pub fn init(context: *BaseAudioContext, opts: Init) AudioNode {
    return .{
        ._proto = undefined,
        ._type = opts.type,
        ._context = context,
        ._inputs = opts.inputs,
        ._outputs = opts.outputs,
        ._channel_count = opts.channel_count,
        ._channel_count_mode = opts.channel_count_mode,
        ._channel_interpretation = opts.channel_interpretation,
        ._rules = opts.rules,
    };
}

// Applies a constructor's AudioNodeOptions, then registers the node with its
// context.
pub fn setup(self: *AudioNode, options: Options) !void {
    if (options.channelCount) |count| {
        try self.setChannelCount(count);
    }
    if (options.channelCountMode) |mode| {
        try self.applyChannelCountMode(mode);
    }
    if (options.channelInterpretation) |interpretation| {
        self._channel_interpretation = switch (interpretation) {
            .speakers => .speakers,
            .discrete => .discrete,
        };
    }
    try self._context.registerNode(self);
}

pub fn asEventTarget(self: *AudioNode) *EventTarget {
    return self._proto;
}

pub fn format(self: *const AudioNode, writer: *std.Io.Writer) !void {
    return writer.writeAll(self.describe("<{s}>"));
}

pub fn toString(self: *const AudioNode) []const u8 {
    return self.describe("[object {s}]");
}

// `fmt` applied to the concrete node's interface name.
fn describe(self: *const AudioNode, comptime fmt: []const u8) []const u8 {
    return switch (self._type) {
        .scheduled_source => switch (self.subtype(AudioScheduledSourceNode)._type) {
            inline else => |tag| std.fmt.comptimePrint(fmt, .{AudioScheduledSourceNode.Subtype(tag).JsApi.Meta.name}),
        },
        inline else => |tag| std.fmt.comptimePrint(fmt, .{Subtype(tag).JsApi.Meta.name}),
    };
}

pub fn acquireRef(self: *AudioNode) void {
    self._context.acquireRef();
}

pub fn releaseRef(self: *AudioNode, page: *Page) void {
    self._context.releaseRef(page);
}

fn getContext(self: *const AudioNode) *BaseAudioContext {
    return self._context;
}

fn getNumberOfInputs(self: *const AudioNode) u32 {
    return self._inputs;
}

fn getNumberOfOutputs(self: *const AudioNode) u32 {
    return self._outputs;
}

fn getChannelCount(self: *const AudioNode) u32 {
    return self._channel_count;
}

fn setChannelCount(self: *AudioNode, count: u32) !void {
    if (count == 0) {
        return error.NotSupported;
    }
    if (count > self._rules.max_channel_count) {
        // past a destination's maxChannelCount
        return if (self._type == .destination) error.IndexSizeError else error.NotSupported;
    }
    self._channel_count = count;
}

fn getChannelCountMode(self: *const AudioNode) []const u8 {
    return @tagName(self._channel_count_mode);
}

// An unknown enum value is ignored, as for any IDL enum attribute.
fn setChannelCountMode(self: *AudioNode, value: []const u8) !void {
    const mode = std.meta.stringToEnum(ChannelCountMode, value) orelse return;
    return self.applyChannelCountMode(mode);
}

fn applyChannelCountMode(self: *AudioNode, mode: ChannelCountMode) !void {
    if (self._rules.no_max_mode and mode == .max) {
        return error.NotSupported;
    }
    self._channel_count_mode = mode;
}

fn getChannelInterpretation(self: *const AudioNode) []const u8 {
    return @tagName(self._channel_interpretation);
}

fn setChannelInterpretation(self: *AudioNode, value: []const u8) void {
    self._channel_interpretation = std.meta.stringToEnum(Bus.Interpretation, value) orelse return;
}

const ConnectTarget = union(enum) {
    node: *AudioNode,
    param: *AudioParam,
};

const Connected = union(enum) {
    node: *AudioNode,
    param: js.Undefined,
};

fn connect(self: *AudioNode, destination: ConnectTarget, output_: ?u32, input_: ?u32) !Connected {
    const output = output_ orelse 0;
    if (output >= self._outputs) {
        return error.IndexSizeError;
    }
    const allocator = self._context._arena.allocator();
    switch (destination) {
        .node => |node| {
            if (node._context != self._context) {
                return error.InvalidAccessError;
            }
            const input = input_ orelse 0;
            if (input >= node._inputs) {
                return error.IndexSizeError;
            }
            if (self.findTarget(.{ .node = node }) == null) {
                try self._targets.ensureUnusedCapacity(allocator, 1);
                try node._sources.append(allocator, self);
                self._targets.appendAssumeCapacity(.{ .node = node });
            }
            return .{ .node = node };
        },
        .param => |param| {
            if (param._context != self._context) {
                return error.InvalidAccessError;
            }
            if (self.findTarget(.{ .param = param }) == null) {
                try self._targets.ensureUnusedCapacity(allocator, 1);
                try param.connect(self);
                self._targets.appendAssumeCapacity(.{ .param = param });
            }
            return .{ .param = .{} };
        },
    }
}

const DisconnectFrom = union(enum) {
    output: u32,
    node: *AudioNode,
    param: *AudioParam,
};

fn disconnect(self: *AudioNode, from_: ?DisconnectFrom, output_: ?u32, input_: ?u32) !void {
    const from = from_ orelse {
        self.disconnectAll();
        return;
    };
    switch (from) {
        .output => |output| {
            if (output >= self._outputs) {
                return error.IndexSizeError;
            }
            self.disconnectAll();
        },
        inline .node, .param => |target, tag| {
            if (output_) |output| {
                if (output >= self._outputs) return error.IndexSizeError;
            }
            if (tag == .node) {
                if (input_) |input| {
                    if (input >= target._inputs) return error.IndexSizeError;
                }
            }
            const index = self.findTarget(@unionInit(Target, @tagName(tag), target)) orelse {
                return error.InvalidAccessError;
            };
            self.removeTarget(index);
        },
    }
}

fn disconnectAll(self: *AudioNode) void {
    while (self._targets.items.len > 0) {
        self.removeTarget(self._targets.items.len - 1);
    }
}

fn findTarget(self: *const AudioNode, target: Target) ?usize {
    for (self._targets.items, 0..) |t, i| {
        if (std.meta.eql(t, target)) return i;
    }
    return null;
}

fn removeTarget(self: *AudioNode, index: usize) void {
    switch (self._targets.orderedRemove(index)) {
        .node => |node| {
            for (node._sources.items, 0..) |s, i| {
                if (s == self) {
                    _ = node._sources.orderedRemove(i);
                    break;
                }
            }
        },
        .param => |param| _ = param.disconnect(self),
    }
}

// This quantum's output, rendering it first if needed. A node reached again
// while rendering is part of a cycle, which renders silence. So does a node
// more than `render.max_depth` connections from the destination, where Chrome
// would render the whole chain.
pub fn pull(self: *AudioNode, r: *render.Quantum) anyerror!*const Bus {
    if (self._rendered == r.index) {
        return &self._output;
    }
    if (self._pulling or r.depth >= render.max_depth) {
        return r.silence;
    }
    self._pulling = true;
    r.depth += 1;
    defer {
        self._pulling = false;
        r.depth -= 1;
    }

    const input = if (self._inputs > 0) try self.pullInput(r) else null;
    switch (self._type) {
        .destination => {},
        .convolver => try self.subtype(ConvolverNode).process(r, input.?, &self._output),
        .gain => try self.subtype(GainNode).process(r, input.?, &self._output),
        .dynamics_compressor => try self.subtype(DynamicsCompressorNode).process(r, input.?, &self._output),
        .scheduled_source => try self.subtype(AudioScheduledSourceNode).process(r, &self._output),
    }
    self._rendered = r.index;
    return &self._output;
}

// The input bus: every connection mixed to the computed channel count.
fn pullInput(self: *AudioNode, r: *render.Quantum) !*const Bus {
    var max: u32 = 0;
    for (self._sources.items) |source| {
        const bus = try source.pull(r);
        max = @max(max, bus.channels);
    }
    max = @max(max, 1);
    const channels = switch (self._channel_count_mode) {
        .max => max,
        .@"clamped-max" => @min(max, self._channel_count),
        .explicit => self._channel_count,
    };

    const input = &self._input;
    try input.setChannels(r.allocator, channels);
    input.zero();
    for (self._sources.items) |source| {
        input.sumFrom(try source.pull(r), self._channel_interpretation);
    }
    return input;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioNode);

    pub const Meta = struct {
        pub const name = "AudioNode";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const context = bridge.accessor(AudioNode.getContext, null, .{});
    pub const numberOfInputs = bridge.accessor(AudioNode.getNumberOfInputs, null, .{});
    pub const numberOfOutputs = bridge.accessor(AudioNode.getNumberOfOutputs, null, .{});
    pub const channelCount = bridge.accessor(AudioNode.getChannelCount, AudioNode.setChannelCount, .{});
    pub const channelCountMode = bridge.accessor(AudioNode.getChannelCountMode, AudioNode.setChannelCountMode, .{});
    pub const channelInterpretation = bridge.accessor(AudioNode.getChannelInterpretation, AudioNode.setChannelInterpretation, .{});
    pub const connect = bridge.function(AudioNode.connect, .{});
    pub const disconnect = bridge.function(AudioNode.disconnect, .{});
};
