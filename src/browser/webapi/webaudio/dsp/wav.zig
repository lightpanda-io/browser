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

// RIFF/WAVE parsing for decodeAudioData: integer PCM (8, 16, 24, 32 bits) and
// IEEE float (32, 64 bits), read in place from the encoded bytes.

const std = @import("std");

pub const Error = error{EncodingError};

pub const Wav = struct {
    format: Format,
    channels: u32,
    sample_rate: f32,
    frames: u32,
    // the data chunk, cut to whole frames
    data: []const u8,

    const Format = enum { uint8, int16, int24, int32, float32, float64 };

    fn bytesPerSample(self: *const Wav) usize {
        return switch (self.format) {
            .uint8 => 1,
            .int16 => 2,
            .int24 => 3,
            .int32, .float32 => 4,
            .float64 => 8,
        };
    }

    // One sample in [-1, 1].
    pub fn sample(self: *const Wav, frame: usize, channel: usize) f32 {
        const size = self.bytesPerSample();
        const at = self.data[(frame * self.channels + channel) * size ..][0..size];
        return switch (self.format) {
            .uint8 => (@as(f32, @floatFromInt(at[0])) - 128) / 128,
            .int16 => @as(f32, @floatFromInt(std.mem.readInt(i16, at[0..2], .little))) / 32768,
            .int24 => @as(f32, @floatFromInt(std.mem.readInt(i24, at[0..3], .little))) / 8388608,
            .int32 => @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i32, at[0..4], .little))) / 2147483648),
            .float32 => @bitCast(std.mem.readInt(u32, at[0..4], .little)),
            .float64 => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, at[0..8], .little)))),
        };
    }

    // Channel `channel` resampled to `rate` (linear interpolation) into `out`,
    // whose length is `resampledLength(rate)`.
    pub fn resample(self: *const Wav, channel: usize, rate: f32, out: []f32) void {
        if (rate == self.sample_rate) {
            for (out, 0..) |*o, i| o.* = self.sample(i, channel);
            return;
        }
        const step: f64 = @as(f64, self.sample_rate) / rate;
        const last = self.frames - 1;
        for (out, 0..) |*o, i| {
            const position = @as(f64, @floatFromInt(i)) * step;
            const index: usize = @min(@as(usize, @intFromFloat(position)), last);
            const frac: f32 = @floatCast(position - @as(f64, @floatFromInt(index)));
            const a = self.sample(index, channel);
            const b = self.sample(@min(index + 1, last), channel);
            o.* = a + (b - a) * frac;
        }
    }

    pub fn resampledLength(self: *const Wav, rate: f32) u32 {
        if (rate == self.sample_rate) {
            return self.frames;
        }
        const length = @as(f64, @floatFromInt(self.frames)) * rate / self.sample_rate;
        return @intFromFloat(@max(1, @min(length, std.math.maxInt(u32))));
    }
};

pub fn parse(bytes: []const u8) Error!Wav {
    if (bytes.len < 12 or std.mem.eql(u8, bytes[0..4], "RIFF") == false or std.mem.eql(u8, bytes[8..12], "WAVE") == false) {
        return error.EncodingError;
    }

    var fmt: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var pos: usize = 12;
    while (bytes.len - pos >= 8) {
        const id = bytes[pos..][0..4];
        const declared = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        pos += 8;
        // a streamed file's sizes can overstate what's there
        const size = @min(declared, bytes.len - pos);
        const body = bytes[pos..][0..size];
        if (std.mem.eql(u8, id, "fmt ")) {
            fmt = body;
        } else if (std.mem.eql(u8, id, "data")) {
            data = body;
            if (fmt != null) break;
        }
        // chunks are padded to an even size
        pos += size + (size & 1);
        if (pos > bytes.len) break;
    }

    const f = fmt orelse return error.EncodingError;
    const samples = data orelse return error.EncodingError;
    if (f.len < 16) {
        return error.EncodingError;
    }

    var tag = std.mem.readInt(u16, f[0..2], .little);
    const channels = std.mem.readInt(u16, f[2..4], .little);
    const sample_rate = std.mem.readInt(u32, f[4..8], .little);
    const block_align = std.mem.readInt(u16, f[12..14], .little);
    const bits = std.mem.readInt(u16, f[14..16], .little);
    // WAVE_FORMAT_EXTENSIBLE: the real tag starts the sub-format GUID
    if (tag == 0xFFFE) {
        if (f.len < 26) return error.EncodingError;
        tag = std.mem.readInt(u16, f[24..26], .little);
    }

    const format: Wav.Format = switch (tag) {
        1 => switch (bits) {
            8 => .uint8,
            16 => .int16,
            24 => .int24,
            32 => .int32,
            else => return error.EncodingError,
        },
        3 => switch (bits) {
            32 => .float32,
            64 => .float64,
            else => return error.EncodingError,
        },
        else => return error.EncodingError,
    };
    if (channels == 0 or sample_rate == 0 or block_align != @as(u32, channels) * (bits / 8)) {
        return error.EncodingError;
    }
    const frames = samples.len / block_align;
    if (frames == 0 or frames > std.math.maxInt(u32)) {
        return error.EncodingError;
    }

    return .{
        .format = format,
        .channels = channels,
        .sample_rate = @floatFromInt(sample_rate),
        .frames = @intCast(frames),
        .data = samples[0 .. frames * block_align],
    };
}

