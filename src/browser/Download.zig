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

const uuidv4 = @import("../id.zig").uuidv4;

const log = lp.log;

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
fn init(frame: *Frame, url: []const u8, filename: []const u8, maybe_total: ?usize) !Download {
    const session = frame._session;

    // `guid` is the CDP "Global Unique Identifier" which helps us find
    // where to dispatch events on.
    var guid: [36]u8 = undefined;
    uuidv4(&guid);

    const maybe_file: ?std.Io.File = switch (session.download_behavior) {
        inline .allow, .allow_and_name => blk: {
            const download_path = session.download_path orelse {
                log.warn(.frame, "download without downloadPath", .{ .url = url });
                return error.WithoutDownloadPath;
            };
            // allowAndName stores the file under its guid.
            //const on_disk_name = if (comptime behavior == .allow_and_name) @as([]const u8, guid) else filename;
            const on_disk_name = filename;

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
        });
    }

    return .{
        .guid = guid,
        .file = maybe_file,
        .filename = filename,
        .received = 0,
        .total = maybe_total,
        .frame = frame,
    };
}

/// Try to initialize a `Download` from a `Transfer`. It's up to caller to
/// call `feed`, `finish` or `cancel` where necessary.
pub fn fromTransfer(frame: *Frame, transfer: *HttpClient.Transfer) !Download {
    if (frame._session.download_behavior == .deny) {
        return error.Denied;
    }

    // Find `Content-Disposition`.
    const disposition: HttpClient.Header = blk: {
        for (transfer.responseHeaders()) |header| {
            if (std.mem.eql(u8, header.name, "content-disposition")) {
                break :blk header;
            }
        }
        return error.MissingHeader;
    };
    if (std.ascii.eqlIgnoreCase(disposition.firstValue(), "attachment") == false) {
        return error.MissingHeader;
    }

    // Expect a success status code to continue.
    const status = transfer.responseStatus() orelse return error.UnexpectedHttpStatus;
    if (isSuccessStatus(status) == false) {
        return error.UnexpectedHttpStatus;
    }

    // TODO: Find filename correctly.
    const filename = "dummy.txt";
    return init(frame, frame.url, filename, transfer.getContentLength());
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
        // Pass-in hint, `headerCallback` will change this, though.
        .filename = filename_hint,
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
    if (self.file) |file| {
        file.close(lp.io);
    }
}

/// The transfer failed partway. The partial file stays on disk for now.
pub fn cancel(self: *Download) void {
    defer self.report(.canceled);
    if (self.file) |file| {
        file.close(lp.io);
    }
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

    const status = transfer.responseStatus() orelse return .abort;
    if (isSuccessStatus(status) == false) {
        return .abort;
    }

    download.* = init(frame, final_url, "dummy.txt", transfer.getContentLength()) catch |err| {
        log.err(.frame, "download init", .{ .err = err });
        return .abort;
    };
    // Later callbacks read `req.ctx` at call time, so they see the tag.
    transfer.req.ctx = @ptrFromInt(@intFromPtr(download) | announced_bit);
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
