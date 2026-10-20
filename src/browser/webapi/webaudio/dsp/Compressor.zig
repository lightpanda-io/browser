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

// The DynamicsCompressorNode kernel, ported from Chromium's
// platform/audio/dynamics_compressor.cc (Copyright (C) 2011 Google Inc., BSD
// license). The float/double mix of every expression follows the original.

const std = @import("std");
const math = @import("math.zig");

const Compressor = @This();

pub const channels = 2;

const max_pre_delay_frames = 1024;
const max_pre_delay_mask = max_pre_delay_frames - 1;
const default_pre_delay_frames = 256;
const pre_delay: f32 = 0.006; // seconds
const metering_release_time_constant: f32 = 0.325;
const sat_release_time: f32 = 0.0025;
const division_frames = 32;
const uninitialized: f32 = -1;

// Release curve: a polynomial fit through these four zones (seconds).
const release_zone1: f32 = 0.09;
const release_zone2: f32 = 0.16;
const release_zone3: f32 = 0.42;
const release_zone4: f32 = 0.98;
const a_base: f32 = 0.9999999999999998 * release_zone1 + 1.8432219684323923e-16 * release_zone2 - 1.9373394351676423e-16 * release_zone3 + 8.824516011816245e-18 * release_zone4;
const b_base: f32 = -1.5788320352845888 * release_zone1 + 2.3305837032074286 * release_zone2 - 0.9141194204840429 * release_zone3 + 0.1623677525612032 * release_zone4;
const c_base: f32 = 0.5334142869106424 * release_zone1 - 1.272736789213631 * release_zone2 + 0.9258856042207512 * release_zone3 - 0.18656310191776226 * release_zone4;
const d_base: f32 = 0.08783463138207234 * release_zone1 - 0.1694162967925622 * release_zone2 + 0.08588057951595272 * release_zone3 - 0.00429891410546283 * release_zone4;
const e_base: f32 = -0.042416883008123074 * release_zone1 + 0.1115693827987602 * release_zone2 - 0.09764676325265872 * release_zone3 + 0.028494263462021576 * release_zone4;

pub const Params = struct {
    threshold: f32,
    knee: f32,
    ratio: f32,
    attack: f32,
    release: f32,
};

sample_rate: f32,
pre_delay_buffers: [channels][max_pre_delay_frames]f32 = @splat(@splat(0)),
pre_delay_read: u32 = 0,
pre_delay_write: u32 = default_pre_delay_frames,
last_pre_delay_frames: u32 = default_pre_delay_frames,

detector_average: f32 = 0,
compressor_gain: f32 = 1,
metering_gain: f32 = 1,
metering_release_k: f32,
max_attack_compression_diff_db: f32 = -1,

// static curve, recomputed when threshold, knee or ratio change
ratio: f32 = uninitialized,
slope: f32 = uninitialized,
linear_threshold: f32 = uninitialized,
threshold_db: f32 = uninitialized,
knee_db: f32 = uninitialized,
knee_threshold: f32 = uninitialized,
knee_threshold_db: f32 = uninitialized,
yknee_threshold_db: f32 = uninitialized,
knee_k: f32 = uninitialized,

pub fn init(sample_rate: f32) Compressor {
    return .{
        .sample_rate = sample_rate,
        .metering_release_k = @floatCast(math.discreteTimeConstant(metering_release_time_constant, sample_rate)),
    };
}

// The gain reduction in dB, for DynamicsCompressorNode.reduction.
pub fn reduction(self: *const Compressor) f32 {
    return self.metering_gain;
}

