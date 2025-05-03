const std = @import("std");
const Allocator = std.mem.Allocator;

// Represents https://developer.mozilla.org/en-US/docs/Web/URI/Reference/Schemes/data
pub const DataURI = struct {
    was_base64_encoded: bool,
    // The contents in the uri. It will be base64 decoded but not prepared in
    // any way for mime.charset.
    data: []const u8,

    // Parses data:[<media-type>][;base64],<data>
    pub fn parse(allocator: Allocator, src: []const u8) !?DataURI {
        if (!std.mem.startsWith(u8, src, "data:")) {
            return null;
        }

        const uri = src[5..];
        const data_starts = std.mem.indexOfScalar(u8, uri, ',') orelse return null;

        // Extract the encoding.
        var metadata = uri[0..data_starts];
        var base64_encoded = false;
        if (std.mem.endsWith(u8, metadata, ";base64")) {
            base64_encoded = true;
            metadata = metadata[0 .. metadata.len - 7];
        }

        // TODO: Extract mime type. This not trivial because Mime.parse requires
        // a []u8 and might mutate the src. And, the DataURI.parse references atm
        // do not have deinit calls.

        // Prepare the data.
        var data = uri[data_starts + 1 ..];
        if (base64_encoded) {
            const decoder = std.base64.standard.Decoder;
            const decoded_size = try decoder.calcSizeForSlice(data);

            const buffer = try allocator.alloc(u8, decoded_size);
            errdefer allocator.free(buffer);

            try decoder.decode(buffer, data);
            data = buffer;
        }

        return .{
            .was_base64_encoded = base64_encoded,
            .data = data,
        };
    }

    pub fn deinit(self: *const DataURI, allocator: Allocator) void {
        if (self.was_base64_encoded) {
            allocator.free(self.data);
        }
    }
};

const testing = std.testing;
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
    const data_uri = try DataURI.parse(std.testing.allocator, uri) orelse return error.TestFailed;
    defer data_uri.deinit(testing.allocator);
    try testing.expectEqualStrings(expected, data_uri.data);
}

fn test_cannot_parse(uri: []const u8) !void {
    try testing.expectEqual(null, DataURI.parse(std.testing.allocator, uri));
}
