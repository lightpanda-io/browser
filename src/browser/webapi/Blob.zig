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

const Writer = std.Io.Writer;
const Execution = js.Execution;

/// https://w3c.github.io/FileAPI/#blob-section
/// https://developer.mozilla.org/en-US/docs/Web/API/Blob
const Blob = @This();

pub const _prototype_root = true;

_type: Type,
_rc: lp.RC,

_arena: *lp.Arena,

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

// Stored in Page.blob_urls.
pub const UrlEntry = struct {
    blob: *Blob,
    creator: u32, // frame_id of creator
};
pub const UrlMap = std.StringHashMapUnmanaged(UrlEntry);

// A blob URL is encoded as: blob:{origin}/{uuid}. So, given an origin, we can
// check if it should be able to access a given bolb URL.
pub fn urlBelongsToOrigin(url: []const u8, origin_: ?[]const u8) bool {
    const origin = origin_ orelse "null";
    if (!std.mem.startsWith(u8, url, "blob:")) {
        return false;
    }
    const rest = url["blob:".len..];
    return rest.len > origin.len and rest[origin.len] == '/' and std.mem.startsWith(u8, rest, origin);
}

const InitOptions = struct {
    /// How to handle line endings (CR and LF).
    /// `transparent` means do nothing, `native` expects CRLF (\r\n) on Windows.
    endings: []const u8 = "transparent",
    /// MIME type.
    type: []const u8 = "",
};

/// Creates a new Blob from JS values with optional MIME validation.
/// This is the JS Constructor
pub fn init(parts_: ?js.Value, opts_: ?js.Value, exec: *const Execution) !*Blob {
    const parts = if (parts_) |p| try collectParts(p, exec) else null;
    const blob = try buildValue(parts, blk: {
        const o = opts_ orelse break :blk .{};
        break :blk (try o.toZig(?InitOptions)) orelse .{};
    }, exec);
    errdefer blob._arena.release();

    const self = try blob._arena.create(Blob);
    self.* = blob;

    blob._arena.report();
    return self;
}

pub fn collectParts(value: js.Value, exec: *const Execution) !?[]const []const u8 {
    if (value.isUndefined()) {
        return null;
    }
    const it = (try value.iterator()) orelse return error.TypeError;

    var parts: std.ArrayList([]const u8) = .empty;
    while (try it.next()) |part| {
        try parts.append(exec.call_arena, try part.toStringSmart());
    }
    return parts.items;
}

pub fn buildValue(parts_: ?[]const []const u8, opts: InitOptions, exec: *const Execution) !Blob {
    const use_native_endings = blk: {
        if (std.mem.eql(u8, opts.endings, "native")) {
            break :blk true;
        }
        if (std.mem.eql(u8, opts.endings, "transparent")) {
            break :blk false;
        }
        return error.TypeError;
    };

    const data, const arena = blk: {
        const parts = parts_ orelse {
            break :blk .{ "", try exec.getPinnedArena(.tiny, "Blob") };
        };
        var len: usize = 0;
        for (parts) |part| {
            len += part.len;
        }
        // +256, ~struct overhead, mime dupe, ...
        const arena = try exec.getPinnedArena(len + 256, "blob");

        const buf = try arena.alloc(u8, len);
        var w: Writer = .fixed(buf);

        for (parts) |part| {
            try writePartWithEndings(part, use_native_endings, &w);
        }
        break :blk .{ w.buffered(), arena };
    };

    const mime = try normalizeType(arena.allocator(), opts.type);

    return .{
        ._rc = .{},
        ._arena = arena,
        ._type = .generic,
        ._slice = data,
        ._mime = mime,
    };
}

pub fn buildValueFromBytes(arena: *lp.Arena, data: []const u8, content_type: []const u8) !Blob {
    return .{
        ._rc = .{},
        ._arena = arena,
        ._type = .generic,
        ._slice = try arena.dupe(u8, data),
        ._mime = try normalizeType(arena.allocator(), content_type),
    };
}

// Blob's type is NOT a MIME Type. Far less strict.
fn normalizeType(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) {
        return "";
    }
    for (input) |c| {
        if (c < 0x20 or c > 0x7E) {
            return "";
        }
    }
    return std.ascii.allocLowerString(arena, input);
}

/// Creates a new Blob from raw byte slices (for internal Zig use).
pub fn initFromBytes(data: []const u8, content_type: []const u8, exec: *const Execution) !*Blob {
    const arena = try exec.getPinnedArena(data.len + content_type.len + 256, "Blob");
    errdefer arena.release();

    const self = try arena.create(Blob);
    self.* = try buildValueFromBytes(arena, data, content_type);
    arena.report();
    return self;
}

