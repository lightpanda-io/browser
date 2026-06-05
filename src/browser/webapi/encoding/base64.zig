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

//! Pure-byte base64 helpers for btoa/atob. The "binary string" semantics
//! (each JS code unit 0..255 = one byte) are handled at the JS boundary in
//! Window.atob / Window.btoa via the one-byte string APIs — this module
//! just deals in bytes.

const std = @import("std");
const js = @import("../../js/js.zig");

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

pub fn encode(alloc: Allocator, in: BinInput) ![]const u8 {
    const input = in.bytes();
    const encoded_len = std.base64.standard.Encoder.calcSize(input.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    return std.base64.standard.Encoder.encode(encoded, input);
}

/// Forgiving base64 decode per WHATWG spec:
/// https://infra.spec.whatwg.org/#forgiving-base64-decode
///
/// std's decoders reject non-canonical trailing bits (e.g. "ab") and only trim
/// padding from the ends, neither of which match forgiving-base64 — so decode by
/// hand: strip *all* ASCII whitespace, validate padding, tolerate trailing bits.
pub fn decode(alloc: Allocator, in: BinInput) ![]const u8 {
    const input = in.bytes();

    // Step 1: remove all ASCII whitespace (tab, LF, FF, CR, space) from anywhere.
    const buf = try alloc.alloc(u8, input.len);
    var n: usize = 0;
    for (input) |c| switch (c) {
        ' ', '\t', '\n', '\r', std.ascii.control_code.ff => {},
        else => {
            buf[n] = c;
            n += 1;
        },
    };
    var src = buf[0..n];

    // Step 2: only a multiple-of-4 length may carry (and shed) up to two "=".
    if (src.len % 4 == 0) {
        if (std.mem.endsWith(u8, src, "==")) {
            src = src[0 .. src.len - 2];
        } else if (std.mem.endsWith(u8, src, "=")) {
            src = src[0 .. src.len - 1];
        }
    }
    // Step 3: a length % 4 == 1 can't represent valid base64.
    if (src.len % 4 == 1) return error.InvalidCharacterError;
    // Any "=" still present is misplaced padding.
    if (std.mem.indexOfScalar(u8, src, '=') != null) return error.InvalidCharacterError;

    const out_len = src.len / 4 * 3 + switch (src.len % 4) {
        0 => @as(usize, 0),
        2 => 1,
        3 => 2,
        else => unreachable,
    };
    const out = try alloc.alloc(u8, out_len);

    var oi: usize = 0;
    var i: usize = 0;
    while (i + 4 <= src.len) : (i += 4) {
        const a = try b64Val(src[i]);
        const b = try b64Val(src[i + 1]);
        const c = try b64Val(src[i + 2]);
        const d = try b64Val(src[i + 3]);
        out[oi] = (a << 2) | (b >> 4);
        out[oi + 1] = (b << 4) | (c >> 2);
        out[oi + 2] = (c << 6) | d;
        oi += 3;
    }
    switch (src.len - i) {
        0 => {},
        2 => {
            const a = try b64Val(src[i]);
            const b = try b64Val(src[i + 1]);
            out[oi] = (a << 2) | (b >> 4);
        },
        3 => {
            const a = try b64Val(src[i]);
            const b = try b64Val(src[i + 1]);
            const c = try b64Val(src[i + 2]);
            out[oi] = (a << 2) | (b >> 4);
            out[oi + 1] = (b << 4) | (c >> 2);
        },
        else => unreachable,
    }
    return out;
}

fn b64Val(c: u8) !u8 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => error.InvalidCharacterError,
    };
}
