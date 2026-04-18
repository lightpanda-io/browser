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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Session = @import("../Session.zig");

const Mime = @import("../Mime.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// https://w3c.github.io/FileAPI/#blob-section
/// https://developer.mozilla.org/en-US/docs/Web/API/Blob
const Blob = @This();

pub const _prototype_root = true;

_type: Type,
_rc: lp.RC(u32),

_arena: Allocator,

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

/// Creates a new Blob from JS values with optional MIME validation.
/// This is the JS Constructor
pub fn init(parts_: ?[]const js.Value, opts_: ?InitOptions, page: *Page) !*Blob {
    const arena = try page.getArena(.large, "Blob");
    errdefer page.releaseArena(arena);

    const opts: InitOptions = opts_ orelse .{};
    const mime = try validateMimeType(arena, opts.type, false);

    const data = blk: {
        if (parts_) |blob_parts| {
            const use_native_endings = std.mem.eql(u8, opts.endings, "native");
            var w: Writer.Allocating = .init(arena);
            for (blob_parts) |js_val| {
                const part = try js_val.toStringSmart();
                try writePartWithEndings(part, use_native_endings, &w.writer);
            }
            break :blk w.written();
        }

        break :blk "";
    };

    const self = try arena.create(Blob);
    self.* = .{
        ._rc = .{},
        ._arena = arena,
        ._type = .generic,
        ._slice = data,
        ._mime = mime,
    };
    return self;
}

/// Creates a new Blob from raw byte slices (for internal Zig use).
pub fn initFromBytes(data: []const u8, content_type: []const u8, validate_mime: bool, page: *Page) !*Blob {
    const arena = try page.getArena(.large, "Blob");
    errdefer page.releaseArena(arena);

    const mime = try validateMimeType(arena, content_type, validate_mime);

    const self = try arena.create(Blob);
    self.* = .{
        ._rc = .{},
        ._arena = arena,
        ._type = .generic,
        ._slice = try arena.dupe(u8, data),
        ._mime = mime,
    };
    return self;
}

/// Validates and normalizes MIME type according to spec.
fn validateMimeType(arena: Allocator, mime_type: []const u8, full_validation: bool) ![]const u8 {
    if (mime_type.len == 0) {
        return "";
    }

    const buf = try arena.dupe(u8, mime_type);

    if (full_validation) {
        // Full MIME parsing per MIME sniff spec (for Content-Type headers)
        _ = Mime.parse(buf) catch return "";
    } else {
        // Simple validation per FileAPI spec (for Blob constructor):
        // - If any char is outside U+0020-U+007E, return empty string
        // - Otherwise lowercase
        for (mime_type) |c| {
            if (c < 0x20 or c > 0x7E) {
                return "";
            }
        }
        _ = std.ascii.lowerString(buf, buf);
    }

    return buf;
}

pub fn deinit(self: *Blob, session: *Session) void {
    session.releaseArena(self._arena);
}

pub fn releaseRef(self: *Blob, session: *Session) void {
    self._rc.release(self, session);
}

pub fn acquireRef(self: *Blob) void {
    self._rc.acquire();
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

/// Writes a single part with optional line ending normalization.
fn writePartWithEndings(part: []const u8, use_native_endings: bool, writer: *Writer) !void {
    // Transparent - no conversion needed.
    if (!use_native_endings) {
        try writer.writeAll(part);
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

            // Part ends with CR. We need to remember this for next part.
            if (end + 1 == part.len) {
                return;
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
    start_: ?i32,
    end_: ?i32,
    content_type_: ?[]const u8,
    page: *Page,
) !*Blob {
    const data = self._slice;

    const start = blk: {
        const requested_start = start_ orelse break :blk 0;
        if (requested_start < 0) {
            break :blk data.len -| @abs(requested_start);
        }
        break :blk @min(data.len, @as(u31, @intCast(requested_start)));
    };

    const end: usize = blk: {
        const requested_end = end_ orelse break :blk data.len;
        if (requested_end < 0) {
            break :blk @max(start, data.len -| @abs(requested_end));
        }

        break :blk @min(data.len, @max(start, @as(u31, @intCast(requested_end))));
    };

    return Blob.initFromBytes(data[start..end], content_type_ orelse "", false, page);
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
