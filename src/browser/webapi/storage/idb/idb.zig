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

pub const Key = @import("Key.zig");
pub const Engine = @import("Engine.zig");
pub const Manager = @import("Manager.zig");

pub const IDBFactory = @import("IDBFactory.zig");
pub const IDBRequest = @import("IDBRequest.zig");
pub const IDBDatabase = @import("IDBDatabase.zig");
pub const IDBKeyRange = @import("IDBKeyRange.zig");
pub const IDBTransaction = @import("IDBTransaction.zig");
pub const IDBObjectStore = @import("IDBObjectStore.zig");
pub const IDBVersionChangeEvent = @import("IDBVersionChangeEvent.zig");

pub fn registerTypes() []const type {
    return &.{
        IDBFactory,
        IDBRequest,
        IDBDatabase,
        IDBKeyRange,
        IDBTransaction,
        IDBObjectStore,
        IDBVersionChangeEvent,
    };
}

// An on* event-handler attribute setter. The bridge can hand the setter either
// a function (store it) or any other value (clears it).
pub const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

const testing = @import("../../../../testing.zig");
test "WebApi: IndexedDB" {
    try testing.htmlRunner("indexeddb.html", .{});
}
