// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const json = std.json;
const Allocator = std.mem.Allocator;

const Error = error{
    InvalidJson,
    OutOfMemory,
    SyntaxError,
    UnexpectedEndOfInput,
    ValueTooLong,
};

pub fn jsonToCbor(arena: Allocator, input: []const u8) ![]const u8 {
    var scanner = json.Scanner.initCompleteInput(arena, input);
    defer scanner.deinit();

    var arr: std.ArrayListUnmanaged(u8) = .empty;
    try writeNext(arena, &arr, &scanner);
    return arr.items;
}

fn writeNext(arena: Allocator, arr: *std.ArrayListUnmanaged(u8), scanner: *json.Scanner) Error!void {
    const token = scanner.nextAlloc(arena, .alloc_if_needed) catch return error.InvalidJson;
    return writeToken(arena, arr, scanner, token);
}

fn writeToken(arena: Allocator, arr: *std.ArrayListUnmanaged(u8), scanner: *json.Scanner, token: json.Token) Error!void {
    switch (token) {
        .object_begin => return writeObject(arena, arr, scanner),
        .array_begin => return writeArray(arena, arr, scanner),
        .true => return arr.append(arena, 7 << 5 | 21),
        .false => return arr.append(arena, 7 << 5 | 20),
        .null => return arr.append(arena, 7 << 5 | 22),
        .allocated_string, .string => |key| return writeString(arena, arr, key),
        .allocated_number, .number => |s| {
            if (json.isNumberFormattedLikeAnInteger(s)) {
                return writeInteger(arena, arr, s);
            }
            const f = std.fmt.parseFloat(f64, s) catch unreachable;
            return writeHeader(arena, arr, 7, @intCast(@as(u64, @bitCast(f))));
        },
        else => unreachable,
    }
}

fn writeObject(arena: Allocator, arr: *std.ArrayListUnmanaged(u8), scanner: *json.Scanner) !void {
    const envelope = try startEmbeddedMessage(arena, arr);

    // MajorType 5 (map) | 5-byte infinite length
    try arr.append(arena, 5 << 5 | 31);

    while (true) {
        switch (try scanner.nextAlloc(arena, .alloc_if_needed)) {
            .allocated_string, .string => |key| {
                try writeString(arena, arr, key);
                try writeNext(arena, arr, scanner);
            },
            .object_end => {
                // MajorType 7 (break) | 5-byte infinite length
                try arr.append(arena, 7 << 5 | 31);
                return finalizeEmbeddedMessage(arr, envelope);
            },
            else => return error.InvalidJson,
        }
    }
}

fn writeArray(arena: Allocator, arr: *std.ArrayListUnmanaged(u8), scanner: *json.Scanner) !void {
    const envelope = try startEmbeddedMessage(arena, arr);

    // MajorType 4 (array) | 5-byte infinite length
    try arr.append(arena, 4 << 5 | 31);
    while (true) {
        const token = scanner.nextAlloc(arena, .alloc_if_needed) catch return error.InvalidJson;
        switch (token) {
            .array_end => {
                // MajorType 7 (break) | 5-byte infinite length
                try arr.append(arena, 7 << 5 | 31);
                return finalizeEmbeddedMessage(arr, envelope);
            },
            else => try writeToken(arena, arr, scanner, token),
        }
    }
}

fn writeString(arena: Allocator, arr: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try writeHeader(arena, arr, 3, value.len);
    return arr.appendSlice(arena, value);
}

fn writeInteger(arena: Allocator, arr: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    const n = std.fmt.parseInt(i64, s, 10) catch {
        return error.InvalidJson;
    };
    if (n >= 0) {
        return writeHeader(arena, arr, 0, @intCast(n));
    }
    return writeHeader(arena, arr, 1, @intCast(-1 - n));
}

fn writeHeader(arena: Allocator, arr: *std.ArrayListUnmanaged(u8), comptime typ: u8, count: usize) !void {
    switch (count) {
        0...23 => try arr.append(arena, typ << 5 | @as(u8, @intCast(count))),
        24...255 => {
            try arr.ensureUnusedCapacity(arena, 2);
            arr.appendAssumeCapacity(typ << 5 | 24);
            arr.appendAssumeCapacity(@intCast(count));
        },
        256...65535 => {
            try arr.ensureUnusedCapacity(arena, 3);
            arr.appendAssumeCapacity(typ << 5 | 25);
            arr.appendAssumeCapacity(@intCast((count >> 8) & 0xff));
            arr.appendAssumeCapacity(@intCast(count & 0xff));
        },
        65536...4294967295 => {
            try arr.ensureUnusedCapacity(arena, 5);
            arr.appendAssumeCapacity(typ << 5 | 26);
            arr.appendAssumeCapacity(@intCast((count >> 24) & 0xff));
            arr.appendAssumeCapacity(@intCast((count >> 16) & 0xff));
            arr.appendAssumeCapacity(@intCast((count >> 8) & 0xff));
            arr.appendAssumeCapacity(@intCast(count & 0xff));
        },
        else => {
            try arr.ensureUnusedCapacity(arena, 9);
            arr.appendAssumeCapacity(typ << 5 | 27);
            arr.appendAssumeCapacity(@intCast((count >> 56) & 0xff));
            arr.appendAssumeCapacity(@intCast((count >> 48) & 0xff));
            arr.appendAssumeCapacity(@intCast((count >> 40) & 0xff));
            arr.appendAssumeCapacity(@intCast((count >> 32) & 0xff));
            arr.appendAssumeCapacity(@intCast((count >> 24) & 0xff));
            arr.appendAssumeCapacity(@intCast((count >> 16) & 0xff));
            arr.appendAssumeCapacity(@intCast((count >> 8) & 0xff));
            arr.appendAssumeCapacity(@intCast(count & 0xff));
        },
    }
}

// I don't know why, but V8 expects any array or map (including the outer-most
// object), to be encoded as embedded cbor data. This is CBOR that contains CBOR.
// I feel that it's fine that it supports it, but why _require_ it? Seems like
// a waste of 7 bytes.
fn startEmbeddedMessage(arena: Allocator, arr: *std.ArrayListUnmanaged(u8)) !usize {
    try arr.appendSlice(arena, &.{ 0xd8, 0x18, 0x5a, 0, 0, 0, 0 });
    return arr.items.len;
}

fn finalizeEmbeddedMessage(arr: *std.ArrayListUnmanaged(u8), pos: usize) !void {
    var items = arr.items;
    const length = items.len - pos;
    items[pos - 4] = @intCast((length >> 24) & 0xff);
    items[pos - 3] = @intCast((length >> 16) & 0xff);
    items[pos - 2] = @intCast((length >> 8) & 0xff);
    items[pos - 1] = @intCast(length & 0xff);
}
