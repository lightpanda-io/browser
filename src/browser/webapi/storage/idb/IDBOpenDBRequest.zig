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

const js = @import("../../../js/js.zig");

const idb = @import("idb.zig");
const IDBRequest = @import("IDBRequest.zig");

const FunctionSetter = idb.FunctionSetter;

// The request returned by IDBFactory.open / deleteDatabase.
const IDBOpenDBRequest = @This();

pub const Proto = IDBRequest;

_proto: *IDBRequest,
// Stored, never fired: an open that upgrades does not wait on other
// connections (see IDBFactory.OpenContext), so nothing ever blocks.
_on_blocked: ?js.Function.Global = null,

pub fn getOnBlocked(self: *const IDBOpenDBRequest) ?js.Function.Global {
    return self._on_blocked;
}

pub fn setOnBlocked(self: *IDBOpenDBRequest, setter: ?FunctionSetter) void {
    self._on_blocked = idb.functionFromSetter(setter);
}

pub fn getOnUpgradeNeeded(self: *const IDBOpenDBRequest) ?js.Function.Global {
    return self._proto.getOnUpgradeNeeded();
}

pub fn setOnUpgradeNeeded(self: *IDBOpenDBRequest, setter: ?FunctionSetter) void {
    self._proto.setOnUpgradeNeeded(setter);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBOpenDBRequest);

    pub const Meta = struct {
        pub const name = "IDBOpenDBRequest";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const onblocked = bridge.accessor(IDBOpenDBRequest.getOnBlocked, IDBOpenDBRequest.setOnBlocked, .{});
    pub const onupgradeneeded = bridge.accessor(IDBOpenDBRequest.getOnUpgradeNeeded, IDBOpenDBRequest.setOnUpgradeNeeded, .{});
};
