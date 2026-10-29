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

const Frame = @import("Frame.zig");
const URL = @import("URL.zig");
const HttpClient = @import("../network/HttpClient.zig");

const sys_url = @import("../sys/url.zig");
const uuidv4 = @import("../id.zig").uuidv4;
const latin1ToUtf8 = @import("../string.zig").latin1ToUtf8;

const log = lp.log;
const Allocator = std.mem.Allocator;

const Download = @This();
// UUIDv4.
guid: [36]u8,
/// `null` if session's `download_behavior` set for streaming over CDP,
/// or if the response failed and there's nothing to write.
file: ?std.Io.File = null,
/// Suggested filename surfaced to the client, arena-owned.
filename: []const u8,
/// Bytes received so far.
received: usize = 0,
// Total bytes, filled if HTTP response advertised one.
total: ?usize = null,
/// Frame that owns the operation.
frame: *Frame,

/// Prefer `from*` variants to initialize.
/// `maybe_suggestion` is the caller's sanitized pick; `null` falls back to the `guid`.
fn init(frame: *Frame, transfer: *HttpClient.Transfer, maybe_suggestion: ?[]const u8) !Download {
    const session = frame._session;
    // The final URL, after any redirects.
    const url = transfer.req.url;

    // `guid` is the CDP "Global Unique Identifier" which helps us find
    // where to dispatch events on.
    var guid: [36]u8 = undefined;
    uuidv4(&guid);

    // The suggestion may point into the response headers, which don't
    // outlive the transfer. Content-Disposition filenames can be in a
    // legacy encoding (e.g. Shift_JIS) but must yield valid UTF-8.
    const name = maybe_suggestion orelse &guid;
    const filename = if (std.unicode.utf8ValidateSlice(name))
        try frame.page_arena.dupe(u8, name)
    else
        try latin1ToUtf8(frame.page_arena, name);

    const succeeded = isSuccessStatus(transfer.responseStatus() orelse 0);
    const maybe_file: ?std.Io.File = if (succeeded == false) null else switch (session.download_behavior) {
        inline .allow, .allow_and_name => |behavior| blk: {
            const download_path = session.download_path orelse {
                log.warn(.frame, "download without downloadPath", .{ .url = url });
                return error.WithoutDownloadPath;
            };
            // allowAndName stores the file under its guid.
            const on_disk_name: []const u8 = if (comptime behavior == .allow_and_name) &guid else filename;

            const cwd = std.Io.Dir.cwd();
            try cwd.createDirPath(lp.io, download_path);
            var dir = try cwd.openDir(lp.io, download_path, .{});
            defer dir.close(lp.io);
            break :blk try dir.createFile(lp.io, on_disk_name, .{ .truncate = true });
        },
        .deny => unreachable, // Must be handled before.
        .stream => null, // Will be streamed over CDP, no need to file.
    };

    // Announce.
    if (session.download_events_enabled) {
        session.notification.dispatch(.download_will_begin, &.{
            .frame_id = frame._frame_id,
            .guid = &guid,
            .url = url,
            .suggested_filename = filename,
            .content_type = transfer.contentType(),
        });
    }

    const download: Download = .{
        .guid = guid,
        .file = maybe_file,
        .filename = filename,
        .received = 0,
        // Like Chrome, a failed download reports 0/0 bytes, whatever the
        // response advertised.
        .total = if (succeeded) transfer.getContentLength() else null,
        .frame = frame,
    };
    // Like Chrome, downloadWillBegin is followed by an inProgress
    // downloadProgress. A failed download is canceled at once instead.
    if (succeeded) {
        download.report(.in_progress);
    }
    return download;
}

