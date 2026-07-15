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

//! We have multiple places that are in need of same parsing requirements
//! with same efficiency. This file tries to unite them under here.

const std = @import("std");
const builtin = @import("builtin");

/// Block size of the CPU.
const block_size = @sizeOf(usize);

const header_key_map = [256]u1{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0-15
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 16-31
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 32-47
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, // 48-63
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 64-79
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 80-95
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 96-111
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, // 112-127
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 128-143
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 144-159
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 160-175
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 176-191
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 192-207
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 208-223
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 224-239
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 240-255
};

const header_value_map = [256]u1{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0-15
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 16-31
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 32-47
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 48-63
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 64-79
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 80-95
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 96-111
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, // 112-127
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 128-143
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 144-159
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 160-175
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 176-191
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 192-207
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 208-223
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 224-239
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 240-255
};

/// Returns an integer filled with a given byte.
inline fn broadcast(comptime T: type, byte: u8) T {
    comptime {
        const bits = @ctz(@as(T, 0));
        const b = @as(T, byte);
        return switch (bits) {
            8 => b * 0x01,
            16 => b * 0x01_01,
            32 => b * 0x01_01_01_01,
            64 => b * 0x01_01_01_01_01_01_01_01,
            else => @compileError("unexpected broadcast size"),
        };
    }
}

/// Returns how much to move forward for the end of header key; the byte at
/// the returned index is either an invalid one or the `:` delimiter. If the
/// returned index is equal to `bytes.len`, the buffer has been consumed fully.
/// Force this to inline, there's merely a single call-site for it.
inline fn matchHeaderKey(bytes: []const u8) usize {
    // How much we've moved forward.
    var i: usize = 0;

    const use_vectors = if (std.simd.suggestVectorLength(u8)) |recommended|
        recommended >= 16
    else
        false;

    if (comptime use_vectors) {
        // Pick a good default for relatively small strings.
        const vec_size = 16;
        const Vec = @Vector(vec_size, u8);
        const Int = std.meta.Int(.unsigned, vec_size);

        while (bytes.len - i >= vec_size) {
            const spaces: Vec = @splat(' ');
            const colons: Vec = @splat(':');
            const deletes: Vec = @splat(0x7f);
            const chunk: Vec = bytes[i..][0..vec_size].*;

            const bits = @intFromBool(chunk > spaces) & ~(@intFromBool(chunk == colons) | @intFromBool(chunk == deletes));
            // How much to move forward.
            const advance_by = @ctz(~@as(Int, @bitCast(bits)));
            i += advance_by;
            // Found one of the characters we'd like to have.
            if (advance_by != vec_size) {
                return i;
            }
        }
    }

    // NOTE: SWAR is not preferred here, this might change in the future
    // but honestly header keys are not so large.

    // Fallback for len < sse_vec_size.
    while (i < bytes.len) : (i += 1) {
        if (header_key_map[bytes[i]] == 0) {
            return i;
        }
    }

    return i;
}

/// Returns how much to move forward for the end of header value; the byte at
/// the returned index is either an invalid one or a line ending. If the
/// returned index is equal to `bytes.len`, the buffer has been consumed fully.
/// Force this to inline, there's merely a single call-site for it.
inline fn matchHeaderValue(bytes: []const u8) usize {
    // How much we've moved forward.
    var i: usize = 0;

    const maybe_vec_size: ?usize = comptime blk: {
        if (std.simd.suggestVectorLength(u8)) |recommended| {
            break :blk if (recommended >= 64) 32 else recommended;
        }
        break :blk null;
    };

    // Unlike header keys, prefer larger vectors initially when validating
    // header values if possible.
    if (comptime maybe_vec_size) |vec_size| {
        const Vec = @Vector(vec_size, u8);
        const Int = std.meta.Int(.unsigned, vec_size);

        while (bytes.len - i >= vec_size) {
            // Fill a vector with DEL (127).
            const deletes: Vec = @splat(0x7f);
            // Fill a vector with US (31).
            const full_31: Vec = @splat(0x1f);
            // Load the next chunk from the buffer.
            const chunk: Vec = bytes[i..][0..vec_size].*;

            const bits = @intFromBool(chunk > full_31) & ~@intFromBool(chunk == deletes);
            const advance_by = @ctz(~@as(Int, @bitCast(bits)));
            i += advance_by;

            if (advance_by != vec_size) {
                return i;
            }
        }
    }

    // SWAR path.
    while (bytes.len - i >= block_size) {
        const spaces = comptime broadcast(usize, ' ');
        const ones = comptime broadcast(usize, 0x01);
        const dels = comptime broadcast(usize, 0x7f);
        const full_128 = comptime broadcast(usize, 128);
        const chunk: usize = @bitCast(bytes[i..][0..block_size].*);

        // When a byte is less than a space (32), subtraction will wrap around
        // and set the high bit; the AND NOT makes sure only bytes below 128
        // can report so.
        const lt = (chunk -% spaces) & ~chunk;
        const xor_dels = chunk ^ dels;
        const eq_del = (xor_dels -% ones) & ~xor_dels;
        const advance_by = @ctz((lt | eq_del) & full_128) >> 3;
        i += advance_by;

        if (advance_by != block_size) {
            return i;
        }
    }

    // Fallback for len < block_size.
    while (i < bytes.len) : (i += 1) {
        if (header_value_map[bytes[i]] == 0) {
            return i;
        }
    }

    return i;
}

