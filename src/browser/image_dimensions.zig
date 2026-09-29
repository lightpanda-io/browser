// Copyright (C) 2026 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

pub const Dimensions = struct { width: u32, height: u32 };

/// Read only the image header. The caller supplies a bounded prefix; an
/// unsupported format or a JPEG with its SOF beyond that prefix has no known
/// dimensions. No bitmap data is decoded.
pub fn parse(bytes: []const u8) ?Dimensions {
    if (bytes.len >= 24 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") and
        std.mem.eql(u8, bytes[8..12], "\x00\x00\x00\x0d") and std.mem.eql(u8, bytes[12..16], "IHDR"))
    {
        return valid(std.mem.readInt(u32, bytes[16..20], .big), std.mem.readInt(u32, bytes[20..24], .big));
    }

    if (bytes.len >= 10 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) {
        return valid(std.mem.readInt(u16, bytes[6..8], .little), std.mem.readInt(u16, bytes[8..10], .little));
    }

    if (bytes.len >= 4 and bytes[0] == 0xff and bytes[1] == 0xd8) {
        var pos: usize = 2;
        while (pos < bytes.len) {
            if (bytes[pos] != 0xff) return null;
            while (pos < bytes.len and bytes[pos] == 0xff) : (pos += 1) {}
            if (pos >= bytes.len) return null;
            const marker = bytes[pos];
            pos += 1;
            if (marker == 0xd9 or marker == 0xda) return null; // EOI or scan data
            if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
            if (bytes.len - pos < 2) return null;
            const len = std.mem.readInt(u16, bytes[pos..][0..2], .big);
            if (len < 2 or len > bytes.len - pos) return null;
            // SOF markers (except the non-frame DHT, JPG and DAC markers).
            if ((marker >= 0xc0 and marker <= 0xcf) and marker != 0xc4 and marker != 0xc8 and marker != 0xcc) {
                if (len < 7) return null;
                return valid(std.mem.readInt(u16, bytes[pos + 5 ..][0..2], .big), std.mem.readInt(u16, bytes[pos + 3 ..][0..2], .big));
            }
            pos += len;
        }
    }

    if (bytes.len >= 25 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        if (bytes.len >= 30 and std.mem.eql(u8, bytes[12..16], "VP8X")) {
            const width = @as(u32, bytes[24]) | @as(u32, bytes[25]) << 8 | @as(u32, bytes[26]) << 16;
            const height = @as(u32, bytes[27]) | @as(u32, bytes[28]) << 8 | @as(u32, bytes[29]) << 16;
            return valid(width + 1, height + 1);
        }
        if (bytes.len >= 30 and std.mem.eql(u8, bytes[12..16], "VP8 ") and std.mem.eql(u8, bytes[23..26], "\x9d\x01\x2a")) {
            return valid(std.mem.readInt(u16, bytes[26..28], .little) & 0x3fff, std.mem.readInt(u16, bytes[28..30], .little) & 0x3fff);
        }
        if (std.mem.eql(u8, bytes[12..16], "VP8L") and bytes[20] == 0x2f) {
            const width = @as(u32, bytes[21]) | (@as(u32, bytes[22]) & 0x3f) << 8;
            const height = @as(u32, bytes[22]) >> 6 | @as(u32, bytes[23]) << 2 | (@as(u32, bytes[24]) & 0x0f) << 10;
            return valid(width + 1, height + 1);
        }
    }
    return null;
}

fn valid(width: u32, height: u32) ?Dimensions {
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

const testing = std.testing;
test "image dimensions: PNG, GIF, JPEG, WebP" {
    try testing.expectEqual(Dimensions{ .width = 1000, .height = 750 }, parse("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x03\xe8\x00\x00\x02\xee").?);
    try testing.expectEqual(Dimensions{ .width = 320, .height = 240 }, parse("GIF89a\x40\x01\xf0\x00").?);
    try testing.expectEqual(Dimensions{ .width = 1000, .height = 750 }, parse("\xff\xd8\xff\xe1\x00\x04\x00\x00\xff\xc0\x00\x0b\x08\x02\xee\x03\xe8\x01\x01\x11\x00").?);
    try testing.expectEqual(Dimensions{ .width = 1000, .height = 750 }, parse("RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\xe7\x03\x00\xed\x02\x00").?);
    try testing.expectEqual(Dimensions{ .width = 1, .height = 1 }, parse("RIFF\x00\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\x00\x00\x00\x00\x00").?);
}

test "image dimensions: truncated or invalid headers" {
    try testing.expectEqual(null, parse("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00"));
    try testing.expectEqual(null, parse("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x00\x00\x00\x00\x01"));
    try testing.expectEqual(null, parse("\xff\xd8\xff\xe1\x00\xff\x00"));
    try testing.expectEqual(null, parse("<svg width='10' height='20'></svg>"));
}
