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

const Module = @This();

ctx: *js.Context,
handle: *const v8.c.Module,

pub const Status = enum(u32) {
    kUninstantiated = v8.c.kUninstantiated,
    kInstantiating = v8.c.kInstantiating,
    kInstantiated = v8.c.kInstantiated,
    kEvaluating = v8.c.kEvaluating,
    kEvaluated = v8.c.kEvaluated,
    kErrored = v8.c.kErrored,
};

pub fn getStatus(self: Module) Status {
    return @enumFromInt(v8.c.v8__Module__GetStatus(self.handle));
}

pub fn getException(self: Module) js.Value {
    return .{
        .ctx = self.ctx,
        .handle = v8.c.v8__Module__GetException(self.handle).?,
    };
}

pub fn getModuleRequests(self: Module) Requests {
    return .{
        .ctx = self.ctx.handle,
        .handle = v8.c.v8__Module__GetModuleRequests(self.handle).?,
    };
}

pub fn instantiate(self: Module, cb: v8.c.ResolveModuleCallback) !bool {
    var out: v8.c.MaybeBool = undefined;
    v8.c.v8__Module__InstantiateModule(self.handle, self.ctx.handle, cb, &out);
    if (out.has_value) {
        return out.value;
    }
    return error.JsException;
}

pub fn evaluate(self: Module) !js.Value {
    const ctx = self.ctx;
    const res = v8.c.v8__Module__Evaluate(self.handle, ctx.handle) orelse return error.JsException;

    if (self.getStatus() == .kErrored) {
        return error.JsException;
    }

    return .{
        .ctx = ctx,
        .handle = res,
    };
}

pub fn getIdentityHash(self: Module) u32 {
    return @bitCast(v8.c.v8__Module__GetIdentityHash(self.handle));
}

pub fn getModuleNamespace(self: Module) js.Value {
    return .{
        .ctx = self.ctx,
        .handle = v8.c.v8__Module__GetModuleNamespace(self.handle).?,
    };
}

pub fn getScriptId(self: Module) u32 {
    return @intCast(v8.c.v8__Module__ScriptId(self.handle));
}

pub fn persist(self: Module) !Module {
    var ctx = self.ctx;

    const global = js.Global(Module).init(ctx.isolate.handle, self.handle);
    try ctx.global_modules.append(ctx.arena, global);

    return .{
        .ctx = ctx,
        .handle = global.local(),
    };
}

const Requests = struct {
    ctx: *const v8.c.Context,
    handle: *const v8.c.FixedArray,

    pub fn len(self: Requests) usize {
        return @intCast(v8.c.v8__FixedArray__Length(self.handle));
    }

    pub fn get(self: Requests, idx: usize) Request {
        return .{ .handle = v8.c.v8__FixedArray__Get(self.handle, self.ctx, @intCast(idx)).? };
    }
};

const Request = struct {
    handle: *const v8.c.ModuleRequest,

    pub fn specifier(self: Request) *const v8.c.String {
        return v8.c.v8__ModuleRequest__GetSpecifier(self.handle).?;
    }
};
