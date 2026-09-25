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

//! simdutf, as bundled with V8.
//!
//! Check `binding.cpp` of `zig-v8-fork` for "extern C" side of bindings.

pub const base64_options = struct {
    pub const DEFAULT = 0;
    pub const URL = 1;
    pub const DEFAULT_NO_PADDING = 2;
    pub const URL_WITH_PADDING = 3;
    pub const DEFAULT_ACCEPT_GARBAGE = 4;
    pub const URL_ACCEPT_GARBAGE = 5;
    pub const DEFAULT_OR_URL = 8;
    pub const DEFAULT_OR_URL_ACCEPT_GARBAGE = 12;
};

pub const last_chunk_handling_options = struct {
    pub const LOOSE = 0;
    pub const STRICT = 1;
    pub const STOP_BEFORE_PARTIAL = 2;
    pub const ONLY_FULL_CHUNKS = 3;
};

pub const result = extern struct {
    error_code: c_int,
    count: usize,
};

const error_code = struct {
    const SUCCESS = 0;
    const HEADER_BITS = 1;
    const TOO_SHORT = 2;
    const TOO_LONG = 3;
    const OVERLONG = 4;
    const TOO_LARGE = 5;
    const SURROGATE = 6;
    const INVALID_BASE64_CHARACTER = 7;
    const BASE64_INPUT_REMAINDER = 8;
    const BASE64_EXTRA_BITS = 9;
    const OUTPUT_BUFFER_TOO_SMALL = 10;
    const OTHER = 11;
};

pub const Error = error{
    HeaderBits,
    TooShort,
    TooLong,
    Overlong,
    TooLarge,
    Surrogate,
    InvalidBase64Character,
    Base64InputRemainder,
    Base64ExtraBits,
    OutputBufferTooSmall,
    Other,
};

pub fn getError(rc: c_int) Error!void {
    return switch (rc) {
        error_code.SUCCESS => {},
        error_code.HEADER_BITS => error.HeaderBits,
        error_code.TOO_SHORT => error.TooShort,
        error_code.TOO_LONG => error.TooLong,
        error_code.OVERLONG => error.Overlong,
        error_code.TOO_LARGE => error.TooLarge,
        error_code.SURROGATE => error.Surrogate,
        error_code.INVALID_BASE64_CHARACTER => error.InvalidBase64Character,
        error_code.BASE64_INPUT_REMAINDER => error.Base64InputRemainder,
        error_code.BASE64_EXTRA_BITS => error.Base64ExtraBits,
        error_code.OUTPUT_BUFFER_TOO_SMALL => error.OutputBufferTooSmall,
        error_code.OTHER => error.Other,
        else => unreachable,
    };
}

pub extern fn simdutf_validate_utf8(buf: [*]const u8, len: usize) bool;
pub extern fn simdutf_utf16_length_from_utf8(input: [*]const u8, length: usize) usize;
pub extern fn simdutf_maximal_binary_length_from_base64(input: [*]const u8, length: usize) usize;
pub extern fn simdutf_base64_length_from_binary(length: usize, options: c_int) usize;
pub extern fn simdutf_binary_to_base64(input: [*]const u8, length: usize, output: [*]u8, options: c_int) usize;
pub extern fn simdutf_base64_to_binary(input: [*]const u8, length: usize, output: [*]u8, options: c_int, last_chunk_options: c_int) result;

pub const Base64 = struct {
    pub inline fn calcSizeDefault(source_len: usize) usize {
        return simdutf_base64_length_from_binary(source_len, base64_options.DEFAULT);
    }

    /// Prefers default encoding.
    pub inline fn encode(dest: []u8, source: []const u8) []const u8 {
        const written = simdutf_binary_to_base64(source.ptr, source.len, dest.ptr, base64_options.DEFAULT);
        return dest[0..written];
    }

    pub inline fn calcDecodingSizeMax(source: []const u8) usize {
        return simdutf_maximal_binary_length_from_base64(source.ptr, source.len);
    }

    /// Decodes in WHATWG forgiving-base64 format.
    pub inline fn decodeForgiving(dest: []u8, source: []const u8) Error![]u8 {
        const res = simdutf_base64_to_binary(
            source.ptr,
            source.len,
            dest.ptr,
            base64_options.DEFAULT,
            last_chunk_handling_options.LOOSE,
        );
        try getError(res.error_code);
        return dest[0..res.count];
    }
};
