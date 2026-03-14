const std = @import("std");
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const String = @import("../../../string.zig").String;

const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ IDBFactory, IDBRequest, IDBOpenDBRequest, IDBDatabase, IDBTransaction, IDBObjectStore };
}

pub const Shed = struct {
    _origins: std.StringHashMapUnmanaged(*OriginBucket) = .empty,

    pub fn deinit(self: *Shed, allocator: Allocator) void {
        var it = self._origins.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit(allocator);
            allocator.destroy(kv.value_ptr.*);
        }
        self._origins.deinit(allocator);
        self.* = .{};
    }

    pub fn clear(self: *Shed, allocator: Allocator) void {
        self.deinit(allocator);
    }

    pub fn getOrPutOrigin(self: *Shed, allocator: Allocator, origin: []const u8) !*OriginBucket {
        const gop = try self._origins.getOrPut(allocator, origin);
        if (gop.found_existing) {
            return gop.value_ptr.*;
        }

        const bucket = try allocator.create(OriginBucket);
        errdefer allocator.destroy(bucket);
        bucket.* = .{};

        gop.key_ptr.* = try allocator.dupe(u8, origin);
        gop.value_ptr.* = bucket;
        return bucket;
    }

    pub fn getOrigin(self: *const Shed, origin: []const u8) ?*OriginBucket {
        return self._origins.get(origin);
    }

    pub fn originCount(self: *const Shed) usize {
        var count: usize = 0;
        var it = self._origins.valueIterator();
        while (it.next()) |bucket| {
            if (bucket.*._databases.count() > 0) {
                count += 1;
            }
        }
        return count;
    }

    pub fn databaseCount(self: *const Shed) usize {
        var count: usize = 0;
        var it = self._origins.valueIterator();
        while (it.next()) |bucket| {
            count += bucket.*.databaseCount();
        }
        return count;
    }

    pub fn storeCount(self: *const Shed) usize {
        var count: usize = 0;
        var it = self._origins.valueIterator();
        while (it.next()) |bucket| {
            count += bucket.*.storeCount();
        }
        return count;
    }

    pub fn itemCount(self: *const Shed) usize {
        var count: usize = 0;
        var it = self._origins.valueIterator();
        while (it.next()) |bucket| {
            count += bucket.*.itemCount();
        }
        return count;
    }
};

pub const OriginBucket = struct {
    _databases: std.StringHashMapUnmanaged(*DatabaseData) = .empty,

    pub fn deinit(self: *OriginBucket, allocator: Allocator) void {
        var it = self._databases.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit(allocator);
            allocator.destroy(kv.value_ptr.*);
        }
        self._databases.deinit(allocator);
        self.* = .{};
    }

    pub fn getOrPutDatabase(self: *OriginBucket, allocator: Allocator, name: []const u8) !*DatabaseData {
        const gop = try self._databases.getOrPut(allocator, name);
        if (gop.found_existing) {
            return gop.value_ptr.*;
        }

        const database = try allocator.create(DatabaseData);
        errdefer allocator.destroy(database);
        database.* = .{};

        gop.key_ptr.* = try allocator.dupe(u8, name);
        gop.value_ptr.* = database;
        return database;
    }

    pub fn getDatabase(self: *const OriginBucket, name: []const u8) ?*DatabaseData {
        return self._databases.get(name);
    }

    pub fn databaseCount(self: *const OriginBucket) usize {
        return self._databases.count();
    }

    pub fn storeCount(self: *const OriginBucket) usize {
        var count: usize = 0;
        var it = self._databases.valueIterator();
        while (it.next()) |database| {
            count += database.*.storeCount();
        }
        return count;
    }

    pub fn itemCount(self: *const OriginBucket) usize {
        var count: usize = 0;
        var it = self._databases.valueIterator();
        while (it.next()) |database| {
            count += database.*.itemCount();
        }
        return count;
    }
};

