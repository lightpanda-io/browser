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

// QuickJS-NG backend. Mirrors the public surface of v8/js.zig; see the
// engine-selection facade in ../js.zig. CDP (and thus the Inspector,
// isolated worlds and `lightpanda serve`) is not supported with this
// backend.
const std = @import("std");
const lp = @import("lightpanda");

pub const q = @cImport(@cInclude("quickjs.h"));

const string = @import("../../../string.zig");

pub const Env = @import("Env.zig");
pub const bridge = @import("bridge.zig");
pub const Caller = @import("Caller.zig");
pub const Origin = @import("Origin.zig");
pub const Identity = @import("Identity.zig");
pub const Context = @import("Context.zig");
pub const Execution = @import("../Execution.zig");
pub const Local = @import("Local.zig");
pub const Snapshot = @import("Snapshot.zig");
pub const Platform = @import("Platform.zig");

pub const RegExp = @import("RegExp.zig");

// quickjs has no HandleScope; the Context's handle stack plays that role
// (see Local). This stub keeps shared call sites (`var hs: js.HandleScope`)
// compiling.
pub const HandleScope = struct {
    pub fn init(_: *HandleScope, _: anytype) void {}
    pub fn deinit(_: *HandleScope) void {}
};

pub const Value = @import("Value.zig");
pub const Array = @import("Array.zig");
pub const String = @import("String.zig");
pub const Object = @import("Object.zig");
pub const TryCatch = @import("TryCatch.zig");
pub const Function = @import("Function.zig");
pub const Script = @import("Script.zig");
pub const Promise = @import("Promise.zig");
pub const PromiseResolver = @import("PromiseResolver.zig");
pub const PromiseRejection = @import("PromiseRejection.zig");

const js = @This();
const Allocator = std.mem.Allocator;

pub const UNDEFINED = q.JSValue{ .u = .{ .int32 = 0 }, .tag = q.JS_TAG_UNDEFINED };
pub const NULL = q.JSValue{ .u = .{ .int32 = 0 }, .tag = q.JS_TAG_NULL };
pub const TRUE = q.JSValue{ .u = .{ .int32 = 1 }, .tag = q.JS_TAG_BOOL };
pub const FALSE = q.JSValue{ .u = .{ .int32 = 0 }, .tag = q.JS_TAG_BOOL };
pub const EXCEPTION = q.JSValue{ .u = .{ .int32 = 0 }, .tag = q.JS_TAG_EXCEPTION };

// must be kept in sync with quickjs' JS_ATOM_TAG_INT
pub const JS_ATOM_TAG_INT: u32 = 1 << 31;

// A persisted (ref-counted) JSValue. The engine-neutral equivalent of a
// v8::Global - Page tracks these in `globals` and `temps` so they can be
// released on teardown. `key` uniquely identifies this persist operation
// (quickjs object pointers aren't unique per persist, unlike v8 Global
// slots, so we mint our own key). Holds the runtime, not the context: a
// persisted handle can outlive the JSContext it was created in (e.g. the
// Page-level identity map vs per-iframe contexts), so it must be released
// with JS_FreeValueRT.
// The handle is a POINTER to a shared slot (allocated on the page arena
// by Context.persist): both the wrapper .Global/.Temp and Page's tracking
// list hold the same slot, so releasing from either side is seen by the
// other - mirroring how copies of a v8::Global all reference one slot.
pub const PersistentHandle = *PersistentSlot;

pub const PersistentSlot = struct {
    value: q.JSValue,
    rt: ?*q.JSRuntime,
    key: usize,
};

pub fn resetPersistentHandle(handle: *const PersistentHandle) void {
    const slot = handle.*;
    const rt = slot.rt orelse return;
    q.JS_FreeValueRT(rt, slot.value);
    slot.rt = null;
}

pub fn Bridge(comptime T: type) type {
    return bridge.Builder(T);
}

// See v8/js.zig - a []i32 maps to a plain JS array by default; wrap in
// this to get an Int32Array instead.
pub fn TypedArray(comptime T: type) type {
    return struct {
        values: []const T,

        pub fn dupe(self: TypedArray(T), allocator: Allocator) !TypedArray(T) {
            return .{ .values = try allocator.dupe(T, self.values) };
        }
    };
}

pub const ArrayBuffer = struct {
    values: []const u8,

    pub fn dupe(self: ArrayBuffer, allocator: Allocator) !ArrayBuffer {
        return .{ .values = try allocator.dupe(u8, self.values) };
    }
};

pub const ArrayType = enum(u8) {
    int8,
    uint8,
    uint8_clamped,
    int16,
    uint16,
    int32,
    uint32,
    float16,
    float32,
    float64,
};

