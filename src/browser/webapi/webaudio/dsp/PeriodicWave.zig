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

// Band-limited wavetables for OscillatorNode, ported from Chromium's
// modules/webaudio/periodic_wave.cc (Copyright (C) 2012 Google Inc., BSD
// license). Each table holds one period; table `r` drops the partials that
// would alias for fundamentals in pitch range `r` (three ranges per octave).

const std = @import("std");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;

const PeriodicWave = @This();

const octave_bands = 3;
const cents_per_range: f32 = 1200 / octave_bands;

size: u32,
number_of_ranges: u32,
lowest_fundamental: f32,
// table index per sample of frequency: size / sample_rate
rate_scale: f32,
// 1 / the largest sample of range 0, or 0.5 unnormalized
normalization: f32 = 0.5,
// owns the coefficients and tables, which outlive the wave
allocator: Allocator,
real: ?[]const f32,
imag: []const f32,
// per range, built on first use
tables: []?[]const f32,

pub const Shape = enum { sine, square, sawtooth, triangle };

pub fn initBasic(allocator: Allocator, sample_rate: f32, shape: Shape) !PeriodicWave {
    const size = waveSize(sample_rate);
    const half = size / 2;
    const imag = try allocator.alloc(f32, half);
    defer allocator.free(imag);

    imag[0] = 0;
    for (1..half) |n| {
        const pi_factor: f32 = 2 / (@as(f32, @floatFromInt(n)) * math.pi_f32);
        const odd = n & 1 == 1;
        // Fourier sine coefficients; all four shapes are odd functions.
        imag[n] = switch (shape) {
            .sine => if (n == 1) 1 else 0,
            .square => if (odd) 2 * pi_factor else 0,
            .sawtooth => pi_factor * @as(f32, if (odd) 1 else -1),
            .triangle => if (odd) 2 * (pi_factor * pi_factor) * @as(f32, if (((n - 1) >> 1) & 1 == 1) -1 else 1) else 0,
        };
    }
    return initCoefficients(allocator, sample_rate, null, imag, false);
}

// `real` null means all-zero cosine terms. Only range 0 (which sets the
// normalization) is built here; waveData builds the others on first use, as
// an oscillator rarely reads more than a few of them.
pub fn initCoefficients(allocator: Allocator, sample_rate: f32, real: ?[]const f32, imag: []const f32, disable_normalization: bool) !PeriodicWave {
    const size = waveSize(sample_rate);
    const half = size / 2;
    const nyquist: f32 = 0.5 * sample_rate;
    const number_of_ranges: u32 = @intFromFloat(0.5 + octave_bands * math.log2f(@floatFromInt(size)));
    const components: u32 = @intCast(@min(imag.len, half));

    const tables = try allocator.alloc(?[]const f32, number_of_ranges);
    @memset(tables, null);

    var self: PeriodicWave = .{
        .size = size,
        .number_of_ranges = number_of_ranges,
        .lowest_fundamental = nyquist / @as(f32, @floatFromInt(half)),
        .rate_scale = @as(f32, @floatFromInt(size)) / sample_rate,
        .allocator = allocator,
        .real = if (real) |r| try allocator.dupe(f32, r[0..components]) else null,
        .imag = try allocator.dupe(f32, imag[0..components]),
        .tables = tables,
    };

    const first = try self.buildTable(0);
    if (disable_normalization == false) {
        var max: f32 = 0;
        for (first) |t| max = @max(max, @abs(t));
        if (max != 0) self.normalization = 1.0 / max;
    }
    for (first) |*t| t.* *= self.normalization;
    tables[0] = first;
    return self;
}

// The unnormalized table for `range`.
fn buildTable(self: *const PeriodicWave, range: u32) ![]f32 {
    const size = self.size;
    const half = size / 2;
    const allocator = self.allocator;

    const work = try allocator.alloc(Complex, size);
    defer allocator.free(work);
    const twiddles = try allocator.alloc(Complex, half);
    defer allocator.free(twiddles);
    initTwiddles(twiddles);

    // Bins [1, cutoff) survive; DC and Nyquist never do.
    const cutoff = @min(self.imag.len, partialsForRange(half, range) + 1);
    @memset(work, .{ .re = 0, .im = 0 });
    for (1..cutoff) |k| {
        const a: f64 = if (self.real) |r| r[k] else 0;
        const b: f64 = self.imag[k];
        work[k] = .{ .re = a, .im = -b };
        work[size - k] = .{ .re = a, .im = b };
    }
    inverseFft(work, twiddles);

    const table = try allocator.alloc(f32, size);
    for (table, work) |*t, w| {
        // x[n] = 2 * sum(a cos + b sin); the default (unnormalized)
        // scale of 0.5 leaves the sum the spec defines.
        t.* = @floatCast(w.re);
    }
    return table;
}

