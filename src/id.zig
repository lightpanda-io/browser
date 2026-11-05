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
const lp = @import("lightpanda");

pub fn uuidv4(hex: *[36]u8) void {
    var bin: [16]u8 = undefined;
    lp.io.random(&bin);
    bin[6] = (bin[6] & 0x0f) | 0x40;
    bin[8] = (bin[8] & 0x3f) | 0x80;

    const alphabet = "0123456789abcdef";

    hex[8] = '-';
    hex[13] = '-';
    hex[18] = '-';
    hex[23] = '-';

    const encoded_pos = [16]u8{ 0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34 };
    inline for (encoded_pos, 0..) |i, j| {
        hex[i + 0] = alphabet[bin[j] >> 4];
        hex[i + 1] = alphabet[bin[j] & 0x0f];
    }
}

const testing = std.testing;
test "id: uuidv4" {
    const expectUUID = struct {
        fn expect(uuid: [36]u8) !void {
            for (uuid, 0..) |c, i| {
                switch (i) {
                    8, 13, 18, 23 => try testing.expectEqual('-', c),
                    else => switch (c) {
                        '0'...'9', 'a'...'f' => {},
                        else => return error.InvalidHexEncoding,
                    },
                }
            }
            // Version: 0100 in the high nibble of byte 6.
            try testing.expectEqual('4', uuid[14]);
            // Variant: 10 in the high bits of byte 8.
            switch (uuid[19]) {
                '8', '9', 'a', 'b' => {},
                else => return error.InvalidVariant,
            }
        }
    }.expect;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var seen = std.StringHashMapUnmanaged(void){};
    for (0..100) |_| {
        var hex: [36]u8 = undefined;
        uuidv4(&hex);
        try expectUUID(hex);
        try seen.put(allocator, try allocator.dupe(u8, &hex), {});
    }
    try testing.expectEqual(100, seen.count());
}
