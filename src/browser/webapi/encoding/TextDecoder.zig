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
const html5ever = @import("../../parser/html5ever.zig");

const Session = @import("../../Session.zig");
const Allocator = std.mem.Allocator;

const TextDecoder = @This();

_rc: lp.RC(u8) = .{},
_fatal: bool,
_arena: Allocator,
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

pub fn init(label_: ?[]const u8, opts_: ?InitOpts, session: *Session) !*TextDecoder {
    const label = label_ orelse "utf-8";

    const info = html5ever.encoding_for_label(label.ptr, label.len);
    if (!info.isValid()) {
        return error.RangeError;
    }

    // Check for "replacement" encoding - it's not usable for decoding per spec
    const enc_name = info.name();
    if (std.mem.eql(u8, enc_name, "replacement")) {
        return error.RangeError;
    }

    const arena = try session.getArena(.large, "TextDecoder");
    errdefer session.releaseArena(arena);

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

pub fn deinit(self: *TextDecoder, session: *Session) void {
    if (self._decoder) |decoder| {
        html5ever.encoding_decoder_free(decoder);
    }
    session.releaseArena(self._arena);
}

pub fn releaseRef(self: *TextDecoder, session: *Session) void {
    self._rc.release(self, session);
}

pub fn acquireRef(self: *TextDecoder) void {
    self._rc.acquire();
}

pub fn getIgnoreBOM(self: *const TextDecoder) bool {
    return self._ignore_bom;
}

pub fn getFatal(self: *const TextDecoder) bool {
    return self._fatal;
}

pub fn getEncoding(self: *TextDecoder) ![]const u8 {
    // Spec requires lowercase encoding name
    // Allocate buffer for lowercase name on first access
    if (self._lowercase_name.len > 0) {
        return self._lowercase_name;
    }
    self._lowercase_name = try std.ascii.allocLowerString(self._arena, self._encoding_name);
    return self._lowercase_name;
}

const DecodeOpts = struct {
    stream: bool = false,
};

pub fn decode(self: *TextDecoder, input_: ?[]const u8, opts_: ?DecodeOpts) ![]const u8 {
    const opts: DecodeOpts = opts_ orelse .{};
    const input = input_ orelse "";

    if (opts.stream) {
        // Streaming mode: create decoder if needed, keep it alive
        if (self._decoder == null) {
            self._decoder = html5ever.encoding_decoder_new(self._encoding_handle);
            if (self._decoder == null) {
                return error.OutOfMemory;
            }
        }
        return self._decode(input, self._decoder, false);
    }

    if (self._decoder) |decoder| {
        // Non-streaming with existing decoder: flush with is_last=true, then free
        const result = try self._decode(input, decoder, true);

        // on error, _decode will free the decoder. So we only free it on non-error
        html5ever.encoding_decoder_free(decoder);
        self._decoder = null;
        return result;
    }

    // non-streaming, no existing decoder
    return self._decode(input, null, true);
}

fn _decode(self: *TextDecoder, input: []const u8, streaming_decoder: ?*anyopaque, is_last: bool) ![]const u8 {
    if (input.len == 0 and !is_last) {
        return "";
    }

    // Calculate max output size (add extra for potential buffered bytes when finishing)
    const max_out = html5ever.encoding_max_utf8_buffer_length(
        self._encoding_handle,
        if (input.len == 0) 4 else input.len,
    );

    if (max_out == 0) {
        return "";
    }

    // Allocate output buffer
    const output = try self._arena.alloc(u8, max_out);

    // Decode using either streaming or one-shot decoder
    const result = if (streaming_decoder) |decoder|
        html5ever.encoding_decoder_decode(
            decoder,
            input.ptr,
            input.len,
            output.ptr,
            output.len,
            @intFromBool(is_last),
        )
    else
        html5ever.encoding_decode(
            self._encoding_handle,
            input.ptr,
            input.len,
            output.ptr,
            output.len,
            1, // is_last = true for one-shot
        );

    // Handle errors in fatal mode
    if (self._fatal and result.hadErrors()) {
        if (streaming_decoder != null) {
            // Reset decoder on error
            if (self._decoder) |decoder| {
                html5ever.encoding_decoder_free(decoder);
                self._decoder = null;
            }
        }
        self._bom_seen = false;
        return error.TypeError;
    }

    var decoded: []const u8 = output[0..result.bytes_written];

    // Handle BOM stripping
    if (!self._bom_seen and !self._ignore_bom) {
        decoded = stripBom(decoded);
        self._bom_seen = true;
    }

    return decoded;
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
        pub const prototype_chain = bridge.prototypeChain();
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
