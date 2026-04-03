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

//! Base64 encoding/decoding helpers for btoa/atob.
//! Used by both Window and WorkerGlobalScope.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Encodes input to base64 (btoa).
pub fn encode(alloc: Allocator, input: []const u8) ![]const u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(input.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    return std.base64.standard.Encoder.encode(encoded, input);
}

/// Decodes base64 input (atob).
/// Implements forgiving base64 decode per WHATWG spec.
pub fn decode(alloc: Allocator, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    // Forgiving base64 decode per WHATWG spec:
    // https://infra.spec.whatwg.org/#forgiving-base64-decode
    // Remove trailing padding to use standard_no_pad decoder
    const unpadded = std.mem.trimRight(u8, trimmed, "=");

    // Length % 4 == 1 is invalid (can't represent valid base64)
    if (unpadded.len % 4 == 1) {
        return error.InvalidCharacterError;
    }

    const decoded_len = std.base64.standard_no_pad.Decoder.calcSizeForSlice(unpadded) catch return error.InvalidCharacterError;
    const decoded = try alloc.alloc(u8, decoded_len);
    std.base64.standard_no_pad.Decoder.decode(decoded, unpadded) catch return error.InvalidCharacterError;
    return decoded;
}
