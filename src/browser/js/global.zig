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

const std = @import("std");
const js = @import("js.zig");

const v8 = js.v8;

pub fn Global(comptime T: type) type {
    const H = @FieldType(T, "handle");

    return struct {
        global: v8.c.Global,

        const Self = @This();

        pub fn init(isolate: *v8.c.Isolate, handle: H) Self {
            var global: v8.c.Global = undefined;
            v8.c.v8__Global__New(isolate, handle, &global);
            return .{
                .global = global,
            };
        }

        pub fn deinit(self: *Self) void {
            v8.c.v8__Global__Reset(&self.global);
        }

        pub fn local(self: *const Self) H {
            return @ptrCast(@alignCast(@as(*const anyopaque, @ptrFromInt(self.global.data_ptr))));
        }
    };
}
