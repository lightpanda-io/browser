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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const Mime = @import("../Mime.zig");
const html5ever = @import("../parser/html5ever.zig");

const Blob = @import("Blob.zig");
const EventTarget = @import("EventTarget.zig");
const ProgressEvent = @import("event/ProgressEvent.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

/// https://w3c.github.io/FileAPI/#dfn-filereader
/// https://developer.mozilla.org/en-US/docs/Web/API/FileReader
const FileReader = @This();

pub const Proto = EventTarget;

_rc: lp.RC = .{},
_exec: *Execution,
_proto: *EventTarget,
_arena: *lp.Arena,

_generation: u32 = 0,
_ready_state: ReadyState = .empty,
_result: ?Result = null,
_error: ?[]const u8 = null,

_on_abort: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_load: ?js.Function.Global = null,
_on_load_end: ?js.Function.Global = null,
_on_load_start: ?js.Function.Global = null,
_on_progress: ?js.Function.Global = null,

const ReadyState = enum(u8) {
    empty = 0,
    loading = 1,
    done = 2,
};

const Result = union(enum) {
    string: []const u8,
    binary_string: js.String.OneByte,
    arraybuffer: js.ArrayBuffer,
};

pub fn init(exec: *Execution) !*FileReader {
    const arena = try exec.getArena(.tiny, "FileReader");
    errdefer arena.release();

    return exec._factory.eventTargetWithAllocator(arena.allocator(), FileReader{
        ._exec = exec,
        ._arena = arena,
        ._proto = undefined,
    });
}

pub fn deinit(self: *FileReader, _: *Page) void {
    if (self._on_abort) |func| func.release();
    if (self._on_error) |func| func.release();
    if (self._on_load) |func| func.release();
    if (self._on_load_end) |func| func.release();
    if (self._on_load_start) |func| func.release();
    if (self._on_progress) |func| func.release();

    self._arena.release();
}

pub fn releaseRef(self: *FileReader, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *FileReader) void {
    self._rc.acquire();
}

fn asEventTarget(self: *FileReader) *EventTarget {
    return self._proto;
}

pub fn getOnAbort(self: *const FileReader) ?js.Function.Global {
    return self._on_abort;
}

pub fn setOnAbort(self: *FileReader, cb: ?js.Function.Global) !void {
    self._on_abort = cb;
}

pub fn getOnError(self: *const FileReader) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *FileReader, cb: ?js.Function.Global) !void {
    self._on_error = cb;
}

pub fn getOnLoad(self: *const FileReader) ?js.Function.Global {
    return self._on_load;
}

pub fn setOnLoad(self: *FileReader, cb: ?js.Function.Global) !void {
    self._on_load = cb;
}

pub fn getOnLoadEnd(self: *const FileReader) ?js.Function.Global {
    return self._on_load_end;
}

pub fn setOnLoadEnd(self: *FileReader, cb: ?js.Function.Global) !void {
    self._on_load_end = cb;
}

pub fn getOnLoadStart(self: *const FileReader) ?js.Function.Global {
    return self._on_load_start;
}

pub fn setOnLoadStart(self: *FileReader, cb: ?js.Function.Global) !void {
    self._on_load_start = cb;
}

pub fn getOnProgress(self: *const FileReader) ?js.Function.Global {
    return self._on_progress;
}

pub fn setOnProgress(self: *FileReader, cb: ?js.Function.Global) !void {
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
    try self.readInternal(blob, .arraybuffer, null);
}

pub fn readAsBinaryString(self: *FileReader, blob: *Blob) !void {
    try self.readInternal(blob, .binary_string, null);
}

pub fn readAsText(self: *FileReader, blob: *Blob, encoding_: ?[]const u8) !void {
    try self.readInternal(blob, .text, encoding_);
}

pub fn readAsDataURL(self: *FileReader, blob: *Blob) !void {
    try self.readInternal(blob, .data_url, null);
}

const ReadType = enum {
    arraybuffer,
    binary_string,
    text,
    data_url,
};

fn readInternal(self: *FileReader, blob: *Blob, read_type: ReadType, encoding_: ?[]const u8) !void {
    if (self._ready_state == .loading) {
        return error.InvalidStateError;
    }

    self._error = null;
    self._result = null;
    self._generation +%= 1;
    self._ready_state = .loading;

    const exec = self._exec;

    // The task holds the blob rather than a copy of its bytes: the events are
    // dispatched from later tasks, by which point JS may have dropped its last
    // reference. Only `encoding` is copied, because it comes off the call arena.
    const task = try exec._factory.create(ReadTask{
        .blob = blob,
        .reader = self,
        .step = .load_start,
        .read_type = read_type,
        .generation = self._generation,
        .encoding = if (encoding_) |e| try self._arena.dupe(u8, e) else null,
    });
    errdefer exec._factory.destroy(task);

    blob.acquireRef();
    errdefer blob.releaseRef(exec.page);

    self.acquireRef();
    errdefer self.releaseRef(exec.page);

    try exec._scheduler.add(task, ReadTask.run, 0, .{
        .name = "FileReader.read",
        .finalizer = ReadTask.cancelled,
    });
}