/// Represents a single HTTP header.
pub const HttpHeader = struct {
    key: []const u8,
    value: []const u8,
};

pub const ParseHttpHeaderError = error{ Incomplete, Invalid };

/// Parses a single HTTP header out of given buffer and returns how many bytes
/// are consumed, including the line ending. The buffer MAY or MAY NOT have a
/// line ending; in case it doesn't exist, `error.Incomplete` is returned.
/// Which allows streaming (or push-style) usage of this function.
pub fn parseHttpHeader(bytes: []const u8, header: *HttpHeader) ParseHttpHeaderError!usize {
    var cursor = bytes;

    const key_end = matchHeaderKey(cursor);
    // Buffer has been consumed fully without a delimiter; the caller can read
    // more data and try to parse again.
    if (key_end == cursor.len) {
        return error.Incomplete;
    }

    // Make sure we're at colon.
    switch (cursor[key_end]) {
        ':' => {
            @branchHint(.likely);
            // 0 length headers are invalid.
            if (key_end == 0) {
                return error.Invalid;
            }
        },
        // Invalid character, so a malformed header. Can't go further.
        else => return error.Invalid,
    }

    // Found header key.
    const key = cursor[0..key_end];
    // Skip the key and the colon.
    cursor = cursor[key_end + 1 ..];

    // Skip leading whitespaces.
    while (cursor.len > 0 and cursor[0] == ' ') : (cursor = cursor[1..]) {}

    // We're at where header value starts; find where it ends.
    const value_end = matchHeaderValue(cursor);
    // Buffer has been consumed fully without a line ending; the caller can
    // read more data and try to parse again.
    if (value_end == cursor.len) {
        return error.Incomplete;
    }

    // Found header value.
    const value = cursor[0..value_end];

    // Both `\n` and `\r\n` indicate the end of the value part.
    switch (cursor[value_end]) {
        '\n' => cursor = cursor[value_end + 1 ..],
        '\r' => {
            // We need a `\n` character too.
            if (value_end + 1 == cursor.len) {
                return error.Incomplete;
            }
            if (cursor[value_end + 1] != '\n') {
                @branchHint(.unlikely);
                return error.Invalid;
            }

            cursor = cursor[value_end + 2 ..];
        },
        // Any other character is invalid.
        else => return error.Invalid,
    }

    // Header is set.
    header.* = .{ .key = key, .value = value };

    // Return the total consumed length to caller.
    return bytes.len - cursor.len;
}

