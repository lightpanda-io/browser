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

const js = @import("js.zig");
const v8 = js.v8;

const Isolate = @This();

handle: *v8.c.Isolate,

pub fn deinit(self: Isolate) void {
    v8.c.v8__Isolate__Dispose(self.handle);
}

pub fn exit(self: Isolate) void {
    v8.c.v8__Isolate__Exit(self.handle);
}

pub fn performMicrotasksCheckpoint(self: Isolate) void {
    v8.c.v8__Isolate__PerformMicrotaskCheckpoint(self.handle);
}

pub fn enqueueMicrotask(self: Isolate, callback: anytype, data: anytype) void {
    const v8_isolate = v8.Isolate{ .handle = self.handle };
    v8_isolate.enqueueMicrotask(callback, data);
}

pub fn enqueueMicrotaskFunc(self: Isolate, function: js.Function) void {
    v8.c.v8__Isolate__EnqueueMicrotaskFunc(self.handle, function.handle);
}

pub fn lowMemoryNotification(self: Isolate) void {
    v8.c.v8__Isolate__LowMemoryNotification(self.handle);
}

pub fn getHeapStatistics(self: Isolate) v8.c.HeapStatistics {
    var res: v8.c.HeapStatistics = undefined;
    v8.c.v8__Isolate__GetHeapStatistics(self.handle, &res);
    return res;
}

pub fn throwException(self: Isolate, value: anytype) v8.Value {
    const handle = switch (@TypeOf(value)) {
        v8.Value => value.handle,
        else => @compileError("Unsupported type for throwException"),
    };
    return .{
        .handle = v8.c.v8__Isolate__ThrowException(self.handle, handle).?,
    };
}

pub fn newStringHandle(self: Isolate, str: []const u8) *const v8.c.String {
    return v8.c.v8__String__NewFromUtf8(self.handle, str.ptr, v8.c.kNormal, @as(c_int, @intCast(str.len))).?;
}
