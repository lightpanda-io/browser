// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

pub fn registerTypes() []const type {
    return &.{ StorageManager, StorageEstimate };
}

const StorageManager = @This();

_pad: bool = false,

pub fn estimate(_: *const StorageManager, page: *Page) !js.Promise {
    const est = try page._factory.create(StorageEstimate{
        ._usage = 0,
        ._quota = 1024 * 1024 * 1024, // 1 GiB
    });
    return page.js.local.?.resolvePromise(est);
}

const StorageEstimate = struct {
    _quota: u64,
    _usage: u64,

    fn getUsage(self: *const StorageEstimate) u64 {
        return self._usage;
    }

    fn getQuota(self: *const StorageEstimate) u64 {
        return self._quota;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StorageEstimate);
        pub const Meta = struct {
            pub const name = "StorageEstimate";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const quota = bridge.accessor(getQuota, null, .{});
        pub const usage = bridge.accessor(getUsage, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(StorageManager);
    pub const Meta = struct {
        pub const name = "StorageManager";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };
    pub const estimate = bridge.function(StorageManager.estimate, .{});
};
