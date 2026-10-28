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

// https://w3c.github.io/webcodecs/#audiodata-interface

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const common = @import("common.zig");

const Execution = js.Execution;

const AudioData = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_data_arena: ?*lp.Arena, // separate so that close() can immediately free
_data: []const u8,
_format: ?Format, // null once closed
_sample_rate: f32,
_number_of_frames: u32,
_number_of_channels: u32,
_timestamp: i64,

pub const Format = enum {
    u8,
    s16,
    s32,
    f32,
    @"u8-planar",
    @"s16-planar",
    @"s32-planar",
    @"f32-planar",

    pub fn bytesPerSample(self: Format) u32 {
        return switch (self) {
            .u8, .@"u8-planar" => 1,
            .s16, .@"s16-planar" => 2,
            .s32, .@"s32-planar", .f32, .@"f32-planar" => 4,
        };
    }

    pub fn isPlanar(self: Format) bool {
        return switch (self) {
            .u8, .s16, .s32, .f32 => false,
            else => true,
        };
    }
};

const Init = struct {
    data: js.AllowSharedBufferSource,
    format: []const u8,
    numberOfChannels: js.EnforceRange(u32),
    numberOfFrames: js.EnforceRange(u32),
    sampleRate: f64,
    timestamp: js.EnforceRange(i64),
    transfer: []const js.Value = &.{},
};

fn init(init_: Init, exec: *const Execution) !*AudioData {
    const format = std.meta.stringToEnum(Format, init_.format) orelse return error.TypeError;
    const frames = init_.numberOfFrames.value;
    const channels = init_.numberOfChannels.value;
    const timestamp = init_.timestamp.value;
    if (std.math.isFinite(init_.sampleRate) == false) {
        return error.TypeError;
    }
    const sample_rate: f32 = @floatCast(init_.sampleRate);

    if (sample_rate <= 0 or frames == 0 or channels == 0) {
        return error.TypeError;
    }
    const total_size = @as(u64, frames) * channels * format.bytesPerSample();
    const data = init_.data.bytes();
    if (data.len < total_size) {
        return error.TypeError;
    }

    const transfer: common.Transfer = .{ .buffers = init_.transfer };
    try transfer.check();

    const self = try create(.{
        .format = format,
        .sample_rate = sample_rate,
        .number_of_frames = frames,
        .number_of_channels = channels,
        .timestamp = timestamp,
    }, data[0..@intCast(total_size)], exec.page);
    errdefer self.deinit(exec.page);

    try transfer.detach();
    return self;
}

const Attributes = struct {
    format: Format,
    sample_rate: f32,
    number_of_frames: u32,
    number_of_channels: u32,
    timestamp: i64,
};

fn create(attributes: Attributes, data: []const u8, page: *Page) !*AudioData {
    const arena = try page.getPinnedArena(.tiny, "AudioData");
    errdefer arena.release();

    const data_arena = try page.getPinnedArena(data.len, "AudioData.data");
    errdefer data_arena.release();

    const self = try arena.create(AudioData);
    self.* = .{
        ._arena = arena,
        ._data_arena = data_arena,
        ._data = try data_arena.dupe(u8, data),
        ._format = attributes.format,
        ._sample_rate = attributes.sample_rate,
        ._number_of_frames = attributes.number_of_frames,
        ._number_of_channels = attributes.number_of_channels,
        ._timestamp = attributes.timestamp,
    };
    data_arena.report();
    return self;
}

pub fn deinit(self: *AudioData, _: *Page) void {
    if (self._data_arena) |data_arena| {
        data_arena.release();
    }
    self._arena.release();
}

pub fn acquireRef(self: *AudioData) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *AudioData, page: *Page) void {
    self._rc.release(self, page);
}

pub fn isClosed(self: *const AudioData) bool {
    return self._format == null;
}

fn getFormat(self: *const AudioData) ?[]const u8 {
    const format = self._format orelse return null;
    return @tagName(format);
}

fn getSampleRate(self: *const AudioData) f32 {
    return self._sample_rate;
}

fn getNumberOfFrames(self: *const AudioData) u32 {
    return self._number_of_frames;
}

fn getNumberOfChannels(self: *const AudioData) u32 {
    return self._number_of_channels;
}

fn getTimestamp(self: *const AudioData) i64 {
    return self._timestamp;
}

fn getDuration(self: *const AudioData) u64 {
    if (self._sample_rate == 0) {
        return 0;
    }
    const seconds = @as(f64, @floatFromInt(self._number_of_frames)) / @as(f64, self._sample_rate);
    const micros = seconds * 1_000_000;
    // The sample rate only has to be positive, so this can exceed a u64.
    if (micros >= 0x1p64) {
        return std.math.maxInt(u64);
    }
    return @intFromFloat(micros);
}

const CopyToOptions = struct {
    format: ?[]const u8 = null,
    frameCount: ?js.EnforceRange(u32) = null,
    frameOffset: js.EnforceRange(u32) = .{},
    planeIndex: js.EnforceRange(u32),
};

