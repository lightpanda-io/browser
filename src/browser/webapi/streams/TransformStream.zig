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

const ReadableStream = @import("ReadableStream.zig");
const ReadableStreamDefaultController = @import("ReadableStreamDefaultController.zig");
const WritableStream = @import("WritableStream.zig");

const Execution = js.Execution;

const TransformStream = @This();

pub const DefaultController = TransformStreamDefaultController;

pub const ZigTransformFn = *const fn (*TransformStreamDefaultController, js.Value) anyerror!void;

_readable: *ReadableStream,
_writable: *WritableStream,
_controller: *TransformStreamDefaultController,

const Transformer = struct {
    start: ?js.Function = null,
    transform: ?js.Function.Global = null,
    flush: ?js.Function.Global = null,
};

pub fn init(transformer_: ?Transformer, exec: *const Execution) !*TransformStream {
    const readable = try ReadableStream.init(null, null, exec);

    const self = try exec._factory.create(TransformStream{
        ._readable = readable,
        ._writable = undefined,
        ._controller = undefined,
    });

    const transform_controller = try TransformStreamDefaultController.init(
        self,
        if (transformer_) |t| t.transform else null,
        if (transformer_) |t| t.flush else null,
        null,
        exec,
    );
    self._controller = transform_controller;

    self._writable = try WritableStream.initForTransform(self, exec);

    if (transformer_) |transformer| {
        if (transformer.start) |start| {
            try start.call(void, .{transform_controller});
        }
    }

    return self;
}

pub fn initWithZigTransform(zig_transform: ZigTransformFn, exec: *const Execution) !*TransformStream {
    const readable = try ReadableStream.init(null, null, exec);

    const self = try exec._factory.create(TransformStream{
        ._readable = readable,
        ._writable = undefined,
        ._controller = undefined,
    });

    const transform_controller = try TransformStreamDefaultController.init(self, null, null, zig_transform, exec);
    self._controller = transform_controller;

    self._writable = try WritableStream.initForTransform(self, exec);
    return self;
}

pub fn transformWrite(self: *TransformStream, chunk: js.Value, exec: *const Execution) !void {
    if (self._controller._zig_transform_fn) |zig_fn| {
        // Zig-level transform (used by TextEncoderStream etc.)
        try zig_fn(self._controller, chunk);
        return;
    }

    if (self._controller._transform_fn) |transform_fn| {
        var ls: js.Local.Scope = undefined;
        exec.context.localScope(&ls);
        defer ls.deinit();

        try ls.toLocal(transform_fn).call(void, .{ chunk, self._controller });
    } else {
        try self._readable._controller.enqueue(.{ .string = try chunk.toStringSlice() });
    }
}

pub fn transformClose(self: *TransformStream, exec: *const Execution) !void {
    if (self._controller._flush_fn) |flush_fn| {
        var ls: js.Local.Scope = undefined;
        exec.context.localScope(&ls);
        defer ls.deinit();

        try ls.toLocal(flush_fn).call(void, .{self._controller});
    }

    try self._readable._controller.close();
}

pub fn getReadable(self: *const TransformStream) *ReadableStream {
    return self._readable;
}

pub fn getWritable(self: *const TransformStream) *WritableStream {
    return self._writable;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TransformStream);

    pub const Meta = struct {
        pub const name = "TransformStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TransformStream.init, .{});
    pub const readable = bridge.accessor(TransformStream.getReadable, null, .{});
    pub const writable = bridge.accessor(TransformStream.getWritable, null, .{});
};

pub fn registerTypes() []const type {
    return &.{
        TransformStream,
        TransformStreamDefaultController,
    };
}

pub const TransformStreamDefaultController = struct {
    _stream: *TransformStream,
    _transform_fn: ?js.Function.Global,
    _flush_fn: ?js.Function.Global,
    _zig_transform_fn: ?ZigTransformFn,

    pub fn init(
        stream: *TransformStream,
        transform_fn: ?js.Function.Global,
        flush_fn: ?js.Function.Global,
        zig_transform_fn: ?ZigTransformFn,
        exec: *const Execution,
    ) !*TransformStreamDefaultController {
        return exec._factory.create(TransformStreamDefaultController{
            ._stream = stream,
            ._transform_fn = transform_fn,
            ._flush_fn = flush_fn,
            ._zig_transform_fn = zig_transform_fn,
        });
    }

    pub fn enqueue(self: *TransformStreamDefaultController, chunk: ReadableStreamDefaultController.Chunk) !void {
        try self._stream._readable._controller.enqueue(chunk);
    }

    /// Enqueue a raw JS value, preserving its type. Used by the JS-facing API.
    pub fn enqueueValue(self: *TransformStreamDefaultController, value: js.Value) !void {
        try self._stream._readable._controller.enqueueValue(value);
    }

    pub fn doError(self: *TransformStreamDefaultController, reason: []const u8) !void {
        try self._stream._readable._controller.doError(reason);
    }

    pub fn terminate(self: *TransformStreamDefaultController) !void {
        try self._stream._readable._controller.close();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TransformStreamDefaultController);

        pub const Meta = struct {
            pub const name = "TransformStreamDefaultController";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const enqueue = bridge.function(TransformStreamDefaultController.enqueueValue, .{});
        pub const @"error" = bridge.function(TransformStreamDefaultController.doError, .{});
        pub const terminate = bridge.function(TransformStreamDefaultController.terminate, .{});
    };
};
