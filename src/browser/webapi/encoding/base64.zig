// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

//! Pure-byte base64 helpers for btoa/atob. The "binary string" semantics
//! (each JS code unit 0..255 = one byte) are handled at the JS boundary in
//! Window.atob / Window.btoa via the one-byte string APIs — this module
//! just deals in bytes.

const std = @import("std");
const js = @import("../../js/js.zig");

const Base64 = @import("../../../sys/simdutf.zig").Base64;

const Allocator = std.mem.Allocator;

pub const BinInput = union(enum) {
    // order matters
    js_string: js.String.OneByte,
    raw: []const u8,

    fn bytes(self: BinInput) []const u8 {
        return switch (self) {
            .js_string => |v| v.bytes,
            .raw => |v| v,
        };
    }
};

pub fn encode(allocator: Allocator, in: BinInput) ![]const u8 {
    const input = in.bytes();
    const encoded_len = Base64.calcSizeDefault(input.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    return Base64.encode(encoded, input);
}

pub fn decode(alloc: Allocator, in: BinInput) ![]const u8 {
    const input = in.bytes();
    const decoded_len = Base64.calcDecodingSizeMax(input);
    const output = try alloc.alloc(u8, decoded_len);
    return Base64.decodeForgiving(output, input) catch |err| switch (err) {
        // Translate to DOM errors.
        error.InvalidBase64Character, error.Base64InputRemainder => error.InvalidCharacterError,
        else => unreachable,
    };
}
