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

ctx: *js.Context,
handle: *const v8.PromiseResolver,

pub fn init(ctx: *js.Context) PromiseResolver {
    return .{
        .ctx = ctx,
        .handle = v8.v8__Promise__Resolver__New(ctx.handle).?,
    };
}

pub fn promise(self: PromiseResolver) js.Promise {
    return .{
        .ctx = self.ctx,
        .handle = v8.v8__Promise__Resolver__GetPromise(self.handle).?,
    };
}

pub fn resolve(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self._resolve(value) catch |err| {
        log.err(.bug, "resolve", .{ .source = source, .err = err, .persistent = false });
    };
}

fn _resolve(self: PromiseResolver, value: anytype) !void {
    const ctx: *js.Context = @constCast(self.ctx);
    const js_value = try ctx.zigValueToJs(value, .{});

    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Resolve(self.handle, self.ctx.handle, js_value.handle, &out);
    if (!out.has_value or !out.value) {
        return error.FailedToResolvePromise;
    }
    ctx.runMicrotasks();
}

pub fn reject(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self._reject(value) catch |err| {
        log.err(.bug, "reject", .{ .source = source, .err = err, .persistent = false });
    };
}

fn _reject(self: PromiseResolver, value: anytype) !void {
    const ctx = self.ctx;
    const js_value = try ctx.zigValueToJs(value, .{});

    var out: v8.MaybeBool = undefined;
    v8.v8__Promise__Resolver__Reject(self.handle, ctx.handle, js_value.handle, &out);
    if (!out.has_value or !out.value) {
        return error.FailedToRejectPromise;
    }
    ctx.runMicrotasks();
}

pub fn persist(self: PromiseResolver) !Global {
    var ctx = self.ctx;
    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);
    try ctx.global_promise_resolvers.append(ctx.arena, global);
    return .{
        .handle = global,
        .ctx = ctx,
    };
}

pub const Global = struct {
    handle: v8.Global,
    ctx: *js.Context,

    pub fn deinit(self: *Global) void {
        v8.v8__Global__Reset(&self.handle);
    }

    pub fn local(self: *const Global) PromiseResolver {
        return .{
            .ctx = self.ctx,
            .handle = @ptrCast(v8.v8__Global__Get(&self.handle, self.ctx.isolate.handle)),
        };
    }

    pub fn isEqual(self: *const Global, other: PromiseResolver) bool {
        return v8.v8__Global__IsEqual(&self.handle, other.handle);
    }
};
