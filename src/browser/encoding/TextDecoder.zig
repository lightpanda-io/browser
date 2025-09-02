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

pub fn constructor(label_: ?[]const u8, opts_: ?Options) !TextDecoder {
    if (label_) |l| {
        _ = std.meta.stringToEnum(SupportedLabels, l) orelse {
            log.warn(.web_api, "not implemented", .{ .feature = "TextDecoder label", .label = l });
            return error.NotImplemented;
        };
    }
    const opts = opts_ orelse Options{};
    return .{
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

// TODO: Should accept an ArrayBuffer, TypedArray or DataView
// js.zig will currently only map a TypedArray to our []const u8.
pub fn _decode(self: *const TextDecoder, v: []const u8) ![]const u8 {
    if (self.fatal and !std.unicode.utf8ValidateSlice(v)) {
        return error.InvalidUtf8;
    }

    if (self.ignore_bom == false and std.mem.startsWith(u8, v, &.{ 0xEF, 0xBB, 0xBF })) {
        return v[3..];
    }

    return v;
}

const testing = @import("../../testing.zig");
test "Browser: Encoding.TextDecoder" {
    try testing.htmlRunner("encoding/decoder.html");
}
