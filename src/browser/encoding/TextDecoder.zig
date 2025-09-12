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
const log = @import("../../log.zig");

const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

// https://encoding.spec.whatwg.org/#interface-textdecoder
const TextDecoder = @This();

const SupportedLabels = enum {
    utf8,
    @"utf-8",
    @"unicode-1-1-utf-8",
};

const Options = struct {
    fatal: bool = false,
    ignoreBOM: bool = false,
};

fatal: bool,
ignore_bom: bool,
stream: std.ArrayList(u8),

pub fn constructor(label_: ?[]const u8, opts_: ?Options) !TextDecoder {
    if (label_) |l| {
        _ = std.meta.stringToEnum(SupportedLabels, l) orelse {
            log.warn(.web_api, "not implemented", .{ .feature = "TextDecoder label", .label = l });
            return error.NotImplemented;
        };
    }
    const opts = opts_ orelse Options{};
    return .{
        .stream = .empty,
        .fatal = opts.fatal,
        .ignore_bom = opts.ignoreBOM,
    };
}

pub fn get_encoding(_: *const TextDecoder) []const u8 {
    return "utf-8";
}

pub fn get_ignoreBOM(self: *const TextDecoder) bool {
    return self.ignore_bom;
}

pub fn get_fatal(self: *const TextDecoder) bool {
    return self.fatal;
}

const DecodeOptions = struct {
    stream: bool = false,
};
pub fn _decode(self: *TextDecoder, input_: ?[]const u8, opts_: ?DecodeOptions, page: *Page) ![]const u8 {
    var str = input_ orelse return "";
    const opts: DecodeOptions = opts_ orelse .{};

    if (self.stream.items.len > 0) {
        try self.stream.appendSlice(page.arena, str);
        str = self.stream.items;
    }

    if (self.fatal and !std.unicode.utf8ValidateSlice(str)) {
        if (opts.stream) {
            if (self.stream.items.len == 0) {
                try self.stream.appendSlice(page.arena, str);
            }
            return "";
        }
        return error.InvalidUtf8;
    }

    self.stream.clearRetainingCapacity();
    if (self.ignore_bom == false and std.mem.startsWith(u8, str, &.{ 0xEF, 0xBB, 0xBF })) {
        return str[3..];
    }

    return str;
}

const testing = @import("../../testing.zig");
test "Browser: Encoding.TextDecoder" {
    try testing.htmlRunner("encoding/decoder.html");
}
