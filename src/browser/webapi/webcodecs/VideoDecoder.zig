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

// https://w3c.github.io/webcodecs/#videodecoder-interface

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const codec = @import("codec.zig");
const common = @import("common.zig");

const EventTarget = @import("../EventTarget.zig");
const VideoColorSpace = @import("VideoColorSpace.zig");
const EncodedVideoChunk = @import("encoded_chunk.zig").EncodedVideoChunk;

const Execution = js.Execution;

const VideoDecoder = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_rc: lp.RC = .{},
_arena: *lp.Arena,
_core: codec.Core(VideoDecoder),

pub const Config = struct {
    codec: []const u8,
    codedHeight: ?js.EnforceRange(u32) = null,
    codedWidth: ?js.EnforceRange(u32) = null,
    colorSpace: ?VideoColorSpace.Init = null,
    description: ?js.Value = null,
    displayAspectHeight: ?js.EnforceRange(u32) = null,
    displayAspectWidth: ?js.EnforceRange(u32) = null,
    flip: bool = false,
    hardwareAcceleration: []const u8 = "no-preference",
    optimizeForLatency: bool = false,
    rotation: f64 = 0,

    // "valid VideoDecoderConfig"
    pub fn isValid(self: Config) bool {
        if (codec.isEmptyCodec(self.codec)) return false;
        if (codec.checkEnum(self.hardwareAcceleration, codec.hardware_acceleration) == false) return false;
        if (std.math.isFinite(self.rotation) == false) return false;
        if (self.colorSpace) |cs| {
            _ = cs.toValue() catch return false;
        }
        if (pairIsInvalid(self.codedWidth, self.codedHeight)) return false;
        if (pairIsInvalid(self.displayAspectWidth, self.displayAspectHeight)) return false;
        if (self.description) |d| {
            if (codec.isDetachedBuffer(d)) return false;
        }
        return true;
    }

    // Both or neither, and neither zero.
    fn pairIsInvalid(a: ?js.EnforceRange(u32), b: ?js.EnforceRange(u32)) bool {
        const x = a orelse return b != null;
        const y = b orelse return true;
        return x.value == 0 or y.value == 0;
    }
};

fn init(callbacks: codec.Init, exec: *Execution) !*VideoDecoder {
    const arena = try exec.getArena(.tiny, "VideoDecoder");
    errdefer arena.release();
    return exec._factory.eventTargetWithAllocator(arena.allocator(), VideoDecoder{
        ._proto = undefined,
        ._arena = arena,
        ._core = .init(callbacks, exec),
    });
}

pub fn deinit(self: *VideoDecoder, page: *Page) void {
    self._core.deinit();
    page.removeTarget(self.asEventTarget());
    self._arena.release();
}

pub fn acquireRef(self: *VideoDecoder) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *VideoDecoder, page: *Page) void {
    self._rc.release(self, page);
}

pub fn asEventTarget(self: *VideoDecoder) *EventTarget {
    return self._proto;
}

fn getState(self: *const VideoDecoder) []const u8 {
    return self._core.getState();
}

fn getDecodeQueueSize(self: *const VideoDecoder) u32 {
    return self._core.queue_size;
}

fn configure(self: *VideoDecoder, config: Config) !void {
    if (config.isValid() == false) {
        return error.TypeError;
    }
    return self._core.configure(true);
}

fn decode(self: *VideoDecoder, chunk: *EncodedVideoChunk) !void {
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

fn flush(self: *VideoDecoder, exec: *const Execution) !js.Promise {
    return self._core.flush(true, exec);
}

fn reset(self: *VideoDecoder) !void {
    return self._core.reset();
}

fn close(self: *VideoDecoder) !void {
    return self._core.close();
}

fn isConfigSupported(config: js.Value, exec: *Execution) !js.Promise {
    return codec.isConfigSupported(Config, config, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(VideoDecoder);

    pub const Meta = struct {
        pub const name = "VideoDecoder";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(VideoDecoder.init, .{});
    pub const state = bridge.accessor(VideoDecoder.getState, null, .{});
    pub const decodeQueueSize = bridge.accessor(VideoDecoder.getDecodeQueueSize, null, .{});
    pub const ondequeue = EventTarget.handlerAccessor(VideoDecoder, "dequeue");
    pub const configure = bridge.function(VideoDecoder.configure, .{});
    pub const decode = bridge.function(VideoDecoder.decode, .{});
    pub const flush = bridge.function(VideoDecoder.flush, .{});
    pub const reset = bridge.function(VideoDecoder.reset, .{});
    pub const close = bridge.function(VideoDecoder.close, .{});
    pub const isConfigSupported = bridge.function(VideoDecoder.isConfigSupported, .{ .static = true });
};