// The parsed options, after "Compute Copy Element Count".
const Copy = struct {
    format: Format,
    plane_index: u32,
    frame_offset: u32,
    frame_count: u32,
    element_count: u64,

    fn byteLength(self: Copy) u64 {
        return self.element_count * self.format.bytesPerSample();
    }
};

fn computeCopy(self: *const AudioData, options: CopyToOptions) !Copy {
    const source_format = self._format orelse return error.InvalidStateError;
    const plane_index = options.planeIndex.value;
    const frame_offset = options.frameOffset.value;
    const requested_count = if (options.frameCount) |c| c.value else null;

    const format = if (options.format) |f|
        std.meta.stringToEnum(Format, f) orelse return error.TypeError
    else
        source_format;

    if (format.isPlanar()) {
        if (plane_index >= self._number_of_channels) return error.RangeError;
    } else if (plane_index > 0) {
        return error.RangeError;
    }

    // Every plane holds every frame, whatever the arrangement.
    const frame_count = self._number_of_frames;
    if (frame_offset >= frame_count) {
        return error.RangeError;
    }
    var copy_count = frame_count - frame_offset;
    if (requested_count) |count| {
        if (count > copy_count) return error.RangeError;
        copy_count = count;
    }

    var element_count: u64 = copy_count;
    if (format.isPlanar() == false) {
        element_count *= self._number_of_channels;
    }

    return .{
        .format = format,
        .plane_index = plane_index,
        .frame_offset = frame_offset,
        .frame_count = copy_count,
        .element_count = element_count,
    };
}

fn allocationSize(self: *const AudioData, options: CopyToOptions) !u32 {
    const copy = try self.computeCopy(options);
    return std.math.cast(u32, copy.byteLength()) orelse error.RangeError;
}

fn copyTo(self: *const AudioData, destination: js.AllowSharedBufferSource, options: CopyToOptions) !void {
    const copy = try self.computeCopy(options);
    const byte_length = copy.byteLength();
    const destination_bytes = destination.bytes();
    if (byte_length > destination_bytes.len) {
        return error.RangeError;
    }

    const source_format = self._format.?;
    const channels = self._number_of_channels;
    const frames = self._number_of_frames;
    const dest = destination_bytes[0..@intCast(byte_length)];

    // Same format, and the copied range is contiguous in the source.
    if (source_format == copy.format) {
        const bps = source_format.bytesPerSample();
        const start: usize = if (source_format.isPlanar())
            (@as(usize, copy.plane_index) * frames + copy.frame_offset) * bps
        else
            @as(usize, copy.frame_offset) * channels * bps;
        @memcpy(dest, self._data[start..][0..dest.len]);
        return;
    }

    var out: usize = 0;
    for (0..copy.frame_count) |i| {
        const frame = copy.frame_offset + i;
        if (copy.format.isPlanar()) {
            convertSample(self, frame, copy.plane_index, copy.format, dest, out);
            out += 1;
        } else {
            for (0..channels) |channel| {
                convertSample(self, frame, channel, copy.format, dest, out);
                out += 1;
            }
        }
    }
}

fn convertSample(self: *const AudioData, frame: usize, channel: usize, dest_format: Format, dest: []u8, index: usize) void {
    const source_format = self._format.?;
    const source_index = if (source_format.isPlanar())
        channel * self._number_of_frames + frame
    else
        frame * self._number_of_channels + channel;

    const source = Sample.read(source_format, self._data, source_index);
    source.write(dest_format, dest, index);
}

const Sample = union(enum) {
    u8: u8,
    s16: i16,
    s32: i32,
    f32: f32,

    fn read(format: Format, data: []const u8, index: usize) Sample {
        return switch (format) {
            .u8, .@"u8-planar" => .{ .u8 = data[index] },
            .s16, .@"s16-planar" => .{ .s16 = std.mem.readInt(i16, data[index * 2 ..][0..2], .little) },
            .s32, .@"s32-planar" => .{ .s32 = std.mem.readInt(i32, data[index * 4 ..][0..4], .little) },
            .f32, .@"f32-planar" => .{ .f32 = @bitCast(std.mem.readInt(u32, data[index * 4 ..][0..4], .little)) },
        };
    }

    fn write(self: Sample, format: Format, dest: []u8, index: usize) void {
        switch (format) {
            .u8, .@"u8-planar" => dest[index] = switch (self) {
                .f32 => |f| fromFloat(u8, f),
                else => @intCast((self.scaled() >> 24) + 128),
            },
            .s16, .@"s16-planar" => std.mem.writeInt(i16, dest[index * 2 ..][0..2], switch (self) {
                .f32 => |f| fromFloat(i16, f),
                else => @intCast(self.scaled() >> 16),
            }, .little),
            .s32, .@"s32-planar" => std.mem.writeInt(i32, dest[index * 4 ..][0..4], switch (self) {
                .f32 => |f| fromFloat(i32, f),
                else => self.scaled(),
            }, .little),
            .f32, .@"f32-planar" => std.mem.writeInt(u32, dest[index * 4 ..][0..4], @bitCast(self.toFloat()), .little),
        }
    }

    // An integer sample at s32 scale.
    fn scaled(self: Sample) i32 {
        return switch (self) {
            .u8 => |v| (@as(i32, v) - 128) << 24,
            .s16 => |v| @as(i32, v) << 16,
            .s32 => |v| v,
            .f32 => unreachable,
        };
    }

    fn toFloat(self: Sample) f32 {
        return switch (self) {
            .u8 => |v| toFloatFrom(u8, v),
            .s16 => |v| toFloatFrom(i16, v),
            .s32 => |v| toFloatFrom(i32, v),
            .f32 => |v| v,
        };
    }
};

