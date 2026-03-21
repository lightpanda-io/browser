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

const DOMException = @import("../webapi/DOMException.zig");

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
    local.runMicrotasks();
}

pub fn reject(self: PromiseResolver, comptime source: []const u8, value: anytype) void {
    self._reject(value) catch |err| {
        log.err(.bug, "reject", .{ .source = source, .err = err, .persistent = false });
    };
}

pub const RejectError = union(enum) {
    /// Not to be confused with `DOMException`; this is bare `Error`.
    generic_error: []const u8,
    range_error: []const u8,
    reference_error: []const u8,
    syntax_error: []const u8,
    type_error: []const u8,
    /// DOM exceptions are unknown to V8, belongs to web standards.
    dom_exception: struct { err: anyerror },
};

/// Rejects the promise w/ an error object.
pub fn rejectError(
    self: PromiseResolver,
    comptime source: []const u8,
    err: RejectError,
) void {
    const handle = switch (err) {
        .generic_error => |msg| self.local.isolate.createError(msg),
        .range_error => |msg| self.local.isolate.createRangeError(msg),
        .reference_error => |msg| self.local.isolate.createReferenceError(msg),
        .syntax_error => |msg| self.local.isolate.createSyntaxError(msg),
        .type_error => |msg| self.local.isolate.createTypeError(msg),
        // "Exceptional".
        .dom_exception => |exception| {
            self._reject(DOMException.fromError(exception.err) orelse unreachable) catch |reject_err| {
                log.err(.bug, "rejectDomException", .{ .source = source, .err = reject_err, .persistent = false });
            };
            return;
        },
    };

    self._reject(js.Value{ .handle = handle, .local = self.local }) catch |reject_err| {
        log.err(.bug, "rejectError", .{ .source = source, .err = reject_err, .persistent = false });
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
    local.runMicrotasks();
}

pub fn persist(self: PromiseResolver) !Global {
    var ctx = self.local.ctx;
    var global: v8.Global = undefined;
    v8.v8__Global__New(ctx.isolate.handle, self.handle, &global);
    try ctx.trackGlobal(global);
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
