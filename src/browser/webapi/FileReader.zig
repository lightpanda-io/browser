// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const EventTarget = @import("EventTarget.zig");
const ProgressEvent = @import("event/ProgressEvent.zig");
const Blob = @import("Blob.zig");

const Allocator = std.mem.Allocator;

/// https://w3c.github.io/FileAPI/#dfn-filereader
/// https://developer.mozilla.org/en-US/docs/Web/API/FileReader
const FileReader = @This();

_page: *Page,
_proto: *EventTarget,
_arena: Allocator,

_ready_state: ReadyState = .empty,
_result: ?Result = null,
_error: ?[]const u8 = null,

_on_abort: ?js.Function.Temp = null,
_on_error: ?js.Function.Temp = null,
_on_load: ?js.Function.Temp = null,
_on_load_end: ?js.Function.Temp = null,
_on_load_start: ?js.Function.Temp = null,
_on_progress: ?js.Function.Temp = null,

_aborted: bool = false,

const ReadyState = enum(u8) {
    empty = 0,
    loading = 1,
    done = 2,
};

const Result = union(enum) {
    string: []const u8,
    arraybuffer: js.ArrayBuffer,
};

pub fn init(page: *Page) !*FileReader {
    const arena = try page.getArena(.{ .debug = "FileReader" });
    errdefer page.releaseArena(arena);

    return page._factory.eventTargetWithAllocator(arena, FileReader{
        ._page = page,
        ._arena = arena,
        ._proto = undefined,
    });
}

pub fn deinit(self: *FileReader, _: bool, page: *Page) void {
    const js_ctx = page.js;

    if (self._on_abort) |func| js_ctx.release(func);
    if (self._on_error) |func| js_ctx.release(func);
    if (self._on_load) |func| js_ctx.release(func);
    if (self._on_load_end) |func| js_ctx.release(func);
    if (self._on_load_start) |func| js_ctx.release(func);
    if (self._on_progress) |func| js_ctx.release(func);

    page.releaseArena(self._arena);
}

fn asEventTarget(self: *FileReader) *EventTarget {
    return self._proto;
}

pub fn getOnAbort(self: *const FileReader) ?js.Function.Temp {
    return self._on_abort;
}

pub fn setOnAbort(self: *FileReader, cb: ?js.Function.Temp) !void {
    self._on_abort = cb;
}

pub fn getOnError(self: *const FileReader) ?js.Function.Temp {
    return self._on_error;
}

pub fn setOnError(self: *FileReader, cb: ?js.Function.Temp) !void {
    self._on_error = cb;
}

pub fn getOnLoad(self: *const FileReader) ?js.Function.Temp {
    return self._on_load;
}

pub fn setOnLoad(self: *FileReader, cb: ?js.Function.Temp) !void {
    self._on_load = cb;
}

pub fn getOnLoadEnd(self: *const FileReader) ?js.Function.Temp {
    return self._on_load_end;
}

pub fn setOnLoadEnd(self: *FileReader, cb: ?js.Function.Temp) !void {
    self._on_load_end = cb;
}

pub fn getOnLoadStart(self: *const FileReader) ?js.Function.Temp {
    return self._on_load_start;
}

pub fn setOnLoadStart(self: *FileReader, cb: ?js.Function.Temp) !void {
    self._on_load_start = cb;
}

pub fn getOnProgress(self: *const FileReader) ?js.Function.Temp {
    return self._on_progress;
}

pub fn setOnProgress(self: *FileReader, cb: ?js.Function.Temp) !void {
    self._on_progress = cb;
}

pub fn getReadyState(self: *const FileReader) u8 {
    return @intFromEnum(self._ready_state);
}

pub fn getResult(self: *const FileReader) ?Result {
    return self._result;
}

pub fn getError(self: *const FileReader) ?[]const u8 {
    return self._error;
}

pub fn readAsArrayBuffer(self: *FileReader, blob: *Blob) !void {
    try self.readInternal(blob, .arraybuffer);
}

pub fn readAsBinaryString(self: *FileReader, blob: *Blob) !void {
    try self.readInternal(blob, .binary_string);
}

pub fn readAsText(self: *FileReader, blob: *Blob, encoding_: ?[]const u8) !void {
    _ = encoding_; // TODO: Handle encoding properly
    try self.readInternal(blob, .text);
}

pub fn readAsDataURL(self: *FileReader, blob: *Blob) !void {
    try self.readInternal(blob, .data_url);
}

const ReadType = enum {
    arraybuffer,
    binary_string,
    text,
    data_url,
};