// The kernel always runs two channels; a mono source feeds both.
pub fn process(self: *Compressor, source: []const []const f32, destination: *const [channels][]f32, params: Params) void {
    const frames = destination[0].len;
    std.debug.assert(source.len > 0);

    const k = self.updateStaticCurve(params.threshold, params.knee, params.ratio);
    const linear_post_gain: f32 = @floatCast(math.powd(1 / self.saturate(1, k), @as(f32, 0.6)));
    const attack_frames = @max(@as(f32, 0.001), params.attack) * self.sample_rate;
    const release_frames = self.sample_rate * params.release;
    const sat_release_frames = sat_release_time * self.sample_rate;
    const a = release_frames * a_base;
    const b = release_frames * b_base;
    const c = release_frames * c_base;
    const d = release_frames * d_base;
    const e = release_frames * e_base;

    self.setPreDelayFrames(@intFromFloat(pre_delay * self.sample_rate));

    var frame_index: usize = 0;
    while (frame_index < frames) {
        self.detector_average = ensureFinite(self.detector_average, 1);
        const desired_gain = self.detector_average;
        const scaled_desired_gain = @as(f32, @floatCast(math.asind(desired_gain))) / math.pi_over_two_f32;

        const is_releasing = scaled_desired_gain > self.compressor_gain;
        var compression_diff_db: f32 = undefined;
        if (scaled_desired_gain == 0) {
            compression_diff_db = if (is_releasing) -1 else 1;
        } else {
            compression_diff_db = math.linearToDecibels(self.compressor_gain / scaled_desired_gain);
        }

        var envelope_rate: f32 = undefined;
        if (is_releasing) {
            self.max_attack_compression_diff_db = -1;
            var x = ensureFinite(compression_diff_db, -1);
            x = std.math.clamp(x, -12, 0);
            x = 0.25 * (x + 12);
            const x2 = x * x;
            const x3 = x2 * x;
            const x4 = x2 * x2;
            const calc_release_frames = a + b * x + c * x2 + d * x3 + e * x4;
            const db_spacing: f32 = 5;
            envelope_rate = math.decibelsToLinear(db_spacing / calc_release_frames);
        } else {
            compression_diff_db = ensureFinite(compression_diff_db, 1);
            if (self.max_attack_compression_diff_db == -1 or self.max_attack_compression_diff_db < compression_diff_db) {
                self.max_attack_compression_diff_db = compression_diff_db;
            }
            const eff_atten_diff_db = @max(@as(f32, 0.5), self.max_attack_compression_diff_db);
            const x: f32 = 0.25 / eff_atten_diff_db;
            envelope_rate = 1 - @as(f32, @floatCast(math.powd(x, 1 / attack_frames)));
        }

        var read = self.pre_delay_read;
        var write = self.pre_delay_write;
        var detector_average = self.detector_average;
        var compressor_gain = self.compressor_gain;

        const loop_frames = @min(division_frames, frames - frame_index);
        for (0..loop_frames) |_| {
            var compressor_input: f32 = 0;
            for (0..channels) |j| {
                const undelayed = (if (source.len > j) source[j] else source[0])[frame_index];
                self.pre_delay_buffers[j][write] = undelayed;
                const abs_undelayed = if (undelayed > 0) undelayed else -undelayed;
                if (compressor_input < abs_undelayed) {
                    compressor_input = abs_undelayed;
                }
            }

            const abs_input = if (compressor_input > 0) compressor_input else -compressor_input;
            const shaped_input = self.saturate(abs_input, k);
            const attenuation: f32 = if (abs_input <= 0.0001) 1 else shaped_input / abs_input;
            const attenuation_db = @max(@as(f32, 2), -math.linearToDecibels(attenuation));
            const db_per_frame = attenuation_db / sat_release_frames;
            const sat_release_rate = math.decibelsToLinear(db_per_frame) - 1;
            const rate: f32 = if (attenuation > detector_average) sat_release_rate else 1;
            detector_average += (attenuation - detector_average) * rate;
            detector_average = @min(@as(f32, 1), detector_average);
            detector_average = ensureFinite(detector_average, 1);

            if (envelope_rate < 1) {
                compressor_gain += (scaled_desired_gain - compressor_gain) * envelope_rate;
            } else {
                compressor_gain *= envelope_rate;
                compressor_gain = @min(@as(f32, 1), compressor_gain);
            }

            const post_warp_gain: f32 = @floatCast(math.sind(math.pi_over_two_f32 * compressor_gain));
            const total_gain = linear_post_gain * post_warp_gain;

            const real_gain_db = math.linearToDecibels(post_warp_gain);
            if (real_gain_db < self.metering_gain) {
                self.metering_gain = real_gain_db;
            } else {
                self.metering_gain += (real_gain_db - self.metering_gain) * self.metering_release_k;
            }

            for (0..channels) |j| {
                destination[j][frame_index] = self.pre_delay_buffers[j][read] * total_gain;
            }

            frame_index += 1;
            read = (read + 1) & max_pre_delay_mask;
            write = (write + 1) & max_pre_delay_mask;
        }

        self.pre_delay_read = read;
        self.pre_delay_write = write;
        self.detector_average = flushDenormal(detector_average);
        self.compressor_gain = flushDenormal(compressor_gain);
    }
}

