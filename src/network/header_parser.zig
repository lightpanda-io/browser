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

const std = @import("std");
const builtin = @import("builtin");

/// Block size of the CPU.
const block_size = @sizeOf(usize);

/// Whether a byte is allowed in a header key; controls (including space),
/// the `:` delimiter and DEL are excluded.
fn isHeaderKeyByte(byte: u8) bool {
    return switch (byte) {
        0...' ', ':', 0x7f => false,
        else => true,
    };
}

/// Whether a byte is allowed in a header value; controls other than HTAB,
/// and DEL, are excluded. HTAB is legal field content per RFC 9110.
fn isHeaderValueByte(byte: u8) bool {
    return switch (byte) {
        0...0x08, 0x0a...0x1f, 0x7f => false,
        else => true,
    };
}

/// Returns a mask with the high bit of each byte set where the corresponding
/// byte of `v` is zero. Exact per byte: carries never cross byte lanes
/// (Hacker's Delight zero-byte detection).
fn zeroBytes(v: usize) usize {
    const low7 = comptime broadcast(0x7f);
    return ~(((v & low7) + low7) | v | low7);
}

/// Returns an integer filled with a given byte.
fn broadcast(byte: u8) usize {
    return @as(usize, @intCast(byte)) * 0x01_01_01_01_01_01_01_01;
}

fn matchHeaderKey(cursor: *Cursor) void {
    // Pick a good default for relatively small strings.
    const vec_size = 16;
    const use_vectors = comptime if (std.simd.suggestVectorLength(u8)) |recommended|
        recommended >= vec_size
    else
        false;

    if (comptime use_vectors) {
        const Vec = @Vector(vec_size, u8);
        const Int = @Int(.unsigned, vec_size);

        while (cursor.hasLength(vec_size)) {
            const spaces: Vec = @splat(' ');
            const colons: Vec = @splat(':');
            const deletes: Vec = @splat(0x7f);
            const chunk = cursor.asVector(vec_size);

            // Per-lane `isHeaderKeyByte`: a lane is 1 when its byte is valid,
            // above space (which also rules out the controls) and neither the
            // `:` delimiter nor DEL. Inverting the mask makes invalid lanes
            // 1s, so `@ctz` yields the index of the first invalid byte, or
            // `vec_size` when the whole chunk is valid.
            const mask = @intFromBool(chunk > spaces) & ~(@intFromBool(chunk == colons) | @intFromBool(chunk == deletes));
            const advance_by = @ctz(~@as(Int, @bitCast(mask)));
            // Advance.
            cursor.advance(advance_by);
            if (advance_by != vec_size) {
                return;
            }
        }
    }

    // NOTE: SWAR is not preferred here, this might change in the future
    // but honestly header keys are not so long.

    // Fallback for len < `vec_size`.
    while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
        if (isHeaderKeyByte(cursor.char()) == false) {
            return;
        }
    }
}

fn matchHeaderValue(cursor: *Cursor) void {
    const maybe_vec_size: ?usize = comptime blk: {
        if (std.simd.suggestVectorLength(u8)) |recommended| {
            break :blk if (recommended >= 64) 32 else recommended;
        }
        break :blk null;
    };

    if (comptime maybe_vec_size) |vec_size| {
        const Vec = @Vector(vec_size, u8);
        const Int = @Int(.unsigned, vec_size);

        while (cursor.hasLength(vec_size)) {
            // Fill a vector with DEL (127).
            const deletes: Vec = @splat(0x7f);
            // Fill a vector with US (31).
            const full_31: Vec = @splat(0x1f);
            // Fill a vector with HTAB (9).
            const tabs: Vec = @splat('\t');
            // Load the next chunk from the buffer.
            const chunk = cursor.asVector(vec_size);

            // Per-lane `isHeaderValueByte`: a lane is 1 when its byte is
            // valid, above US (which rules out the controls but keeps space)
            // or an HTAB, and not DEL. Inverting the mask makes invalid lanes
            // 1s, so `@ctz` yields the index of the first invalid byte, or
            // `vec_size` when the whole chunk is valid.
            const mask = (@intFromBool(chunk > full_31) | @intFromBool(chunk == tabs)) & ~@intFromBool(chunk == deletes);
            const advance_by = @ctz(~@as(Int, @bitCast(mask)));
            cursor.advance(advance_by);
            if (advance_by != vec_size) {
                return;
            }
        }
    }

    // SWAR path.
    while (cursor.hasLength(block_size)) {
        const tabs = comptime broadcast('\t');
        const dels = comptime broadcast(0x7f);
        // A byte is below space (32) exactly when its top three bits are
        // all zero.
        const high3 = comptime broadcast(0xe0);
        const chunk = cursor.asInteger(usize);

        const is_ctl = zeroBytes(chunk & high3);
        const is_tab = zeroBytes(chunk ^ tabs);
        const is_del = zeroBytes(chunk ^ dels);
        const advance_by = @ctz((is_ctl & ~is_tab) | is_del) >> 3;

        cursor.advance(advance_by);
        if (advance_by != block_size) {
            return;
        }
    }

    while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
        if (isHeaderValueByte(cursor.char()) == false) {
            return;
        }
    }
}

