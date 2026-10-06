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

//! brotli utilities.

pub const BROTLI_BOOL = c_int;
pub const BROTLI_TRUE: BROTLI_BOOL = 1;
pub const BROTLI_FALSE: BROTLI_BOOL = 0;

/// Passing null for both alloc_func and free_func makes brotli use malloc/free.
const brotli_alloc_func = ?*const fn (@"opaque": ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
const brotli_free_func = ?*const fn (@"opaque": ?*anyopaque, address: ?*anyopaque) callconv(.c) void;

// Encoder.

pub const BrotliEncoderState = opaque {};

pub const BrotliEncoderOperation = enum(c_int) {
    process = 0,
    flush = 1,
    finish = 2,
    emit_metadata = 3,
};

pub const BrotliEncoderParameter = enum(c_int) {
    mode = 0,
    quality = 1,
    lgwin = 2,
    lgblock = 3,
    disable_literal_context_modeling = 4,
    size_hint = 5,
    large_window = 6,
    npostfix = 7,
    ndirect = 8,
    stream_offset = 9,
};

pub extern fn BrotliEncoderCreateInstance(alloc_func: brotli_alloc_func, free_func: brotli_free_func, @"opaque": ?*anyopaque) ?*BrotliEncoderState;
pub extern fn BrotliEncoderSetParameter(state: *BrotliEncoderState, param: BrotliEncoderParameter, value: u32) BROTLI_BOOL;
pub extern fn BrotliEncoderCompressStream(state: *BrotliEncoderState, op: BrotliEncoderOperation, available_in: *usize, next_in: *[*c]const u8, available_out: *usize, next_out: ?*[*c]u8, total_out: ?*usize) BROTLI_BOOL;
pub extern fn BrotliEncoderIsFinished(state: *BrotliEncoderState) BROTLI_BOOL;
pub extern fn BrotliEncoderHasMoreOutput(state: *BrotliEncoderState) BROTLI_BOOL;
pub extern fn BrotliEncoderDestroyInstance(state: *BrotliEncoderState) void;
pub extern fn BrotliEncoderTakeOutput(state: *BrotliEncoderState, size: *usize) [*c]const u8;

// Decoder.

pub const BrotliDecoderState = opaque {};

pub const BrotliDecoderResult = enum(c_int) {
    @"error" = 0,
    success = 1,
    needs_more_input = 2,
    needs_more_output = 3,
};

pub extern fn BrotliDecoderCreateInstance(alloc_func: brotli_alloc_func, free_func: brotli_free_func, @"opaque": ?*anyopaque) ?*BrotliDecoderState;
pub extern fn BrotliDecoderDecompressStream(state: *BrotliDecoderState, available_in: *usize, next_in: *[*c]const u8, available_out: *usize, next_out: ?*[*c]u8, total_out: ?*usize) BrotliDecoderResult;
pub extern fn BrotliDecoderHasMoreOutput(state: *const BrotliDecoderState) BROTLI_BOOL;
pub extern fn BrotliDecoderDestroyInstance(state: *BrotliDecoderState) void;
pub extern fn BrotliDecoderTakeOutput(state: *BrotliDecoderState, size: *usize) [*c]const u8;
