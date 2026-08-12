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

//! Minimal Web Audio compatibility APIs.

const std = @import("std");
const lp = @import("lightpanda");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

pub fn registerTypes() []const type {
    return &.{
        AudioContext,
        OfflineAudioContext,
        AudioBuffer,
        OscillatorNode,
        DynamicsCompressorNode,
        AnalyserNode,
        GainNode,
        AudioDestinationNode,
        AudioParam,
    };
}

pub const AudioParam = struct {
    _value: f64 = 0,

    pub fn getValue(self: *const AudioParam) f64 {
        return self._value;
    }
    pub fn setValue(self: *AudioParam, v: f64) void {
        self._value = v;
    }
    pub fn setValueAtTime(self: *AudioParam, value: f64, _: f64) *AudioParam {
        self._value = value;
        return self;
    }
    pub fn linearRampToValueAtTime(self: *AudioParam, value: f64, _: f64) *AudioParam {
        self._value = value;
        return self;
    }
    pub fn exponentialRampToValueAtTime(self: *AudioParam, value: f64, _: f64) *AudioParam {
        self._value = value;
        return self;
    }
    pub fn setTargetAtTime(self: *AudioParam, value: f64, _: f64, _: f64) *AudioParam {
        self._value = value;
        return self;
    }
    pub fn cancelScheduledValues(self: *AudioParam, _: f64) *AudioParam {
        return self;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioParam);
        pub const Meta = struct {
            pub const name = "AudioParam";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const value = bridge.accessor(AudioParam.getValue, AudioParam.setValue, .{});
        pub const defaultValue = bridge.property(0, .{ .template = false, .readonly = true });
        pub const minValue = bridge.property(-3.4028235e38, .{ .template = false, .readonly = true });
        pub const maxValue = bridge.property(3.4028235e38, .{ .template = false, .readonly = true });
        pub const setValueAtTime = bridge.function(AudioParam.setValueAtTime, .{});
        pub const linearRampToValueAtTime = bridge.function(AudioParam.linearRampToValueAtTime, .{});
        pub const exponentialRampToValueAtTime = bridge.function(AudioParam.exponentialRampToValueAtTime, .{});
        pub const setTargetAtTime = bridge.function(AudioParam.setTargetAtTime, .{});
        pub const cancelScheduledValues = bridge.function(AudioParam.cancelScheduledValues, .{});
    };
};

pub const AudioBuffer = struct {
    _rc: lp.RC = .{},
    _sample_rate: f32,
    _length: u32,
    _number_of_channels: u32,
    _data: js.ArrayBufferRef(.float32).Global,

    pub fn deinit(self: *AudioBuffer, page: *Page) void {
        self._data.release();
        page.factory.destroy(self);
    }
    pub fn releaseRef(self: *AudioBuffer, page: *Page) void {
        self._rc.release(self, page);
    }
    pub fn acquireRef(self: *AudioBuffer) void {
        self._rc.acquire();
    }

    pub fn getSampleRate(self: *const AudioBuffer) f32 {
        return self._sample_rate;
    }
    pub fn getLength(self: *const AudioBuffer) u32 {
        return self._length;
    }
    pub fn getDuration(self: *const AudioBuffer) f64 {
        return @as(f64, @floatFromInt(self._length)) / @as(f64, self._sample_rate);
    }
    pub fn getNumberOfChannels(self: *const AudioBuffer) u32 {
        return self._number_of_channels;
    }

    pub fn getChannelData(self: *AudioBuffer, channel: u32, exec: *const js.Execution) !js.ArrayBufferRef(.float32).Global {
        if (channel >= self._number_of_channels) return error.IndexSizeError;
        _ = exec;
        return self._data;
    }

    pub fn copyFromChannel(self: *AudioBuffer, _: js.Value, channel: u32, _: ?u32, _: *const js.Execution) !void {
        if (channel >= self._number_of_channels) return error.IndexSizeError;
        // Destination write is best-effort; primary path is getChannelData.
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioBuffer);
        pub const Meta = struct {
            pub const name = "AudioBuffer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const sampleRate = bridge.accessor(AudioBuffer.getSampleRate, null, .{});
        pub const length = bridge.accessor(AudioBuffer.getLength, null, .{});
        pub const duration = bridge.accessor(AudioBuffer.getDuration, null, .{});
        pub const numberOfChannels = bridge.accessor(AudioBuffer.getNumberOfChannels, null, .{});
        pub const getChannelData = bridge.function(AudioBuffer.getChannelData, .{});
        pub const copyFromChannel = bridge.function(AudioBuffer.copyFromChannel, .{});
    };
};

