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

// https://w3c.github.io/webcodecs/#videocolorspace

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Execution = js.Execution;

const VideoColorSpace = @This();

_rc: lp.RC = .{},
_arena: *lp.Arena,
_value: Value,

pub const Primaries = enum { bt709, bt470bg, smpte170m, bt2020, smpte432 };
pub const Transfer = enum { bt709, smpte170m, @"iec61966-2-1", linear, pq, hlg };
pub const Matrix = enum { rgb, bt709, bt470bg, smpte170m, @"bt2020-ncl" };

// Also what VideoFrame stores: it hands out a new VideoColorSpace each time.
pub const Value = struct {
    primaries: ?Primaries = null,
    transfer: ?Transfer = null,
    matrix: ?Matrix = null,
    fullRange: ?bool = null,
};

// VideoColorSpaceInit
pub const Init = struct {
    fullRange: ?bool = null,
    matrix: ?[]const u8 = null,
    primaries: ?[]const u8 = null,
    transfer: ?[]const u8 = null,

    pub fn toValue(self: Init) !Value {
        return .{
            .primaries = try parseEnum(Primaries, self.primaries),
            .transfer = try parseEnum(Transfer, self.transfer),
            .matrix = try parseEnum(Matrix, self.matrix),
            .fullRange = self.fullRange,
        };
    }
};

fn parseEnum(comptime E: type, value: ?[]const u8) !?E {
    const str = value orelse return null;
    return std.meta.stringToEnum(E, str) orelse error.TypeError;
}

fn constructor(init_: ?Init, exec: *const Execution) !*VideoColorSpace {
    const init = init_ orelse Init{};
    return create(try init.toValue(), exec.page);
}

pub fn create(value: Value, page: *Page) !*VideoColorSpace {
    const arena = try page.getPinnedArena(.tiny, "VideoColorSpace");
    errdefer arena.release();
    const self = try arena.create(VideoColorSpace);
    self.* = .{ ._arena = arena, ._value = value };
    return self;
}

pub fn deinit(self: *VideoColorSpace, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *VideoColorSpace) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *VideoColorSpace, page: *Page) void {
    self._rc.release(self, page);
}

fn enumName(value: anytype) ?[]const u8 {
    return if (value) |v| @tagName(v) else null;
}

fn getPrimaries(self: *const VideoColorSpace) ?[]const u8 {
    return enumName(self._value.primaries);
}

fn getTransfer(self: *const VideoColorSpace) ?[]const u8 {
    return enumName(self._value.transfer);
}

fn getMatrix(self: *const VideoColorSpace) ?[]const u8 {
    return enumName(self._value.matrix);
}

fn getFullRange(self: *const VideoColorSpace) ?bool {
    return self._value.fullRange;
}

const Json = struct {
    primaries: ?[]const u8,
    transfer: ?[]const u8,
    matrix: ?[]const u8,
    fullRange: ?bool,
};

fn toJSON(self: *const VideoColorSpace) Json {
    return .{
        .primaries = self.getPrimaries(),
        .transfer = self.getTransfer(),
        .matrix = self.getMatrix(),
        .fullRange = self.getFullRange(),
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(VideoColorSpace);

    pub const Meta = struct {
        pub const name = "VideoColorSpace";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(VideoColorSpace.constructor, .{});
    pub const primaries = bridge.accessor(VideoColorSpace.getPrimaries, null, .{});
    pub const transfer = bridge.accessor(VideoColorSpace.getTransfer, null, .{});
    pub const matrix = bridge.accessor(VideoColorSpace.getMatrix, null, .{});
    pub const fullRange = bridge.accessor(VideoColorSpace.getFullRange, null, .{});
    pub const toJSON = bridge.function(VideoColorSpace.toJSON, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: VideoColorSpace" {
    try testing.htmlRunner("webcodecs/video_color_space.html", .{});
}
