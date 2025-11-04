// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const Writer = std.Io.Writer;

const Page = @import("../page.zig").Page;
const js = @import("../js/js.zig");

const ReadableStream = @import("../streams/ReadableStream.zig");

/// https://w3c.github.io/FileAPI/#blob-section
/// https://developer.mozilla.org/en-US/docs/Web/API/Blob
const Blob = @This();

/// Immutable slice of blob.
/// Note that another blob may hold a pointer/slice to this,
/// so its better to leave the deallocation of it to arena allocator.
slice: []const u8,
/// MIME attached to blob. Can be an empty string.
mime: []const u8,

const ConstructorOptions = struct {
    /// MIME type.
    type: []const u8 = "",
    /// How to handle line endings (CR and LF).
    /// `transparent` means do nothing, `native` expects CRLF (\r\n) on Windows.
    endings: []const u8 = "transparent",
};

/// Creates a new Blob.
pub fn constructor(
    maybe_blob_parts: ?[]const []const u8,
    maybe_options: ?ConstructorOptions,
    page: *Page,
) !Blob {
    const options: ConstructorOptions = maybe_options orelse .{};
    // Setup MIME; This can be any string according to my observations.
    const mime: []const u8 = blk: {
        const t = options.type;
        if (t.len == 0) {
            break :blk "";
        }

        break :blk try page.arena.dupe(u8, t);
    };

    if (maybe_blob_parts) |blob_parts| {
        var w: Writer.Allocating = .init(page.arena);
        const use_native_endings = std.mem.eql(u8, options.endings, "native");
        try writeBlobParts(&w.writer, blob_parts, use_native_endings);

        return .{ .slice = w.written(), .mime = mime };
    }

    // We don't have `blob_parts`, why would you want a Blob anyway then?
    return .{ .slice = "", .mime = mime };
}

const largest_vector = @max(std.simd.suggestVectorLength(u8) orelse 1, 8);
/// Array of possible vector sizes for the current arch in decrementing order.
/// We may move this to some file for SIMD helpers in the future.
const vector_sizes = blk: {
    // Required for length calculation.
    var n: usize = largest_vector;
    var total: usize = 0;
    while (n != 2) : (n /= 2) total += 1;
    // Populate an array with vector sizes.
    n = largest_vector;
    var i: usize = 0;
    var items: [total]usize = undefined;
    while (n != 2) : (n /= 2) {
        defer i += 1;
        items[i] = n;
    }

    break :blk items;
};

/// Writes blob parts to given `Writer` with desired endings.
fn writeBlobParts(
    writer: *Writer,
    blob_parts: []const []const u8,
    use_native_endings: bool,
) !void {
    // Transparent.
    if (!use_native_endings) {
        for (blob_parts) |part| {
            try writer.writeAll(part);
        }

        return;
    }

    // TODO: Windows support.

    // Linux & Unix.
    // Both Firefox and Chrome implement it as such:
    // CRLF => LF
    // CR   => LF
    // So even though CR is not followed by LF, it gets replaced.
    //
    // I believe this is because such scenario is possible:
    // ```
    // let parts = [ "the quick\r", "\nbrown fox" ];
    // ```
    // In the example, one should have to check the part before in order to
    // understand that CRLF is being presented in the final buffer.
    // So they took a simpler approach, here's what given blob parts produce:
    // ```
    // "the quick\n\nbrown fox"
    // ```
    scan_parts: for (blob_parts) |part| {
        var end: usize = 0;

        inline for (vector_sizes) |vector_len| {
            const Vec = @Vector(vector_len, u8);

            while (end + vector_len <= part.len) : (end += vector_len) {
                const cr: Vec = @splat('\r');
                // Load chunk as vectors.
                const slice = part[end..][0..vector_len];
                const chunk: Vec = slice.*;
                // Look for CR.
                const match = chunk == cr;

                // Create a bitset out of match vector.
                const bitset = std.bit_set.IntegerBitSet(vector_len){
                    .mask = @bitCast(@intFromBool(match)),
                };

                var iter = bitset.iterator(.{});
                var relative_start: usize = 0;
                while (iter.next()) |index| {
                    _ = try writer.writeVec(&.{ slice[relative_start..index], "\n" });

                    if (index + 1 != slice.len and slice[index + 1] == '\n') {
                        relative_start = index + 2;
                    } else {
                        relative_start = index + 1;
                    }
                }

                _ = try writer.writeVec(&.{slice[relative_start..]});
            }
        }

        // Scalar scan fallback.
        var relative_start: usize = end;
        while (end < part.len) {
            if (part[end] == '\r') {
                _ = try writer.writeVec(&.{ part[relative_start..end], "\n" });

                // Part ends with CR. We can continue to next part.
                if (end + 1 == part.len) {
                    continue :scan_parts;
                }

                // If next char is LF, skip it too.
                if (part[end + 1] == '\n') {
                    relative_start = end + 2;
                } else {
                    relative_start = end + 1;
                }
            }

            end += 1;
        }

        // Write the remaining. We get this in such situations:
        // `the quick brown\rfox`
        // `the quick brown\r\nfox`
        try writer.writeAll(part[relative_start..end]);
    }
}

