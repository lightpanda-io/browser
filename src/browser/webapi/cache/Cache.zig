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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const URL = @import("../../URL.zig");
const http = @import("../../../network/http.zig");

const Fetch = @import("../net/Fetch.zig");
const Headers = @import("../net/Headers.zig");
const Request = @import("../net/Request.zig");
const Response = @import("../net/Response.zig");

const Store = @import("Store.zig");

const log = lp.log;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

// Entries are matched on their url alone: no Vary, and only GET is ever stored.
const Cache = @This();

_origin: *Store.Origin,
_bucket: *Store.Bucket,

const QueryOptions = struct {
    ignoreMethod: bool = false, // TODO
    ignoreSearch: bool = false,
    ignoreVary: bool = false, // TODO
};

pub fn init(origin: *Store.Origin, bucket: *Store.Bucket, exec: *const Execution) !*Cache {
    return exec._factory.create(Cache{ ._origin = origin, ._bucket = bucket });
}

fn match(self: *Cache, input: Request.Input, opts_: ?QueryOptions, exec: *const Execution) !js.Promise {
    const opts = opts_ orelse QueryOptions{};
    return matchIn(&.{self._bucket}, input, opts.ignoreSearch, exec);
}

pub fn matchIn(buckets: []const *Store.Bucket, input: Request.Input, ignore_search: bool, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const key = try Key.init(input, exec);
    if (key.method == .GET) {
        for (buckets) |bucket| {
            const entry = bucket.match(key.url, ignore_search) orelse continue;
            const response = try toResponse(entry, exec);
            response.acquireRef();
            defer response.releaseRef(exec.page); // safely transfered to v8, release
            return local.resolvePromise(response);
        }
    }
    return local.resolvePromise({});
}

fn put(self: *Cache, input: Request.Input, response: *Response, exec: *const Execution) !js.Promise {
    // Errors reject: the bridge turns an error from a promise-returning
    // function into a rejection.
    const local = exec.js.local.?;
    const key = try Key.init(input, exec);
    if (key.storable() == false) {
        return local.typeError("Request must be an http(s) GET");
    }
    if (unstorable(response)) |reason| {
        return local.typeError(reason);
    }
    const body = try response.consumeBytes(exec);

    const allocator = self._origin.allocator;
    const entry = try toEntry(allocator, key.url, response, body);
    errdefer entry.deinit();

    try self._bucket.put(allocator, entry);
    return local.resolvePromise({});
}

fn delete(self: *Cache, input: Request.Input, opts_: ?QueryOptions, exec: *const Execution) !js.Promise {
    const opts = opts_ orelse QueryOptions{};
    const key = try Key.init(input, exec);
    var deleted = false;
    if (key.method == .GET) {
        deleted = self._bucket.delete(key.url, opts.ignoreSearch);
    }
    return exec.js.local.?.resolvePromise(deleted);
}

fn keys(self: *Cache, exec: *const Execution) !js.Promise {
    const entries = self._bucket.entries.values();

    // call_arena: resolving runs microtasks, and a nested native call resets
    // local_arena before the defer below gets to run.
    var requests: std.ArrayList(*Request) = try .initCapacity(exec.call_arena, entries.len);
    defer for (requests.items) |request| {
        // once we know they've safely been transfered to v8, we can release them
        request.releaseRef(exec.page);
    };

    for (entries) |entry| {
        const url = try exec.call_arena.dupeZ(u8, entry.url);
        const request = try Request.init(.{ .url = url }, null, exec);
        request.acquireRef();
        requests.appendAssumeCapacity(request);
    }
    return exec.js.local.?.resolvePromise(requests.items);
}

fn add(self: *Cache, input: Request.Input, exec: *const Execution) !js.Promise {
    return self.addAll(&.{input}, exec);
}

fn addAll(self: *Cache, inputs: []const Request.Input, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    // call_arena: batch.release() below can settle the promise synchronously,
    // and that runs microtasks (see keys).
    const requests = try exec.call_arena.alloc(*Request, inputs.len);
    var added_count: usize = 0;
    defer for (requests[0..added_count]) |request| {
        request.releaseRef(exec.page);
    };

    for (inputs, requests) |input, *request| {
        request.* = try Request.init(input, null, exec);
        request.*.acquireRef();
        added_count += 1;

        const key: Key = .{ .url = request.*._url, .method = request.*._method };
        if (key.storable() == false) {
            return local.typeError("Request must be an http(s) GET");
        }
    }

    const resolver = local.createPromiseResolver();
    const batch = try Batch.init(self, try resolver.persist(), requests, exec);
    for (requests, batch.slots) |request, *slot| {
        batch.pending += 1;
        Fetch.start(request, .{ .ctx = slot, .callback = Batch.fetched }, exec) catch |err| {
            log.warn(.http, "Cache.add fetch", .{ .err = err, .url = request._url });
            batch.pending -= 1;
            batch.outcome = .failed;
            break;
        };
    }
    batch.release();
    return resolver.promise();
}