/// Parses HTTP headers out of given buffer until the terminating empty line
/// (exclusive `\n` or `\r\n`), which is required; if the buffer ends before
/// it, `error.Incomplete` is returned. Returns how many bytes are consumed,
/// including the terminating line ending; `count` receives how many headers
/// are parsed. If the provided `headers` length is not sufficient,
/// `error.Invalid` is returned.
pub fn parseHttpHeaders(bytes: []const u8, headers: []HttpHeader, count: *usize) ParseHttpHeaderError!usize {
    var cursor = bytes;

    var i: usize = 0;
    while (true) {
        // The terminating empty line is required; the caller can read more
        // data and try to parse again.
        if (cursor.len == 0) {
            return error.Incomplete;
        }

        // Check if headers part has finished.
        switch (cursor[0]) {
            '\n' => {
                // End of headers.
                cursor = cursor[1..];
                break;
            },
            '\r' => {
                // We need a `\n` character too.
                if (cursor.len < 2) {
                    return error.Incomplete;
                }
                if (cursor[1] != '\n') {
                    return error.Invalid;
                }

                // End of headers.
                cursor = cursor[2..];
                break;
            },
            else => {},
        }

        // Not enough space in `headers`.
        // NOTE: Currently interpreted as `error.Invalid`, this might change in the future.
        if (i == headers.len) {
            return error.Invalid;
        }

        const consumed = try parseHttpHeader(cursor, &headers[i]);
        cursor = cursor[consumed..];
        i += 1;
    }

    // Set the count of parsed headers.
    count.* = i;

    // Return the total consumed length to caller.
    return bytes.len - cursor.len;
}

pub const Disposition = struct {
    name: ?[]const u8 = null,
    filename: ?[]const u8 = null,
};

// Parses a part's Content-Disposition value: `form-data` followed by
// `; key="value"` params. Values are quoted-strings whose CR/LF/" were
// percent-escaped by the encoder (writeMultipartName), so the next raw '"'
// always closes the value; a raw ';' inside quotes is legal and preserved.
pub fn parseDisposition(value: []const u8) !Disposition {
    var rest = std.mem.trim(u8, value, " \t");
    if (!std.ascii.startsWithIgnoreCase(rest, "form-data")) {
        return error.InvalidFormData;
    }
    rest = rest["form-data".len..];

    var disposition = Disposition{};
    while (true) {
        rest = std.mem.trimLeft(u8, rest, " \t");
        if (rest.len == 0) {
            return disposition;
        }
        if (rest[0] != ';') {
            return error.InvalidFormData;
        }
        rest = std.mem.trimLeft(u8, rest[1..], " \t");

        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.InvalidFormData;
        const key = rest[0..eq];
        rest = rest[eq + 1 ..];
        if (rest.len == 0 or rest[0] != '"') {
            return error.InvalidFormData;
        }
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.InvalidFormData;
        const param_value = rest[1..end];
        rest = rest[end + 1 ..];

        if (std.ascii.eqlIgnoreCase(key, "name")) {
            disposition.name = param_value;
        } else if (std.ascii.eqlIgnoreCase(key, "filename")) {
            disposition.filename = param_value;
        }
    }
}

const testing = @import("testing.zig");
test "simd: parse HTTP header" {
    const bytes = "Content-Disposition: attachment; filename*=UTF-8''file%20name.jpg\r\nrest";
    var header: HttpHeader = undefined;
    const consumed = try parseHttpHeader(bytes, &header);

    try testing.expectEqual(bytes.len - "rest".len, consumed);
    try testing.expectString("Content-Disposition", header.key);
    try testing.expectString("attachment; filename*=UTF-8''file%20name.jpg", header.value);

    // Lone `\n` line endings are accepted too.
    try testing.expectEqual(10, try parseHttpHeader("Host: abc\nHost: def\n", &header));
    try testing.expectString("Host", header.key);
    try testing.expectString("abc", header.value);

    // Leading whitespaces of the value are skipped, trailing ones are kept.
    _ = try parseHttpHeader("Key:    value  \r\n", &header);
    try testing.expectString("value  ", header.value);

    // 0 length values are fine.
    _ = try parseHttpHeader("Key:\r\n", &header);
    try testing.expectString("Key", header.key);
    try testing.expectString("", header.value);
}

test "simd: parse HTTP header incomplete" {
    var header: HttpHeader = undefined;

    // Buffer may end anywhere before the line ending is complete.
    const bytes = "Content-Type: text/plain\r\n";
    for (0..bytes.len) |len| {
        try testing.expectError(error.Incomplete, parseHttpHeader(bytes[0..len], &header));
    }
    // The lone `\n` variant completes a byte earlier.
    const lf_bytes = "Content-Type: text/plain\n";
    try testing.expectEqual(lf_bytes.len, try parseHttpHeader(lf_bytes, &header));
}

