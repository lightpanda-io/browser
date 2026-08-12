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
idle_tasks_enabled: bool,

pub fn init(v8_flags: ?[]const u8) !Platform {
    return initWithOptions(v8_flags, .{});
}

pub const Options = struct {
    /// 0 lets V8 size the pool from the host CPU count.
    thread_pool_size: u8 = 0,
    idle_task_support: bool = true,
};

pub fn initWithOptions(v8_flags: ?[]const u8, opts: Options) !Platform {
    if (v8_flags) |flags| {
        v8.v8__V8__SetFlagsFromString(flags.ptr, flags.len);
    }

    if (v8.v8__V8__InitializeICU() == false) {
        return error.FailedToInitializeICU;
    }
    const handle = v8.v8__Platform__NewDefaultPlatform(
        opts.thread_pool_size,
        @intFromBool(opts.idle_task_support),
    ).?;
    v8.v8__V8__InitializePlatform(handle);
    v8.v8__V8__Initialize();
    return .{
        .handle = handle,
        .idle_tasks_enabled = opts.idle_task_support,
    };
}

pub fn deinit(self: Platform) void {
    _ = v8.v8__V8__Dispose();
    v8.v8__V8__DisposePlatform();
    v8.v8__Platform__DELETE(self.handle);
}
