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
/// hand in one pass: skip ASCII whitespace anywhere, accept up to two trailing
/// "=", tolerate trailing bits.
pub fn decode(alloc: Allocator, in: BinInput) ![]const u8 {
    const input = in.bytes();

    // Peel the trailing "=" (and the whitespace around them) off the end, so
    // the main loop only sees the alphabet and whitespace.
    var end = input.len;
    var pad: usize = 0;
    while (end > 0) : (end -= 1) {
        switch (decode_lut[input[end - 1]]) {
            ws => {},
            eq => {
                if (pad == 2) break;
                pad += 1;
            },
            else => break,
        }
    }

    const out = try alloc.alloc(u8, end / 4 * 3 + 2);
    errdefer alloc.free(out);

    var oi: usize = 0;
    var acc: u32 = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < end) {
        if (n % 4 == 0 and i + 4 <= end) {
            const a = decode_lut[input[i]];
            const b = decode_lut[input[i + 1]];
            const c = decode_lut[input[i + 2]];
            const d = decode_lut[input[i + 3]];
            if ((a | b | c | d) < 64) {
                const v = @as(u32, a) << 18 | @as(u32, b) << 12 | @as(u32, c) << 6 | d;
                out[oi] = @truncate(v >> 16);
                out[oi + 1] = @truncate(v >> 8);
                out[oi + 2] = @truncate(v);
                oi += 3;
                n += 4;
                i += 4;
                continue;
            }
        }
        const v = decode_lut[input[i]];
        i += 1;
        if (v == ws) continue;
        if (v >= 64) return error.InvalidCharacterError;
        acc = acc << 6 | v;
        n += 1;
        if (n % 4 == 0) {
            out[oi] = @truncate(acc >> 16);
            out[oi + 1] = @truncate(acc >> 8);
            out[oi + 2] = @truncate(acc);
            oi += 3;
            acc = 0;
        }
    }

    // Padding is only stripped when it completes a quantum; otherwise the "="
    // stays in the input and is invalid. A lone leftover sextet can't encode a byte.
    if (pad > 0 and (n + pad) % 4 != 0) return error.InvalidCharacterError;
    switch (n % 4) {
        0 => {},
        1 => return error.InvalidCharacterError,
        2 => {
            out[oi] = @truncate(acc >> 4);
            oi += 1;
        },
        3 => {
            out[oi] = @truncate(acc >> 10);
            out[oi + 1] = @truncate(acc >> 2);
            oi += 2;
        },
        else => unreachable,
    }
    return alloc.realloc(out, oi);
}

const ws = 0xfe;
const eq = 0xfd;
const invalid = 0xff;

const decode_lut: [256]u8 = blk: {
    var lut: [256]u8 = @splat(invalid);
    for (std.base64.standard_alphabet_chars, 0..) |c, i| lut[c] = i;
    for (" \t\n\r" ++ [_]u8{std.ascii.control_code.ff}) |c| lut[c] = ws;
    lut['='] = eq;
    break :blk lut;
};

fn testDecode(input: []const u8) ![]const u8 {
    return decode(std.testing.allocator, .{ .raw = input });
}

test "base64: forgiving decode" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "" },
        .{ " \t\n", "" },
        .{ "YQ==", "a" },
        .{ "YQ", "a" },
        .{ "YWI=", "ab" },
        .{ "YWI", "ab" },
        .{ "YWJj", "abc" },
        .{ " Y W\nJ j\r\x0c", "abc" },
        .{ "YQ= =", "a" },
        .{ "YQ==\n", "a" },
        .{ "YR", "a" },
        .{ "SGVsbG8gV29y\nbGQh", "Hello World!" },
        .{ "/P3+/w==", "\xfc\xfd\xfe\xff" },
    };
    for (cases) |case| {
        const out = try testDecode(case[0]);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualSlices(u8, case[1], out);
    }
}

test "base64: forgiving decode rejects" {
    const cases = [_][]const u8{ "Y", "YQ=", "YQ===", "YWI==", "=", "==", "Y=Q=", "YQ==YQ==", "YQ-_", "YQ\x00=", "YWJjZ" };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidCharacterError, testDecode(case));
    }
}

test "base64: decode matches std on canonical input" {
    var prng: std.Random.DefaultPrng = .init(0);
    const random = prng.random();
    var raw: [300]u8 = undefined;
    var enc: [400]u8 = undefined;
    for (0..raw.len) |len| {
        random.bytes(raw[0..len]);
        const encoded = std.base64.standard.Encoder.encode(&enc, raw[0..len]);
        const out = try testDecode(encoded);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualSlices(u8, raw[0..len], out);
    }
}
