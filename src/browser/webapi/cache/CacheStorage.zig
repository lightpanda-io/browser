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

const js = @import("../../js/js.zig");

const Request = @import("../net/Request.zig");

const Cache = @import("Cache.zig");
const Store = @import("Store.zig");

const Execution = js.Execution;

const CacheStorage = @This();

_pad: bool = false,

fn open(_: *CacheStorage, name: []const u8, exec: *const Execution) !js.Promise {
    const origin = try storeOrigin(exec);
    const bucket = try origin.open(name);
    return exec.js.local.?.resolvePromise(try Cache.init(origin, bucket, exec));
}

fn has(_: *CacheStorage, name: []const u8, exec: *const Execution) !js.Promise {
    const origin = try storeOrigin(exec);
    return exec.js.local.?.resolvePromise(origin.find(name) != null);
}

fn delete(_: *CacheStorage, name: []const u8, exec: *const Execution) !js.Promise {
    const origin = try storeOrigin(exec);
    return exec.js.local.?.resolvePromise(try origin.delete(name));
}

fn keys(_: *CacheStorage, exec: *const Execution) !js.Promise {
    const origin = try storeOrigin(exec);
    return exec.js.local.?.resolvePromise(origin.buckets.keys());
}

const MatchOptions = struct {
    cacheName: ?[]const u8 = null,
    ignoreMethod: bool = false, // TODO
    ignoreSearch: bool = false,
    ignoreVary: bool = false, // TODO
};

fn match(_: *CacheStorage, input: Request.Input, opts_: ?MatchOptions, exec: *const Execution) !js.Promise {
    const origin = try storeOrigin(exec);
    const opts = opts_ orelse MatchOptions{};
    if (opts.cacheName) |name| {
        const bucket = origin.find(name) orelse return exec.js.local.?.resolvePromise({});
        return Cache.matchIn(&.{bucket}, input, opts.ignoreSearch, exec);
    }
    return Cache.matchIn(origin.buckets.values(), input, opts.ignoreSearch, exec);
}

// Unavailable for an opaque origin, e.g. about:blank. The bridge turns the
// error into a rejection.
fn storeOrigin(exec: *const Execution) !*Store.Origin {
    const origin = exec.origin() orelse return error.SecurityError;
    return exec.session.cache_store.forOrigin(origin);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CacheStorage);

    pub const Meta = struct {
        pub const name = "CacheStorage";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const open = bridge.function(CacheStorage.open, .{});
    pub const has = bridge.function(CacheStorage.has, .{});
    pub const delete = bridge.function(CacheStorage.delete, .{});
    pub const keys = bridge.function(CacheStorage.keys, .{});
    pub const match = bridge.function(CacheStorage.match, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CacheStorage" {
    testing.silenceLog(&.{.http}); // addAll's 404 case
    try testing.htmlRunner("cache/cache.html", .{ .experimental_features = .{ .serviceworker = true } });
}

test "WebApi: CacheStorage addAll torn down in flight" {
    try testing.htmlRunner("cache/teardown.html", .{ .experimental_features = .{ .serviceworker = true } });
}

test "WebApi: CacheStorage disabled" {
    try testing.htmlRunner("cache/disabled.html", .{});
}
