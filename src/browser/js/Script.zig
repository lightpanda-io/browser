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

const Script = @This();

handle: *const v8.c.Script,

pub fn compile(ctx_handle: *const v8.c.Context, src_handle: *const v8.c.String, origin: ?*const v8.c.ScriptOrigin) !Script {
    if (v8.c.v8__Script__Compile(ctx_handle, src_handle, origin)) |handle| {
        return .{ .handle = handle };
    }
    return error.JsException;
}

pub fn run(self: Script, ctx_handle: *const v8.c.Context) !v8.Value {
    if (v8.c.v8__Script__Run(self.handle, ctx_handle)) |value| {
        return .{ .handle = value };
    }
    return error.JsException;
}