/// Try to initialize a `Download` from a `Transfer`. It's up to caller to
/// call `feed`, `finish` or `cancel` where necessary.
pub fn fromTransfer(frame: *Frame, transfer: *HttpClient.Transfer) !Download {
    if (frame._session.download_behavior == .deny) {
        return error.Denied;
    }

    const disposition = contentDisposition(transfer) orelse return error.MissingHeader;
    if (std.ascii.eqlIgnoreCase(disposition.firstValue(), "attachment") == false) {
        return error.MissingHeader;
    }

    // Expect a success status code to continue.
    const status = transfer.responseStatus() orelse return error.UnexpectedHttpStatus;
    if (isSuccessStatus(status) == false) {
        return error.UnexpectedHttpStatus;
    }

    const maybe_suggestion = dispositionFilename(disposition) orelse (try urlBasename(frame.page_arena, frame.url));
    return init(frame, transfer, maybe_suggestion) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // As before, a download we can't write renders the response instead.
        else => {
            log.err(.frame, "download init", .{ .err = err, .url = frame.url });
            return error.Unwritable;
        },
    };
}

/// Try to initialize an asynchronous `Download` from a href. In order to
/// download to finish, contrary to Chrome, `Frame` must live throughout
/// the download process. The function may or may not use `file_name_hint`,
/// hence it's a _hint_.
pub fn fromHref(frame: *Frame, href: []const u8, filename_hint: []const u8) !void {
    if (frame._session.download_behavior == .deny) {
        return error.Denied;
    }

    const url = try URL.resolve(frame.page_arena, frame.navigationBase(), href, .{ .encoding = frame.charset });

    const download = try frame._factory.create(Download{
        // Let `init` initialize this at `headerCallback`.
        .guid = undefined,
        // Pass-in hint, `headerCallback` will change this, though. Duped,
        // since the attribute can change before the response arrives.
        .filename = try frame.page_arena.dupe(u8, filename_hint),
        .frame = frame,
    });
    // `transfer.deinit()` fires no callbacks, so this is still ours on error.
    errdefer frame._factory.destroy(download);

    // Setup transfer.
    const transfer = try frame.newRequest(.{
        .ctx = download,
        .url = url,
        .method = .GET,
        .origin = frame.origin,
        .initiator_origin = frame.origin,
        .request_mode = .navigate,
        .credentials_mode = .include,
        .resource_type = .download,
        .streaming = true,
        .header_callback = headerCallback,
        .data_callback = dataCallback,
        .done_callback = doneCallback,
        .error_callback = errorCallback,
        .shutdown_callback = shutdownCallback,
    });
    errdefer transfer.deinit();
    try transfer.setHeader("Accept", lp.Config.HttpHeaders.navigation_accept, .{});
    // Set common headers.
    try frame.headersForRequest(transfer, .{});

    transfer.submit() catch |err| {
        log.debug(.frame, "href download", .{ .err = err, .url = url });
    };
}

/// Feeds the operation with bytes by either writing to a file or streaming over CDP.
pub fn feed(self: *Download, bytes: []const u8) !void {
    const session = self.frame._session;
    // Write to file.
    if (self.file) |file| {
        file.writeStreamingAll(lp.io, bytes) catch |err| {
            log.err(.frame, "download feed", .{ .err = err, .guid = &self.guid });
            return err;
        };
    } else {
        // Announce over CDP.
        if (session.download_events_enabled == false) return;
        session.notification.dispatch(.download_data, &.{ .guid = &self.guid, .data = bytes });
    }

    self.received += bytes.len;
}

/// The body was fully received.
pub fn finish(self: *Download) void {
    defer self.report(.completed);
    self.closeFile();
}

/// The transfer failed partway. The partial file stays on disk for now.
pub fn cancel(self: *Download) void {
    defer self.report(.canceled);
    self.closeFile();
}

fn closeFile(self: *Download) void {
    const file = self.file orelse return;
    file.close(lp.io);
    self.file = null;
}

// Playwright only settles a download on a `completed` or `canceled`
// downloadProgress; without one, download.path() and friends never return.
fn report(self: *const Download, state: lp.Notification.DownloadProgress.State) void {
    const session = self.frame._session;
    if (session.download_events_enabled) {
        session.notification.dispatch(.download_progress, &.{
            .guid = &self.guid,
            .total_bytes = self.total orelse self.received,
            .received_bytes = self.received,
            .state = state,
        });
    }
}

