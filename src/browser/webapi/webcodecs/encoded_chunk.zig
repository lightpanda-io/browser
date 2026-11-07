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

// EncodedAudioChunk and EncodedVideoChunk: the same interface under two names.
// https://w3c.github.io/webcodecs/#encodedaudiochunk-interface

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const common = @import("common.zig");

const Execution = js.Execution;

pub const EncodedAudioChunk = EncodedChunk("EncodedAudioChunk");
pub const EncodedVideoChunk = EncodedChunk("EncodedVideoChunk");

pub fn registerTypes() []const type {
    return &.{ EncodedAudioChunk, EncodedVideoChunk };
}

pub const Type = enum { key, delta };

fn EncodedChunk(comptime interface_name: [:0]const u8) type {
    return struct {
        const Self = @This();

        _rc: lp.RC = .{},
        _arena: *lp.Arena,
        _type: Type,
        _timestamp: i64,
        _duration: ?u64,
        _data: []const u8,

        const Init = struct {
            data: js.AllowSharedBufferSource,
            duration: ?js.EnforceRange(u64) = null,
            timestamp: js.EnforceRange(i64),
            transfer: []const js.Value = &.{},
            type: []const u8,
        };

        pub fn init(init_: Init, exec: *const Execution) !*Self {
            const chunk_type = std.meta.stringToEnum(Type, init_.type) orelse return error.TypeError;
            const timestamp = init_.timestamp.value;
            const duration = if (init_.duration) |d| d.value else null;

            const transfer: common.Transfer = .{ .buffers = init_.transfer };
            try transfer.check();

            const self = try create(chunk_type, timestamp, duration, init_.data.bytes(), exec.page);
            errdefer self.deinit(exec.page);

            try transfer.detach();
            return self;
        }

        fn create(chunk_type: Type, timestamp: i64, duration: ?u64, data: []const u8, page: *Page) !*Self {
            const arena = try page.getPinnedArena(data.len + 256, interface_name);
            errdefer arena.release();

            const self = try arena.create(Self);
            self.* = .{
                ._arena = arena,
                ._type = chunk_type,
                ._timestamp = timestamp,
                ._duration = duration,
                ._data = try arena.dupe(u8, data),
            };
            arena.report();
            return self;
        }

        pub fn deinit(self: *Self, _: *Page) void {
            self._arena.release();
        }

        pub fn acquireRef(self: *Self) void {
            self._rc.acquire();
        }

        pub fn releaseRef(self: *Self, page: *Page) void {
            self._rc.release(self, page);
        }

        pub fn bytes(self: *const Self) []const u8 {
            return self._data;
        }

        fn getType(self: *const Self) []const u8 {
            return @tagName(self._type);
        }

        fn getTimestamp(self: *const Self) i64 {
            return self._timestamp;
        }

        fn getDuration(self: *const Self) ?u64 {
            return self._duration;
        }

        fn getByteLength(self: *const Self) u32 {
            return @intCast(self._data.len);
        }

        fn copyTo(self: *const Self, destination: js.AllowSharedBufferSource) !void {
            const dest = destination.bytes();
            if (dest.len < self._data.len) {
                return error.TypeError;
            }
            @memcpy(dest[0..self._data.len], self._data);
        }

        pub fn structuredSerialize(self: *const Self, writer: *js.StructuredWriter) !void {
            writer.writeUint32(@backingInt(self._type));
            writer.writeUint64(@bitCast(self._timestamp));
            writer.writeUint32(@intFromBool(self._duration != null));
            writer.writeUint64(self._duration orelse 0);
            writer.writeBytes(self._data);
        }

        pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*Self {
            const chunk_type = std.enums.fromInt(Type, try reader.readUint32()) orelse return error.DataClone;
            const timestamp: i64 = @bitCast(try reader.readUint64());
            const has_duration = try reader.readUint32() != 0;
            const duration = try reader.readUint64();
            const data = try reader.readBytes();
            return create(chunk_type, timestamp, if (has_duration) duration else null, data, page);
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = interface_name;
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const constructor = bridge.constructor(Self.init, .{});
            pub const @"type" = bridge.accessor(Self.getType, null, .{});
            pub const timestamp = bridge.accessor(Self.getTimestamp, null, .{});
            pub const duration = bridge.accessor(Self.getDuration, null, .{});
            pub const byteLength = bridge.accessor(Self.getByteLength, null, .{});
            pub const copyTo = bridge.function(Self.copyTo, .{});
        };
    };
}

const testing = @import("../../../testing.zig");
test "WebApi: EncodedChunk" {
    try testing.htmlRunner("webcodecs/encoded_chunk.html", .{});
}