fn setPreDelayFrames(self: *Compressor, requested: u32) void {
    const frames = @min(requested, max_pre_delay_frames - 1);
    if (self.last_pre_delay_frames == frames) {
        return;
    }
    self.last_pre_delay_frames = frames;
    self.pre_delay_buffers = @splat(@splat(0));
    self.pre_delay_read = 0;
    self.pre_delay_write = frames;
}

fn kneeCurve(self: *const Compressor, x: f32, k: f32) f32 {
    if (x < self.linear_threshold) {
        return x;
    }
    return self.linear_threshold + (1 - @as(f32, @floatCast(math.expd(-k * (x - self.linear_threshold))))) / k;
}

fn saturate(self: *const Compressor, x: f32, k: f32) f32 {
    if (x < self.knee_threshold) {
        return self.kneeCurve(x, k);
    }
    const x_db = math.linearToDecibels(x);
    const y_db = self.yknee_threshold_db + self.slope * (x_db - self.knee_threshold_db);
    return math.decibelsToLinear(y_db);
}

// Binary search for the knee curve's k whose slope at the knee's end is
// `desired_slope`.
fn kAtSlope(self: *const Compressor, desired_slope: f32) f32 {
    const x_db = self.threshold_db + self.knee_db;
    const x = math.decibelsToLinear(x_db);

    var x2: f32 = 1;
    var x2_db: f32 = 0;
    if ((x < self.linear_threshold) == false) {
        x2 = @floatCast(@as(f64, x) * 1.001);
        x2_db = math.linearToDecibels(x2);
    }

    var min_k: f32 = 0.1;
    var max_k: f32 = 10000;
    var k: f32 = 5;
    var slope: f32 = 1;
    for (0..15) |_| {
        if ((x < self.linear_threshold) == false) {
            const y_db = math.linearToDecibels(self.kneeCurve(x, k));
            const y2_db = math.linearToDecibels(self.kneeCurve(x2, k));
            slope = (y2_db - y_db) / (x2_db - x_db);
        }
        if (slope < desired_slope) {
            max_k = k;
        } else {
            min_k = k;
        }
        k = @sqrt(min_k * max_k);
    }
    return k;
}

fn updateStaticCurve(self: *Compressor, threshold_db: f32, knee_db: f32, ratio: f32) f32 {
    if (threshold_db != self.threshold_db or knee_db != self.knee_db or ratio != self.ratio) {
        self.threshold_db = threshold_db;
        self.linear_threshold = math.decibelsToLinear(threshold_db);
        self.knee_db = knee_db;
        self.ratio = ratio;
        self.slope = 1 / ratio;
        const k = self.kAtSlope(1 / ratio);
        self.knee_threshold_db = threshold_db + knee_db;
        self.knee_threshold = math.decibelsToLinear(self.knee_threshold_db);
        self.yknee_threshold_db = math.linearToDecibels(self.kneeCurve(self.knee_threshold, k));
        self.knee_k = k;
    }
    return self.knee_k;
}

fn ensureFinite(x: f32, default: f32) f32 {
    return if (std.math.isFinite(x)) x else default;
}

fn flushDenormal(x: f32) f32 {
    return if (@abs(x) < std.math.floatMin(f32)) 0 else x;
}
