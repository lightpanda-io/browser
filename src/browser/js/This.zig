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

// This only exists so that we know whether a function wants the opaque
// JS argument (js.Object), or if it wants the receiver as an opaque
// value.
// js.Object is normally used when a method wants an opaque JS object
// that it'll pass into a callback.
// This is used when the function wants to do advanced manipulation
// of the v8.Object bound to the instance. For example, postAttach is an
// example of using This.

const This = @This();
obj: js.Object,

pub fn setIndex(self: This, index: u32, value: anytype, opts: js.Object.SetOpts) !void {
    return self.obj.setIndex(index, value, opts);
}

pub fn set(self: This, key: []const u8, value: anytype, opts: js.Object.SetOpts) !void {
    return self.obj.set(key, value, opts);
}
