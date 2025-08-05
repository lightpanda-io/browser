const std = @import("std");
const Allocator = std.mem.Allocator;

// Parses data:[<media-type>][;base64],<data>
pub fn parse(allocator: Allocator, src: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, src, "data:")) {
        return null;
    }

    const uri = src[5..];
    const data_starts = std.mem.indexOfScalar(u8, uri, ',') orelse return null;

    var data = uri[data_starts + 1 ..];

    // Extract the encoding.
    const metadata = uri[0..data_starts];
    if (std.mem.endsWith(u8, metadata, ";base64")) {
        const decoder = std.base64.standard.Decoder;
        const decoded_size = try decoder.calcSizeForSlice(data);

        const buffer = try allocator.alloc(u8, decoded_size);
        errdefer allocator.free(buffer);

        try decoder.decode(buffer, data);
        data = buffer;
    }

    return data;
}

const testing = @import("../testing.zig");
test "DataURI: parse valid" {
    try test_valid("data:text/javascript; charset=utf-8;base64,Zm9v", "foo");
    try test_valid("data:text/javascript; charset=utf-8;,foo", "foo");
    try test_valid("data:,foo", "foo");
}

test "DataURI: parse invalid" {
    try test_cannot_parse("atad:,foo");
    try test_cannot_parse("data:foo");
    try test_cannot_parse("data:");
}

fn test_valid(uri: []const u8, expected: []const u8) !void {
    defer testing.reset();
    const data_uri = try parse(testing.arena_allocator, uri) orelse return error.TestFailed;
    try testing.expectEqual(expected, data_uri);
}

fn test_cannot_parse(uri: []const u8) !void {
    try testing.expectEqual(null, parse(undefined, uri));
}
