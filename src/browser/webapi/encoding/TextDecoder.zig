// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const std = @import("std");
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Allocator = std.mem.Allocator;

const TextDecoder = @This();

_fatal: bool,
_arena: Allocator,
_ignore_bom: bool,
_stream: std.ArrayList(u8),

const Label = enum {
    utf8,
    @"utf-8",
    @"unicode-1-1-utf-8",
};

const InitOpts = struct {
    fatal: bool = false,
    ignoreBOM: bool = false,
};

pub fn init(label_: ?[]const u8, opts_: ?InitOpts, page: *Page) !*TextDecoder {
    if (label_) |label| {
        _ = std.meta.stringToEnum(Label, label) orelse return error.RangeError;
    }

    const arena = try page.getArena(.{ .debug = "TextDecoder" });
    errdefer page.releaseArena(arena);

    const opts = opts_ orelse InitOpts{};
    const self = try arena.create(TextDecoder);
    self.* = .{
        ._arena = arena,
        ._stream = .empty,
        ._fatal = opts.fatal,
        ._ignore_bom = opts.ignoreBOM,
    };
    return self;
}

pub fn deinit(self: *TextDecoder, _: bool, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn getIgnoreBOM(self: *const TextDecoder) bool {
    return self._ignore_bom;
}

pub fn getFatal(self: *const TextDecoder) bool {
    return self._fatal;
}

const DecodeOpts = struct {
    stream: bool = false,
};
pub fn decode(self: *TextDecoder, input_: ?[]const u8, opts_: ?DecodeOpts) ![]const u8 {
    var input = input_ orelse return "";
    const opts: DecodeOpts = opts_ orelse .{};

    if (self._stream.items.len > 0) {
        try self._stream.appendSlice(self._arena, input);
        input = self._stream.items;
    }

    if (self._fatal and !std.unicode.utf8ValidateSlice(input)) {
        if (opts.stream) {
            if (self._stream.items.len == 0) {
                try self._stream.appendSlice(self._arena, input);
            }
            return "";
        }
        return error.InvalidUtf8;
    }

    self._stream.clearRetainingCapacity();
    if (self._ignore_bom == false and std.mem.startsWith(u8, input, &.{ 0xEF, 0xBB, 0xBF })) {
        return input[3..];
    }

    return input;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextDecoder);

    pub const Meta = struct {
        pub const name = "TextDecoder";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(TextDecoder.deinit);
    };

    pub const constructor = bridge.constructor(TextDecoder.init, .{});
    pub const decode = bridge.function(TextDecoder.decode, .{});
    pub const encoding = bridge.property("utf-8", .{ .template = false });
    pub const fatal = bridge.accessor(TextDecoder.getFatal, null, .{});
    pub const ignoreBOM = bridge.accessor(TextDecoder.getIgnoreBOM, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextDecoder" {
    try testing.htmlRunner("encoding/text_decoder.html", .{});
}