fn headerCallback(transfer: *HttpClient.Transfer) !HttpClient.Transfer.HeaderResult {
    const download, _ = fromRaw(transfer.req.ctx);
    const frame = download.frame;
    // The final URL, after any redirects.
    const final_url = transfer.req.url;

    // setDownloadBehavior can change while the fetch is in-flight.
    if (frame._session.download_behavior == .deny) {
        log.info(.frame, "download denied", .{ .url = final_url });
        return .abort;
    }

    const status = transfer.responseStatus() orelse return .abort;

    // A Content-Disposition filename wins over the `download` attribute.
    const disposition_name = if (contentDisposition(transfer)) |disposition| dispositionFilename(disposition) else null;
    const maybe_suggestion = disposition_name orelse
        sanitizeFilename(download.filename) orelse (try urlBasename(frame.page_arena, final_url));

    download.* = init(frame, transfer, maybe_suggestion) catch |err| {
        log.err(.frame, "download init", .{ .err = err });
        return .abort;
    };
    // Later callbacks read `req.ctx` at call time, so they see the tag.
    transfer.req.ctx = @ptrFromInt(@intFromPtr(download) | announced_bit);

    if (isSuccessStatus(status) == false) {
        // Announced, so `errorCallback` reports it canceled.
        log.info(.frame, "download failed", .{ .status = status, .url = final_url });
        return .abort;
    }
    return .proceed;
}

fn dataCallback(transfer: *HttpClient.Transfer, bytes: []const u8) !void {
    const download, _ = fromRaw(transfer.req.ctx);
    return download.feed(bytes);
}

/// This must not fail! A `done_callback` error is routed to `error_callback`,
/// which would destroy `ctx` a second time.
fn doneCallback(raw_ctx: *anyopaque) !void {
    end(raw_ctx, .completed);
}

fn errorCallback(raw_ctx: *anyopaque, err: anyerror) void {
    // An `Abort` comes from headerCallback, which already logged why.
    if (err != error.Abort) {
        log.warn(.frame, "link download", .{ .err = err });
    }
    end(raw_ctx, .canceled);
}

/// Frame teardown or a superseding navigation. Unlike Chrome, downloads
/// don't outlive their `Frame`, so report it canceled. Must not run JS.
fn shutdownCallback(raw_ctx: *anyopaque) void {
    end(raw_ctx, .canceled);
}

/// Every terminal callback goes through here; exactly one of them fires, so
/// this frees `ctx` exactly once.
fn end(raw_ctx: *anyopaque, comptime state: enum { completed, canceled }) void {
    const download, const announced = fromRaw(raw_ctx);
    defer download.frame._factory.destroy(download);
    // No downloadWillBegin was sent, so there's nothing to report.
    if (announced == false) return;
    switch (state) {
        .completed => download.finish(),
        .canceled => download.cancel(),
    }
}

const announced_bit: usize = 1;
comptime {
    std.debug.assert(@alignOf(Download) > announced_bit);
}

/// The `bool` is `true` if the download was announced (finished or canceled).
fn fromRaw(ptr: *anyopaque) struct { *Download, bool } {
    const addr = @intFromPtr(ptr);
    return .{ @ptrFromInt(addr & ~announced_bit), addr & announced_bit != 0 };
}

// Chrome downloads only 200-203; any other status is announced, then
// canceled at once, and nothing is written. 206 is only valid for a range
// request, which we never send.
inline fn isSuccessStatus(status: u16) bool {
    return status >= 200 and status <= 203;
}

fn contentDisposition(transfer: *HttpClient.Transfer) ?HttpClient.Header {
    for (transfer.responseHeaders()) |header| {
        if (std.mem.eql(u8, header.name, "content-disposition")) {
            return header;
        }
    }
    return null;
}