// An addAll in flight.
const Batch = struct {
    arena: *lp.Arena,
    exec: *const Execution,
    origin: *Store.Origin,
    bucket: *Store.Bucket,
    resolver: js.PromiseResolver.Global,
    slots: []Slot,
    staged: std.ArrayList(*Store.Entry),
    outcome: enum { ok, failed, shutdown } = .ok,
    pending: usize = 1,

    const Slot = struct {
        batch: *Batch,
        url: []const u8,
    };

    fn init(cache: *const Cache, resolver: js.PromiseResolver.Global, requests: []const *Request, exec: *const Execution) !*Batch {
        const arena = try exec.getArena(.small, "Cache.addAll");
        errdefer arena.release();

        const self = try arena.create(Batch);
        self.* = .{
            .arena = arena,
            .exec = exec,
            .origin = cache._origin,
            .bucket = cache._bucket,
            .resolver = resolver,
            .slots = try arena.alloc(Slot, requests.len),
            .staged = try .initCapacity(arena.allocator(), requests.len),
        };
        for (requests, self.slots) |request, *slot| {
            slot.* = .{ .batch = self, .url = try arena.dupe(u8, request._url) };
        }
        return self;
    }

    // callback from Fetch on complete/error/shutdown
    fn fetched(ctx: *anyopaque, result: Fetch.Completion.Result) void {
        const slot: *Slot = @ptrCast(@alignCast(ctx));
        const self = slot.batch;
        defer self.release();

        switch (result) {
            .done => |response| if (self.outcome == .ok) {
                self.stage(slot.url, response) catch {
                    self.outcome = .failed;
                };
            },
            .err => if (self.outcome == .ok) {
                self.outcome = .failed;
            },
            .shutdown => self.outcome = .shutdown,
        }
    }

    fn stage(self: *Batch, url: []const u8, response: *const Response) !void {
        if (response._status < 200 or response._status > 299 or unstorable(response) != null) {
            return error.Unstorable;
        }
        const entry = try toEntry(self.origin.allocator, url, response, response._body.bytes);
        self.staged.appendAssumeCapacity(entry);
    }

    fn release(self: *Batch) void {
        self.pending -= 1;
        if (self.pending > 0) {
            return;
        }
        defer self.arena.release();

        if (self.outcome == .ok) {
            self.commit() catch {
                self.outcome = .failed;
            };
        }
        for (self.staged.items) |entry| {
            entry.deinit();
        }

        if (self.outcome == .shutdown) {
            return;
        }

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        const resolver = ls.toLocal(self.resolver);
        switch (self.outcome) {
            .ok => resolver.resolve("Cache.addAll", {}),
            .failed => resolver.rejectError("Cache.addAll", .{ .type_error = "Request failed" }),
            .shutdown => unreachable,
        }
    }

    fn commit(self: *Batch) !void {
        const allocator = self.origin.allocator;
        try self.bucket.entries.ensureUnusedCapacity(allocator, self.staged.items.len);
        for (self.staged.items) |entry| {
            self.bucket.put(allocator, entry) catch unreachable;
        }
        self.staged.clearRetainingCapacity();
    }
};

// What an entry is looked up by.
const Key = struct {
    url: [:0]const u8,
    method: http.Method,

    fn init(input: Request.Input, exec: *const Execution) !Key {
        return switch (input) {
            .request => |r| .{ .url = r._url, .method = r._method },
            .url => |u| .{
                .url = try URL.resolve(exec.call_arena, exec.base(), u, .{ .encoding = exec.charset.* }),
                .method = .GET,
            },
        };
    }

    fn storable(self: Key) bool {
        if (self.method != .GET) {
            return false;
        }
        return std.mem.startsWith(u8, self.url, "http://") or std.mem.startsWith(u8, self.url, "https://");
    }
};

// Why this response can't be stored, if it can't.
fn unstorable(response: *const Response) ?[]const u8 {
    if (response._status == 206) {
        return "Partial response (status code 206) is unsupported";
    }
    if (response._body == .stream) {
        return "Response with a ReadableStream body is unsupported";
    }
    for (response._headers._list._entries.items) |*header| {
        if (std.ascii.eqlIgnoreCase(header.name.str(), "vary") == false) {
            continue;
        }
        var it = std.mem.splitScalar(u8, header.value.str(), ',');
        while (it.next()) |value| {
            if (std.mem.eql(u8, std.mem.trim(u8, value, " \t"), "*")) {
                return "Vary header contains *";
            }
        }
    }
    return null;
}

fn toEntry(allocator: Allocator, url: []const u8, response: *const Response, body: []const u8) !*Store.Entry {
    const entry = try Store.Entry.create(allocator, url);
    errdefer entry.deinit();

    const arena = entry.arena.allocator();
    const source = response._headers._list._entries.items;
    const headers = try arena.alloc([2][]const u8, source.len);
    for (source, headers) |*header, *kv| {
        kv.* = .{ try arena.dupe(u8, header.name.str()), try arena.dupe(u8, header.value.str()) };
    }

    entry.response_url = try arena.dupeZ(u8, response._url);
    entry.status = response._status;
    entry.status_text = try arena.dupe(u8, response._status_text);
    entry.response_type = response._type;
    entry.is_redirected = response._is_redirected;
    entry.headers = headers;
    entry.body = try arena.dupe(u8, body);
    return entry;
}

fn toResponse(entry: *const Store.Entry, exec: *const Execution) !*Response {
    const arena = try exec.getPinnedArena(entry.body.len + entry.response_url.len + 256, "Cache.match");
    errdefer arena.release();

    const response = try arena.create(Response);
    response.* = .{
        ._arena = arena,
        ._status = entry.status,
        ._status_text = try arena.dupe(u8, entry.status_text),
        ._url = try arena.dupeZ(u8, entry.response_url),
        ._body = .{ .bytes = try arena.dupe(u8, entry.body) },
        ._type = entry.response_type,
        ._is_redirected = entry.is_redirected,
        ._headers = try .initGuarded(.{ .strings = entry.headers }, .immutable, exec),
    };
    arena.report();
    return response;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Cache);

    pub const Meta = struct {
        pub const name = "Cache";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const match = bridge.function(Cache.match, .{});
    pub const add = bridge.function(Cache.add, .{});
    pub const addAll = bridge.function(Cache.addAll, .{});
    pub const put = bridge.function(Cache.put, .{});
    pub const delete = bridge.function(Cache.delete, .{});
    pub const keys = bridge.function(Cache.keys, .{});
};
