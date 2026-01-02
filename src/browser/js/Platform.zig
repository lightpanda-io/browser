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

const Platform = @This();
handle: *v8.Platform,

pub fn init() !Platform {
    if (v8.v8__V8__InitializeICU() == false) {
        return error.FailedToInitializeICU;
    }
    // 0 - threadpool size, 0 == let v8 decide
    // 1 - idle_task_support, 1 == enabled
    const handle = v8.v8__Platform__NewDefaultPlatform(0, 1).?;
    v8.v8__V8__InitializePlatform(handle);
    v8.v8__V8__Initialize();
    return .{ .handle = handle };
}

pub fn deinit(self: Platform) void {
    _ = v8.v8__V8__Dispose();
    v8.v8__V8__DisposePlatform();
    v8.v8__Platform__DELETE(self.handle);
}
