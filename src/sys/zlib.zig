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

//! zlib utilities.

const Byte = u8;
pub const uInt = c_uint;
const uLong = c_ulong;
const Bytef = Byte;
const voidpc = ?*const anyopaque;
const voidpf = ?*anyopaque;
const voidp = ?*anyopaque;

pub const MAX_WBITS = @as(c_int, 15);

pub const Z_OK = @as(c_int, 0);
pub const Z_STREAM_END = @as(c_int, 1);
pub const Z_NEED_DICT = @as(c_int, 2);
pub const Z_STREAM_ERROR = -@as(c_int, 2);
pub const Z_DATA_ERROR = -@as(c_int, 3);
pub const Z_MEM_ERROR = -@as(c_int, 4);
pub const Z_BUF_ERROR = -@as(c_int, 5);
pub const Z_VERSION_ERROR = -@as(c_int, 6);
pub const Z_NO_FLUSH = @as(c_int, 0);
pub const Z_FINISH = @as(c_int, 4);
pub const Z_DEFAULT_STRATEGY = @as(c_int, 0);
pub const Z_DEFLATED = @as(c_int, 8);

const alloc_func = ?*const fn (@"opaque": voidpf, items: uInt, size: uInt) callconv(.c) voidpf;
const free_func = ?*const fn (@"opaque": voidpf, address: voidpf) callconv(.c) void;

const internal_state = opaque {};
/// Zero-initialized; though its not indicated that if its necessary or not.
pub const z_stream = extern struct {
    next_in: [*c]Bytef = null,
    avail_in: uInt = 0,
    total_in: uLong = 0,
    next_out: [*c]Bytef = null,
    avail_out: uInt = 0,
    total_out: uLong = 0,
    msg: [*c]u8 = null,
    state: ?*internal_state = null,
    zalloc: alloc_func = null,
    zfree: free_func = null,
    @"opaque": voidpf = null, // userdata.
    data_type: c_int = 0,
    adler: uLong = 0,
    reserved: uLong = 0,
};

pub extern fn zlibVersion() [*:0]const u8;
pub extern fn deflateInit2_(strm: *z_stream, level: c_int, method: c_int, windowBits: c_int, memLevel: c_int, strategy: c_int, version: [*c]const u8, stream_size: c_int) c_int;
pub extern fn inflateInit2_(strm: *z_stream, windowBits: c_int, version: [*c]const u8, stream_size: c_int) c_int;
pub extern fn deflate(strm: *z_stream, flush: c_int) c_int;
pub extern fn deflateEnd(strm: *z_stream) c_int;
pub extern fn inflate(strm: *z_stream, flush: c_int) c_int;
pub extern fn inflateEnd(strm: *z_stream) c_int;
