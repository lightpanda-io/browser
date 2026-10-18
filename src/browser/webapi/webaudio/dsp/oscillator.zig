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

// Wavetable oscillator, ported from Chromium's oscillator_handler.cc and
// cpu/x86/oscillator_kernel_sse2.cc (Copyright The Chromium Authors, BSD
// license). The four-wide paths reproduce the SSE2 kernels' f32/f64 mix, so
// the samples match Chrome on x86-64 bit for bit, given the same tables.

const std = @import("std");
const PeriodicWave = @import("PeriodicWave.zig");

// Below these phase increments, 2-point interpolation is too coarse.
const interpolate_2_point: f32 = 0.3;
const interpolate_3_point: f32 = 0.16;

const V4 = @Vector(4, f32);
const I4 = @Vector(4, i32);

// Frequency (already detuned and clamped) constant over the quantum.
pub fn processKRate(wave: *const PeriodicWave, destination: []f32, virtual_read_index: f64, frequency: f32) f64 {
    const size = wave.size;
    const size_f: f64 = @floatFromInt(size);
    const inv_size: f64 = 1.0 / size_f;
    const mask = size - 1;
    const n = destination.len;

    const data = wave.waveData(frequency);
    const incr = frequency * wave.rate_scale;

    var index = virtual_read_index;
    if (incr >= interpolate_2_point) {
        const k = kRateVector(wave, destination, index, incr, data);
        index += @as(f32, @floatFromInt(k)) * incr;
        index -= @floor(index * inv_size) * size_f;
        if (k < n) {
            _ = kRateScalar(destination[k..], index, incr, mask, inv_size, size_f, data);
        }
        var result = virtual_read_index + @as(f32, @floatFromInt(n)) * incr;
        result -= @floor(result * inv_size) * size_f;
        return result;
    }

    for (destination) |*d| {
        d.* = interpolate(index, @abs(incr), mask, data);
        index += incr;
        index -= @floor(index * inv_size) * size_f;
    }
    return index;
}

fn kRateVector(wave: *const PeriodicWave, destination: []f32, virtual_read_index: f64, incr: f32, data: PeriodicWave.WaveData) usize {
    const size_v: V4 = @splat(@floatFromInt(wave.size));
    const inv_size_v: V4 = @splat(1.0 / @as(f32, @floatFromInt(wave.size)));
    const mask_v: I4 = @splat(@intCast(wave.size - 1));
    const factor_v: V4 = @splat(data.factor);
    const incr_v: V4 = @splat(4 * incr);

    var virt: V4 = .{
        @floatCast(virtual_read_index),
        @floatCast(virtual_read_index + incr),
        @floatCast(virtual_read_index + 2 * incr),
        @floatCast(virtual_read_index + 3 * incr),
    };
    virt = wrapVector(virt, size_v, inv_size_v);

    var k: usize = 0;
    const loops = destination.len / 4;
    for (0..loops) |_| {
        const read0 = truncate(virt) & mask_v;
        const read1 = (read0 + @as(I4, @splat(1))) & mask_v;
        var s1_lower: V4 = undefined;
        var s2_lower: V4 = undefined;
        var s1_higher: V4 = undefined;
        var s2_higher: V4 = undefined;
        inline for (0..4) |m| {
            const r0: usize = @intCast(read0[m]);
            const r1: usize = @intCast(read1[m]);
            s1_lower[m] = data.lower[r0];
            s2_lower[m] = data.lower[r1];
            s1_higher[m] = data.higher[r0];
            s2_higher[m] = data.higher[r1];
        }
        const interpolation = virt - @as(V4, @floatFromInt(read0));
        const higher = s1_higher + interpolation * (s2_higher - s1_higher);
        const lower = s1_lower + interpolation * (s2_lower - s1_lower);
        const sample = higher + factor_v * (lower - higher);
        destination[k..][0..4].* = sample;

        virt += incr_v;
        virt = wrapVector(virt, size_v, inv_size_v);
        k += 4;
    }
    return k;
}

fn kRateScalar(destination: []f32, virtual_read_index: f64, incr: f32, mask: u32, inv_size: f64, size_f: f64, data: PeriodicWave.WaveData) f64 {
    var index = virtual_read_index;
    for (destination) |*d| {
        const read0 = @as(u32, @intFromFloat(index)) & mask;
        const read1 = (read0 + 1) & mask;
        const interpolation = @as(f32, @floatCast(index)) - @as(f32, @floatFromInt(read0));
        const higher = data.higher[read0] + interpolation * (data.higher[read1] - data.higher[read0]);
        const lower = data.lower[read0] + interpolation * (data.lower[read1] - data.lower[read0]);
        d.* = higher + data.factor * (lower - higher);
        index += incr;
        index -= @floor(index * inv_size) * size_f;
    }
    return index;
}