pub const AudioDestinationNode = struct {
    _pad: bool = false,

    pub fn connect(self: *AudioDestinationNode, _: js.Value, _: ?u32, _: ?u32) *AudioDestinationNode {
        return self;
    }
    pub fn disconnect(_: *AudioDestinationNode, _: ?js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioDestinationNode);
        pub const Meta = struct {
            pub const name = "AudioDestinationNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
        pub const maxChannelCount = bridge.property(2, .{ .template = false, .readonly = true });
        pub const numberOfInputs = bridge.property(1, .{ .template = false, .readonly = true });
        pub const numberOfOutputs = bridge.property(0, .{ .template = false, .readonly = true });
        pub const connect = bridge.function(AudioDestinationNode.connect, .{});
        pub const disconnect = bridge.function(AudioDestinationNode.disconnect, .{ .noop = true });
    };
};

pub const OscillatorNode = struct {
    _frequency: *AudioParam,
    _type: [16]u8 = "sine".* ++ .{0} ** 12,
    _type_len: u8 = 4,

    pub fn getFrequency(self: *OscillatorNode) *AudioParam {
        return self._frequency;
    }
    pub fn getType(self: *const OscillatorNode) []const u8 {
        return self._type[0..self._type_len];
    }
    pub fn setType(self: *OscillatorNode, value: []const u8) void {
        const n = @min(value.len, self._type.len);
        @memcpy(self._type[0..n], value[0..n]);
        self._type_len = @intCast(n);
    }
    pub fn start(_: *OscillatorNode, _: ?f64) void {}
    pub fn stop(_: *OscillatorNode, _: ?f64) void {}
    pub fn connect(self: *OscillatorNode, _: js.Value, _: ?u32, _: ?u32) *OscillatorNode {
        return self;
    }
    pub fn disconnect(_: *OscillatorNode, _: ?js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(OscillatorNode);
        pub const Meta = struct {
            pub const name = "OscillatorNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const frequency = bridge.accessor(OscillatorNode.getFrequency, null, .{});
        pub const @"type" = bridge.accessor(OscillatorNode.getType, OscillatorNode.setType, .{});
        pub const start = bridge.function(OscillatorNode.start, .{ .noop = true });
        pub const stop = bridge.function(OscillatorNode.stop, .{ .noop = true });
        pub const connect = bridge.function(OscillatorNode.connect, .{});
        pub const disconnect = bridge.function(OscillatorNode.disconnect, .{ .noop = true });
    };
};

pub const DynamicsCompressorNode = struct {
    _threshold: *AudioParam,
    _knee: *AudioParam,
    _ratio: *AudioParam,
    _attack: *AudioParam,
    _release: *AudioParam,

    pub fn getThreshold(self: *DynamicsCompressorNode) *AudioParam {
        return self._threshold;
    }
    pub fn getKnee(self: *DynamicsCompressorNode) *AudioParam {
        return self._knee;
    }
    pub fn getRatio(self: *DynamicsCompressorNode) *AudioParam {
        return self._ratio;
    }
    pub fn getAttack(self: *DynamicsCompressorNode) *AudioParam {
        return self._attack;
    }
    pub fn getRelease(self: *DynamicsCompressorNode) *AudioParam {
        return self._release;
    }
    pub fn connect(self: *DynamicsCompressorNode, _: js.Value, _: ?u32, _: ?u32) *DynamicsCompressorNode {
        return self;
    }
    pub fn disconnect(_: *DynamicsCompressorNode, _: ?js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(DynamicsCompressorNode);
        pub const Meta = struct {
            pub const name = "DynamicsCompressorNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const threshold = bridge.accessor(DynamicsCompressorNode.getThreshold, null, .{});
        pub const knee = bridge.accessor(DynamicsCompressorNode.getKnee, null, .{});
        pub const ratio = bridge.accessor(DynamicsCompressorNode.getRatio, null, .{});
        pub const attack = bridge.accessor(DynamicsCompressorNode.getAttack, null, .{});
        pub const release = bridge.accessor(DynamicsCompressorNode.getRelease, null, .{});
        pub const reduction = bridge.property(-20, .{ .template = false, .readonly = true });
        pub const connect = bridge.function(DynamicsCompressorNode.connect, .{});
        pub const disconnect = bridge.function(DynamicsCompressorNode.disconnect, .{ .noop = true });
    };
};

pub const AnalyserNode = struct {
    _pad: bool = false,

    pub fn getFloatFrequencyData(_: *AnalyserNode, array: js.Value) void {
        // Accept any typed array-like; callers commonly pass Float32Array.
        _ = array;
    }
    pub fn getByteFrequencyData(_: *AnalyserNode, array: js.Value) void {
        _ = array;
    }
    pub fn getFloatTimeDomainData(_: *AnalyserNode, array: js.Value) void {
        _ = array;
    }
    pub fn getByteTimeDomainData(_: *AnalyserNode, array: js.Value) void {
        _ = array;
    }
    pub fn connect(self: *AnalyserNode, _: js.Value, _: ?u32, _: ?u32) *AnalyserNode {
        return self;
    }
    pub fn disconnect(_: *AnalyserNode, _: ?js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AnalyserNode);
        pub const Meta = struct {
            pub const name = "AnalyserNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
        pub const fftSize = bridge.property(2048, .{ .template = false, .readonly = false });
        pub const frequencyBinCount = bridge.property(1024, .{ .template = false, .readonly = true });
        pub const minDecibels = bridge.property(-100, .{ .template = false, .readonly = false });
        pub const maxDecibels = bridge.property(-30, .{ .template = false, .readonly = false });
        pub const smoothingTimeConstant = bridge.property(0.8, .{ .template = false, .readonly = false });
        pub const getFloatFrequencyData = bridge.function(AnalyserNode.getFloatFrequencyData, .{});
        pub const getByteFrequencyData = bridge.function(AnalyserNode.getByteFrequencyData, .{});
        pub const getFloatTimeDomainData = bridge.function(AnalyserNode.getFloatTimeDomainData, .{});
        pub const getByteTimeDomainData = bridge.function(AnalyserNode.getByteTimeDomainData, .{});
        pub const connect = bridge.function(AnalyserNode.connect, .{});
        pub const disconnect = bridge.function(AnalyserNode.disconnect, .{ .noop = true });
    };
};

pub const GainNode = struct {
    _gain: *AudioParam,

    pub fn getGain(self: *GainNode) *AudioParam {
        return self._gain;
    }
    pub fn connect(self: *GainNode, _: js.Value, _: ?u32, _: ?u32) *GainNode {
        return self;
    }
    pub fn disconnect(_: *GainNode, _: ?js.Value) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(GainNode);
        pub const Meta = struct {
            pub const name = "GainNode";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const gain = bridge.accessor(GainNode.getGain, null, .{});
        pub const connect = bridge.function(GainNode.connect, .{});
        pub const disconnect = bridge.function(GainNode.disconnect, .{ .noop = true });
    };
};

const Base = struct {
    sample_rate: f32,
    state: []const u8 = "running",
    current_time: f64 = 0,
    destination: ?*AudioDestinationNode = null,
    seed: u64,

    fn ensureDestination(self: *Base, exec: *const js.Execution) !*AudioDestinationNode {
        if (self.destination) |d| return d;
        const dest = try exec._factory.create(AudioDestinationNode{});
        self.destination = dest;
        return dest;
    }
};

fn createParam(exec: *const js.Execution, value: f64) !*AudioParam {
    return exec._factory.create(AudioParam{ ._value = value });
}

fn fillSamples(samples: []f32, seed: u64, sample_rate: f32) void {
    var rng = seed ^ 0x415544494f;
    for (samples, 0..) |*s, i| {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        const t = @as(f32, @floatFromInt(i)) / sample_rate;
        const osc = @sin(t * 10000.0 * std.math.tau) * 0.5;
        const noise = @as(f32, @floatFromInt(@as(u16, @truncate(rng)))) / 65535.0 - 0.5;
        var v = osc * 0.35 + noise * 0.02;
        if (i >= 4500 and i < 5000) {
            v += 0.12 + @as(f32, @floatFromInt(i - 4500)) * 0.0001;
        }
        s.* = v;
    }
}

fn fnv(h: u64, v: u64) u64 {
    var x = h ^ v;
    x *%= 0x100000001b3;
    return x;
}

pub const OfflineAudioContext = struct {
    _base: Base,
    _length: u32,
    _number_of_channels: u32,

    pub fn init(channels_or_opts: ChannelsOrOpts, length: ?u32, sample_rate: ?f32, exec: *const js.Execution) !*OfflineAudioContext {
        const ch: u32, const len: u32, const rate: f32 = switch (channels_or_opts) {
            .channels => |c| .{ c, length orelse return error.TypeError, sample_rate orelse return error.TypeError },
            .opts => |o| .{ o.numberOfChannels, o.length, o.sampleRate },
        };
        if (ch == 0 or ch > 32 or len == 0 or rate < 3000 or rate > 768000) {
            return error.NotSupportedError;
        }
        // Mix the profile noise seed in here (not only at render time) so every
        // seed-derived audio path differs per instance instead of sharing one
        // product-wide hash.
        var seed: u64 = exec.session.browser.app.config.fingerprint_profile.noise_seed;
        seed = fnv(seed, ch);
        seed = fnv(seed, len);
        seed = fnv(seed, @as(u32, @bitCast(rate)));
        return exec._factory.create(OfflineAudioContext{
            ._base = .{ .sample_rate = rate, .state = "suspended", .seed = seed },
            ._length = len,
            ._number_of_channels = ch,
        });
    }

    const ChannelsOrOpts = union(enum) {
        channels: u32,
        opts: Opts,
        const Opts = struct {
            numberOfChannels: u32,
            length: u32,
            sampleRate: f32,
        };
    };

    pub fn getDestination(self: *OfflineAudioContext, exec: *const js.Execution) !*AudioDestinationNode {
        return self._base.ensureDestination(exec);
    }
    pub fn getSampleRate(self: *const OfflineAudioContext) f32 {
        return self._base.sample_rate;
    }
    pub fn getCurrentTime(self: *const OfflineAudioContext) f64 {
        return self._base.current_time;
    }
    pub fn getState(self: *const OfflineAudioContext) []const u8 {
        return self._base.state;
    }
    pub fn getLength(self: *const OfflineAudioContext) u32 {
        return self._length;
    }

    pub fn createOscillator(self: *OfflineAudioContext, exec: *const js.Execution) !*OscillatorNode {
        _ = self;
        return exec._factory.create(OscillatorNode{ ._frequency = try createParam(exec, 440) });
    }
    pub fn createDynamicsCompressor(self: *OfflineAudioContext, exec: *const js.Execution) !*DynamicsCompressorNode {
        _ = self;
        return exec._factory.create(DynamicsCompressorNode{
            ._threshold = try createParam(exec, -24),
            ._knee = try createParam(exec, 30),
            ._ratio = try createParam(exec, 12),
            ._attack = try createParam(exec, 0.003),
            ._release = try createParam(exec, 0.25),
        });
    }
    pub fn createAnalyser(self: *OfflineAudioContext, exec: *const js.Execution) !*AnalyserNode {
        _ = self;
        return exec._factory.create(AnalyserNode{});
    }
    pub fn createGain(self: *OfflineAudioContext, exec: *const js.Execution) !*GainNode {
        _ = self;
        return exec._factory.create(GainNode{ ._gain = try createParam(exec, 1) });
    }

    pub fn startRendering(self: *OfflineAudioContext, exec: *const js.Execution) !js.Promise {
        self._base.state = "closed";
        const local = exec.js.local.?;
        const samples = local.createTypedArray(.float32, self._length);
        fillSamples(samples.slice(), self._base.seed, self._base.sample_rate);
        const buffer = try exec._factory.create(AudioBuffer{
            ._sample_rate = self._base.sample_rate,
            ._length = self._length,
            ._number_of_channels = self._number_of_channels,
            ._data = try samples.persist(),
        });
        return local.resolvePromise(buffer);
    }

    pub fn close(self: *OfflineAudioContext, exec: *const js.Execution) !js.Promise {
        self._base.state = "closed";
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(OfflineAudioContext);
        pub const Meta = struct {
            pub const name = "OfflineAudioContext";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(OfflineAudioContext.init, .{});
        pub const destination = bridge.accessor(OfflineAudioContext.getDestination, null, .{});
        pub const sampleRate = bridge.accessor(OfflineAudioContext.getSampleRate, null, .{});
        pub const currentTime = bridge.accessor(OfflineAudioContext.getCurrentTime, null, .{});
        pub const state = bridge.accessor(OfflineAudioContext.getState, null, .{});
        pub const length = bridge.accessor(OfflineAudioContext.getLength, null, .{});
        pub const createOscillator = bridge.function(OfflineAudioContext.createOscillator, .{});
        pub const createDynamicsCompressor = bridge.function(OfflineAudioContext.createDynamicsCompressor, .{});
        pub const createAnalyser = bridge.function(OfflineAudioContext.createAnalyser, .{});
        pub const createGain = bridge.function(OfflineAudioContext.createGain, .{});
        pub const startRendering = bridge.function(OfflineAudioContext.startRendering, .{});
        pub const close = bridge.function(OfflineAudioContext.close, .{});
    };
};

pub const AudioContext = struct {
    _base: Base,

    pub fn init(opts_: ?Opts, exec: *const js.Execution) !*AudioContext {
        const opts = opts_ orelse Opts{};
        const rate = opts.sampleRate orelse 44100;
        return exec._factory.create(AudioContext{
            ._base = .{
                .sample_rate = rate,
                .state = "running",
                .seed = fnv(exec.session.browser.app.config.fingerprint_profile.noise_seed, @as(u32, @bitCast(rate))),
            },
        });
    }

    const Opts = struct {
        sampleRate: ?f32 = null,
        latencyHint: ?[]const u8 = null,
    };

    pub fn getDestination(self: *AudioContext, exec: *const js.Execution) !*AudioDestinationNode {
        return self._base.ensureDestination(exec);
    }
    pub fn getSampleRate(self: *const AudioContext) f32 {
        return self._base.sample_rate;
    }
    pub fn getCurrentTime(self: *const AudioContext) f64 {
        return self._base.current_time;
    }
    pub fn getState(self: *const AudioContext) []const u8 {
        return self._base.state;
    }
    pub fn getBaseLatency(_: *const AudioContext) f64 {
        return 0.01;
    }
    pub fn getOutputLatency(_: *const AudioContext) f64 {
        return 0.02;
    }

    pub fn createOscillator(self: *AudioContext, exec: *const js.Execution) !*OscillatorNode {
        _ = self;
        return exec._factory.create(OscillatorNode{ ._frequency = try createParam(exec, 440) });
    }
    pub fn createDynamicsCompressor(self: *AudioContext, exec: *const js.Execution) !*DynamicsCompressorNode {
        _ = self;
        return exec._factory.create(DynamicsCompressorNode{
            ._threshold = try createParam(exec, -24),
            ._knee = try createParam(exec, 30),
            ._ratio = try createParam(exec, 12),
            ._attack = try createParam(exec, 0.003),
            ._release = try createParam(exec, 0.25),
        });
    }
    pub fn createAnalyser(self: *AudioContext, exec: *const js.Execution) !*AnalyserNode {
        _ = self;
        return exec._factory.create(AnalyserNode{});
    }
    pub fn createGain(self: *AudioContext, exec: *const js.Execution) !*GainNode {
        _ = self;
        return exec._factory.create(GainNode{ ._gain = try createParam(exec, 1) });
    }

    pub fn resumeContext(self: *AudioContext, exec: *const js.Execution) !js.Promise {
        self._base.state = "running";
        return exec.js.local.?.resolvePromise({});
    }
    pub fn suspendContext(self: *AudioContext, exec: *const js.Execution) !js.Promise {
        self._base.state = "suspended";
        return exec.js.local.?.resolvePromise({});
    }
    pub fn close(self: *AudioContext, exec: *const js.Execution) !js.Promise {
        self._base.state = "closed";
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AudioContext);
        pub const Meta = struct {
            pub const name = "AudioContext";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const constructor = bridge.constructor(AudioContext.init, .{});
        pub const destination = bridge.accessor(AudioContext.getDestination, null, .{});
        pub const sampleRate = bridge.accessor(AudioContext.getSampleRate, null, .{});
        pub const currentTime = bridge.accessor(AudioContext.getCurrentTime, null, .{});
        pub const state = bridge.accessor(AudioContext.getState, null, .{});
        pub const baseLatency = bridge.accessor(AudioContext.getBaseLatency, null, .{});
        pub const outputLatency = bridge.accessor(AudioContext.getOutputLatency, null, .{});
        pub const createOscillator = bridge.function(AudioContext.createOscillator, .{});
        pub const createDynamicsCompressor = bridge.function(AudioContext.createDynamicsCompressor, .{});
        pub const createAnalyser = bridge.function(AudioContext.createAnalyser, .{});
        pub const createGain = bridge.function(AudioContext.createGain, .{});
        pub const @"resume" = bridge.function(AudioContext.resumeContext, .{});
        pub const @"suspend" = bridge.function(AudioContext.suspendContext, .{});
        pub const close = bridge.function(AudioContext.close, .{});
    };
};

const testing = @import("../../../testing.zig");
const Fingerprint = @import("../../Fingerprint.zig");

test "WebApi: AudioContext" {
    try testing.htmlRunner("audio/audio_context.html", .{});
}

/// The hash a page computes from `startRendering()`'s samples, for a fixed
/// (channels, length, rate) and a given profile.
fn audioHash(noise_seed: u64) u64 {
    var samples: [8192]f32 = undefined;
    var seed = fnv(noise_seed, 1);
    seed = fnv(seed, samples.len);
    seed = fnv(seed, @as(u32, @bitCast(@as(f32, 44100))));
    fillSamples(&samples, seed, 44100);

    var hash: u64 = 0xcbf29ce484222325;
    for (samples) |sample| {
        hash = fnv(hash, @as(u32, @bitCast(sample)));
    }
    return hash;
}

test "AudioContext: audio fingerprint follows the profile seed" {
    const a = Fingerprint.Profile.fromSeed(1234, .windows).noise_seed;
    const b = Fingerprint.Profile.fromSeed(5678, .windows).noise_seed;

    // Same seed reproduces; different seeds must not share one product-wide hash.
    try testing.expectEqual(audioHash(a), audioHash(a));
    try testing.expect(audioHash(a) != audioHash(b));
    try testing.expect(audioHash(a) != audioHash(Fingerprint.Profile.stock.noise_seed));
}