fn readInternal(self: *FileReader, blob: *Blob, read_type: ReadType) !void {
    if (self._ready_state == .loading) {
        return error.InvalidStateError;
    }

    // Reset state
    self._ready_state = .loading;
    self._result = null;
    self._error = null;
    self._aborted = false;

    const page = self._page;

    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();
    const local = &ls.local;

    try self.dispatch(.load_start, .{ .loaded = 0, .total = blob.getSize() }, local, page);
    if (self._aborted) {
        return;
    }

    // Perform the read (synchronous since data is in memory)
    const data = blob._slice;
    const size = data.len;
    try self.dispatch(.progress, .{ .loaded = size, .total = size }, local, page);
    if (self._aborted) {
        return;
    }

    // Process the data based on read type
    self._result = switch (read_type) {
        .arraybuffer => .{ .arraybuffer = .{ .values = data } },
        .binary_string => .{ .string = data },
        .text => .{ .string = data },
        .data_url => blk: {
            // Create data URL with base64 encoding
            const mime = if (blob._mime.len > 0) blob._mime else "application/octet-stream";
            const data_url = try encodeDataURL(self._arena, mime, data);
            break :blk .{ .string = data_url };
        },
    };

    self._ready_state = .done;

    try self.dispatch(.load, .{ .loaded = size, .total = size }, local, page);
    try self.dispatch(.load_end, .{ .loaded = size, .total = size }, local, page);
}

pub fn abort(self: *FileReader) !void {
    if (self._ready_state != .loading) {
        return;
    }

    self._aborted = true;
    self._ready_state = .done;
    self._result = null;

    const page = self._page;

    var ls: js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();
    const local = &ls.local;

    try self.dispatch(.abort, null, local, page);

    try self.dispatch(.load_end, null, local, page);
}

fn dispatch(self: *FileReader, comptime event_type: DispatchType, progress_: ?Progress, local: *const js.Local, page: *Page) !void {
    const field, const typ = comptime blk: {
        break :blk switch (event_type) {
            .abort => .{ "_on_abort", "abort" },
            .err => .{ "_on_error", "error" },
            .load => .{ "_on_load", "load" },
            .load_end => .{ "_on_load_end", "loadend" },
            .load_start => .{ "_on_load_start", "loadstart" },
            .progress => .{ "_on_progress", "progress" },
        };
    };

    const progress = progress_ orelse Progress{};
    const event = (try ProgressEvent.initTrusted(
        comptime .wrap(typ),
        .{ .total = progress.total, .loaded = progress.loaded },
        page,
    )).asEvent();

    return page._event_manager.dispatchWithFunction(
        self.asEventTarget(),
        event,
        local.toLocal(@field(self, field)),
        .{ .context = "FileReader " ++ typ },
    );
}

const DispatchType = enum {
    abort,
    err,
    load,
    load_end,
    load_start,
    progress,
};

const Progress = struct {
    loaded: usize = 0,
    total: usize = 0,
};

/// Encodes binary data as a data URL with base64 encoding.
/// Format: data:[<mediatype>][;base64],<data>
fn encodeDataURL(arena: Allocator, mime: []const u8, data: []const u8) ![]const u8 {
    const base64 = std.base64.standard.Encoder;

    // Calculate size needed for base64 encoding
    const encoded_size = base64.calcSize(data.len);

    // Allocate buffer for the full data URL
    // Format: "data:" + mime + ";base64," + encoded_data
    const prefix = "data:";
    const suffix = ";base64,";
    const total_size = prefix.len + mime.len + suffix.len + encoded_size;

    var pos: usize = 0;
    const buf = try arena.alloc(u8, total_size);

    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    @memcpy(buf[pos..][0..mime.len], mime);
    pos += mime.len;

    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    _ = base64.encode(buf[pos..], data);

    return buf;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FileReader);

    pub const Meta = struct {
        pub const name = "FileReader";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const weak = true;
        pub const finalizer = bridge.finalizer(FileReader.deinit);
    };

    pub const constructor = bridge.constructor(FileReader.init, .{});

    // State constants
    pub const EMPTY = bridge.property(@intFromEnum(FileReader.ReadyState.empty), .{ .template = true });
    pub const LOADING = bridge.property(@intFromEnum(FileReader.ReadyState.loading), .{ .template = true });
    pub const DONE = bridge.property(@intFromEnum(FileReader.ReadyState.done), .{ .template = true });

    // Properties
    pub const readyState = bridge.accessor(FileReader.getReadyState, null, .{});
    pub const result = bridge.accessor(FileReader.getResult, null, .{});
    pub const @"error" = bridge.accessor(FileReader.getError, null, .{});

    // Event handlers
    pub const onabort = bridge.accessor(FileReader.getOnAbort, FileReader.setOnAbort, .{});
    pub const onerror = bridge.accessor(FileReader.getOnError, FileReader.setOnError, .{});
    pub const onload = bridge.accessor(FileReader.getOnLoad, FileReader.setOnLoad, .{});
    pub const onloadend = bridge.accessor(FileReader.getOnLoadEnd, FileReader.setOnLoadEnd, .{});
    pub const onloadstart = bridge.accessor(FileReader.getOnLoadStart, FileReader.setOnLoadStart, .{});
    pub const onprogress = bridge.accessor(FileReader.getOnProgress, FileReader.setOnProgress, .{});

    // Methods
    pub const readAsArrayBuffer = bridge.function(FileReader.readAsArrayBuffer, .{ .dom_exception = true });
    pub const readAsBinaryString = bridge.function(FileReader.readAsBinaryString, .{ .dom_exception = true });
    pub const readAsText = bridge.function(FileReader.readAsText, .{ .dom_exception = true });
    pub const readAsDataURL = bridge.function(FileReader.readAsDataURL, .{ .dom_exception = true });
    pub const abort = bridge.function(FileReader.abort, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: FileReader" {
    try testing.htmlRunner("file_reader.html", .{});
}