/// Returns a Promise that resolves with the contents of the blob
/// as binary data contained in an ArrayBuffer.
pub fn _arrayBuffer(self: *const Blob, page: *Page) !js.Promise {
    return page.js.resolvePromise(js.ArrayBuffer{ .values = self.slice });
}

/// Returns a ReadableStream which upon reading returns the data
/// contained within the Blob.
pub fn _stream(self: *const Blob, page: *Page) !*ReadableStream {
    const stream = try ReadableStream.constructor(null, null, page);
    try stream.queue.append(page.arena, .{
        .uint8array = .{ .values = self.slice },
    });
    return stream;
}

/// Returns a Promise that resolves with a string containing
/// the contents of the blob, interpreted as UTF-8.
pub fn _text(self: *const Blob, page: *Page) !js.Promise {
    return page.js.resolvePromise(self.slice);
}

/// Extension to Blob; works on Firefox and Safari.
/// https://developer.mozilla.org/en-US/docs/Web/API/Blob/bytes
/// Returns a Promise that resolves with a Uint8Array containing
/// the contents of the blob as an array of bytes.
pub fn _bytes(self: *const Blob, page: *Page) !js.Promise {
    return page.js.resolvePromise(js.TypedArray(u8){ .values = self.slice });
}

/// Returns a new Blob object which contains data
/// from a subset of the blob on which it's called.
pub fn _slice(
    self: *const Blob,
    maybe_start: ?i32,
    maybe_end: ?i32,
    maybe_content_type: ?[]const u8,
    page: *Page,
) !Blob {
    const mime: []const u8 = blk: {
        if (maybe_content_type) |content_type| {
            if (content_type.len == 0) {
                break :blk "";
            }

            break :blk try page.arena.dupe(u8, content_type);
        }

        break :blk "";
    };

    const slice = self.slice;
    if (maybe_start) |_start| {
        const start = blk: {
            if (_start < 0) {
                break :blk slice.len -| @abs(_start);
            }

            break :blk @min(slice.len, @as(u31, @intCast(_start)));
        };

        const end: usize = blk: {
            if (maybe_end) |_end| {
                if (_end < 0) {
                    break :blk @max(start, slice.len -| @abs(_end));
                }

                break :blk @min(slice.len, @max(start, @as(u31, @intCast(_end))));
            }

            break :blk slice.len;
        };

        return .{ .slice = slice[start..end], .mime = mime };
    }

    return .{ .slice = slice, .mime = mime };
}

/// Returns the size of the Blob in bytes.
pub fn get_size(self: *const Blob) usize {
    return self.slice.len;
}

/// Returns the type of Blob; likely a MIME type, yet anything can be given.
pub fn get_type(self: *const Blob) []const u8 {
    return self.mime;
}

const testing = @import("../../testing.zig");
test "Browser: File.Blob" {
    try testing.htmlRunner("file/blob.html");
}
