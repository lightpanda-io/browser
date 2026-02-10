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

const PromiseRejection = @This();

local: *const js.Local,
handle: *const v8.PromiseRejectMessage,

pub fn promise(self: PromiseRejection) js.Promise {
    return .{
        .local = self.local,
        .handle = v8.v8__PromiseRejectMessage__GetPromise(self.handle).?,
    };
}

pub fn reason(self: PromiseRejection) ?js.Value {
    const value_handle = v8.v8__PromiseRejectMessage__GetValue(self.handle) orelse return null;

    return .{
        .local = self.local,
        .handle = value_handle,
    };
}
