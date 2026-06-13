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

// See v8/TaggedOpaque.zig for the full rationale. The quickjs version is
// stored in the JSObject via JS_SetOpaque and recovered via JS_GetAnyOpaque.
// The one quickjs-specific wrinkle: the global object cannot hold an opaque
// (https://github.com/quickjs-ng/quickjs/issues/695), so fromJS falls back
// to the context's global scope (Window or WorkerGlobalScope) when given
// the global object (or undefined, for bare `addEventListener()` calls).
const std = @import("std");

const js = @import("js.zig");
const bridge = @import("bridge.zig");
const Context = @import("Context.zig");
const registry = @import("../registry.zig");

const q = js.q;

const TaggedOpaque = @This();

prototype_len: u16,
prototype_chain: [*]const registry.PrototypeChainEntry,

// Ptr to the Zig instance.
value: *anyopaque,

pub const PrototypeChainEntry = registry.PrototypeChainEntry;

pub fn fromJS(comptime R: type, ctx: *Context, js_val: q.JSValueConst) !R {
    const ti = @typeInfo(R);
    if (ti != .pointer) {
        @compileError("non-pointer Zig parameter type: " ++ @typeName(R));
    }

    const T = ti.pointer.child;
    const JsApi = bridge.Struct(T).JsApi;

    if (@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
        return @constCast(@as(*const T, &.{}));
    }

    if (!registry.JsApiLookup.has(JsApi)) {
        @compileError("unknown Zig type: " ++ @typeName(R));
    }

    const value, const prototype_chain = blk: {
        var class_id: q.JSClassID = undefined;
        if (q.JS_GetAnyOpaque(js_val, &class_id)) |opq| {
            // quickjs built-in classes use the opaque slot for their own
            // native state; only our JsApi classes hold a TaggedOpaque.
            const env = ctx.env;
            if (class_id < env.first_js_class_id or class_id > env.last_js_class_id) {
                return error.InvalidArgument;
            }
            const tao: *TaggedOpaque = @ptrCast(@alignCast(opq));
            break :blk .{ tao.value, tao.prototype_chain[0..tao.prototype_len] };
        }

        // No opaque. Either this is the global object (which can't hold an
        // opaque in quickjs), undefined (a bare global function call), or
        // a plain JS value that was never created by mapZigInstanceToJs.
        const tag = q.JS_VALUE_GET_TAG(js_val);
        if (tag != q.JS_TAG_UNDEFINED) {
            if (tag != q.JS_TAG_OBJECT) {
                return error.InvalidArgument;
            }
            const js_global = q.JS_GetGlobalObject(ctx.ctx);
            defer q.JS_FreeValue(ctx.ctx, js_global);
            if (q.JS_VALUE_GET_PTR(js_val) != q.JS_VALUE_GET_PTR(js_global)) {
                return error.InvalidArgument;
            }
        }

        switch (ctx.global) {
            .frame => |frame| {
                const Window = @import("../../webapi/Window.zig");
                break :blk .{ @as(*anyopaque, @ptrCast(frame.window)), &Window.JsApi.Meta.prototype_chain };
            },
            .worker => |worker| {
                const WorkerGlobalScope = @import("../../webapi/WorkerGlobalScope.zig");
                break :blk .{ @as(*anyopaque, @ptrCast(worker)), &WorkerGlobalScope.JsApi.Meta.prototype_chain };
            },
        }
    };

    const expected_type_index = registry.JsApiLookup.getId(JsApi);
    if (prototype_chain[0].index == expected_type_index) {
        return @ptrCast(@alignCast(value));
    }

    // Walk up the chain
    var ptr = @intFromPtr(value);
    for (prototype_chain[1..]) |proto| {
        ptr += proto.offset; // the offset to the _proto field
        const proto_ptr: **anyopaque = @ptrFromInt(ptr);
        if (proto.index == expected_type_index) {
            return @ptrCast(@alignCast(proto_ptr.*));
        }
        ptr = @intFromPtr(proto_ptr.*);
    }
    return error.InvalidArgument;
}
