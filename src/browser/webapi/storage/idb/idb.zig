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

const std = @import("std");
const js = @import("../../../js/js.zig");

pub const Key = @import("Key.zig");
pub const Engine = @import("Engine.zig");
pub const Manager = @import("Manager.zig");

pub const IDBFactory = @import("IDBFactory.zig");
pub const IDBRecord = @import("IDBRecord.zig");
pub const IDBRequest = @import("IDBRequest.zig");
pub const IDBOpenDBRequest = @import("IDBOpenDBRequest.zig");
pub const IDBCursor = @import("IDBCursor.zig");
pub const IDBIndex = @import("IDBIndex.zig");
pub const IDBDatabase = @import("IDBDatabase.zig");
pub const IDBKeyRange = @import("IDBKeyRange.zig");
pub const IDBTransaction = @import("IDBTransaction.zig");
pub const IDBObjectStore = @import("IDBObjectStore.zig");
pub const IDBCursorWithValue = @import("IDBCursorWithValue.zig");
pub const IDBVersionChangeEvent = @import("IDBVersionChangeEvent.zig");

pub fn registerTypes() []const type {
    return &.{
        IDBFactory,
        IDBRecord,
        IDBRequest,
        IDBOpenDBRequest,
        IDBCursor,
        IDBIndex,
        IDBDatabase,
        IDBKeyRange,
        IDBTransaction,
        IDBObjectStore,
        IDBCursorWithValue,
        IDBVersionChangeEvent,
    };
}

// the keyPath attribute need identity equality. For a compound key (an array)
// we have to return the same v8::rray on every reach. So users of KeyPath will
// cache it locally, and store it in the Transaction's globals list for cleanup.
pub fn cachedKeyPathJs(cache: *?*js.GlobalSlot, txn: *IDBTransaction, kp: ?Key.KeyPath, exec: *js.Execution) !js.Value {
    const local = exec.js.local.?;
    if (kp) |path| {
        if (std.meta.activeTag(path) == .list) {
            if (cache.*) |slot| {
                return slot.local(local);
            }
            const value = try Key.keyPathToJs(local, path);
            cache.* = try txn.persist(value);
            return value;
        }
    }
    return Key.keyPathToJs(local, kp);
}

const testing = @import("../../../../testing.zig");
test "WebApi: IndexedDB" {
    try testing.htmlRunner("indexeddb.html", .{});
}

test "WebApi: IndexedDB pending request keeps its JS object alive" {
    // Zone.js registers one shared listener and reads the real callbacks from
    // an expando on `this`. A pending request JS no longer references must
    // survive a GC, or its event reaches a fresh JS object without the expando.
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    // IndexedDB needs a non-opaque origin.
    try frame.navigate("http://localhost:9582/", .{});
    try testing.waitForFrame();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec(
            \\globalThis.fired = [];
            \\globalThis.zoneListener = function(e) {
            \\  for (const cb of this.__tasks || []) cb(e);
            \\};
            \\globalThis.zoneAdd = function(target, type, cb) {
            \\  (target.__tasks ||= []).push(cb);
            \\  target.addEventListener(type, zoneListener);
            \\};
            \\{
            \\  const req = indexedDB.open('gc_pin', 1);
            \\  req.onupgradeneeded = () => req.result.createObjectStore('s');
            \\  req.onsuccess = () => { globalThis.db = req.result; };
            \\}
        , null);
    }
    try testing.waitForFrame();

    {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        _ = try ls.local.exec(
            \\(() => {
            \\  const store = db.transaction('s', 'readwrite').objectStore('s');
            \\  zoneAdd(store.put(1, 'k'), 'success', () => fired.push('put'));
            \\  zoneAdd(indexedDB.open('gc_pin_2'), 'success', () => fired.push('open'));
            \\  zoneAdd(indexedDB.deleteDatabase('gc_pin_3'), 'success', () => fired.push('delete'));
            \\})();
        , null);
    }

    // Not env.memoryPressureNotification: it skips small heaps.
    const isolate = testing.test_session.browser.env.isolate;
    for (0..3) |_| {
        isolate.memoryPressureNotification(.critical);
    }

    try testing.waitForFrame();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const fired = try ls.local.exec("fired.sort().join(',')", null);
    try testing.expectEqual("delete,open,put", try fired.toStringSlice());
}