const testing = std.testing;

fn header(buf: []u8, tag: u16, channels: u16, rate: u32, bits: u16, data_len: u32) []u8 {
    const block: u16 = channels * (bits / 8);
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("RIFF") catch unreachable;
    w.writeInt(u32, 36 + data_len, .little) catch unreachable;
    w.writeAll("WAVEfmt ") catch unreachable;
    w.writeInt(u32, 16, .little) catch unreachable;
    w.writeInt(u16, tag, .little) catch unreachable;
    w.writeInt(u16, channels, .little) catch unreachable;
    w.writeInt(u32, rate, .little) catch unreachable;
    w.writeInt(u32, rate * block, .little) catch unreachable;
    w.writeInt(u16, block, .little) catch unreachable;
    w.writeInt(u16, bits, .little) catch unreachable;
    w.writeAll("data") catch unreachable;
    w.writeInt(u32, data_len, .little) catch unreachable;
    return w.buffered();
}

test "wav: int16 stereo" {
    var buf: [64]u8 = undefined;
    const head = header(&buf, 1, 2, 8000, 16, 8);
    const samples = [_]i16{ 0, -32768, 16384, 32767 };
    var len = head.len;
    for (samples) |s| {
        std.mem.writeInt(i16, buf[len..][0..2], s, .little);
        len += 2;
    }
    const wav = try parse(buf[0..len]);
    try testing.expectEqual(2, wav.channels);
    try testing.expectEqual(2, wav.frames);
    try testing.expectEqual(8000, wav.sample_rate);
    try testing.expectEqual(0, wav.sample(0, 0));
    try testing.expectEqual(-1, wav.sample(0, 1));
    try testing.expectEqual(0.5, wav.sample(1, 0));

    // upsampled 2x: interpolated between frames, held at the end
    var out: [4]f32 = undefined;
    try testing.expectEqual(4, wav.resampledLength(16000));
    wav.resample(0, 16000, &out);
    try testing.expectEqualSlices(f32, &.{ 0, 0.25, 0.5, 0.5 }, &out);
}

test "wav: float32 and uint8" {
    var buf: [64]u8 = undefined;
    var head = header(&buf, 3, 1, 44100, 32, 4);
    std.mem.writeInt(u32, buf[head.len..][0..4], @bitCast(@as(f32, -0.25)), .little);
    const float = try parse(buf[0 .. head.len + 4]);
    try testing.expectEqual(-0.25, float.sample(0, 0));

    head = header(&buf, 1, 1, 44100, 8, 2);
    buf[head.len] = 0;
    buf[head.len + 1] = 192;
    const byte = try parse(buf[0 .. head.len + 2]);
    try testing.expectEqual(-1, byte.sample(0, 0));
    try testing.expectEqual(0.5, byte.sample(1, 0));
}

test "wav: rejects" {
    var buf: [64]u8 = undefined;
    try testing.expectError(error.EncodingError, parse("ID3\x04\x00\x00\x00\x00\x00\x00\x00\x00"));
    try testing.expectError(error.EncodingError, parse(header(&buf, 85, 1, 44100, 16, 0)));
    // header only: no frames
    try testing.expectError(error.EncodingError, parse(header(&buf, 1, 1, 44100, 16, 0)));
}