pub const DatabaseData = struct {
    version: u32 = 0,
    _stores: std.StringHashMapUnmanaged(*ObjectStoreData) = .empty,

    pub fn deinit(self: *DatabaseData, allocator: Allocator) void {
        var it = self._stores.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit(allocator);
            allocator.destroy(kv.value_ptr.*);
        }
        self._stores.deinit(allocator);
        self.* = .{};
    }

    pub fn getStore(self: *const DatabaseData, name: []const u8) ?*ObjectStoreData {
        return self._stores.get(name);
    }

    pub fn createStore(self: *DatabaseData, allocator: Allocator, name: []const u8) !*ObjectStoreData {
        const gop = try self._stores.getOrPut(allocator, name);
        if (gop.found_existing) {
            return error.ConstraintError;
        }

        const store = try allocator.create(ObjectStoreData);
        errdefer allocator.destroy(store);
        store.* = .{};

        gop.key_ptr.* = try allocator.dupe(u8, name);
        gop.value_ptr.* = store;
        return store;
    }

    pub fn getOrPutStore(self: *DatabaseData, allocator: Allocator, name: []const u8) !*ObjectStoreData {
        const gop = try self._stores.getOrPut(allocator, name);
        if (gop.found_existing) {
            return gop.value_ptr.*;
        }

        const store = try allocator.create(ObjectStoreData);
        errdefer allocator.destroy(store);
        store.* = .{};

        gop.key_ptr.* = try allocator.dupe(u8, name);
        gop.value_ptr.* = store;
        return store;
    }

    pub fn storeCount(self: *const DatabaseData) usize {
        return self._stores.count();
    }

    pub fn itemCount(self: *const DatabaseData) usize {
        var count: usize = 0;
        var it = self._stores.valueIterator();
        while (it.next()) |store| {
            count += store.*.itemCount();
        }
        return count;
    }
};

pub const ObjectStoreData = struct {
    _items: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(self: *ObjectStoreData, allocator: Allocator) void {
        var it = self._items.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        self._items.deinit(allocator);
        self.* = .{};
    }

    pub fn putJson(self: *ObjectStoreData, allocator: Allocator, key: []const u8, json: []const u8) !void {
        const key_owned = try allocator.dupe(u8, key);
        errdefer allocator.free(key_owned);
        const value_owned = try allocator.dupe(u8, json);
        errdefer allocator.free(value_owned);

        const gop = try self._items.getOrPut(allocator, key_owned);
        if (gop.found_existing) {
            allocator.free(key_owned);
            allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = value_owned;
    }

    pub fn getJson(self: *const ObjectStoreData, key: []const u8) ?[]const u8 {
        return self._items.get(key);
    }

    pub fn deleteKey(self: *ObjectStoreData, allocator: Allocator, key: []const u8) bool {
        if (self._items.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
            return true;
        }
        return false;
    }

    pub fn clear(self: *ObjectStoreData, allocator: Allocator) void {
        var it = self._items.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        self._items.clearAndFree(allocator);
    }

    pub fn itemCount(self: *const ObjectStoreData) usize {
        return self._items.count();
    }
};

pub const IDBFactory = struct {
    _page: *Page,
    _shed: *Shed,
    _origin: []const u8,
    _persistent: bool,

    pub fn init(page: *Page, shed: *Shed, origin: []const u8, persistent: bool) !*IDBFactory {
        return page._factory.create(IDBFactory{
            ._page = page,
            ._shed = shed,
            ._origin = try page.arena.dupe(u8, origin),
            ._persistent = persistent,
        });
    }

    fn storageAllocator(self: *const IDBFactory) Allocator {
        if (self._persistent) {
            return self._page._session.browser.app.allocator;
        }
        return self._page.arena;
    }

    pub fn open(self: *IDBFactory, name: []const u8, version_: ?u32, page: *Page) !*IDBOpenDBRequest {
        const request = try page._factory.eventTarget(IDBOpenDBRequest{
            ._proto = undefined,
            ._page = page,
        });

        const allocator = self.storageAllocator();
        var callback = try page._factory.create(OpenRequestCallback{
            .page = page,
            .request = request,
            .fire_upgrade = false,
        });

        if (name.len == 0) {
            request._error = "InvalidAccessError";
        } else if (version_ != null and version_.? == 0) {
            request._error = "VersionError";
        } else {
            const bucket = try self._shed.getOrPutOrigin(allocator, self._origin);
            const database = try bucket.getOrPutDatabase(allocator, name);
            const current_version = if (database.version == 0) @as(u32, 1) else database.version;
            const requested_version = version_ orelse current_version;
            if (database.version != 0 and requested_version < database.version) {
                request._error = "VersionError";
            } else {
                const upgrade = database.version == 0 or requested_version > database.version;
                if (upgrade) {
                    database.version = requested_version;
                } else if (database.version == 0) {
                    database.version = current_version;
                }
                request._result = try page._factory.eventTarget(IDBDatabase{
                    ._proto = undefined,
                    ._page = page,
                    ._factory = self,
                    ._name = try page.arena.dupe(u8, name),
                    ._data = database,
                });
                callback.fire_upgrade = upgrade;
            }
        }

        try page.js.scheduler.add(callback, OpenRequestCallback.run, 0, .{
            .name = "IDBFactory.open",
            .low_priority = false,
        });
        return request;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IDBFactory);

        pub const Meta = struct {
            pub const name = "IDBFactory";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const open = bridge.function(IDBFactory.open, .{ .dom_exception = true });
    };
};

pub const IDBDatabase = struct {
    _proto: *EventTarget,
    _page: *Page,
    _factory: *IDBFactory,
    _name: []const u8,
    _data: *DatabaseData,

    pub fn asEventTarget(self: *IDBDatabase) *EventTarget {
        return self._proto;
    }

    pub fn getName(self: *const IDBDatabase) []const u8 {
        return self._name;
    }

    pub fn getVersion(self: *const IDBDatabase) u32 {
        return self._data.version;
    }

    pub fn createObjectStore(self: *IDBDatabase, name: []const u8, _: *Page) !*IDBObjectStore {
        const store = try self._data.createStore(self._factory.storageAllocator(), name);
        return self._page._factory.create(IDBObjectStore{
            ._page = self._page,
            ._transaction = null,
            ._database = self,
            ._name = try self._page.arena.dupe(u8, name),
            ._data = store,
        });
    }

    pub fn transaction(self: *IDBDatabase, name: []const u8, mode_: ?[]const u8, _: *Page) !*IDBTransaction {
        _ = mode_;
        if (self._data.getStore(name) == null) {
            return error.NotFoundError;
        }
        return self._page._factory.create(IDBTransaction{
            ._page = self._page,
            ._database = self,
            ._store_name = try self._page.arena.dupe(u8, name),
        });
    }

    pub fn close(_: *IDBDatabase) void {}

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IDBDatabase);

        pub const Meta = struct {
            pub const name = "IDBDatabase";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(IDBDatabase.getName, null, .{});
        pub const version = bridge.accessor(IDBDatabase.getVersion, null, .{});
        pub const createObjectStore = bridge.function(IDBDatabase.createObjectStore, .{ .dom_exception = true });
        pub const transaction = bridge.function(IDBDatabase.transaction, .{ .dom_exception = true });
        pub const close = bridge.function(IDBDatabase.close, .{});
    };
};

