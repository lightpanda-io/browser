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

// Origin represents the shared Zig<->JS bridge state for all contexts within
// the same origin. Multiple contexts (frames) from the same origin share a
// single Origin, ensuring that JS objects maintain their identity across frames.

const std = @import("std");
const js = @import("js.zig");

const App = @import("../../App.zig");
const Session = @import("../Session.zig");

const v8 = js.v8;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Origin = @This();

rc: usize = 1,
arena: Allocator,

// The key, e.g. lightpanda.io:443
key: []const u8,

// Security token - all contexts in this realm must use the same v8::Value instance
// as their security token for V8 to allow cross-context access
security_token: v8.Global,

// Serves two purposes. Like `global_objects`, this is used to free
// every Global(Object) we've created during the lifetime of the realm.
// More importantly, it serves as an identity map - for a given Zig
// instance, we map it to the same Global(Object).
// The key is the @intFromPtr of the Zig value
identity_map: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,

// Some web APIs have to manage opaque values. Ideally, they use an
// js.Object, but the js.Object has no lifetime guarantee beyond the
// current call. They can call .persist() on their js.Object to get
// a `Global(Object)`. We need to track these to free them.
// This used to be a map and acted like identity_map; the key was
// the @intFromPtr(js_obj.handle). But v8 can re-use address. Without
// a reliable way to know if an object has already been persisted,
// we now simply persist every time persist() is called.
globals: std.ArrayList(v8.Global) = .empty,

// Temp variants stored in HashMaps for O(1) early cleanup.
// Key is global.data_ptr.
temps: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,

// Any type that is stored in the identity_map which has a finalizer declared
// will have its finalizer stored here. This is only used when shutting down
// if v8 hasn't called the finalizer directly itself.
finalizer_callbacks: std.AutoHashMapUnmanaged(usize, *FinalizerCallback) = .empty,

pub fn init(app: *App, isolate: js.Isolate, key: []const u8) !*Origin {
    const arena = try app.arena_pool.acquire();
    errdefer app.arena_pool.release(arena);

    var hs: js.HandleScope = undefined;
    hs.init(isolate);
    defer hs.deinit();

    const owned_key = try arena.dupe(u8, key);
    const token_local = isolate.initStringHandle(owned_key);
    var token_global: v8.Global = undefined;
    v8.v8__Global__New(isolate.handle, token_local, &token_global);

    const self = try arena.create(Origin);
    self.* = .{
        .rc = 1,
        .arena = arena,
        .key = owned_key,
        .globals = .empty,
        .temps = .empty,
        .security_token = token_global,
    };
    return self;
}

pub fn deinit(self: *Origin, app: *App) void {
    // Call finalizers before releasing anything
    {
        var it = self.finalizer_callbacks.valueIterator();
        while (it.next()) |finalizer| {
            finalizer.*.deinit();
        }
    }

    v8.v8__Global__Reset(&self.security_token);

    {
        var it = self.identity_map.valueIterator();
        while (it.next()) |global| {
            v8.v8__Global__Reset(global);
        }
    }

    for (self.globals.items) |*global| {
        v8.v8__Global__Reset(global);
    }

    {
        var it = self.temps.valueIterator();
        while (it.next()) |global| {
            v8.v8__Global__Reset(global);
        }
    }

    app.arena_pool.release(self.arena);
}

pub fn trackGlobal(self: *Origin, global: v8.Global) !void {
    return self.globals.append(self.arena, global);
}

pub const IdentityResult = struct {
    value_ptr: *v8.Global,
    found_existing: bool,
};

pub fn addIdentity(self: *Origin, ptr: usize) !IdentityResult {
    const gop = try self.identity_map.getOrPut(self.arena, ptr);
    return .{
        .value_ptr = gop.value_ptr,
        .found_existing = gop.found_existing,
    };
}

pub fn trackTemp(self: *Origin, global: v8.Global) !void {
    return self.temps.put(self.arena, global.data_ptr, global);
}

pub fn releaseTemp(self: *Origin, global: v8.Global) void {
    if (self.temps.fetchRemove(global.data_ptr)) |kv| {
        var g = kv.value;
        v8.v8__Global__Reset(&g);
    }
}

/// Release an item from the identity_map (called after finalizer runs from V8)
pub fn release(self: *Origin, item: *anyopaque) void {
    var global = self.identity_map.fetchRemove(@intFromPtr(item)) orelse {
        if (comptime IS_DEBUG) {
            std.debug.assert(false);
        }
        return;
    };
    v8.v8__Global__Reset(&global.value);

    // The item has been finalized, remove it from the finalizer callback so that
    // we don't try to call it again on shutdown.
    const kv = self.finalizer_callbacks.fetchRemove(@intFromPtr(item)) orelse {
        if (comptime IS_DEBUG) {
            std.debug.assert(false);
        }
        return;
    };
    const fc = kv.value;
    fc.session.releaseArena(fc.arena);
}

pub fn createFinalizerCallback(
    self: *Origin,
    session: *Session,
    global: v8.Global,
    ptr: *anyopaque,
    zig_finalizer: *const fn (ptr: *anyopaque, session: *Session) void,
) !*FinalizerCallback {
    const arena = try session.getArena(.{ .debug = "FinalizerCallback" });
    errdefer session.releaseArena(arena);
    const fc = try arena.create(FinalizerCallback);
    fc.* = .{
        .arena = arena,
        .origin = self,
        .session = session,
        .ptr = ptr,
        .global = global,
        .zig_finalizer = zig_finalizer,
    };
    return fc;
}

pub fn transferTo(self: *Origin, dest: *Origin) !void {
    const arena = dest.arena;

    try dest.globals.ensureUnusedCapacity(arena, self.globals.items.len);
    for (self.globals.items) |obj| {
        dest.globals.appendAssumeCapacity(obj);
    }
    self.globals.clearRetainingCapacity();

    {
        try dest.temps.ensureUnusedCapacity(arena, self.temps.count());
        var it = self.temps.iterator();
        while (it.next()) |kv| {
            try dest.temps.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        self.temps.clearRetainingCapacity();
    }

    {
        try dest.finalizer_callbacks.ensureUnusedCapacity(arena, self.finalizer_callbacks.count());
        var it = self.finalizer_callbacks.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.origin = dest;
            try dest.finalizer_callbacks.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        self.finalizer_callbacks.clearRetainingCapacity();
    }

    {
        try dest.identity_map.ensureUnusedCapacity(arena, self.identity_map.count());
        var it = self.identity_map.iterator();
        while (it.next()) |kv| {
            try dest.identity_map.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        self.identity_map.clearRetainingCapacity();
    }
}

// A type that has a finalizer can have its finalizer called one of two ways.
// The first is from V8 via the WeakCallback we give to weakRef. But that isn't
// guaranteed to fire, so we track this in finalizer_callbacks and call them on
// origin shutdown.
pub const FinalizerCallback = struct {
    arena: Allocator,
    origin: *Origin,
    session: *Session,
    ptr: *anyopaque,
    global: v8.Global,
    zig_finalizer: *const fn (ptr: *anyopaque, session: *Session) void,

    pub fn deinit(self: *FinalizerCallback) void {
        self.zig_finalizer(self.ptr, self.session);
        self.session.releaseArena(self.arena);
    }
};
