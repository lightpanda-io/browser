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

const js = @import("js.zig");
const v8 = js.v8;

const Private = @This();

// Unlike most types, we always store the Private as a Global. It makes more
// sense for this type given how it's used.
handle: v8.Global,

pub fn init(isolate: *v8.Isolate, name: []const u8) Private {
    const v8_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
    const private_handle = v8.v8__Private__New(isolate, v8_name);

    var global: v8.Global = undefined;
    v8.v8__Global__New(isolate, private_handle, &global);

    return .{
        .handle = global,
    };
}

pub fn deinit(self: *Private) void {
    v8.v8__Global__Reset(&self.handle);
}