pub const IDBTransaction = struct {
    _page: *Page,
    _database: *IDBDatabase,
    _store_name: []const u8,

    pub fn objectStore(self: *IDBTransaction, name: []const u8, _: *Page) !*IDBObjectStore {
        if (!std.mem.eql(u8, name, self._store_name)) {
            return error.NotFoundError;
        }
        const store = self._database._data.getStore(name) orelse return error.NotFoundError;
        return self._page._factory.create(IDBObjectStore{
            ._page = self._page,
            ._transaction = self,
            ._database = self._database,
            ._name = try self._page.arena.dupe(u8, name),
            ._data = store,
        });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IDBTransaction);

        pub const Meta = struct {
            pub const name = "IDBTransaction";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const objectStore = bridge.function(IDBTransaction.objectStore, .{ .dom_exception = true });
    };
};

pub const IDBObjectStore = struct {
    _page: *Page,
    _transaction: ?*IDBTransaction,
    _database: *IDBDatabase,
    _name: []const u8,
    _data: *ObjectStoreData,

    pub fn getName(self: *const IDBObjectStore) []const u8 {
        return self._name;
    }

    pub fn put(self: *IDBObjectStore, value: js.Value.Temp, key: []const u8, page: *Page) !*IDBRequest {
        const json = try value.local(page.js.local.?).toJson(page.call_arena);
        try self._data.putJson(self._database._factory.storageAllocator(), key, json);

        const request = try page._factory.eventTarget(IDBRequest{
            ._proto = undefined,
            ._page = page,
            ._result_json = try std.json.Stringify.valueAlloc(page.arena, key, .{}),
            ._source = self,
            ._transaction = self._transaction,
        });
        try scheduleRequestSuccess(page, request, "IDBObjectStore.put");
        return request;
    }

    pub fn get(self: *IDBObjectStore, key: []const u8, page: *Page) !*IDBRequest {
        const request = try page._factory.eventTarget(IDBRequest{
            ._proto = undefined,
            ._page = page,
            ._source = self,
            ._transaction = self._transaction,
        });
        if (self._data.getJson(key)) |json| {
            request._result_json = json;
        } else {
            request._result_json = "null";
        }
        try scheduleRequestSuccess(page, request, "IDBObjectStore.get");
        return request;
    }

    pub fn @"delete"(self: *IDBObjectStore, key: []const u8, page: *Page) !*IDBRequest {
        _ = self._data.deleteKey(self._database._factory.storageAllocator(), key);
        const request = try page._factory.eventTarget(IDBRequest{
            ._proto = undefined,
            ._page = page,
            ._result_json = "null",
            ._source = self,
            ._transaction = self._transaction,
        });
        try scheduleRequestSuccess(page, request, "IDBObjectStore.delete");
        return request;
    }

    pub fn clear(self: *IDBObjectStore, page: *Page) !*IDBRequest {
        self._data.clear(self._database._factory.storageAllocator());
        const request = try page._factory.eventTarget(IDBRequest{
            ._proto = undefined,
            ._page = page,
            ._result_json = "null",
            ._source = self,
            ._transaction = self._transaction,
        });
        try scheduleRequestSuccess(page, request, "IDBObjectStore.clear");
        return request;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IDBObjectStore);

        pub const Meta = struct {
            pub const name = "IDBObjectStore";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(IDBObjectStore.getName, null, .{});
        pub const put = bridge.function(IDBObjectStore.put, .{ .dom_exception = true });
        pub const get = bridge.function(IDBObjectStore.get, .{ .dom_exception = true });
        pub const delete = bridge.function(IDBObjectStore.@"delete", .{ .dom_exception = true });
        pub const clear = bridge.function(IDBObjectStore.clear, .{ .dom_exception = true });
    };
};

