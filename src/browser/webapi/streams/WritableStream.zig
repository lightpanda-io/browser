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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const WritableStreamDefaultWriter = @import("WritableStreamDefaultWriter.zig");
const WritableStreamDefaultController = @import("WritableStreamDefaultController.zig");
const TransformStream = @import("TransformStream.zig");

const WritableStream = @This();

pub const State = enum {
    writable,
    closed,
    errored,
};

_state: State,
_writer: ?*WritableStreamDefaultWriter,
_controller: *WritableStreamDefaultController,
_stored_error: ?[]const u8,
_write_fn: ?js.Function.Global,
_close_fn: ?js.Function.Global,
_transform_stream: ?*TransformStream,

const UnderlyingSink = struct {
    start: ?js.Function = null,
    write: ?js.Function.Global = null,
    close: ?js.Function.Global = null,
    abort: ?js.Function.Global = null,
    type: ?[]const u8 = null,
};

pub fn init(sink_: ?UnderlyingSink, page: *Page) !*WritableStream {
    const self = try page._factory.create(WritableStream{
        ._state = .writable,
        ._writer = null,
        ._controller = undefined,
        ._stored_error = null,
        ._write_fn = null,
        ._close_fn = null,
        ._transform_stream = null,
    });

    self._controller = try WritableStreamDefaultController.init(self, page);

    if (sink_) |sink| {
        if (sink.start) |start| {
            try start.call(void, .{self._controller});
        }
        self._write_fn = sink.write;
        self._close_fn = sink.close;
    }

    return self;
}

pub fn initForTransform(transform_stream: *TransformStream, page: *Page) !*WritableStream {
    const self = try page._factory.create(WritableStream{
        ._state = .writable,
        ._writer = null,
        ._controller = undefined,
        ._stored_error = null,
        ._write_fn = null,
        ._close_fn = null,
        ._transform_stream = transform_stream,
    });

    self._controller = try WritableStreamDefaultController.init(self, page);
    return self;
}

pub fn getWriter(self: *WritableStream, page: *Page) !*WritableStreamDefaultWriter {
    if (self.getLocked()) {
        return error.WriterLocked;
    }

    const writer = try WritableStreamDefaultWriter.init(self, page);
    self._writer = writer;
    return writer;
}

pub fn getLocked(self: *const WritableStream) bool {
    return self._writer != null;
}

pub fn writeChunk(self: *WritableStream, chunk: js.Value, page: *Page) !void {
    if (self._state != .writable) return;

    if (self._transform_stream) |ts| {
        try ts.transformWrite(chunk, page);
        return;
    }

    if (self._write_fn) |write_fn| {
        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        try ls.toLocal(write_fn).call(void, .{ chunk, self._controller });
    }
}

pub fn closeStream(self: *WritableStream, page: *Page) !void {
    if (self._state != .writable) return;
    self._state = .closed;

    if (self._transform_stream) |ts| {
        try ts.transformClose(page);
        return;
    }

    if (self._close_fn) |close_fn| {
        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        try ls.toLocal(close_fn).call(void, .{self._controller});
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WritableStream);

    pub const Meta = struct {
        pub const name = "WritableStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(WritableStream.init, .{});
    pub const getWriter = bridge.function(WritableStream.getWriter, .{});
    pub const locked = bridge.accessor(WritableStream.getLocked, null, .{});
};

pub fn registerTypes() []const type {
    return &.{
        WritableStream,
    };
}