fn rangeTable(self: *PeriodicWave, range: u32) ![]const f32 {
    if (self.tables[range]) |t| {
        return t;
    }
    const t = try self.buildTable(range);
    for (t) |*v| v.* *= self.normalization;
    self.tables[range] = t;
    return t;
}

// Shorter tables at low rates keep the FFTs small; 4096 around 44.1kHz.
fn waveSize(sample_rate: f32) u32 {
    if (sample_rate <= 24000) return 2048;
    if (sample_rate <= 88200) return 4096;
    return 16384;
}

fn partialsForRange(max_partials: u32, range: u32) u32 {
    const cents_to_cull = @as(f32, @floatFromInt(range)) * cents_per_range;
    const culling_scale: f32 = @floatCast(math.powd(2, -cents_to_cull / 1200));
    return @intFromFloat(culling_scale * @as(f32, @floatFromInt(max_partials)));
}

pub const WaveData = struct {
    // fewer partials
    lower: []const f32,
    higher: []const f32,
    // 0 => higher, 1 => lower
    factor: f32,
};

pub fn waveData(self: *PeriodicWave, fundamental: f32) !WaveData {
    // negative frequencies alias to the positive one
    const frequency = @abs(fundamental);
    const ratio: f32 = if (frequency > 0) frequency / self.lowest_fundamental else 0.5;
    const cents_above_lowest = math.log2f(ratio) * 1200;
    // Plus one rounds up to the next range just before partials would alias.
    var pitch_range: f32 = 1 + cents_above_lowest / cents_per_range;
    pitch_range = @max(pitch_range, 0);
    pitch_range = @min(pitch_range, @as(f32, @floatFromInt(self.number_of_ranges - 1)));

    const index1: u32 = @intFromFloat(pitch_range);
    const index2 = if (index1 < self.number_of_ranges - 1) index1 + 1 else index1;
    return .{
        .lower = try self.rangeTable(index2),
        .higher = try self.rangeTable(index1),
        .factor = pitch_range - @as(f32, @floatFromInt(index1)),
    };
}

const Complex = struct { re: f64, im: f64 };

// e^(2 pi i k / N) for k < N/2; computed once, the trig dominated the FFTs.
fn initTwiddles(twiddles: []Complex) void {
    const angle = std.math.pi / @as(f64, @floatFromInt(twiddles.len));
    for (twiddles, 0..) |*w, k| {
        const theta = angle * @as(f64, @floatFromInt(k));
        w.* = .{ .re = @cos(theta), .im = @sin(theta) };
    }
}

// In-place radix-2 inverse DFT, unscaled: x[n] = sum X[k] e^(2 pi i k n / N).
fn inverseFft(data: []Complex, twiddles: []const Complex) void {
    const n = data.len;
    std.debug.assert(std.math.isPowerOfTwo(n));
    std.debug.assert(twiddles.len * 2 == n);

    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) {
            j ^= bit;
        }
        j |= bit;
        if (i < j) {
            std.mem.swap(Complex, &data[i], &data[j]);
        }
    }

    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half = len / 2;
        const stride = n / len;
        var start: usize = 0;
        while (start < n) : (start += len) {
            for (0..half) |k| {
                const w = twiddles[k * stride];
                const a = data[start + k];
                const b = data[start + k + half];
                const t: Complex = .{ .re = b.re * w.re - b.im * w.im, .im = b.re * w.im + b.im * w.re };
                data[start + k] = .{ .re = a.re + t.re, .im = a.im + t.im };
                data[start + k + half] = .{ .re = a.re - t.re, .im = a.im - t.im };
            }
        }
    }
}

const testing = std.testing;
test "PeriodicWave: sine table is a normalized sine" {
    const allocator = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const wave = try initBasic(arena.allocator(), 44100, .sine);
    try testing.expectEqual(4096, wave.size);
    try testing.expectEqual(36, wave.number_of_ranges);
    const table = wave.tables[0].?;
    try testing.expectApproxEqAbs(@as(f32, 0), table[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), table[1024], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), table[3072], 1e-6);
}