/// Represents a single HTTP header.
pub const Header = struct {
    key: []const u8,
    value: []const u8,

    pub const ParseError = error{ Incomplete, Invalid };

    pub fn parse(header: *Header, cursor: *Cursor) ParseError!void {
        const key_start = cursor.current();
        matchHeaderKey(cursor);
        const key_end = cursor.current();

        // Buffer has been consumed fully without a delimiter; the caller can
        // read more data and try to parse again. Checked before `char`, which
        // reads unchecked.
        if (cursor.reachedEnd()) {
            return error.Incomplete;
        }

        switch (cursor.char()) {
            ':' => {
                @branchHint(.likely);
                // 0 length header key, which is invalid.
                if (key_end == key_start) {
                    return error.Invalid;
                }
                cursor.advance(1);
            },
            // Invalid character, so a malformed header. Can't go further.
            else => return error.Invalid,
        }

        // Get rid of leading spaces if there are any.
        cursor.skipSpaces();

        // Found where header value starts.
        const val_start = cursor.current();
        matchHeaderValue(cursor);
        const val_end = cursor.current();

        // Buffer has been consumed fully without a line ending; the caller
        // can read more data and try to parse again.
        if (cursor.reachedEnd()) {
            return error.Incomplete;
        }

        // Both LF and CRLF indicate the end of the value part.
        switch (cursor.char()) {
            '\n' => cursor.advance(1),
            '\r' => {
                // We need an LF too.
                if (!cursor.hasLength(2)) {
                    return error.Incomplete;
                }
                if (!cursor.peek2('\r', '\n')) {
                    @branchHint(.unlikely);
                    return error.Invalid;
                }
                cursor.advance(2);
            },
            // Any other character is invalid.
            else => return error.Invalid,
        }

        header.* = .{
            .key = key_start[0 .. key_end - key_start],
            .value = val_start[0 .. val_end - val_start],
        };
    }
};

pub const Disposition = struct {
    name: ?[]const u8 = null,
    filename: ?[]const u8 = null,
};

// Parses a part's Content-Disposition value: `form-data` followed by
// `; key="value"` params. Values are quoted-strings whose CR/LF/" were
// percent-escaped by the encoder (writeMultipartName), so the next raw '"'
// always closes the value; a raw ';' inside quotes is legal and preserved.
// Parameters that are not `key="quoted"` pairs — e.g. RFC 5987
// `filename*=UTF-8''...`, which real servers emit — are skipped rather than
// failing the whole parse, matching browser leniency.
pub fn parseDisposition(value: []const u8) !Disposition {
    var rest = std.mem.trim(u8, value, " \t");
    if (!std.ascii.startsWithIgnoreCase(rest, "form-data")) {
        return error.InvalidFormData;
    }
    rest = rest["form-data".len..];

    var disposition = Disposition{};
    while (true) {
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == 0) {
            return disposition;
        }
        if (rest[0] != ';') {
            return error.InvalidFormData;
        }
        rest = std.mem.trimStart(u8, rest[1..], " \t");

        // An unquoted value cannot contain a `;`, so the next one (or the end
        // of the header) bounds this parameter when it has to be skipped.
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse rest.len;
        if (eq >= semi) {
            // No `=` in this parameter; skip it.
            rest = rest[semi..];
            continue;
        }
        const key = rest[0..eq];
        const after_eq = rest[eq + 1 ..];

        if (after_eq.len == 0 or after_eq[0] != '"') {
            // Unquoted value; skip it.
            rest = rest[semi..];
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, after_eq, 1, '"') orelse {
            // Unterminated quoted value; ignore the rest of the header.
            return disposition;
        };
        const param_value = after_eq[1..end];
        rest = after_eq[end + 1 ..];

        if (std.ascii.eqlIgnoreCase(key, "name")) {
            disposition.name = param_value;
        } else if (std.ascii.eqlIgnoreCase(key, "filename")) {
            disposition.filename = param_value;
        }
    }
}

