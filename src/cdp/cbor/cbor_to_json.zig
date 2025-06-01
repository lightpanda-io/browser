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

const Allocator = std.mem.Allocator;

const Error = error{
    EOSReadingFloat,
    UnknownTag,
    EOSReadingArray,
    UnterminatedArray,
    EOSReadingMap,
    UnterminatedMap,
    EOSReadingLength,
    InvalidLength,
    MissingData,
    EOSExpectedString,
    ExpectedString,
    OutOfMemory,
    EmbeddedDataIsShort,
    InvalidEmbeddedDataEnvelope,
};

pub fn cborToJson(input: []const u8, writer: anytype) !void {
    if (input.len < 7) {
        return error.InvalidCBORMessage;
    }

    var data = input;
    while (data.len > 0) {
        data = try writeValue(data, writer);
    }
}

fn writeValue(data: []const u8, writer: anytype) Error![]const u8 {
    switch (data[0]) {
        0xf4 => {
            try writer.writeAll("false");
            return data[1..];
        },
        0xf5 => {
            try writer.writeAll("true");
            return data[1..];
        },
        0xf6, 0xf7 => { // 0xf7 is undefined
            try writer.writeAll("null");
            return data[1..];
        },
        0x9f => return writeInfiniteArray(data[1..], writer),
        0xbf => return writeInfiniteMap(data[1..], writer),
        0xd8 => {
            // This is major type 6, which is generic tagged data. We only
            // support 1 tag: embedded cbor data.
            if (data.len < 7) {
                return error.EmbeddedDataIsShort;
            }
            if (data[1] != 0x18 or data[2] != 0x5a) {
                return error.InvalidEmbeddedDataEnvelope;
            }
            // skip the length, we have the full paylaod
            return writeValue(data[7..], writer);
        },
        0xf9 => { // f16
            if (data.len < 3) {
                return error.EOSReadingFloat;
            }
            try writer.print("{d}", .{@as(f16, @bitCast(std.mem.readInt(u16, data[1..3], .big)))});
            return data[3..];
        },
        0xfa => { // f32
            if (data.len < 5) {
                return error.EOSReadingFloat;
            }
            try writer.print("{d}", .{@as(f32, @bitCast(std.mem.readInt(u32, data[1..5], .big)))});
            return data[5..];
        },
        0xfb => { // f64
            if (data.len < 9) {
                return error.EOSReadingFloat;
            }
            try writer.print("{d}", .{@as(f64, @bitCast(std.mem.readInt(u64, data[1..9], .big)))});
            return data[9..];
        },
        else => |b| {
            const major_type = b >> 5;
            switch (major_type) {
                0 => {
                    const rest, const length = try parseLength(data);
                    try writer.print("{d}", .{length});
                    return rest;
                },
                1 => {
                    const rest, const length = try parseLength(data);
                    try writer.print("{d}", .{-@as(i64, @intCast(length)) - 1});
                    return rest;
                },
                2 => {
                    const rest, const str = try parseString(data);
                    try writer.writeByte('"');
                    try std.base64.standard.Encoder.encodeWriter(writer, str);
                    try writer.writeByte('"');
                    return rest;
                },
                3 => {
                    const rest, const str = try parseString(data);
                    try std.json.encodeJsonString(str, .{}, writer);
                    return rest;
                },
                // 4 => unreachable, // fixed-length array
                // 5 => unreachable, // fixed-length map
                else => return error.UnknownTag,
            }
        },
    }
}

// We expect every array from V8 to be an infinite-length array. That it, it
// starts with the special tag: (4<<5) | 31  which an "array" with infinite
// length.
// Of course, it isn't infite, the end of the array happens when we hit a break
// code which is FF (7 << 5) | 31
fn writeInfiniteArray(d: []const u8, writer: anytype) ![]const u8 {
    if (d.len == 0) {
        return error.EOSReadingArray;
    }
    if (d[0] == 255) {
        try writer.writeAll("[]");
        return d[1..];
    }

    try writer.writeByte('[');
    var data = try writeValue(d, writer);
    while (data.len > 0) {
        if (data[0] == 255) {
            try writer.writeByte(']');
            return data[1..];
        }
        try writer.writeByte(',');
        data = try writeValue(data, writer);
    }

    // Reaching the end of the input is a mistake, should have reached the break
    // code
    return error.UnterminatedArray;
}

// We expect every map from V8 to be an infinite-length map. That it, it
// starts with the special tag: (5<<5) | 31  which an "map" with infinite
// length.
// Of course, it isn't infite, the end of the map happens when we hit a break
// code which is FF (7 << 5) | 31
fn writeInfiniteMap(d: []const u8, writer: anytype) ![]const u8 {
    if (d.len == 0) {
        return error.EOSReadingMap;
    }
    if (d[0] == 255) {
        try writer.writeAll("{}");
        return d[1..];
    }

    try writer.writeByte('{');

    var data = blk: {
        const data, const field = try maybeParseString(d);
        try std.json.encodeJsonString(field, .{}, writer);
        try writer.writeByte(':');
        break :blk try writeValue(data, writer);
    };

    while (data.len > 0) {
        if (data[0] == 255) {
            try writer.writeByte('}');
            return data[1..];
        }
        try writer.writeByte(',');
        data, const field = try maybeParseString(data);
        try std.json.encodeJsonString(field, .{}, writer);
        try writer.writeByte(':');
        data = try writeValue(data, writer);
    }

    // Reaching the end of the input is a mistake, should have reached the break
    // code
    return error.UnterminatedMap;
}

fn parseLength(data: []const u8) !struct { []const u8, usize } {
    std.debug.assert(data.len > 0);
    switch (data[0] & 0b11111) {
        0...23 => |n| return .{ data[1..], n },
        24 => {
            if (data.len == 1) {
                return error.EOSReadingLength;
            }
            return .{ data[2..], @intCast(data[1]) };
        },
        25 => {
            if (data.len < 3) {
                return error.EOSReadingLength;
            }
            return .{ data[3..], @intCast(std.mem.readInt(u16, data[1..3], .big)) };
        },
        26 => {
            if (data.len < 5) {
                return error.EOSReadingLength;
            }
            return .{ data[5..], @intCast(std.mem.readInt(u32, data[1..5], .big)) };
        },
        27 => {
            if (data.len < 9) {
                return error.EOSReadingLength;
            }
            return .{ data[9..], @intCast(std.mem.readInt(u64, data[1..9], .big)) };
        },
        else => return error.InvalidLength,
    }
}

fn parseString(data: []const u8) !struct { []const u8, []const u8 } {
    const rest, const length = try parseLength(data);
    if (rest.len < length) {
        return error.MissingData;
    }
    return .{ rest[length..], rest[0..length] };
}

fn maybeParseString(data: []const u8) !struct { []const u8, []const u8 } {
    if (data.len == 0) {
        return error.EOSExpectedString;
    }
    const b = data[0];
    if (b >> 5 != 3) {
        return error.ExpectedString;
    }
    return parseString(data);
}
