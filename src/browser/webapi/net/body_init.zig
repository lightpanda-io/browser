// Copyright (C) 2026  Lightpanda (Selecy SAS)
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

// BodyInit — accepted body shapes for fetch(Request) / XHR.send().
//
// Per Fetch §6.5 "extract a body" (https://fetch.spec.whatwg.org/#concept-bodyinit-extract)
// and XHR §4.7.6 "send()" (https://xhr.spec.whatwg.org/#dom-xmlhttprequest-send),
// the runtime must serialize the body and select the matching default
// Content-Type. Without this layer the JS→Zig bridge falls back to
// toStringSmart() on the JSValue, which sends "[object FormData]" for
// FormData (issue #2357) and skips the multipart encoding wired up at
// FormData.multipartEncode (./FormData.zig:198).
//
// The union arms are ordered so the bridge's tagged-union prober matches
// the most specific JsApi class first; the trailing `bytes: []const u8`
// arm soaks up strings (and via .coerce, anything string-like) so plain
// text bodies still work unchanged.

const std = @import("std");

const Blob = @import("../Blob.zig");

const FormData = @import("FormData.zig");
const URLSearchParams = @import("URLSearchParams.zig");

const Allocator = std.mem.Allocator;

pub const BodyInit = union(enum) {
    blob: *Blob,
    form_data: *FormData,
    url_search_params: *URLSearchParams,
    bytes: []const u8, // must be last, js.Bridge will map anything to a string

    pub fn extract(self: BodyInit, arena: Allocator) !Extracted {
        switch (self) {
            .bytes => |b| {
                // String bodies: dupe as-is. Per Fetch §6.5 step 4, the default
                // Content-Type for USVString is "text/plain;charset=UTF-8";
                // emit it so callers without an explicit header still pass spec
                // checks. Pre-fix behaviour also omitted this; tests that depend
                // on no Content-Type for string bodies should set one explicitly.
                return .{
                    .bytes = try arena.dupe(u8, b),
                    .content_type = "text/plain;charset=UTF-8",
                };
            },
            .url_search_params => |usp| {
                var buf = std.Io.Writer.Allocating.init(arena);
                try usp.toString(&buf.writer);
                return .{
                    .bytes = buf.written(),
                    .content_type = "application/x-www-form-urlencoded;charset=UTF-8",
                };
            },
            .form_data => |fd| {
                var rand_bytes: [10]u8 = undefined;
                std.crypto.random.bytes(&rand_bytes);
                const hex = std.fmt.bytesToHex(rand_bytes, .lower);

                var boundary: [24]u8 = undefined;
                @memcpy(boundary[0..4], "----");
                @memcpy(boundary[4..], &hex);

                var buf = std.Io.Writer.Allocating.init(arena);
                try fd.write(.{
                    .allocator = arena,
                    .encoding = .{ .formdata = &boundary },
                }, &buf.writer);

                const ct = try std.fmt.allocPrint(arena, "multipart/form-data; boundary={s}", .{boundary});
                return .{
                    .bytes = buf.written(),
                    .content_type = ct,
                };
            },
            .blob => |blob| {
                return .{
                    .bytes = try arena.dupe(u8, blob._slice),
                    .content_type = if (blob._mime.len > 0) try arena.dupe(u8, blob._mime) else null,
                };
            },
        }
    }
};

// Result of extracting a body. `bytes` is duped into the caller's arena.
// `content_type`, when non-null, is the spec-mandated default Content-Type
// for the body source — callers MUST only apply it if the user has not
// already set a Content-Type header (per Fetch §6.5).
pub const Extracted = struct {
    bytes: []const u8,
    content_type: ?[]const u8,
};

const testing = @import("../../../testing.zig");
test "BodyInit: bytes pass through with text/plain" {
    defer testing.reset();
    const r = try (BodyInit{ .bytes = "hello" }).extract(testing.arena_allocator);
    try testing.expectString("hello", r.bytes);
    try testing.expectString("text/plain;charset=UTF-8", r.content_type.?);
}

test "BodyInit: URLSearchParams emit urlencoded body + content-type" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    const usp = try arena.create(URLSearchParams);
    usp.* = .{ ._arena = arena, ._params = .empty };
    try usp.append("a", "1");
    try usp.append("b", "2");

    const r = try (BodyInit{ .url_search_params = usp }).extract(arena);
    try testing.expectString("a=1&b=2", r.bytes);
    try testing.expectString("application/x-www-form-urlencoded;charset=UTF-8", r.content_type.?);
}

test "BodyInit: FormData emits multipart with random boundary" {
    defer testing.reset();
    const arena = testing.arena_allocator;

    const fd = try arena.create(FormData);
    fd.* = .{ ._arena = arena, ._entries = .empty };
    try fd.append("username", "alice");
    try fd.append("email", "alice@example.com");

    const r = try (BodyInit{ .form_data = fd }).extract(arena);

    // Body must contain the entries' Content-Disposition lines and end with
    // the closing boundary marker.
    const boundary = r.content_type.?["multipart/form-data; boundary=".len..];
    try testing.expectEqual(true, std.mem.startsWith(u8, boundary, "----"));
    try testing.expectEqual(true, boundary.len > 10);

    try testing.expect(std.mem.indexOf(u8, r.bytes, "Content-Disposition: form-data; name=\"username\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "Content-Disposition: form-data; name=\"email\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "alice") != null);
    try testing.expect(std.mem.indexOf(u8, r.bytes, "alice@example.com") != null);
    const closer = try std.fmt.allocPrint(arena, "--{s}--\r\n", .{boundary});
    try testing.expect(std.mem.endsWith(u8, r.bytes, closer));
}

// Blob.extract is exercised end-to-end by the Request/XHR HTML fixture
// tests rather than constructed ad-hoc here — Blob owns `_type`, `_rc`,
// and `_arena` fields that need a Page-backed allocator to initialise
// safely.