test "simd: parse HTTP header invalid" {
    var header: HttpHeader = undefined;

    // 0 length keys.
    try testing.expectError(error.Invalid, parseHttpHeader(": value\r\n", &header));
    // Invalid characters in the key.
    try testing.expectError(error.Invalid, parseHttpHeader("Key\x01: value\r\n", &header));
    try testing.expectError(error.Invalid, parseHttpHeader("Key name: value\r\n", &header));
    // Invalid characters in the value.
    try testing.expectError(error.Invalid, parseHttpHeader("Key: val\x01ue\r\n", &header));
    try testing.expectError(error.Invalid, parseHttpHeader("Key: val\x7fue\r\n", &header));
    // `\r` must be followed by `\n`.
    try testing.expectError(error.Invalid, parseHttpHeader("Key: value\rX\n", &header));
}

test "simd: parse HTTP headers" {
    var headers: [4]HttpHeader = undefined;
    var count: usize = 0;

    const bytes = "Content-Disposition: form-data; name=\"file\"\r\nContent-Type: application/octet-stream\r\n\r\nbinary\x00data";
    const consumed = try parseHttpHeaders(bytes, &headers, &count);

    try testing.expectEqual(bytes.len - "binary\x00data".len, consumed);
    try testing.expectEqual(2, count);
    try testing.expectString("Content-Disposition", headers[0].key);
    try testing.expectString("form-data; name=\"file\"", headers[0].value);
    try testing.expectString("Content-Type", headers[1].key);
    try testing.expectString("application/octet-stream", headers[1].value);

    // Lone `\n` line endings are accepted too.
    try testing.expectEqual(18, try parseHttpHeaders("Host: abc\nX: def\n\nrest", &headers, &count));
    try testing.expectEqual(2, count);

    // 0 length header sections are fine.
    try testing.expectEqual(2, try parseHttpHeaders("\r\nrest", &headers, &count));
    try testing.expectEqual(0, count);

    // The terminating empty line is required.
    try testing.expectError(error.Incomplete, parseHttpHeaders("Host: abc\r\n", &headers, &count));
    try testing.expectError(error.Incomplete, parseHttpHeaders("Host: abc\r\n\r", &headers, &count));

    // Not enough space in `headers`.
    var few: [1]HttpHeader = undefined;
    try testing.expectError(error.Invalid, parseHttpHeaders("A: 1\r\nB: 2\r\n\r\n", &few, &count));
    // ...but an exact fit is fine.
    try testing.expectEqual(8, try parseHttpHeaders("A: 1\r\n\r\n", &few, &count));
    try testing.expectEqual(1, count);
}

test "simd: match functions against scalar reference" {
    // Exhaustive: place every possible byte at every position of an otherwise
    // valid buffer, across lengths covering the vector, SWAR and scalar paths.
    var buf: [48]u8 = undefined;
    for (1..buf.len + 1) |len| {
        for (0..len) |pos| {
            for (0..256) |c| {
                @memset(buf[0..len], 'a');
                buf[pos] = @intCast(c);

                var key_expected: usize = 0;
                while (key_expected < len and header_key_map[buf[key_expected]] != 0) key_expected += 1;
                var value_expected: usize = 0;
                while (value_expected < len and header_value_map[buf[value_expected]] != 0) value_expected += 1;

                try testing.expectEqual(key_expected, matchHeaderKey(buf[0..len]));
                try testing.expectEqual(value_expected, matchHeaderValue(buf[0..len]));
            }
        }
    }

    // Randomized: fully random buffers to exercise multiple invalid bytes per
    // chunk at once.
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (0..20_000) |_| {
        const len = random.intRangeAtMost(usize, 0, buf.len);
        random.bytes(buf[0..len]);

        var key_expected: usize = 0;
        while (key_expected < len and header_key_map[buf[key_expected]] != 0) key_expected += 1;
        var value_expected: usize = 0;
        while (value_expected < len and header_value_map[buf[value_expected]] != 0) value_expected += 1;

        try testing.expectEqual(key_expected, matchHeaderKey(buf[0..len]));
        try testing.expectEqual(value_expected, matchHeaderValue(buf[0..len]));
    }
}
