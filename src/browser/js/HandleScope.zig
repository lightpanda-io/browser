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

const HandleScope = @This();

inner: v8.c.HandleScope,

pub fn init(self: *HandleScope, isolate: js.Isolate) void {
    v8.c.v8__HandleScope__CONSTRUCT(&self.inner, isolate.handle);
}

pub fn deinit(self: *HandleScope) void {
    v8.c.v8__HandleScope__DESTRUCT(&self.inner);
}
