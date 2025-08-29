const std = @import("std");

// Generates incrementing prefixed integers, i.e. CTX-1, CTX-2, CTX-3.
// Wraps to 0 on overflow.
// Many caveats for using this:
// - Not thread-safe.
// - Information leaking
// - The slice returned by next() is only valid:
//   - while incrementor is valid
//   - until the next call to next()
// On the positive, it's zero allocation
pub fn Incrementing(comptime T: type, comptime prefix: []const u8) type {
    // +1 for the '-' separator
    const NUMERIC_START = prefix.len + 1;
    const MAX_BYTES = NUMERIC_START + switch (T) {
        u8 => 3,
        u16 => 5,
        u32 => 10,
        u64 => 20,
        else => @compileError("Incrementing must be given an unsigned int type, got: " ++ @typeName(T)),
    };

    const buffer = blk: {
        var b = [_]u8{0} ** MAX_BYTES;
        @memcpy(b[0..prefix.len], prefix);
        b[prefix.len] = '-';
        break :blk b;
    };

    const PrefixIntType = @Type(.{ .int = .{
        .bits = NUMERIC_START * 8,
        .signedness = .unsigned,
    } });

    const PREFIX_INT_CODE: PrefixIntType = @bitCast(buffer[0..NUMERIC_START].*);

    return struct {
        counter: T = 0,
        buffer: [MAX_BYTES]u8 = buffer,

        const Self = @This();

        pub fn next(self: *Self) []const u8 {
            const counter = self.counter;
            const n = counter +% 1;
            defer self.counter = n;

            const size = std.fmt.printInt(self.buffer[NUMERIC_START..], n, 10, .lower, .{});
            return self.buffer[0 .. NUMERIC_START + size];
        }

        // extracts the numeric portion from an ID
        pub fn parse(str: []const u8) !T {
            if (str.len <= NUMERIC_START) {
                return error.InvalidId;
            }

            if (@as(PrefixIntType, @bitCast(str[0..NUMERIC_START].*)) != PREFIX_INT_CODE) {
                return error.InvalidId;
            }

            return std.fmt.parseInt(T, str[NUMERIC_START..], 10) catch {
                return error.InvalidId;
            };
        }
    };
}

pub fn uuidv4(hex: []u8) void {
    std.debug.assert(hex.len == 36);

    var bin: [16]u8 = undefined;
    std.crypto.random.bytes(&bin);
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
test "id: Incrementing.next" {
    var id = Incrementing(u16, "IDX"){};
    try testing.expectEqualStrings("IDX-1", id.next());
    try testing.expectEqualStrings("IDX-2", id.next());
    try testing.expectEqualStrings("IDX-3", id.next());

    // force a wrap
    id.counter = 65533;
    try testing.expectEqualStrings("IDX-65534", id.next());
    try testing.expectEqualStrings("IDX-65535", id.next());
    try testing.expectEqualStrings("IDX-0", id.next());
}

test "id: Incrementing.parse" {
    const ReqId = Incrementing(u32, "REQ");
    try testing.expectError(error.InvalidId, ReqId.parse(""));
    try testing.expectError(error.InvalidId, ReqId.parse("R"));
    try testing.expectError(error.InvalidId, ReqId.parse("RE"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ-"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ--1"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ--"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ-Nope"));
    try testing.expectError(error.InvalidId, ReqId.parse("REQ-4294967296"));

    try testing.expectEqual(0, try ReqId.parse("REQ-0"));
    try testing.expectEqual(99, try ReqId.parse("REQ-99"));
    try testing.expectEqual(4294967295, try ReqId.parse("REQ-4294967295"));
}

test "id: uuiv4" {
    const expectUUID = struct {
        fn expect(uuid: [36]u8) !void {
            for (uuid, 0..) |b, i| {
                switch (b) {
                    '0'...'9', 'a'...'z' => {},
                    '-' => {
                        if (i != 8 and i != 13 and i != 18 and i != 23) {
                            return error.InvalidEncoding;
                        }
                    },
                    else => return error.InvalidHexEncoding,
                }
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