// Extracts the filename from a Content-Disposition header, handling the quoted,
// unquoted, and RFC 5987 (filename*=charset''value) forms. Path components are
// stripped so the result is always a bare basename.
fn dispositionFilename(disposition: HttpClient.Header) ?[]const u8 {
    // Prefer the extended filename*= form when present, per RFC 6266.
    if (disposition.param("filename*")) |ext| {
        // charset'lang'value — take everything after the second quote.
        if (std.mem.findScalar(u8, ext, '\'')) |first| {
            if (std.mem.findScalarPos(u8, ext, first + 1, '\'')) |second| {
                return sanitizeFilename(ext[second + 1 ..]);
            }
        }
        return sanitizeFilename(ext);
    }
    if (disposition.param("filename")) |name| {
        return sanitizeFilename(name);
    }
    return null;
}

// Strips any directory components, guarding against path traversal. Content-
// Disposition can carry Windows separators, so backslashes are stripped too,
// regardless of the host platform.
fn sanitizeFilename(name: []const u8) ?[]const u8 {
    var out = std.fs.path.basename(name);
    if (std.mem.findScalarLast(u8, out, '\\')) |i| {
        out = out[i + 1 ..];
    }
    if (out.len == 0 or std.mem.eql(u8, out, ".") or std.mem.eql(u8, out, "..")) {
        return null;
    }
    return out;
}

// Derives a filename from a URL's last path segment. The path is taken from a
// real URL parse (rust-url) so query/fragment and percent-encoding are handled
// the same way the rest of the browser handles URLs. The result is duped into
// `arena`, since the parsed URL is freed before this returns.
fn urlBasename(arena: Allocator, url: []const u8) !?[]const u8 {
    var err: i32 = 0;
    const u = sys_url.url_parse(url.ptr, url.len, &err) orelse return null;
    defer sys_url.url_free(u);

    var ptr: [*]const u8 = undefined;
    var len: usize = undefined;
    sys_url.url_get_path(u, &ptr, &len);
    const path = ptr[0..len];
    if (std.mem.startsWith(u8, path, "/") == false) {
        return null;
    }

    const name = sanitizeFilename(path) orelse return null;
    return try arena.dupe(u8, name);
}

const testing = @import("../testing.zig");

fn dispositionHeader(value: []const u8) HttpClient.Header {
    return .{ .name = "content-disposition", .value = value };
}

test "Download: dispositionFilename" {
    try testing.expectEqualSlices(u8, "report.csv", dispositionFilename(dispositionHeader("attachment; filename=\"report.csv\"")).?);
    try testing.expectEqualSlices(u8, "report.csv", dispositionFilename(dispositionHeader("attachment; filename=report.csv")).?);
    try testing.expectEqualSlices(u8, "r e.csv", dispositionFilename(dispositionHeader("attachment; filename=\"r e.csv\"")).?);
    // RFC 5987 extended form is preferred over the plain filename when present
    // (the value is taken verbatim after the charset'lang' prefix).
    try testing.expectEqualSlices(u8, "extended.txt", dispositionFilename(dispositionHeader("attachment; filename=\"fallback.txt\"; filename*=UTF-8''extended.txt")).?);
    try testing.expect(dispositionFilename(dispositionHeader("attachment")) == null);
    // Path components are stripped to guard against traversal.
    try testing.expectEqualSlices(u8, "evil.sh", dispositionFilename(dispositionHeader("attachment; filename=\"../../evil.sh\"")).?);
    try testing.expectEqualSlices(u8, "evil.sh", dispositionFilename(dispositionHeader("attachment; filename=\"..\\..\\evil.sh\"")).?);
    try testing.expect(dispositionFilename(dispositionHeader("attachment; filename=\"..\"")) == null);
}

test "Download: urlBasename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualSlices(u8, "report.csv", (try urlBasename(a, "http://x.com/a/b/report.csv")).?);
    try testing.expectEqualSlices(u8, "report.csv", (try urlBasename(a, "http://x.com/report.csv?v=1#x")).?);
    try testing.expect((try urlBasename(a, "http://x.com/")) == null);
    try testing.expect((try urlBasename(a, "data:text/csv,name%2Cvalue")) == null);
}
