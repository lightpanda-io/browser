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

const js = @import("js.zig");

const q = js.q;
const log = lp.log;

const PromiseResolver = @This();

local: *const js.Local,
promise_handle: q.JSValue,
resolve_handle: q.JSValue,
reject_handle: q.JSValue,

pub fn init(local: *const js.Local) PromiseResolver {
    var funcs: [2]q.JSValue = undefined;
    const promise_value = q.JS_NewPromiseCapability(local.ctx.ctx, &funcs);
    // Can only fail on OOM
    std.debug.assert(!q.JS_IsException(promise_value));
    local.track(promise_value);
    local.track(funcs[0]);
    local.track(funcs[1]);
    return .{
        .local = local,
        .promise_handle = promise_value,
        .resolve_handle = funcs[0],
        .reject_handle = funcs[1],
    };
}

pub fn promise(self: PromiseResolver) js.Promise {
    return .{
        .local = self.local,
        .handle = self.promise_handle,
    };
}

pub fn resolve(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self.settle(source, self.resolve_handle, value);
}

pub fn reject(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self.settle(source, self.reject_handle, value);
}

fn settle(self: PromiseResolver, comptime source: []const u8, func: q.JSValue, value: anytype) void {
    const local = self.local;
    const ctx = local.ctx.ctx;

    const js_value = local.zigValueToJs(value, .{}) catch |err| {
        log.err(.js, "promise resolver value", .{ .err = err, .source = source });
        return;
    };

    var args = [_]q.JSValue{js_value.handle};
    const ret = q.JS_Call(ctx, func, js.UNDEFINED, args.len, &args);
    if (q.JS_IsException(ret)) {
        log.warn(.js, "promise resolver settle", .{ .source = source });
    }
    q.JS_FreeValue(ctx, ret);

    // Settling a promise is a yield point (matches the v8 backend, where
    // Resolve runs the microtask checkpoint synchronously).
    local.runMicrotasks();
}

pub const RejectError = union(enum) {
    /// Not to be confused with `DOMException`; this is bare `Error`.
    generic_error: []const u8,
    range_error: []const u8,
    reference_error: []const u8,
    syntax_error: []const u8,
    type_error: []const u8,
    /// DOM exceptions are unknown to the engine, belongs to web standards.
    dom_exception: struct { err: anyerror },
};

/// Rejects the promise w/ an error object.
pub fn rejectError(self: PromiseResolver, comptime source: []const u8, err: RejectError) void {
    const local = self.local;
    const DOMException = @import("../../webapi/DOMException.zig");

    const ctor_name: [:0]const u8, const msg: []const u8 = switch (err) {
        .generic_error => |m| .{ "Error", m },
        .range_error => |m| .{ "RangeError", m },
        .reference_error => |m| .{ "ReferenceError", m },
        .syntax_error => |m| .{ "SyntaxError", m },
        .type_error => |m| .{ "TypeError", m },
        .dom_exception => |exception| {
            self.settle(source, self.reject_handle, DOMException.fromError(exception.err) orelse unreachable);
            return;
        },
    };

    const ctx = local.ctx.ctx;
    const js_err = blk: {
        const global = q.JS_GetGlobalObject(ctx);
        defer q.JS_FreeValue(ctx, global);
        const ctor = q.JS_GetPropertyStr(ctx, global, ctor_name);
        defer q.JS_FreeValue(ctx, ctor);
        // JS_NewStringLen copies `len` bytes; no NUL terminator needed.
        var args = [_]q.JSValue{q.JS_NewStringLen(ctx, msg.ptr, msg.len)};
        defer q.JS_FreeValue(ctx, args[0]);
        const e = q.JS_CallConstructor(ctx, ctor, args.len, &args);
        if (q.JS_IsException(e)) {
            break :blk q.JS_NewError(ctx);
        }
        break :blk e;
    };
    local.track(js_err);
    self.settle(source, self.reject_handle, js.Value{ .local = local, .handle = js_err });
}

pub fn persist(self: PromiseResolver) !Global {
    var ctx = self.local.ctx;
    const qctx = ctx.ctx;

    const promise_h = ctx.persist(q.JS_DupValue(qctx, self.promise_handle));
    try ctx.trackGlobal(promise_h);
    const resolve_h = ctx.persist(q.JS_DupValue(qctx, self.resolve_handle));
    try ctx.trackGlobal(resolve_h);
    const reject_h = ctx.persist(q.JS_DupValue(qctx, self.reject_handle));
    try ctx.trackGlobal(reject_h);

    return .{
        .promise_handle = promise_h,
        .resolve_handle = resolve_h,
        .reject_handle = reject_h,
    };
}

pub const Global = struct {
    promise_handle: js.PersistentHandle,
    resolve_handle: js.PersistentHandle,
    reject_handle: js.PersistentHandle,

    pub fn deinit(self: *Global) void {
        js.resetPersistentHandle(&self.promise_handle);
        js.resetPersistentHandle(&self.resolve_handle);
        js.resetPersistentHandle(&self.reject_handle);
    }

    pub fn local(self: *const Global, l: *const js.Local) PromiseResolver {
        return .{
            .local = l,
            .promise_handle = self.promise_handle.value,
            .resolve_handle = self.resolve_handle.value,
            .reject_handle = self.reject_handle.value,
        };
    }
};
