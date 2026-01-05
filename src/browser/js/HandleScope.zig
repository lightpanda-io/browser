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

handle: v8.HandleScope,

// V8 takes an address of the value that's passed in, so it needs to be stable.
// We can't create the v8.HandleScope here, pass it to v8 and then return the
// value, as v8 will then have taken the address of the function-scopped (and no
// longer valid) local.
pub fn init(self: *HandleScope, isolate: js.Isolate) void {
    v8.v8__HandleScope__CONSTRUCT(&self.handle, isolate.handle);
}

pub fn deinit(self: *HandleScope) void {
    v8.v8__HandleScope__DESTRUCT(&self.handle);
}
