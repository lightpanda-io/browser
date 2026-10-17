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

pub extern fn v8__simdutf_validate_utf8(buf: [*]const u8, len: usize) bool;
pub extern fn v8__simdutf_validate_ascii(buf: [*]const u8, len: usize) bool;
pub extern fn v8__simdutf_validate_ascii_with_errors(buf: [*]const u8, len: usize) result;
pub extern fn v8__simdutf_count_utf8(input: [*]const u8, length: usize) usize;
pub extern fn v8__simdutf_utf8_length_from_latin1(input: [*]const u8, length: usize) usize;
pub extern fn v8__simdutf_utf16_length_from_utf8(input: [*]const u8, length: usize) usize;
pub extern fn v8__simdutf_convert_latin1_to_utf8(input: [*]const u8, length: usize, output: [*]u8) usize;
pub extern fn v8__simdutf_maximal_binary_length_from_base64(input: [*]const u8, length: usize) usize;
pub extern fn v8__simdutf_maximal_binary_length_from_base64_utf16(input: [*]const u16, length: usize) usize;
pub extern fn v8__simdutf_base64_to_binary(input: [*]const u8, length: usize, output: [*]u8, options: c_int, last_chunk_options: c_int) result;
pub extern fn v8__simdutf_base64_length_from_binary(length: usize, options: c_int) usize;
pub extern fn v8__simdutf_binary_to_base64(input: [*]const u8, length: usize, output: [*]u8, options: c_int) usize;
pub extern fn v8__simdutf_trim_partial_utf8(input: [*]const u8, length: usize) usize;

pub const Base64 = struct {
    pub const Type = enum(c_int) {
        default = 0,
        url = 1,
        default_no_padding = 2,
        url_with_padding = 3,
        default_accept_garbage = 4,
        url_accept_garbage = 5,
        default_or_url = 8,
        default_or_url_accept_garbage = 12,
    };

    pub const Encoder = struct {
        pub inline fn calcSize(encoder: Type, source_len: usize) usize {
            return v8__simdutf_base64_length_from_binary(source_len, @intFromEnum(encoder));
        }

        pub inline fn encode(encoder: Type, dest: []u8, source: []const u8) []const u8 {
            const written = v8__simdutf_binary_to_base64(source.ptr, source.len, dest.ptr, @intFromEnum(encoder));
            return dest[0..written];
        }
    };

    pub const Decoder = struct {
        pub inline fn calcSizeUpperBound(source: []const u8) usize {
            return v8__simdutf_maximal_binary_length_from_base64(source.ptr, source.len);
        }

        pub inline fn decode(decoder: Type, dest: []u8, source: []const u8) Error![]u8 {
            const res = v8__simdutf_base64_to_binary(
                source.ptr,
                source.len,
                dest.ptr,
                @intFromEnum(decoder),
                last_chunk_handling_options.STRICT,
            );
            try getError(res.error_code);
            return dest[0..res.count];
        }

        /// Decodes in WHATWG forgiving-base64 format.
        pub inline fn decodeForgiving(decoder: Type, dest: []u8, source: []const u8) Error![]u8 {
            const res = v8__simdutf_base64_to_binary(
                source.ptr,
                source.len,
                dest.ptr,
                @intFromEnum(decoder),
                last_chunk_handling_options.LOOSE,
            );
            try getError(res.error_code);
            return dest[0..res.count];
        }
    };
};
