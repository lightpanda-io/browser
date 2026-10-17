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

// https://w3c.github.io/webcodecs/#audioencoder-interface

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const codec = @import("codec.zig");
const common = @import("common.zig");

const EventTarget = @import("../EventTarget.zig");
const AudioData = @import("AudioData.zig");

const Execution = js.Execution;

const AudioEncoder = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_rc: lp.RC = .{},
_arena: *lp.Arena,
_core: codec.Core(AudioEncoder),

pub const Config = struct {
    aac: ?Aac = null,
    bitrate: ?js.EnforceRange(u64) = null,
    bitrateMode: []const u8 = "variable",
    codec: []const u8,
    flac: ?Flac = null,
    numberOfChannels: js.EnforceRange(u32),
    opus: ?Opus = null,
    sampleRate: js.EnforceRange(u32),

    // AacEncoderConfig, from the AAC registration
    const Aac = struct {
        format: []const u8 = "aac",
    };

    // FlacEncoderConfig, from the FLAC registration
    const Flac = struct {
        blockSize: js.EnforceRange(u32) = .{},
        compressLevel: js.EnforceRange(u32) = .{ .value = 5 },
    };

    // OpusEncoderConfig, from the Opus registration
    const Opus = struct {
        application: []const u8 = "audio",
        complexity: ?js.EnforceRange(u32) = null,
        format: []const u8 = "opus",
        frameDuration: js.EnforceRange(u64) = .{ .value = 20000 },
        packetlossperc: js.EnforceRange(u32) = .{},
        signal: []const u8 = "auto",
        usedtx: bool = false,
        useinbandfec: bool = false,

        fn isValid(self: Opus) bool {
            if (codec.checkEnum(self.application, &.{ "voip", "audio", "lowdelay" }) == false) return false;
            if (codec.checkEnum(self.format, &.{ "opus", "ogg" }) == false) return false;
            if (codec.checkEnum(self.signal, &.{ "auto", "music", "voice" }) == false) return false;
            // RFC 6716 frames are 2.5 to 20ms; a packet holds up to 120ms of them
            const duration = self.frameDuration.value;
            if (duration < 2500 or duration > 120_000 or duration % 2500 != 0) return false;
            if (self.complexity) |complexity| {
                if (complexity.value > 10) return false;
            }
            return self.packetlossperc.value <= 100;
        }
    };

    // "valid AudioEncoderConfig", plus the codec registrations' checks.
    pub fn isValid(self: Config) bool {
        if (codec.isEmptyCodec(self.codec)) return false;
        if (codec.checkEnum(self.bitrateMode, &.{ "constant", "variable" }) == false) return false;
        if (self.numberOfChannels.value == 0 or self.sampleRate.value == 0) return false;

        const bitrate = if (self.bitrate) |b| b.value else null;
        // Not in the spec, but every engine and WPT reject it.
        if (bitrate == 0) return false;

        if (self.aac) |aac| {
            if (codec.checkEnum(aac.format, &.{ "aac", "adts" }) == false) return false;
        }
        if (std.mem.eql(u8, self.codec, "opus")) {
            if (self.opus) |opus| {
                if (opus.isValid() == false) return false;
            }
            // Opus' own bitrate range, as Chrome enforces it.
            if (bitrate) |b| {
                if (b < 6_000 or b > 510_000) return false;
            }
        }
        return true;
    }
};

fn init(callbacks: codec.Init, exec: *Execution) !*AudioEncoder {
    const arena = try exec.getArena(.tiny, "AudioEncoder");
    errdefer arena.release();
    return exec._factory.eventTargetWithAllocator(arena.allocator(), AudioEncoder{
        ._proto = undefined,
        ._arena = arena,
        ._core = .init(callbacks, exec),
    });
}

pub fn deinit(self: *AudioEncoder, page: *Page) void {
    self._core.deinit();
    page.removeTarget(self.asEventTarget());
    self._arena.release();
}

pub fn acquireRef(self: *AudioEncoder) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *AudioEncoder, page: *Page) void {
    self._rc.release(self, page);
}

pub fn asEventTarget(self: *AudioEncoder) *EventTarget {
    return self._proto;
}

fn getState(self: *const AudioEncoder) []const u8 {
    return self._core.getState();
}

fn getEncodeQueueSize(self: *const AudioEncoder) u32 {
    return self._core.queue_size;
}

fn configure(self: *AudioEncoder, config: Config) !void {
    if (config.isValid() == false) {
        return error.TypeError;
    }
    return self._core.configure(false);
}

fn encode(self: *AudioEncoder, data: *AudioData) !void {
    if (data.isClosed()) {
        return error.TypeError;
    }
    return self._core.enqueue();
}

fn flush(self: *AudioEncoder, exec: *const Execution) !js.Promise {
    return self._core.flush(false, exec);
}

fn reset(self: *AudioEncoder) !void {
    return self._core.reset();
}

fn close(self: *AudioEncoder) !void {
    return self._core.close();
}

fn isConfigSupported(config: js.Value, exec: *Execution) !js.Promise {
    return codec.isConfigSupported(Config, config, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioEncoder);

    pub const Meta = struct {
        pub const name = "AudioEncoder";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AudioEncoder.init, .{});
    pub const state = bridge.accessor(AudioEncoder.getState, null, .{});
    pub const encodeQueueSize = bridge.accessor(AudioEncoder.getEncodeQueueSize, null, .{});
    pub const ondequeue = EventTarget.handlerAccessor(AudioEncoder, "dequeue");
    pub const configure = bridge.function(AudioEncoder.configure, .{});
    pub const encode = bridge.function(AudioEncoder.encode, .{});
    pub const flush = bridge.function(AudioEncoder.flush, .{});
    pub const reset = bridge.function(AudioEncoder.reset, .{});
    pub const close = bridge.function(AudioEncoder.close, .{});
    pub const isConfigSupported = bridge.function(AudioEncoder.isConfigSupported, .{ .static = true });
};