fn complete(self: *FileReader, task: *const ReadTask) !void {
    const arena = self._arena.allocator();
    const data = task.blob._slice;

    self._result = switch (task.read_type) {
        .arraybuffer => .{ .arraybuffer = .{ .values = try arena.dupe(u8, data) } },
        .binary_string => .{ .binary_string = .{ .bytes = try arena.dupe(u8, data) } },
        .text => .{ .string = try decodeText(arena, data, task.encoding, task.blob._mime) },
        .data_url => blk: {
            const mime = if (task.blob._mime.len > 0) task.blob._mime else "application/octet-stream";
            break :blk .{ .string = try encodeDataURL(arena, mime, data) };
        },
    };

    self._ready_state = .done;

    const exec = self._exec;
    const size = data.len;
    try self.dispatch(.load, .{ .loaded = size, .total = size }, exec);
    try self.dispatch(.load_end, .{ .loaded = size, .total = size }, exec);
}

const ReadTask = struct {
    step: Step,
    blob: *Blob,
    generation: u32,
    reader: *FileReader,
    read_type: ReadType,
    encoding: ?[]const u8,

    const Step = enum { load_start, progress, complete };

    fn deinit(self: *ReadTask) void {
        const reader = self.reader;
        const exec = reader._exec;

        self.blob.releaseRef(exec.page);
        reader.releaseRef(exec.page);
        exec._factory.destroy(self);
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *ReadTask = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ReadTask = @ptrCast(@alignCast(ctx));
        const reader = self.reader;
        const exec = reader._exec;

        if (self.generation != reader._generation) {
            self.deinit();
            return null;
        }
        errdefer self.deinit();

        const size = self.blob._slice.len;
        switch (self.step) {
            .load_start => {
                self.step = if (size == 0) .complete else .progress;
                try reader.dispatch(.load_start, .{ .loaded = 0, .total = size }, exec);
            },
            .progress => {
                self.step = .complete;
                try reader.dispatch(.progress, .{ .loaded = size, .total = size }, exec);
            },
            .complete => {
                try reader.complete(self);
                self.deinit();
                return null;
            },
        }

        if (self.generation != reader._generation) {
            // a handler aborted or started another thread
            self.deinit();
            return null;
        }

        // enqueue for the next step
        try exec._scheduler.add(self, run, 0, .{
            .name = "FileReader.read",
            .finalizer = cancelled,
        });
        return null;
    }
};

fn encodingHandle(label: []const u8) ?*anyopaque {
    if (label.len == 0) {
        return null;
    }
    const info = html5ever.encoding_for_label(label.ptr, label.len);
    if (info.isValid() == false or std.mem.eql(u8, info.name(), "replacement")) {
        return null;
    }
    return info.handle;
}

pub fn decodeText(arena: Allocator, input: []const u8, label_: ?[]const u8, mime_type: []const u8) ![]const u8 {
    var data = input;
    var handle: ?*anyopaque = null;

    // BOM wins over an explicit encoding
    if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) {
        data = data[3..];
        handle = encodingHandle("utf-8");
    } else if (std.mem.startsWith(u8, data, "\xFE\xFF")) {
        data = data[2..];
        handle = encodingHandle("utf-16be");
    } else if (std.mem.startsWith(u8, data, "\xFF\xFE")) {
        data = data[2..];
        handle = encodingHandle("utf-16le");
    } else if (label_) |label| {
        handle = encodingHandle(label);
    }

    if (handle == null and mime_type.len > 0) {
        if (Mime.parse(mime_type)) |mime| {
            if (mime.is_default_charset == false) {
                handle = encodingHandle(mime.charsetString());
            }
        } else |_| {}
    }

    const encoding = handle orelse encodingHandle("utf-8") orelse return arena.dupe(u8, data);

    const max_out = html5ever.encoding_max_utf8_buffer_length(encoding, if (data.len == 0) 4 else data.len);
    if (max_out == 0) {
        return "";
    }

    const out = try arena.alloc(u8, max_out);
    const result = html5ever.encoding_decode(
        encoding,
        if (data.len == 0) null else data.ptr,
        data.len,
        out.ptr,
        out.len,
        1, // is_last
    );
    return out[0..result.bytes_written];
}

pub fn abort(self: *FileReader) !void {
    if (self._ready_state != .loading) {
        self._result = null;
        return;
    }

    self._ready_state = .done;
    self._result = null;
    // Retires the queued read chain.
    self._generation +%= 1;

    const exec = self._exec;
    try self.dispatch(.abort, null, exec);
    try self.dispatch(.load_end, null, exec);
}

fn dispatch(self: *FileReader, comptime event_type: DispatchType, progress_: ?Progress, exec: *Execution) !void {
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
        exec.page,
    )).asEvent();

    return exec.dispatch(
        self.asEventTarget(),
        event,
        @field(self, field),
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
pub fn encodeDataURL(arena: Allocator, mime: []const u8, data: []const u8) ![]const u8 {
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
    pub const readAsArrayBuffer = bridge.function(FileReader.readAsArrayBuffer, .{});
    pub const readAsBinaryString = bridge.function(FileReader.readAsBinaryString, .{});
    pub const readAsText = bridge.function(FileReader.readAsText, .{});
    pub const readAsDataURL = bridge.function(FileReader.readAsDataURL, .{});
    pub const abort = bridge.function(FileReader.abort, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: FileReader" {
    try testing.htmlRunner("file_reader.html", .{});
}