pub const IDBRequest = struct {
    _proto: *EventTarget,
    _page: *Page,
    _result_json: ?[]const u8 = null,
    _error: ?[]const u8 = null,
    _source: ?*IDBObjectStore = null,
    _transaction: ?*IDBTransaction = null,
    _on_success: ?js.Function.Temp = null,
    _on_error: ?js.Function.Temp = null,

    pub fn asEventTarget(self: *IDBRequest) *EventTarget {
        return self._proto;
    }

    pub fn getResult(self: *const IDBRequest, page: *Page) !js.Value {
        const local = page.js.local.?;
        if (self._result_json) |json| {
            return try local.parseJSON(json);
        }
        return .{
            .local = local,
            .handle = local.isolate.initUndefined(),
        };
    }

    pub fn getError(self: *const IDBRequest) ?[]const u8 {
        return self._error;
    }

    pub fn getSource(self: *const IDBRequest) ?*IDBObjectStore {
        return self._source;
    }

    pub fn getTransaction(self: *const IDBRequest) ?*IDBTransaction {
        return self._transaction;
    }

    pub fn getOnSuccess(self: *const IDBRequest) ?js.Function.Temp {
        return self._on_success;
    }

    pub fn setOnSuccess(self: *IDBRequest, cb: ?js.Function.Temp) !void {
        self._on_success = cb;
    }

    pub fn getOnError(self: *const IDBRequest) ?js.Function.Temp {
        return self._on_error;
    }

    pub fn setOnError(self: *IDBRequest, cb: ?js.Function.Temp) !void {
        self._on_error = cb;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IDBRequest);

        pub const Meta = struct {
            pub const name = "IDBRequest";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const result = bridge.accessor(IDBRequest.getResult, null, .{});
        pub const @"error" = bridge.accessor(IDBRequest.getError, null, .{});
        pub const source = bridge.accessor(IDBRequest.getSource, null, .{});
        pub const transaction = bridge.accessor(IDBRequest.getTransaction, null, .{});
        pub const onsuccess = bridge.accessor(IDBRequest.getOnSuccess, IDBRequest.setOnSuccess, .{});
        pub const onerror = bridge.accessor(IDBRequest.getOnError, IDBRequest.setOnError, .{});
    };
};

