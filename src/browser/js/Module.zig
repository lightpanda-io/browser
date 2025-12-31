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

pub const Status = enum(u32) {
    kUninstantiated = v8.c.kUninstantiated,
    kInstantiating = v8.c.kInstantiating,
    kInstantiated = v8.c.kInstantiated,
    kEvaluating = v8.c.kEvaluating,
    kEvaluated = v8.c.kEvaluated,
    kErrored = v8.c.kErrored,
};

handle: *const v8.c.Module,

pub fn getStatus(self: Module) Status {
    return @enumFromInt(v8.c.v8__Module__GetStatus(self.handle));
}

pub fn getException(self: Module) v8.Value {
    return .{
        .handle = v8.c.v8__Module__GetException(self.handle).?,
    };
}

pub fn getModuleRequests(self: Module) v8.FixedArray {
    return .{
        .handle = v8.c.v8__Module__GetModuleRequests(self.handle).?,
    };
}

pub fn instantiate(self: Module, ctx_handle: *const v8.c.Context, cb: v8.c.ResolveModuleCallback) !bool {
    var out: v8.c.MaybeBool = undefined;
    v8.c.v8__Module__InstantiateModule(self.handle, ctx_handle, cb, &out);
    if (out.has_value) {
        return out.value;
    }
    return error.JsException;
}

pub fn evaluate(self: Module, ctx_handle: *const v8.c.Context) !v8.Value {
    const res = v8.c.v8__Module__Evaluate(self.handle, ctx_handle) orelse return error.JsException;

    if (self.getStatus() == .kErrored) {
        return error.JsException;
    }

    return .{ .handle = res };
}

pub fn getIdentityHash(self: Module) u32 {
    return @bitCast(v8.c.v8__Module__GetIdentityHash(self.handle));
}

pub fn getModuleNamespace(self: Module) v8.Value {
    return .{
        .handle = v8.c.v8__Module__GetModuleNamespace(self.handle).?,
    };
}

pub fn getScriptId(self: Module) u32 {
    return @intCast(v8.c.v8__Module__ScriptId(self.handle));
}
