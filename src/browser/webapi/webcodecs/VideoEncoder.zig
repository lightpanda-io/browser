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

// https://w3c.github.io/webcodecs/#videoencoder-interface

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const codec = @import("codec.zig");
const common = @import("common.zig");

const EventTarget = @import("../EventTarget.zig");
const VideoFrame = @import("VideoFrame.zig");

const Execution = js.Execution;

const VideoEncoder = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_rc: lp.RC = .{},
_arena: *lp.Arena,
_core: codec.Core(VideoEncoder),

pub const Config = struct {
    alpha: []const u8 = "discard",
    av1: ?Av1 = null,
    avc: ?Avc = null,
    bitrate: ?js.EnforceRange(u64) = null,
    bitrateMode: []const u8 = "variable",
    codec: []const u8,
    contentHint: ?[]const u8 = null,
    displayHeight: ?js.EnforceRange(u32) = null,
    displayWidth: ?js.EnforceRange(u32) = null,
    framerate: ?f64 = null,
    hardwareAcceleration: []const u8 = "no-preference",
    height: js.EnforceRange(u32),
    hevc: ?Hevc = null,
    latencyMode: []const u8 = "quality",
    scalabilityMode: ?[]const u8 = null,
    width: js.EnforceRange(u32),

    // the codec registrations' extensions
    const Av1 = struct {
        forceScreenContentTools: bool = false,
    };
    const Avc = struct {
        format: []const u8 = "avc",
    };
    const Hevc = struct {
        format: []const u8 = "hevc",
    };

    // "valid VideoEncoderConfig"
    pub fn isValid(self: Config) bool {
        if (codec.isEmptyCodec(self.codec)) return false;
        if (codec.checkEnum(self.alpha, &.{ "keep", "discard" }) == false) return false;
        if (codec.checkEnum(self.bitrateMode, &.{ "constant", "variable", "quantizer" }) == false) return false;
        if (codec.checkEnum(self.hardwareAcceleration, codec.hardware_acceleration) == false) return false;
        if (codec.checkEnum(self.latencyMode, &.{ "quality", "realtime" }) == false) return false;
        if (self.avc) |avc| {
            if (codec.checkEnum(avc.format, &.{ "annexb", "avc" }) == false) return false;
        }
        if (self.hevc) |hevc| {
            if (codec.checkEnum(hevc.format, &.{ "annexb", "hevc" }) == false) return false;
        }
        if (self.framerate) |framerate| {
            if (std.math.isFinite(framerate) == false) return false;
        }

        if (self.width.value == 0 or self.height.value == 0) return false;
        if (self.displayWidth) |w| {
            if (w.value == 0) return false;
        }
        if (self.displayHeight) |h| {
            if (h.value == 0) return false;
        }

        if (self.bitrate) |b| {
            // Not in the spec, but every engine and WPT reject it.
            if (b.value == 0) return false;
        }
        return true;
    }
};

fn init(callbacks: codec.Init, exec: *Execution) !*VideoEncoder {
    const arena = try exec.getArena(.tiny, "VideoEncoder");
    errdefer arena.release();
    return exec._factory.eventTargetWithAllocator(arena.allocator(), VideoEncoder{
        ._proto = undefined,
        ._arena = arena,
        ._core = .init(callbacks, exec),
    });
}

pub fn deinit(self: *VideoEncoder, page: *Page) void {
    self._core.deinit();
    page.removeTarget(self.asEventTarget());
    self._arena.release();
}

pub fn acquireRef(self: *VideoEncoder) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *VideoEncoder, page: *Page) void {
    self._rc.release(self, page);
}

pub fn asEventTarget(self: *VideoEncoder) *EventTarget {
    return self._proto;
}

fn getState(self: *const VideoEncoder) []const u8 {
    return self._core.getState();
}

fn getEncodeQueueSize(self: *const VideoEncoder) u32 {
    return self._core.queue_size;
}

fn configure(self: *VideoEncoder, config: Config) !void {
    if (config.isValid() == false) {
        return error.TypeError;
    }
    return self._core.configure(false);
}

const EncodeOptions = struct {
    keyFrame: bool = false,
};

fn encode(self: *VideoEncoder, frame: *VideoFrame, options: ?EncodeOptions) !void {
    _ = options;
    if (frame.isClosed()) {
        return error.TypeError;
    }
    return self._core.enqueue();
}

fn flush(self: *VideoEncoder, exec: *const Execution) !js.Promise {
    return self._core.flush(false, exec);
}

fn reset(self: *VideoEncoder) !void {
    return self._core.reset();
}

fn close(self: *VideoEncoder) !void {
    return self._core.close();
}

fn isConfigSupported(config: js.Value, exec: *Execution) !js.Promise {
    return codec.isConfigSupported(Config, config, exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(VideoEncoder);

    pub const Meta = struct {
        pub const name = "VideoEncoder";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(VideoEncoder.init, .{});
    pub const state = bridge.accessor(VideoEncoder.getState, null, .{});
    pub const encodeQueueSize = bridge.accessor(VideoEncoder.getEncodeQueueSize, null, .{});
    pub const ondequeue = EventTarget.handlerAccessor(VideoEncoder, "dequeue");
    pub const configure = bridge.function(VideoEncoder.configure, .{});
    pub const encode = bridge.function(VideoEncoder.encode, .{});
    pub const flush = bridge.function(VideoEncoder.flush, .{});
    pub const reset = bridge.function(VideoEncoder.reset, .{});
    pub const close = bridge.function(VideoEncoder.close, .{});
    pub const isConfigSupported = bridge.function(VideoEncoder.isConfigSupported, .{ .static = true });
};
