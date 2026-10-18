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

// https://webaudio.github.io/web-audio-api/#AudioBuffer

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");

const AudioBuffer = @This();

pub const max_channels = 32;
pub const min_sample_rate = 3000;
pub const max_sample_rate = 768000;

// Creating a typed array past the isolate's ArrayBuffer budget aborts the
// process, so the buffer's total size is capped well below it.
const max_bytes = 512 * 1024 * 1024;

_rc: lp.RC = .{},
_arena: *lp.Arena,
_sample_rate: f32,
_length: u32,
// One Float32Array per channel: getChannelData() hands these out, and
// rendering reads and writes them in place.
_channels: []js.ArrayBufferRef(.float32).Global,

const Options = struct {
    length: u32,
    numberOfChannels: u32 = 1,
    sampleRate: f32,
};

fn constructor(options: Options, frame: *Frame) !*AudioBuffer {
    return create(options.numberOfChannels, options.length, options.sampleRate, frame.js.local.?, frame.page);
}

pub fn create(number_of_channels: u32, length: u32, sample_rate: f32, local: *const js.Local, page: *Page) !*AudioBuffer {
    try validate(number_of_channels, length, sample_rate);

    const arena = try page.getArena(.tiny, "AudioBuffer");
    errdefer arena.release();

    const channels = try arena.allocator().alloc(js.ArrayBufferRef(.float32).Global, number_of_channels);
    var created: usize = 0;
    errdefer for (channels[0..created]) |c| c.release();
    for (channels) |*c| {
        c.* = try local.createTypedArray(.float32, length).persist();
        created += 1;
    }

    const self = try arena.allocator().create(AudioBuffer);
    self.* = .{
        ._arena = arena,
        ._sample_rate = sample_rate,
        ._length = length,
        ._channels = channels,
    };
    return self;
}

pub fn validate(number_of_channels: u32, length: u32, sample_rate: f32) !void {
    if (number_of_channels == 0 or number_of_channels > max_channels) {
        return error.NotSupported;
    }
    if (length == 0) {
        return error.NotSupported;
    }
    if (std.math.isNan(sample_rate) or sample_rate < min_sample_rate or sample_rate > max_sample_rate) {
        return error.NotSupported;
    }
    if (@as(u64, length) * number_of_channels * @sizeOf(f32) > max_bytes) {
        return error.NotSupported;
    }
}

pub fn deinit(self: *AudioBuffer, _: *Page) void {
    for (self._channels) |c| c.release();
    self._arena.release();
}

pub fn acquireRef(self: *AudioBuffer) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *AudioBuffer, page: *Page) void {
    self._rc.release(self, page);
}

pub fn numberOfChannels(self: *const AudioBuffer) u32 {
    return @intCast(self._channels.len);
}

pub fn sampleRate(self: *const AudioBuffer) f32 {
    return self._sample_rate;
}

pub fn frameCount(self: *const AudioBuffer) u32 {
    return self._length;
}

// A channel's samples. Empty once script detached the array (e.g. by
// transferring its buffer).
pub fn channelData(self: *const AudioBuffer, channel: usize, local: *const js.Local) []f32 {
    return self._channels[channel].local(local).slice();
}

fn getDuration(self: *const AudioBuffer) f64 {
    return @as(f64, @floatFromInt(self._length)) / self._sample_rate;
}

fn getChannelData(self: *const AudioBuffer, channel: u32) !js.ArrayBufferRef(.float32).Global {
    if (channel >= self._channels.len) {
        return error.IndexSizeError;
    }
    return self._channels[channel];
}

fn copyFromChannel(self: *const AudioBuffer, destination: js.Value, channel: u32, buffer_offset_: ?u32, frame: *Frame) !void {
    const local = frame.js.local.?;
    if (destination.isFloat32Array() == false) {
        return error.TypeError;
    }
    if (channel >= self._channels.len) {
        return error.IndexSizeError;
    }
    const into = try destination.toZig([]f32);
    const from = self.channelData(channel, local);
    const offset = buffer_offset_ orelse 0;
    if (offset >= from.len) {
        return;
    }
    const n = @min(into.len, from.len - offset);
    @memmove(into[0..n], from[offset..][0..n]);
}

fn copyToChannel(self: *const AudioBuffer, source: js.Value, channel: u32, buffer_offset_: ?u32, frame: *Frame) !void {
    const local = frame.js.local.?;
    if (source.isFloat32Array() == false) {
        return error.TypeError;
    }
    if (channel >= self._channels.len) {
        return error.IndexSizeError;
    }
    const from = try source.toZig([]f32);
    const into = self.channelData(channel, local);
    const offset = buffer_offset_ orelse 0;
    if (offset >= into.len) {
        return;
    }
    const n = @min(from.len, into.len - offset);
    @memmove(into[offset..][0..n], from[0..n]);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioBuffer);

    pub const Meta = struct {
        pub const name = "AudioBuffer";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AudioBuffer.constructor, .{});
    pub const sampleRate = bridge.accessor(AudioBuffer.sampleRate, null, .{});
    pub const length = bridge.accessor(AudioBuffer.frameCount, null, .{});
    pub const duration = bridge.accessor(AudioBuffer.getDuration, null, .{});
    pub const numberOfChannels = bridge.accessor(AudioBuffer.numberOfChannels, null, .{});
    pub const getChannelData = bridge.function(AudioBuffer.getChannelData, .{});
    pub const copyFromChannel = bridge.function(AudioBuffer.copyFromChannel, .{});
    pub const copyToChannel = bridge.function(AudioBuffer.copyToChannel, .{});
};