/// Helper for wandering around & parsing things along the way.
pub const Cursor = struct {
    /// Pointer to current position of cursor.
    idx: [*]const u8,
    /// Pointer to end of the buffer.
    end: [*]const u8,
    /// Pointer to start of the buffer.
    start: [*]const u8,

    /// Returns the current position.
    pub fn current(cursor: *const Cursor) [*]const u8 {
        return cursor.idx;
    }

    /// Returns the current character.
    pub fn char(cursor: *const Cursor) u8 {
        return cursor.idx[0];
    }

    /// Advances the position of the cursor by given value.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    pub fn advance(cursor: *Cursor, by: usize) void {
        cursor.idx += by;
    }

    /// Checks if buffer has `len` length of characters.
    /// `(cursor.end - cursor.idx >= len)`
    pub fn hasLength(cursor: *const Cursor, len: usize) bool {
        return cursor.end - cursor.idx >= len;
    }

    /// Loads a `@Vector(len, u8)` from the current position of cursor without advancing.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    pub fn asVector(cursor: *const Cursor, len: comptime_int) @Vector(len, u8) {
        return cursor.idx[0..len].*;
    }

    /// Creates an integer from the current position of the cursor without advancing.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    /// SAFETY: T must be an integer with bit size >= @bitSizeOf(u8).
    pub fn asInteger(cursor: *const Cursor, comptime T: type) T {
        return @bitCast(cursor.idx[0 .. @bitSizeOf(T) / @bitSizeOf(u8)].*);
    }

    /// Peek the current and the next but don't advance.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    pub fn peek2(cursor: *const Cursor, c0: u8, c1: u8) bool {
        return cursor.asInteger(u16) == @as(u16, @bitCast([2]u8{ c0, c1 }));
    }

    /// Moves the cursor until no leading spaces there are.
    pub fn skipSpaces(cursor: *Cursor) void {
        while (cursor.end - cursor.current() > 0 and (cursor.char() == ' ' or cursor.char() == '\t')) : (cursor.advance(1)) {}
    }

    /// Returns true if `Cursor` reached end.
    pub fn reachedEnd(cursor: *const Cursor) bool {
        return cursor.idx == cursor.end;
    }

    /// Returns the unread portion of the buffer.
    pub fn remaining(cursor: *const Cursor) []const u8 {
        return cursor.idx[0 .. cursor.end - cursor.idx];
    }
};

const testing = @import("../testing.zig");

fn initCursor(bytes: []const u8) Cursor {
    return .{ .idx = bytes.ptr, .end = bytes.ptr + bytes.len, .start = bytes.ptr };
}

fn consumed(cursor: *const Cursor) usize {
    return cursor.idx - cursor.start;
}

test "header_parser: parse HTTP header" {
    const bytes = "Content-Disposition: attachment; filename*=UTF-8''file%20name.jpg\r\nrest";
    var cursor = initCursor(bytes);
    var header: Header = undefined;
    try header.parse(&cursor);

    try testing.expectEqual(bytes.len - "rest".len, consumed(&cursor));
    try testing.expectString("Content-Disposition", header.key);
    try testing.expectString("attachment; filename*=UTF-8''file%20name.jpg", header.value);

    // Lone `\n` line endings are accepted too; the cursor is left at the next
    // header, so parsing can continue from there.
    cursor = initCursor("Host: abc\nHost: def\n");
    try header.parse(&cursor);
    try testing.expectEqual(10, consumed(&cursor));
    try testing.expectString("Host", header.key);
    try testing.expectString("abc", header.value);
    try header.parse(&cursor);
    try testing.expectString("def", header.value);
    try testing.expectEqual(true, cursor.reachedEnd());

    // Leading whitespaces of the value — spaces and HTABs — are skipped,
    // trailing ones are kept.
    cursor = initCursor("Key:  \t value \t\r\n");
    try header.parse(&cursor);
    try testing.expectString("value \t", header.value);

    // 0 length values are fine.
    cursor = initCursor("Key:\r\n");
    try header.parse(&cursor);
    try testing.expectString("Key", header.key);
    try testing.expectString("", header.value);

    // HTAB is legal field content, including next to spaces.
    cursor = initCursor("Key: a\tb\t c\r\n");
    try header.parse(&cursor);
    try testing.expectString("a\tb\t c", header.value);
}

test "header_parser: parse HTTP header incomplete" {
    var header: Header = undefined;

    // Buffer may end anywhere before the line ending is complete.
    const bytes = "Content-Type: text/plain\r\n";
    for (0..bytes.len) |len| {
        var cursor = initCursor(bytes[0..len]);
        try testing.expectError(error.Incomplete, header.parse(&cursor));
    }
    // The lone `\n` variant completes a byte earlier.
    var cursor = initCursor("Content-Type: text/plain\n");
    try header.parse(&cursor);
    try testing.expectEqual(true, cursor.reachedEnd());
}

test "header_parser: parse HTTP header invalid" {
    var header: Header = undefined;

    const cases = [_][]const u8{
        ": value\r\n", // 0 length key
        "Key\x01: value\r\n", // invalid character in the key
        "Key name: value\r\n", // space in the key
        "Key: val\x01ue\r\n", // invalid character in the value
        "Key: val\x7fue\r\n", // DEL in the value
        "Key: value\rX\n", // `\r` must be followed by `\n`
    };
    for (cases) |case| {
        var cursor = initCursor(case);
        try testing.expectError(error.Invalid, header.parse(&cursor));
    }
}