// Per-frame phase increments (frequency * rate_scale), from an a-rate
// frequency or detune.
pub fn processARate(wave: *const PeriodicWave, destination: []f32, virtual_read_index: f64, increments: []const f32) f64 {
    const size = wave.size;
    const size_f: f64 = @floatFromInt(size);
    const inv_size: f64 = 1.0 / size_f;
    const mask = size - 1;
    const inv_rate_scale: f32 = 1 / wave.rate_scale;

    var index = virtual_read_index;
    var k: usize = 0;
    const loops = destination.len / 4;
    for (0..loops) |_| {
        var big = true;
        var data: [4]PeriodicWave.WaveData = undefined;
        for (0..4) |m| {
            const incr = increments[k + m];
            big = big and @abs(incr) >= interpolate_2_point;
            data[m] = wave.waveData(inv_rate_scale * incr);
        }
        if (big) {
            index = aRateVectorKernel(destination[k..][0..4], index, increments[k..][0..4], size, &data);
        } else {
            for (0..4) |m| {
                destination[k + m] = interpolate(index, @abs(increments[k + m]), mask, data[m]);
                index += increments[k + m];
                index -= @floor(index * inv_size) * size_f;
            }
        }
        k += 4;
    }

    while (k < destination.len) : (k += 1) {
        const incr = increments[k];
        const data = wave.waveData(inv_rate_scale * incr);
        destination[k] = interpolate(index, @abs(incr), mask, data);
        index += incr;
        index -= @floor(index * inv_size) * size_f;
    }
    return index;
}

fn aRateVectorKernel(destination: *[4]f32, virtual_read_index: f64, increments: *const [4]f32, size: u32, data: *const [4]PeriodicWave.WaveData) f64 {
    const size_f: f64 = @floatFromInt(size);
    const inv_size: f64 = 1.0 / size_f;
    const mask: i32 = @intCast(size - 1);

    var sum: [4]f64 = undefined;
    sum[0] = increments[0];
    for (1..4) |m| sum[m] = sum[m - 1] + increments[m];

    var read_index: [4]f64 = .{
        virtual_read_index,
        virtual_read_index + sum[0],
        virtual_read_index + sum[1],
        virtual_read_index + sum[2],
    };
    var read0: [4]i32 = undefined;
    var factor: V4 = undefined;
    var s1_lower: V4 = undefined;
    var s2_lower: V4 = undefined;
    var s1_higher: V4 = undefined;
    var s2_higher: V4 = undefined;
    var table_factor: V4 = undefined;
    inline for (0..4) |m| {
        // floor via truncate-and-adjust, as WrapVirtualIndexVectorPd
        const r = read_index[m] * inv_size;
        var f: i32 = @intFromFloat(r);
        if (r < @as(f64, @floatFromInt(f))) f -= 1;
        read_index[m] -= @as(f64, @floatFromInt(f)) * size_f;

        const r0: i32 = @intFromFloat(read_index[m]);
        read0[m] = r0 & mask;
        const r1: usize = @intCast((r0 + 1) & mask);
        const r0_index: usize = @intCast(read0[m]);
        s1_lower[m] = data[m].lower[r0_index];
        s2_lower[m] = data[m].lower[r1];
        s1_higher[m] = data[m].higher[r0_index];
        s2_higher[m] = data[m].higher[r1];
        table_factor[m] = data[m].factor;
        factor[m] = @as(f32, @floatCast(read_index[m])) - @as(f32, @floatFromInt(read0[m]));
    }
    const higher = s1_higher + factor * (s2_higher - s1_higher);
    const lower = s1_lower + factor * (s2_lower - s1_lower);
    destination.* = higher + table_factor * (lower - higher);

    var index = virtual_read_index + sum[3];
    index -= @floor(index * inv_size) * size_f;
    return index;
}

// Small increments (low frequencies) get 3- or 5-point Lagrange
// interpolation.
fn interpolate(virtual_read_index: f64, incr: f32, mask: u32, data: PeriodicWave.WaveData) f32 {
    var lower: f64 = 0;
    var higher: f64 = 0;
    const read0: u32 = @intFromFloat(virtual_read_index);

    if (incr >= interpolate_2_point) {
        const r0 = read0 & mask;
        const r1 = (read0 + 1) & mask;
        const t: f64 = @as(f32, @floatCast(virtual_read_index)) - @as(f32, @floatFromInt(r0));
        higher = (1 - t) * data.higher[r0] + t * data.higher[r1];
        lower = (1 - t) * data.lower[r0] + t * data.lower[r1];
    } else if (incr >= interpolate_3_point) {
        const t = virtual_read_index - @as(f64, @floatFromInt(read0));
        const a = [3]f64{ 0.5 * t * (t - 1), 1 - t * t, 0.5 * t * (t + 1) };
        inline for (0..3) |i| {
            const r = (read0 +% @as(u32, @bitCast(@as(i32, i) - 1))) & mask;
            lower += a[i] * data.lower[r];
            higher += a[i] * data.higher[r];
        }
    } else {
        const t = virtual_read_index - @as(f64, @floatFromInt(read0));
        const t2 = t * t;
        const a = [5]f64{
            t * (t2 - 1) * (t - 2) / 24,
            -t * (t - 1) * (t2 - 4) / 6,
            (t2 - 1) * (t2 - 4) / 4,
            -t * (t + 1) * (t2 - 4) / 6,
            t * (t2 - 1) * (t + 2) / 24,
        };
        inline for (0..5) |i| {
            const r = (read0 +% @as(u32, @bitCast(@as(i32, i) - 2))) & mask;
            lower += a[i] * data.lower[r];
            higher += a[i] * data.higher[r];
        }
    }
    const factor = data.factor;
    return @floatCast((1 - factor) * higher + factor * lower);
}

fn truncate(v: V4) I4 {
    return @intFromFloat(v);
}

// x - floor(x / size) * size, in f32 as the SSE kernel computes it.
fn wrapVector(x: V4, size: V4, inv_size: V4) V4 {
    const r = x * inv_size;
    var f = truncate(r);
    f -= @select(i32, r < @as(V4, @floatFromInt(f)), @as(I4, @splat(1)), @as(I4, @splat(0)));
    return x - @as(V4, @floatFromInt(f)) * size;
}
