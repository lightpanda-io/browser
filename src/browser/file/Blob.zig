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

const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

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
    /// How to handle newline (LF) characters.
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

    if (maybe_blob_parts) |blob_parts| {
        var w: Writer.Allocating = .init(page.arena);
        const use_native_endings = std.mem.eql(u8, options.endings, "native");
        try writeBlobParts(&w.writer, blob_parts, use_native_endings);

        const written = w.written();

        return .{ .slice = written, .mime = options.type };
    }

    // We don't have `blob_parts`, why would you want a Blob anyway then?
    return .{ .slice = "", .mime = options.type };
}

/// Writes blob parts to given `Writer` by desired encoding.
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
    // TODO: Vector search.

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
        var start = end;
        while (end < part.len) {
            if (part[end] == '\r') {
                try writer.writeAll(part[start..end]);
                try writer.writeByte('\n');

                // Part ends with CR. We can continue to next part.
                if (end + 1 == part.len) {
                    continue :scan_parts;
                }

                // If next char is LF, skip it too.
                if (part[end + 1] == '\n') {
                    start = end + 2;
                } else {
                    start = end + 1;
                }
            }

            end += 1;
        }

        // Write the remaining. We get this in such situations:
        // `the quick brown\rfox`
        // `the quick brown\r\nfox`
        try writer.writeAll(part[start..end]);
    }
}

// TODO: Blob.arrayBuffer.
// https://developer.mozilla.org/en-US/docs/Web/API/Blob/arrayBuffer

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
    const resolver = page.js.createPromiseResolver(.none);
    try resolver.resolve(self.slice);
    return resolver.promise();
}

/// Extension to Blob; works on Firefox and Safari.
/// https://developer.mozilla.org/en-US/docs/Web/API/Blob/bytes
/// Returns a Promise that resolves with a Uint8Array containing
/// the contents of the blob as an array of bytes.
pub fn _bytes(self: *const Blob, page: *Page) !js.Promise {
    const resolver = page.js.createPromiseResolver(.none);
    try resolver.resolve(js.TypedArray(u8){ .values = self.slice });
    return resolver.promise();
}

/// Returns the size of the Blob in bytes.
pub fn get_size(self: *const Blob) usize {
    return self.slice.len;
}

const testing = @import("../../testing.zig");
test "Browser: File.Blob" {
    try testing.htmlRunner("file/blob.html");
}
