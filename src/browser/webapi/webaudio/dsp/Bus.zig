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

// One render quantum of multi-channel audio.
// https://webaudio.github.io/web-audio-api/#channel-up-mixing-and-down-mixing

const std = @import("std");

const Allocator = std.mem.Allocator;

const Bus = @This();

pub const quantum = 128;
pub const max_channels = 32;

pub const Channel = [quantum]f32;

pub const Interpretation = enum { speakers, discrete };

// capacity is data.len
data: []Channel = &.{},
channels: u32 = 0,

// Grows the storage as needed; contents are unspecified afterwards.
pub fn setChannels(self: *Bus, allocator: Allocator, channels: u32) !void {
    std.debug.assert(channels <= max_channels);
    if (channels > self.data.len) {
        allocator.free(self.data);
        self.data = &.{};
        self.channels = 0;
        self.data = try allocator.alloc(Channel, channels);
    }
    self.channels = channels;
}

pub fn deinit(self: *Bus, allocator: Allocator) void {
    allocator.free(self.data);
}

pub fn channel(self: *Bus, index: usize) *Channel {
    return &self.data[index];
}

pub fn constChannel(self: *const Bus, index: usize) *const Channel {
    return &self.data[index];
}

pub fn zero(self: *Bus) void {
    for (self.data[0..self.channels]) |*c| @memset(c, 0);
}

pub fn zeroFrames(self: *Bus, start: usize, end: usize) void {
    for (self.data[0..self.channels]) |*c| @memset(c[start..end], 0);
}

// Mixes source into self, up- or down-mixing between the channel counts.
pub fn sumFrom(self: *Bus, source: *const Bus, interpretation: Interpretation) void {
    const from = source.channels;
    const to = self.channels;
    if (from == to or interpretation == .discrete) {
        return self.discreteSumFrom(source);
    }
    if (from < to) {
        return self.upMix(source);
    }
    return self.downMix(source);
}

fn discreteSumFrom(self: *Bus, source: *const Bus) void {
    const n = @min(self.channels, source.channels);
    for (0..n) |i| add(self.channel(i), source.constChannel(i));
}

fn upMix(self: *Bus, source: *const Bus) void {
    const from = source.channels;
    const to = self.channels;
    if (from == 1 and (to == 2 or to == 4)) {
        add(self.channel(0), source.constChannel(0));
        add(self.channel(1), source.constChannel(0));
    } else if (from == 1 and to == 6) {
        add(self.channel(2), source.constChannel(0));
    } else if (from == 2 and (to == 4 or to == 6)) {
        add(self.channel(0), source.constChannel(0));
        add(self.channel(1), source.constChannel(1));
    } else if (from == 4 and to == 6) {
        add(self.channel(0), source.constChannel(0));
        add(self.channel(1), source.constChannel(1));
        add(self.channel(4), source.constChannel(2));
        add(self.channel(5), source.constChannel(3));
    } else {
        self.discreteSumFrom(source);
    }
}

fn downMix(self: *Bus, source: *const Bus) void {
    const from = source.channels;
    const to = self.channels;
    const sqrt_half: f32 = @sqrt(@as(f32, 0.5));
    const s = source;
    if (from == 2 and to == 1) {
        const d = self.channel(0);
        scaledAdd(d, s.constChannel(0), 0.5);
        scaledAdd(d, s.constChannel(1), 0.5);
    } else if (from == 4 and to == 1) {
        const d = self.channel(0);
        for (0..4) |i| scaledAdd(d, s.constChannel(i), 0.25);
    } else if (from == 6 and to == 1) {
        const d = self.channel(0);
        scaledAdd(d, s.constChannel(0), sqrt_half);
        scaledAdd(d, s.constChannel(1), sqrt_half);
        add(d, s.constChannel(2));
        scaledAdd(d, s.constChannel(4), 0.5);
        scaledAdd(d, s.constChannel(5), 0.5);
    } else if (from == 4 and to == 2) {
        scaledAdd(self.channel(0), s.constChannel(0), 0.5);
        scaledAdd(self.channel(0), s.constChannel(2), 0.5);
        scaledAdd(self.channel(1), s.constChannel(1), 0.5);
        scaledAdd(self.channel(1), s.constChannel(3), 0.5);
    } else if (from == 6 and (to == 2 or to == 4)) {
        add(self.channel(0), s.constChannel(0));
        scaledAdd(self.channel(0), s.constChannel(2), sqrt_half);
        if (to == 2) scaledAdd(self.channel(0), s.constChannel(4), sqrt_half);
        add(self.channel(1), s.constChannel(1));
        scaledAdd(self.channel(1), s.constChannel(2), sqrt_half);
        if (to == 2) {
            scaledAdd(self.channel(1), s.constChannel(5), sqrt_half);
        } else {
            add(self.channel(2), s.constChannel(4));
            add(self.channel(3), s.constChannel(5));
        }
    } else {
        self.discreteSumFrom(source);
    }
}

fn add(destination: *Channel, source: *const Channel) void {
    for (destination, source) |*d, s| d.* += s;
}

fn scaledAdd(destination: *Channel, source: *const Channel, scale: f32) void {
    for (destination, source) |*d, s| d.* += s * scale;
}

const testing = std.testing;
test "Bus: speaker mixing" {
    const allocator = testing.allocator;
    var mono: Bus = .{};
    defer mono.deinit(allocator);
    var stereo: Bus = .{};
    defer stereo.deinit(allocator);

    try mono.setChannels(allocator, 1);
    try stereo.setChannels(allocator, 2);
    @memset(mono.channel(0), 0.5);

    stereo.zero();
    stereo.sumFrom(&mono, .speakers);
    try testing.expectEqual(0.5, stereo.channel(0)[0]);
    try testing.expectEqual(0.5, stereo.channel(1)[127]);

    @memset(stereo.channel(1), 1.5);
    mono.zero();
    mono.sumFrom(&stereo, .speakers);
    try testing.expectEqual(1, mono.channel(0)[3]);

    mono.zero();
    mono.sumFrom(&stereo, .discrete);
    try testing.expectEqual(0.5, mono.channel(0)[3]);
}