fn Range(comptime T: type) type {
    return struct {
        const min: f64 = @floatFromInt(std.math.minInt(T));
        const max: f64 = @floatFromInt(std.math.maxInt(T));
        // the "bias": silence
        const zero: f64 = if (T == u8) 128 else 0;
    };
}

fn toFloatFrom(comptime T: type, value: T) f32 {
    const R = Range(T);
    const v: f64 = @floatFromInt(value);
    const result = if (v < R.zero) (v - R.zero) / (R.zero - R.min) else (v - R.zero) / (R.max - R.zero);
    return @floatCast(result);
}

fn fromFloat(comptime T: type, value: f32) T {
    const R = Range(T);
    const f: f64 = if (std.math.isNan(value)) 0 else std.math.clamp(@as(f64, value), -1, 1);
    const result = if (f < 0) f * (R.zero - R.min) + R.zero else f * (R.max - R.zero) + R.zero;
    return @intFromFloat(result);
}

fn clone(self: *const AudioData, exec: *const Execution) !*AudioData {
    const format = self._format orelse return error.InvalidStateError;
    return create(.{
        .format = format,
        .sample_rate = self._sample_rate,
        .number_of_frames = self._number_of_frames,
        .number_of_channels = self._number_of_channels,
        .timestamp = self._timestamp,
    }, self._data, exec.page);
}

pub fn close(self: *AudioData) void {
    if (self._data_arena) |data_arena| {
        data_arena.release();
        self._data_arena = null;
    }
    // once closed, everything reads as zero/null
    self._data = &.{};
    self._format = null;
    self._sample_rate = 0;
    self._number_of_frames = 0;
    self._number_of_channels = 0;
}

pub fn structuredSerialize(self: *const AudioData, writer: *js.StructuredWriter) !void {
    const format = self._format orelse return error.DataClone;
    writer.writeUint32(@backingInt(format));
    writer.writeUint32(@bitCast(self._sample_rate));
    writer.writeUint32(self._number_of_frames);
    writer.writeUint32(self._number_of_channels);
    writer.writeUint64(@bitCast(self._timestamp));
    writer.writeBytes(self._data);
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*AudioData {
    const format = std.enums.fromInt(Format, try reader.readUint32()) orelse return error.DataClone;
    const sample_rate: f32 = @bitCast(try reader.readUint32());
    const frames = try reader.readUint32();
    const channels = try reader.readUint32();
    const timestamp: i64 = @bitCast(try reader.readUint64());
    const data = try reader.readBytes();
    return create(.{
        .format = format,
        .sample_rate = sample_rate,
        .number_of_frames = frames,
        .number_of_channels = channels,
        .timestamp = timestamp,
    }, data, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioData);

    pub const Meta = struct {
        pub const name = "AudioData";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AudioData.init, .{});
    pub const format = bridge.accessor(AudioData.getFormat, null, .{});
    pub const sampleRate = bridge.accessor(AudioData.getSampleRate, null, .{});
    pub const numberOfFrames = bridge.accessor(AudioData.getNumberOfFrames, null, .{});
    pub const numberOfChannels = bridge.accessor(AudioData.getNumberOfChannels, null, .{});
    pub const duration = bridge.accessor(AudioData.getDuration, null, .{});
    pub const timestamp = bridge.accessor(AudioData.getTimestamp, null, .{});
    pub const allocationSize = bridge.function(AudioData.allocationSize, .{});
    pub const copyTo = bridge.function(AudioData.copyTo, .{});
    pub const clone = bridge.function(AudioData.clone, .{});
    pub const close = bridge.function(AudioData.close, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: AudioData" {
    try testing.htmlRunner("webcodecs/audio_data.html", .{});
}

test "AudioData: sample conversion" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 191), fromFloat(u8, 0.5));
    try t.expectEqual(@as(u8, 64), fromFloat(u8, -0.5));
    try t.expectEqual(@as(i16, 16383), fromFloat(i16, 0.5));
    try t.expectEqual(@as(i32, 2147483647), fromFloat(i32, 1.0));
    try t.expectEqual(@as(f32, -1), toFloatFrom(u8, 0));
    try t.expectEqual(@as(f32, 1), toFloatFrom(i16, 32767));
}
