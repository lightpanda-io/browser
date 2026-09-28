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

//! The embedder half of `WebAssembly.compileStreaming` and
//! `WebAssembly.instantiateStreaming`. V8 only installs the two functions
//! when the isolate has a streaming callback; when a page calls one, V8 hands
//! us the `Response | Promise<Response>` argument and a WasmStreaming handle
//! we feed the module bytes into.
//!
//! https://webassembly.github.io/spec/web-api/#compile-a-potential-webassembly-response

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("js.zig");
const v8 = js.v8;
const Caller = @import("Caller.zig");
const Context = @import("Context.zig");
const Mime = @import("../Mime.zig");
const Response = @import("../webapi/net/Response.zig");

const log = lp.log;

const WasmStreaming = @This();

ctx: *Context,
handle: v8.SharedPtr,

pub fn callback(info_handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    var caller: Caller = undefined;
    if (!caller.initFromHandle(info_handle)) {
        return;
    }
    defer caller.deinit();
    const local = &caller.local;

    const info = Caller.FunctionCallbackInfo{ .handle = info_handle.? };
    var shared = v8.v8__WasmStreaming__Unpack(local.isolate.handle, v8.v8__FunctionCallbackInfo__Data(info.handle).?);

    const ctx = local.ctx;
    const self = ctx.arena.allocator().create(WasmStreaming) catch |err| {
        log.err(.js, "wasm streaming", .{ .err = err });
        v8.v8__WasmStreaming__Abort(&shared, local.isolate.createError("Out of memory"));
        v8.std__shared_ptr__v8__WasmStreaming__reset(&shared);
        return;
    };
    self.* = .{ .ctx = ctx, .handle = shared };

    self.start(local, info.getArg(0, local)) catch |err| self.abortZigError(local, err);
}

fn start(self: *WasmStreaming, local: *const js.Local, source: js.Value) !void {
    const ctx = self.ctx;
    try ctx.wasm_streams.append(ctx.arena.allocator(), self);

    const promise = if (source.isPromise()) source.toPromise() else try local.resolvePromise(source);
    _ = try promise.thenAndCatch(
        local.newCallback(onResponse, self),
        local.newCallback(onFailure, self),
    );
}

fn onResponse(self: *WasmStreaming, value: js.Value, exec: *js.Execution) void {
    const local = exec.js.local.?;
    const response = value.toZig(*Response) catch {
        return self.abortTypeError(local, "Argument 0 must be a Response or a Promise resolving to a Response");
    };

    const content_type = response.getHeaders().get("content-type", exec) catch |err| return self.abortZigError(local, err);
    const essence = Mime.ContentTypeIterator.init(content_type orelse "").essence;
    if (!std.ascii.eqlIgnoreCase(essence, "application/wasm")) {
        return self.abortTypeError(local, "Incorrect response MIME type. Expected 'application/wasm'.");
    }
    if (!response.isOK()) {
        return self.abortTypeError(local, "HTTP status code is not ok");
    }

    const bytes = response.bytes(exec) catch |err| return self.abortZigError(local, err);

    const url = response.getURL();
    v8.v8__WasmStreaming__SetUrl(&self.handle, url.ptr, url.len);

    _ = bytes.thenAndCatch(
        local.newCallback(onBytes, self),
        local.newCallback(onFailure, self),
    ) catch |err| self.abortZigError(local, err);
}

fn onBytes(self: *WasmStreaming, bytes: []const u8) void {
    v8.v8__WasmStreaming__OnBytesReceived(&self.handle, bytes.ptr, bytes.len);
    v8.v8__WasmStreaming__Finish(&self.handle);
    self.release();
}

fn onFailure(self: *WasmStreaming, reason: js.Value) void {
    self.abort(reason.handle);
}

fn abortTypeError(self: *WasmStreaming, local: *const js.Local, message: []const u8) void {
    self.abort(local.isolate.createTypeError(message));
}

/// Body accessors report a TypeError through the context's error_message,
/// the same way the bridge surfaces it to JS.
fn abortZigError(self: *WasmStreaming, local: *const js.Local, err: anyerror) void {
    switch (err) {
        // An exception is already pending, or the script is being killed.
        // Aborting would re-enter V8 and replace it with a catchable error.
        error.TryCatchRethrow, error.JsException, error.ExecutionTerminated => self.release(),
        error.TypeError => {
            const env = local.ctx.env;
            self.abortTypeError(local, env.error_message orelse "Response body is not usable");
            env.error_message = null;
        },
        else => {
            log.err(.js, "wasm streaming", .{ .err = err });
            self.abort(local.isolate.createError(@errorName(err)));
        },
    }
}

/// With a null exception the promise is never settled, which is what a
/// context being torn down wants.
pub fn abort(self: *WasmStreaming, exception: ?*const v8.Value) void {
    v8.v8__WasmStreaming__Abort(&self.handle, exception);
    self.release();
}

fn release(self: *WasmStreaming) void {
    v8.std__shared_ptr__v8__WasmStreaming__reset(&self.handle);
    const streams = &self.ctx.wasm_streams;
    if (std.mem.indexOfScalar(*WasmStreaming, streams.items, self)) |i| {
        _ = streams.swapRemove(i);
    }
}

const testing = @import("../../testing.zig");
test "WebApi: WebAssembly" {
    try testing.htmlRunner("wasm", .{});
}