// A typed array whose backing memory lives in the JS heap. The v8 backend
// hands out a raw pointer into the backing store; we do the same via
// JS_GetTypedArrayBuffer.
pub fn ArrayBufferRef(comptime kind: ArrayType) type {
    return struct {
        const Self = @This();

        const BackingInt = switch (kind) {
            .int8 => i8,
            .uint8, .uint8_clamped => u8,
            .int16 => i16,
            .uint16 => u16,
            .int32 => i32,
            .uint32 => u32,
            .float16 => f16,
            .float32 => f32,
            .float64 => f64,
        };

        local: *const Local,
        handle: q.JSValue,

        pub const Global = struct {
            handle: PersistentHandle,

            pub fn deinit(self: *Global) void {
                resetPersistentHandle(&self.handle);
            }

            pub fn local(self: *const Global, l: *const Local) Self {
                return .{ .local = l, .handle = self.handle.value };
            }
        };

        pub fn init(local: *const Local, size: usize) Self {
            const ctx = local.ctx.ctx;
            const typed_array_type: q.JSTypedArrayEnum = switch (comptime kind) {
                .int8 => q.JS_TYPED_ARRAY_INT8,
                .uint8 => q.JS_TYPED_ARRAY_UINT8,
                .uint8_clamped => q.JS_TYPED_ARRAY_UINT8C,
                .int16 => q.JS_TYPED_ARRAY_INT16,
                .uint16 => q.JS_TYPED_ARRAY_UINT16,
                .int32 => q.JS_TYPED_ARRAY_INT32,
                .uint32 => q.JS_TYPED_ARRAY_UINT32,
                .float16 => q.JS_TYPED_ARRAY_FLOAT16,
                .float32 => q.JS_TYPED_ARRAY_FLOAT32,
                .float64 => q.JS_TYPED_ARRAY_FLOAT64,
            };

            const bits = switch (@typeInfo(BackingInt)) {
                .int => |n| n.bits,
                .float => |f| f.bits,
                else => unreachable,
            };
            const zeroes = local.call_arena.alloc(u8, size * bits / 8) catch &.{};
            const buffer = q.JS_NewArrayBufferCopy(ctx, zeroes.ptr, zeroes.len);
            // Trailing undefineds are byte-offset/length; without them the
            // constructor reads garbage and yields a zero-length view (see
            // the matching note in Local.simpleZigValueToJs).
            var args = [_]q.JSValue{ buffer, UNDEFINED, UNDEFINED };
            const handle = q.JS_NewTypedArray(ctx, args.len, &args, typed_array_type);
            q.JS_FreeValue(ctx, buffer);
            local.track(handle);
            return .{ .local = local, .handle = handle };
        }

        pub fn persist(self: *const Self) !Global {
            var ctx = self.local.ctx;
            const handle = ctx.persist(q.JS_DupValue(ctx.ctx, self.handle));
            try ctx.trackGlobal(handle);
            return .{ .handle = handle };
        }
    };
}

// See v8/js.zig for the null vs "null" coercion rationale.
pub const NullableString = struct {
    value: []const u8,
};

pub const Exception = struct {
    local: *const Local,
    handle: q.JSValue,
};

// marker interface
pub const Undefined = struct {};

// Every finalizable instance of Zig gets 1 FinalizerCallback registered in
// the Page, releasing the acquired ref on Page teardown. Unlike v8, quickjs
// never finalizes our wrappers mid-page (the identity map holds a strong
// ref), so this page-teardown path is the only release path.
pub const FinalizerCallback = struct {
    page: *Page,
    arena: Allocator,
    resolved_ptr_id: usize,
    finalizer_ptr_id: usize,
    release_ref: *const fn (ptr_id: usize, page: *Page) void,

    // Kept for structural compatibility with the v8 backend; quickjs has no
    // weak callbacks so no identities are ever registered.
    identities: ?*FinalizerCallback.Identity = null,
    identity_count: u8 = 0,

    const Page = @import("../../Page.zig");
    const Browser = @import("../../Browser.zig");

    pub const Identity = struct {
        page: *Page,
        browser: *Browser,
        identity: *js.Identity,
        finalizer_ptr_id: usize,
        resolved_ptr_id: usize,
        next: ?*FinalizerCallback.Identity = null,
        done: bool = false,
    };

    pub fn deinit(self: *FinalizerCallback, page: *Page) void {
        var id = self.identities;
        while (id) |identity| {
            identity.done = true;
            id = identity.next;
        }
        self.release_ref(self.finalizer_ptr_id, page);
        page.releaseArena(self.arena);
    }
};

// Converts a JSValue to an owned string on the given allocator. The
// JSValue is not freed.
pub fn valueToString(allocator: Allocator, ctx: *q.JSContext, value: q.JSValueConst) ![]u8 {
    var len: usize = undefined;
    const cstr = q.JS_ToCStringLen2(ctx, &len, value, false) orelse return error.JsException;
    defer q.JS_FreeCString(ctx, cstr);
    return allocator.dupe(u8, cstr[0..len]);
}
