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
const log = @import("../../log.zig");

const PromiseResolver = @This();

local: *const js.Local,
handle: *const v8.PromiseResolver,

pub fn init(local: *const js.Local) PromiseResolver {
    return .{
        .local = local,
        .handle = v8.v8__Promise__Resolver__New(local.handle).?,
    };
}

pub fn promise(self: PromiseResolver) js.Promise {
    return .{
        .local = self.local,
        .handle = v8.v8__Promise__Resolver__GetPromise(self.handle).?,
    };
}

pub fn resolve(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self._resolve(value) catch |err| {
        log.err(.bug, "resolve", .{ .source = source, .err = err, .persistent = false });
    };
}

fn _resolve(self: PromiseResolver, value: anytype) !void {
    const local = self.local;
    const js_val = try local.zigValueToJs(value, .{});

    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Resolve(self.handle, self.local.handle, js_val.handle, &out);
    if (!out.has_value or !out.value) {
        return error.FailedToResolvePromise;
    }
    local.ctx.runMicrotasks();
}

pub fn reject(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self._reject(value) catch |err| {
        log.err(.bug, "reject", .{ .source = source, .err = err, .persistent = false });
    };
}

fn _reject(self: PromiseResolver, value: anytype) !void {
    const local = self.local;
    const js_val = try local.zigValueToJs(value, .{});

    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Reject(self.handle, local.handle, js_val.handle, &out);
    if (!out.has_value or !out.value) {
        return error.FailedToRejectPromise;
    }
    local.ctx.runMicrotasks();
}

pub fn persist(self: PromiseResolver) !Global {
    var ctx = self.local.ctx;
    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);
    try ctx.global_promise_resolvers.append(ctx.arena, global);
    return .{ .handle = global };
}

pub const Global = struct {
    handle: v8.Global,

    pub fn deinit(self: *Global) void {
        v8.v8__Global__Reset(&self.handle);
    }

    pub fn local(self: *const Global, l: *const js.Local) PromiseResolver {
        return .{
            .local = l,
            .handle = @ptrCast(v8.v8__Global__Get(&self.handle, l.isolate.handle)),
        };
    }
};
