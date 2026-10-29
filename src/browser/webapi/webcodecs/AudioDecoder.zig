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

// https://w3c.github.io/webcodecs/#audiodecoder-interface

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const codec = @import("codec.zig");
const common = @import("common.zig");

const EventTarget = @import("../EventTarget.zig");
const EncodedAudioChunk = @import("encoded_chunk.zig").EncodedAudioChunk;

const Execution = js.Execution;

const AudioDecoder = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_rc: lp.RC = .{},
_arena: *lp.Arena,
_core: codec.Core(AudioDecoder),

pub const Config = struct {
    codec: []const u8,
    description: ?js.Value = null,
    numberOfChannels: js.EnforceRange(u32),
    sampleRate: js.EnforceRange(u32),

    // "valid AudioDecoderConfig", plus the Opus registration's check.
    pub fn isValid(self: Config) bool {
        if (codec.isEmptyCodec(self.codec)) return false;
        if (self.description) |d| {
            if (codec.isDetachedBuffer(d)) return false;
        }
        const channels = self.numberOfChannels.value;
        const sample_rate = self.sampleRate.value;
        if (channels == 0 or sample_rate == 0) return false;
        if (std.mem.eql(u8, self.codec, "opus") and channels > 2 and self.description == null) return false;
        return true;
    }
};

fn init(callbacks: codec.Init, exec: *Execution) !*AudioDecoder {
    const arena = try exec.getArena(.tiny, "AudioDecoder");
    errdefer arena.release();
    return exec._factory.eventTargetWithAllocator(arena.allocator(), AudioDecoder{
        ._proto = undefined,
        ._arena = arena,
        ._core = .init(callbacks, exec),
    });
}

pub fn deinit(self: *AudioDecoder, page: *Page) void {
    self._core.deinit();
    page.removeTarget(self.asEventTarget());
    self._arena.release();
}

pub fn acquireRef(self: *AudioDecoder) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *AudioDecoder, page: *Page) void {
    self._rc.release(self, page);
}

pub fn asEventTarget(self: *AudioDecoder) *EventTarget {
    return self._proto;
}

fn getState(self: *const AudioDecoder) []const u8 {
    return self._core.getState();
}

fn getDecodeQueueSize(self: *const AudioDecoder) u32 {
    return self._core.queue_size;
}

fn configure(self: *AudioDecoder, config: Config) !void {
    if (config.isValid() == false) {
        return error.TypeError;
    }
    return self._core.configure(true);
}

fn decode(self: *AudioDecoder, chunk: *EncodedAudioChunk) !void {
    const core = &self._core;
    if (core.state != .configured) {
        return error.InvalidStateError;
    }
    if (core.key_chunk_required) {
        if (chunk._type != .key) return error.DataError;
        core.key_chunk_required = false;
    }
    return core.enqueue();
}

fn flush(self: *AudioDecoder, exec: *const Execution) !js.Promise {
    return self._core.flush(true, exec);
}

fn reset(self: *AudioDecoder) !void {
    return self._core.reset();
}

fn close(self: *AudioDecoder) !void {
    return self._core.close();
}

fn isConfigSupported(config: js.Value, exec: *Execution) !js.Promise {
    return codec.isConfigSupported(Config, config, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioDecoder);

    pub const Meta = struct {
        pub const name = "AudioDecoder";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(AudioDecoder.init, .{});
    pub const state = bridge.accessor(AudioDecoder.getState, null, .{});
    pub const decodeQueueSize = bridge.accessor(AudioDecoder.getDecodeQueueSize, null, .{});
    pub const ondequeue = EventTarget.handlerAccessor(AudioDecoder, "dequeue");
    pub const configure = bridge.function(AudioDecoder.configure, .{});
    pub const decode = bridge.function(AudioDecoder.decode, .{});
    pub const flush = bridge.function(AudioDecoder.flush, .{});
    pub const reset = bridge.function(AudioDecoder.reset, .{});
    pub const close = bridge.function(AudioDecoder.close, .{});
    pub const isConfigSupported = bridge.function(AudioDecoder.isConfigSupported, .{ .static = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: codecs" {
    try testing.htmlRunner("webcodecs/codecs.html", .{});
}