pub const IDBOpenDBRequest = struct {
    _proto: *EventTarget,
    _page: *Page,
    _result: ?*IDBDatabase = null,
    _error: ?[]const u8 = null,
    _on_success: ?js.Function.Temp = null,
    _on_error: ?js.Function.Temp = null,
    _on_upgradeneeded: ?js.Function.Temp = null,

    pub fn asEventTarget(self: *IDBOpenDBRequest) *EventTarget {
        return self._proto;
    }

    pub fn getResult(self: *const IDBOpenDBRequest) ?*IDBDatabase {
        return self._result;
    }

    pub fn getError(self: *const IDBOpenDBRequest) ?[]const u8 {
        return self._error;
    }

    pub fn getOnSuccess(self: *const IDBOpenDBRequest) ?js.Function.Temp {
        return self._on_success;
    }

    pub fn setOnSuccess(self: *IDBOpenDBRequest, cb: ?js.Function.Temp) !void {
        self._on_success = cb;
    }

    pub fn getOnError(self: *const IDBOpenDBRequest) ?js.Function.Temp {
        return self._on_error;
    }

    pub fn setOnError(self: *IDBOpenDBRequest, cb: ?js.Function.Temp) !void {
        self._on_error = cb;
    }

    pub fn getOnUpgradeNeeded(self: *const IDBOpenDBRequest) ?js.Function.Temp {
        return self._on_upgradeneeded;
    }

    pub fn setOnUpgradeNeeded(self: *IDBOpenDBRequest, cb: ?js.Function.Temp) !void {
        self._on_upgradeneeded = cb;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IDBOpenDBRequest);

        pub const Meta = struct {
            pub const name = "IDBOpenDBRequest";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const result = bridge.accessor(IDBOpenDBRequest.getResult, null, .{});
        pub const @"error" = bridge.accessor(IDBOpenDBRequest.getError, null, .{});
        pub const onsuccess = bridge.accessor(IDBOpenDBRequest.getOnSuccess, IDBOpenDBRequest.setOnSuccess, .{});
        pub const onerror = bridge.accessor(IDBOpenDBRequest.getOnError, IDBOpenDBRequest.setOnError, .{});
        pub const onupgradeneeded = bridge.accessor(IDBOpenDBRequest.getOnUpgradeNeeded, IDBOpenDBRequest.setOnUpgradeNeeded, .{});
    };
};

const RequestCallback = struct {
    page: *Page,
    request: *IDBRequest,

    fn deinit(self: *RequestCallback) void {
        self.page._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *RequestCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const page = self.page;
        const request = self.request;
        const event_type = if (request._error == null) "success" else "error";
        const event = try Event.initTrusted(try String.init(page.arena, event_type, .{}), null, page);
        try page._event_manager.dispatchDirect(
            request.asEventTarget(),
            event,
            if (request._error == null) request._on_success else request._on_error,
            .{ .inject_target = true, .context = "indexedDB.request" },
        );
        return null;
    }
};

const OpenRequestCallback = struct {
    page: *Page,
    request: *IDBOpenDBRequest,
    fire_upgrade: bool,

    fn deinit(self: *OpenRequestCallback) void {
        self.page._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *OpenRequestCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const page = self.page;
        const request = self.request;

        if (request._error) |_| {
            const error_event = try Event.initTrusted(try String.init(page.arena, "error", .{}), null, page);
            try page._event_manager.dispatchDirect(
                request.asEventTarget(),
                error_event,
                request._on_error,
                .{ .inject_target = true, .context = "indexedDB.open.error" },
            );
            return null;
        }

        if (self.fire_upgrade) {
            const upgrade_event = try Event.initTrusted(try String.init(page.arena, "upgradeneeded", .{}), null, page);
            try page._event_manager.dispatchDirect(
                request.asEventTarget(),
                upgrade_event,
                request._on_upgradeneeded,
                .{ .inject_target = true, .context = "indexedDB.open.upgradeneeded" },
            );
        }

        const success_event = try Event.initTrusted(try String.init(page.arena, "success", .{}), null, page);
        try page._event_manager.dispatchDirect(
            request.asEventTarget(),
            success_event,
            request._on_success,
            .{ .inject_target = true, .context = "indexedDB.open.success" },
        );
        return null;
    }
};

fn scheduleRequestSuccess(page: *Page, request: *IDBRequest, name: []const u8) !void {
    const callback = try page._factory.create(RequestCallback{
        .page = page,
        .request = request,
    });
    try page.js.scheduler.add(callback, RequestCallback.run, 0, .{
        .name = name,
        .low_priority = false,
    });
}

const testing = @import("../../../testing.zig");
test "WebApi: IndexedDB" {
    try testing.htmlRunner("indexed_db.html", .{});
}