test "header_parser: parse Content-Disposition" {
    var d = try parseDisposition("form-data; name=\"a\"; filename=\"b.txt\"");
    try testing.expectString("a", d.name.?);
    try testing.expectString("b.txt", d.filename.?);

    // Type and parameter names are case-insensitive; surrounding whitespace
    // is tolerated.
    d = try parseDisposition("  Form-Data; NAME=\"x\" ");
    try testing.expectString("x", d.name.?);
    try testing.expectEqual(null, d.filename);

    // No parameters at all is fine; both fields stay null.
    d = try parseDisposition("form-data");
    try testing.expectEqual(null, d.name);
    try testing.expectEqual(null, d.filename);

    // A raw ';' inside a quoted value is preserved; unknown parameters are
    // skipped.
    d = try parseDisposition("form-data; foo=\"bar\"; name=\"a;b\"");
    try testing.expectString("a;b", d.name.?);

    // Parameters without `=` or with an unquoted value — e.g. RFC 5987
    // `filename*` — are skipped without failing the parse; later well-formed
    // parameters still apply.
    d = try parseDisposition("form-data; filename*=UTF-8''file%20name.jpg; name=\"n\"");
    try testing.expectString("n", d.name.?);
    try testing.expectEqual(null, d.filename);
    d = try parseDisposition("form-data; foo; name=bare; filename=\"f.txt\"");
    try testing.expectEqual(null, d.name);
    try testing.expectString("f.txt", d.filename.?);

    // An unterminated quoted value ends the parse, keeping what was found.
    d = try parseDisposition("form-data; name=\"a\"; filename=\"f");
    try testing.expectString("a", d.name.?);
    try testing.expectEqual(null, d.filename);

    // Not form-data at all, or a parameter without a `;` separator, is
    // rejected.
    try testing.expectError(error.InvalidFormData, parseDisposition("attachment; name=\"a\""));
    try testing.expectError(error.InvalidFormData, parseDisposition("form-data name=\"a\""));
}

test "header_parser: cursor" {
    var cursor = initCursor("  ab\r\ncd");
    try testing.expectEqual(8, cursor.remaining().len);
    cursor.skipSpaces();
    try testing.expectEqual(2, consumed(&cursor));
    try testing.expectEqual('a', cursor.char());
    try testing.expectEqual(true, cursor.peek2('a', 'b'));
    try testing.expectEqual(false, cursor.peek2('a', 'c'));
    try testing.expectEqual(true, cursor.hasLength(6));
    try testing.expectEqual(false, cursor.hasLength(7));
    cursor.advance(6);
    try testing.expectEqual(true, cursor.reachedEnd());
    try testing.expectString("", cursor.remaining());

    // Skipping spaces covers HTABs too and stops at the end of the buffer.
    cursor = initCursor(" \t \t");
    cursor.skipSpaces();
    try testing.expectEqual(true, cursor.reachedEnd());
}

fn expectMatchesReference(bytes: []const u8) !void {
    var key_expected: usize = 0;
    while (key_expected < bytes.len and isHeaderKeyByte(bytes[key_expected])) key_expected += 1;
    var value_expected: usize = 0;
    while (value_expected < bytes.len and isHeaderValueByte(bytes[value_expected])) value_expected += 1;

    var cursor = initCursor(bytes);
    matchHeaderKey(&cursor);
    try testing.expectEqual(key_expected, consumed(&cursor));

    cursor = initCursor(bytes);
    matchHeaderValue(&cursor);
    try testing.expectEqual(value_expected, consumed(&cursor));
}

test "header_parser: match functions against scalar reference" {
    // Exhaustive: place every possible byte at every position of an otherwise
    // valid buffer, across lengths covering the vector, SWAR and scalar paths.
    var buf: [48]u8 = undefined;
    for (1..buf.len + 1) |len| {
        for (0..len) |pos| {
            for (0..256) |c| {
                @memset(buf[0..len], 'a');
                buf[pos] = @intCast(c);
                try expectMatchesReference(buf[0..len]);
            }
        }
    }

    // HTAB is the one valid byte below space; pair it with every byte at
    // every position to prove it never disturbs its neighbor's verdict
    // (a cross-lane borrow in the SWAR path would).
    for (2..buf.len + 1) |len| {
        for (0..len - 1) |pos| {
            for (0..256) |c| {
                @memset(buf[0..len], 'a');
                buf[pos] = '\t';
                buf[pos + 1] = @intCast(c);
                try expectMatchesReference(buf[0..len]);
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
        try expectMatchesReference(buf[0..len]);
    }
}