pub fn deinit(self: *Blob, _: *Page) void {
    self._arena.release();
}

pub fn releaseRef(self: *Blob, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *Blob) void {
    self._rc.acquire();
}

pub fn structuredSerialize(self: *const Blob, writer: *js.StructuredWriter) !void {
    writer.writeBytes(self._mime);
    writer.writeBytes(self._slice);
}

pub fn structuredDeserialize(reader: *js.StructuredReader, page: *Page) !*Blob {
    const mime = try reader.readBytes();
    const data = try reader.readBytes();

    const arena = try page.getPinnedArena(data.len + mime.len + 256, "Blob.clone");
    errdefer arena.release();

    const self = try arena.create(Blob);
    self.* = .{
        ._rc = .{},
        ._arena = arena,
        ._type = .generic,
        ._slice = try arena.dupe(u8, data),
        // the serialized mime is already in normalized form; copy it verbatim
        ._mime = try arena.dupe(u8, mime),
    };
    arena.report();
    return self;
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
pub fn writePartWithEndings(part: []const u8, use_native_endings: bool, writer: *Writer) !void {
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
pub fn arrayBuffer(self: *const Blob, exec: *Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(js.ArrayBuffer{ .values = self._slice });
}

const ReadableStream = @import("streams/ReadableStream.zig");
/// Returns a ReadableStream which upon reading returns the data
/// contained within the Blob.
pub fn stream(self: *const Blob, exec: *Execution) !*ReadableStream {
    return ReadableStream.initWithData(self._slice, exec);
}

pub fn textStream(self: *const Blob, exec: *const Execution) !*ReadableStream {
    return ReadableStream.initWithText(self._slice, exec);
}

/// Returns a Promise that resolves with a string containing
/// the contents of the blob, interpreted as UTF-8.
pub fn text(self: *const Blob, exec: *Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(self._slice);
}

/// Extension to Blob; works on Firefox and Safari.
/// https://developer.mozilla.org/en-US/docs/Web/API/Blob/bytes
/// Returns a Promise that resolves with a Uint8Array containing
/// the contents of the blob as an array of bytes.
pub fn bytes(self: *const Blob, exec: *Execution) !js.Promise {
    return exec.js.local.?.resolvePromise(js.TypedArray(u8){ .values = self._slice });
}

/// Returns a new Blob object which contains data
/// from a subset of the blob on which it's called.
pub fn slice(
    self: *const Blob,
    start_: ?f64,
    end_: ?f64,
    content_type_: ?js.NullableString,
    exec: *const Execution,
) !*Blob {
    const data = self._slice;
    const size: i64 = @intCast(data.len);

    const relative_start: i64 = blk: {
        const requested = clampLongLong(start_ orelse break :blk 0);
        break :blk if (requested < 0) @max(size + requested, 0) else @min(requested, size);
    };

    const relative_end: i64 = blk: {
        const requested = clampLongLong(end_ orelse break :blk size);
        break :blk if (requested < 0) @max(size + requested, 0) else @min(requested, size);
    };

    const start: usize = @intCast(relative_start);
    const span: usize = @intCast(@max(relative_end - relative_start, 0));

    const content_type = if (content_type_) |c| c.value else "";
    return Blob.initFromBytes(data[start..][0..span], content_type, exec);
}

// NaN -> 0
// .5 rounds to even,
fn clampLongLong(value: f64) i64 {
    if (std.math.isNan(value)) {
        return 0;
    }

    const min = -9223372036854775808.0;
    const max = 9223372036854775807.0;
    if (value <= min) {
        return std.math.minInt(i64);
    }
    if (value >= max) {
        return std.math.maxInt(i64);
    }

    var rounded = @round(value);
    if (@abs(value - @trunc(value)) == 0.5 and @mod(rounded, 2) != 0) {
        rounded -= std.math.sign(value);
    }
    return @trunc(rounded);
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
    pub const textStream = bridge.function(Blob.textStream, .{});
    pub const arrayBuffer = bridge.function(Blob.arrayBuffer, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Blob" {
    try testing.htmlRunner("blob.html", .{});
}

test "Blob: a pinned arena reaches the browser's account and is given back" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const page = frame._page;
    const browser = frame._session.browser;

    browser.flushArenaMemory();
    try testing.expectEqual(0, browser.arena_account.pending);

    const data = [_]u8{'x'} ** (64 * 1024);
    const blob = try Blob.initFromBytes(&data, "text/plain", &frame.js.execution);
    try testing.expect(browser.arena_account.pending >= data.len);

    // The finalizer path hands every reported byte back.
    blob.deinit(page);
    try testing.expectEqual(0, browser.arena_account.pending);
}
