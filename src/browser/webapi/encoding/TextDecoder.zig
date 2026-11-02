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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const html5ever = @import("../../parser/html5ever.zig");

const TextDecoder = @This();

_rc: lp.RC = .{},
_fatal: bool,
_arena: *lp.Arena,
_ignore_bom: bool,
_bom_seen: bool,
_decoder: ?*anyopaque, // Persistent streaming decoder
_encoding_handle: *anyopaque,
_encoding_name: []const u8,
_lowercase_name: []const u8, // Cached lowercase version of encoding name

const InitOpts = struct {
    fatal: bool = false,
    ignoreBOM: bool = false,
};

/// The encoding a TextDecoder or TextDecoderStream label names: a RangeError
/// for an unknown label, and for "replacement", which can't decode.
pub fn encodingForLabel(label_: ?[]const u8) !html5ever.EncodingInfo {
    const info = html5ever.EncodingInfo.forLabel(label_ orelse "utf-8") orelse return error.RangeError;
    if (std.mem.eql(u8, info.name(), "replacement")) {
        return error.RangeError;
    }
    return info;
}

pub fn init(label_: ?[]const u8, opts_: ?InitOpts, page: *Page) !*TextDecoder {
    const info = try encodingForLabel(label_);
    const enc_name = info.name();

    // Only ever holds the decoder itself and the lazily-lowercased encoding
    // name; decode output comes from the caller's call_arena.
    const arena = try page.getArena(.tiny, "TextDecoder");
    errdefer arena.release();

    const opts = opts_ orelse InitOpts{};
    const self = try arena.create(TextDecoder);
    self.* = .{
        ._arena = arena,
        ._fatal = opts.fatal,
        ._ignore_bom = opts.ignoreBOM,
        ._encoding_handle = info.handle.?,
        ._decoder = null,
        ._bom_seen = false,
        ._lowercase_name = "", // Will be lazily allocated
        ._encoding_name = enc_name, // Points to static Rust memory
    };
    return self;
}

pub fn deinit(self: *TextDecoder, _: *Page) void {
    if (self._decoder) |decoder| {
        html5ever.encoding_decoder_free(decoder);
    }
    self._arena.release();
}

pub fn releaseRef(self: *TextDecoder, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *TextDecoder) void {
    self._rc.acquire();
}

fn getIgnoreBOM(self: *const TextDecoder) bool {
    return self._ignore_bom;
}

fn getFatal(self: *const TextDecoder) bool {
    return self._fatal;
}

fn getEncoding(self: *TextDecoder) ![]const u8 {
    // Spec requires lowercase encoding name
    // Allocate buffer for lowercase name on first access
    if (self._lowercase_name.len > 0) {
        return self._lowercase_name;
    }
    self._lowercase_name = try std.ascii.allocLowerString(self._arena.allocator(), self._encoding_name);
    return self._lowercase_name;
}

const DecodeOpts = struct {
    stream: bool = false,
};

pub fn decode(self: *TextDecoder, input_: ?js.AllowSharedBufferSource, opts_: ?DecodeOpts, exec: *const js.Execution) ![]const u8 {
    const opts: DecodeOpts = opts_ orelse .{};
    const input: []const u8 = if (input_) |i| i.bytes() else "";

    if (opts.stream) {
        // Streaming mode: create decoder if needed, keep it alive
        if (self._decoder == null) {
            self._decoder = html5ever.encoding_decoder_new(self._encoding_handle);
            if (self._decoder == null) {
                return error.OutOfMemory;
            }
        }
        return self._decode(exec.call_arena, input, self._decoder.?, false);
    }

    // Non-streaming: flush the decoder from earlier streaming calls (or a new
    // one) with is_last=true, then free it. On error, _decode frees it.
    const decoder = self._decoder orelse html5ever.encoding_decoder_new(self._encoding_handle) orelse return error.OutOfMemory;
    self._decoder = decoder;
    const result = try self._decode(exec.call_arena, input, decoder, true);
    html5ever.encoding_decoder_free(decoder);
    self._decoder = null;
    self._bom_seen = false;
    return result;
}

fn _decode(self: *TextDecoder, arena: std.mem.Allocator, input: []const u8, decoder: *anyopaque, is_last: bool) ![]const u8 {
    return decodeChunk(arena, .{
        .encoding_name = self._encoding_name,
        .fatal = self._fatal,
        .ignore_bom = self._ignore_bom,
        .bom_seen = &self._bom_seen,
    }, decoder, input, is_last) catch |err| {
        if (err == error.TypeError) {
            // Reset decoder on error
            html5ever.encoding_decoder_free(decoder);
            self._decoder = null;
            self._bom_seen = false;
        }
        return err;
    };
}

pub const ChunkOpts = struct {
    encoding_name: []const u8,
    fatal: bool,
    ignore_bom: bool,
    // Whether output has come out yet, for the BOM.
    bom_seen: *bool,
};

/// Decodes `input` with the streaming `decoder` into `arena`, as TextDecoder
/// and TextDecoderStream do. A decoding error in fatal mode is a TypeError.
pub fn decodeChunk(arena: std.mem.Allocator, opts: ChunkOpts, decoder: *anyopaque, input: []const u8, is_last: bool) ![]const u8 {
    if (input.len == 0 and !is_last) {
        return "";
    }

    // Counts the bytes the decoder holds from earlier input too.
    const max_out = html5ever.encoding_decoder_max_utf8_buffer_length(decoder, input.len);

    if (max_out == 0) {
        return "";
    }

    // Allocate output buffer
    const output = try arena.alloc(u8, max_out);

    const result = html5ever.encoding_decoder_decode(
        decoder,
        input.ptr,
        input.len,
        output.ptr,
        output.len,
        @intFromBool(is_last),
    );

    if (opts.fatal and result.hadErrors()) {
        return error.TypeError;
    }

    var decoded: []const u8 = output[0..result.bytes_written];

    // The decoder does no BOM sniffing, so a BOM of this encoding is a
    // leading U+FEFF in the first output; other bytes stay as decoded.
    // Only UTF-8 and UTF-16 have a BOM: in gb18030, U+FEFF is a character.
    if (!opts.bom_seen.* and decoded.len > 0) {
        if (opts.ignore_bom == false and hasBom(opts.encoding_name)) {
            decoded = stripBom(decoded);
        }
        opts.bom_seen.* = true;
    }

    return decoded;
}

fn hasBom(encoding_name: []const u8) bool {
    return std.mem.eql(u8, encoding_name, "UTF-8") or
        std.mem.eql(u8, encoding_name, "UTF-16LE") or
        std.mem.eql(u8, encoding_name, "UTF-16BE");
}

fn stripBom(data: []const u8) []const u8 {
    // UTF-8 BOM in decoded output appears as U+FEFF (EF BB BF in UTF-8)
    const bom = "\u{FEFF}";
    if (std.mem.startsWith(u8, data, bom)) {
        return data[bom.len..];
    }
    return data;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextDecoder);

    pub const Meta = struct {
        pub const name = "TextDecoder";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TextDecoder.init, .{});
    pub const decode = bridge.function(TextDecoder.decode, .{});
    pub const encoding = bridge.accessor(TextDecoder.getEncoding, null, .{});
    pub const fatal = bridge.accessor(TextDecoder.getFatal, null, .{});
    pub const ignoreBOM = bridge.accessor(TextDecoder.getIgnoreBOM, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextDecoder" {
    try testing.htmlRunner("encoding/text_decoder.html", .{});
}
