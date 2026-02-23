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

handle: *v8.Isolate,

pub fn init(params: *v8.CreateParams) Isolate {
    return .{
        .handle = v8.v8__Isolate__New(params).?,
    };
}

pub fn deinit(self: Isolate) void {
    v8.v8__Isolate__Dispose(self.handle);
}

pub fn enter(self: Isolate) void {
    v8.v8__Isolate__Enter(self.handle);
}

pub fn exit(self: Isolate) void {
    v8.v8__Isolate__Exit(self.handle);
}

pub fn lowMemoryNotification(self: Isolate) void {
    v8.v8__Isolate__LowMemoryNotification(self.handle);
}

pub const MemoryPressureLevel = enum(u32) {
    none = v8.kNone,
    moderate = v8.kModerate,
    critical = v8.kCritical,
};

pub fn memoryPressureNotification(self: Isolate, level: MemoryPressureLevel) void {
    v8.v8__Isolate__MemoryPressureNotification(self.handle, @intFromEnum(level));
}

pub fn notifyContextDisposed(self: Isolate) void {
    _ = v8.v8__Isolate__ContextDisposedNotification(self.handle);
}

pub fn getHeapStatistics(self: Isolate) v8.HeapStatistics {
    var res: v8.HeapStatistics = undefined;
    v8.v8__Isolate__GetHeapStatistics(self.handle, &res);
    return res;
}

pub fn throwException(self: Isolate, value: *const v8.Value) *const v8.Value {
    return v8.v8__Isolate__ThrowException(self.handle, value).?;
}

pub fn initStringHandle(self: Isolate, str: []const u8) *const v8.String {
    return v8.v8__String__NewFromUtf8(self.handle, str.ptr, v8.kNormal, @as(c_int, @intCast(str.len))).?;
}

pub fn createError(self: Isolate, msg: []const u8) *const v8.Value {
    const message = self.initStringHandle(msg);
    return v8.v8__Exception__Error(message).?;
}

pub fn createTypeError(self: Isolate, msg: []const u8) *const v8.Value {
    const message = self.initStringHandle(msg);
    return v8.v8__Exception__TypeError(message).?;
}

pub fn initNull(self: Isolate) *const v8.Value {
    return v8.v8__Null(self.handle).?;
}

pub fn initUndefined(self: Isolate) *const v8.Value {
    return v8.v8__Undefined(self.handle).?;
}

pub fn initFalse(self: Isolate) *const v8.Value {
    return v8.v8__False(self.handle).?;
}

pub fn initTrue(self: Isolate) *const v8.Value {
    return v8.v8__True(self.handle).?;
}

pub fn initInteger(self: Isolate, val: anytype) js.Integer {
    return js.Integer.init(self.handle, val);
}

pub fn initBigInt(self: Isolate, val: anytype) js.BigInt {
    return js.BigInt.init(self.handle, val);
}

pub fn initNumber(self: Isolate, val: anytype) js.Number {
    return js.Number.init(self.handle, val);
}

pub fn createExternal(self: Isolate, val: *anyopaque) *const v8.External {
    return v8.v8__External__New(self.handle, val).?;
}
