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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

/// https://w3c.github.io/FileAPI/#blob-section
/// https://developer.mozilla.org/en-US/docs/Web/API/Blob
const Blob = @This();

pub const _prototype_root = true;

_type: Type,

/// Immutable slice of blob.
/// Note that another blob may hold a pointer/slice to this,
/// so its better to leave the deallocation of it to arena allocator.
_slice: []const u8,
/// MIME attached to blob. Can be an empty string.
_mime: []const u8,

pub const Type = union(enum) {
    generic,
    file: *@import("File.zig"),
};

const InitOptions = struct {
    /// MIME type.
    type: []const u8 = "",
    /// How to handle line endings (CR and LF).
    /// `transparent` means do nothing, `native` expects CRLF (\r\n) on Windows.
    endings: []const u8 = "transparent",
};

/// Creates a new Blob.
pub fn init(
    maybe_blob_parts: ?[]const []const u8,
    maybe_options: ?InitOptions,
    page: *Page,
) !*Blob {
    const options: InitOptions = maybe_options orelse .{};
    // Setup MIME; This can be any string according to my observations.
    const mime: []const u8 = blk: {
        const t = options.type;
        if (t.len == 0) {
            break :blk "";
        }

        break :blk try page.arena.dupe(u8, t);
    };

    const data = blk: {
        if (maybe_blob_parts) |blob_parts| {
            var w: Writer.Allocating = .init(page.arena);
            const use_native_endings = std.mem.eql(u8, options.endings, "native");
            try writeBlobParts(&w.writer, blob_parts, use_native_endings);

            break :blk w.written();
        }

        break :blk "";
    };

    return page._factory.create(Blob{
        ._type = .generic,
        ._slice = data,
        ._mime = mime,
    });
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
                const data = part[end..][0..vector_len];
                const chunk: Vec = data.*;
                // Look for CR.
                const match = chunk == cr;

                // Create a bitset out of match vector.
                const bitset = std.bit_set.IntegerBitSet(vector_len){
                    .mask = @bitCast(@intFromBool(match)),
                };

                var iter = bitset.iterator(.{});
                var relative_start: usize = 0;
                while (iter.next()) |index| {
                    _ = try writer.writeVec(&.{ data[relative_start..index], "\n" });

                    if (index + 1 != data.len and data[index + 1] == '\n') {
                        relative_start = index + 2;
                    } else {
                        relative_start = index + 1;
                    }
                }

                _ = try writer.writeVec(&.{data[relative_start..]});
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
pub fn arrayBuffer(self: *const Blob, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(js.ArrayBuffer{ .values = self._slice });
}

const ReadableStream = @import("streams/ReadableStream.zig");
/// Returns a ReadableStream which upon reading returns the data
/// contained within the Blob.
pub fn stream(self: *const Blob, page: *Page) !*ReadableStream {
    return ReadableStream.initWithData(self._slice, page);
}

/// Returns a Promise that resolves with a string containing
/// the contents of the blob, interpreted as UTF-8.
pub fn text(self: *const Blob, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(self._slice);
}

/// Extension to Blob; works on Firefox and Safari.
/// https://developer.mozilla.org/en-US/docs/Web/API/Blob/bytes
/// Returns a Promise that resolves with a Uint8Array containing
/// the contents of the blob as an array of bytes.
pub fn bytes(self: *const Blob, page: *Page) !js.Promise {
    return page.js.local.?.resolvePromise(js.TypedArray(u8){ .values = self._slice });
}

/// Returns a new Blob object which contains data
/// from a subset of the blob on which it's called.
pub fn slice(
    self: *const Blob,
    maybe_start: ?i32,
    maybe_end: ?i32,
    maybe_content_type: ?[]const u8,
    page: *Page,
) !*Blob {
    const mime: []const u8 = blk: {
        if (maybe_content_type) |content_type| {
            if (content_type.len == 0) {
                break :blk "";
            }

            break :blk try page.dupeString(content_type);
        }

        break :blk "";
    };

    const data = self._slice;
    if (maybe_start) |_start| {
        const start = blk: {
            if (_start < 0) {
                break :blk data.len -| @abs(_start);
            }

            break :blk @min(data.len, @as(u31, @intCast(_start)));
        };

        const end: usize = blk: {
            if (maybe_end) |_end| {
                if (_end < 0) {
                    break :blk @max(start, data.len -| @abs(_end));
                }

                break :blk @min(data.len, @max(start, @as(u31, @intCast(_end))));
            }

            break :blk data.len;
        };

        return page._factory.create(Blob{
            ._type = .generic,
            ._slice = data[start..end],
            ._mime = mime,
        });
    }

    return page._factory.create(Blob{
        ._type = .generic,
        ._slice = data,
        ._mime = mime,
    });
}

/// Returns the size of the Blob in bytes.
pub fn getSize(self: *const Blob) usize {
    return self._slice.len;
}

/// Returns the type of Blob; likely a MIME type, yet anything can be given.
pub fn getType(self: *const Blob) []const u8 {
    return self._mime;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Blob);

    pub const Meta = struct {
        pub const name = "Blob";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Blob.init, .{});
    pub const text = bridge.function(Blob.text, .{});
    pub const bytes = bridge.function(Blob.bytes, .{});
    pub const slice = bridge.function(Blob.slice, .{});
    pub const size = bridge.accessor(Blob.getSize, null, .{});
    pub const @"type" = bridge.accessor(Blob.getType, null, .{});
    pub const stream = bridge.function(Blob.stream, .{});
    pub const arrayBuffer = bridge.function(Blob.arrayBuffer, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Blob" {
    try testing.htmlRunner("blob.html", .{});
}
