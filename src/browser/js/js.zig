// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
pub const v8 = @import("v8");

const types = @import("types.zig");
const log = @import("../../log.zig");
const Page = @import("../page.zig").Page;

const Allocator = std.mem.Allocator;

pub const Env = @import("Env.zig");
pub const ExecutionWorld = @import("ExecutionWorld.zig");
pub const Context = @import("Context.zig");
pub const Inspector = @import("Inspector.zig");

// TODO: Is "This" really necessary?
pub const This = @import("This.zig");
pub const Object = @import("Object.zig");
pub const TryCatch = @import("TryCatch.zig");
pub const Function = @import("Function.zig");

const Caller = @import("Caller.zig");
const NamedFunction = Context.NamedFunction;

// If a function returns a []i32, should that map to a plain-old
// JavaScript array, or a Int32Array? It's ambiguous. By default, we'll
// map arrays/slices to the JavaScript arrays. If you want a TypedArray
// wrap it in this.
// Also, this type has nothing to do with the Env. But we place it here
// for consistency. Want a callback? Env.Callback. Want a JsObject?
// Env.JsObject. Want a TypedArray? Env.TypedArray.
pub fn TypedArray(comptime T: type) type {
    return struct {
        pub const _TYPED_ARRAY_ID_KLUDGE = true;

        values: []const T,

        pub fn dupe(self: TypedArray(T), allocator: Allocator) !TypedArray(T) {
            return .{ .values = try allocator.dupe(T, self.values) };
        }
    };
}

pub const PromiseResolver = struct {
    context: *Context,
    resolver: v8.PromiseResolver,

    pub fn promise(self: PromiseResolver) Promise {
        return self.resolver.getPromise();
    }

    pub fn resolve(self: PromiseResolver, value: anytype) !void {
        const context = self.context;
        const js_value = try context.zigValueToJs(value);

        // resolver.resolve will return null if the promise isn't pending
        const ok = self.resolver.resolve(context.v8_context, js_value) orelse return;
        if (!ok) {
            return error.FailedToResolvePromise;
        }
    }

    pub fn reject(self: PromiseResolver, value: anytype) !void {
        const context = self.context;
        const js_value = try context.zigValueToJs(value);

        // resolver.reject will return null if the promise isn't pending
        const ok = self.resolver.reject(context.v8_context, js_value) orelse return;
        if (!ok) {
            return error.FailedToRejectPromise;
        }
    }
};

pub const PersistentPromiseResolver = struct {
    context: *Context,
    resolver: v8.Persistent(v8.PromiseResolver),

    pub fn deinit(self: *PersistentPromiseResolver) void {
        self.resolver.deinit();
    }

    pub fn promise(self: PersistentPromiseResolver) Promise {
        return self.resolver.castToPromiseResolver().getPromise();
    }

    pub fn resolve(self: PersistentPromiseResolver, value: anytype) !void {
        const context = self.context;
        const js_value = try context.zigValueToJs(value);

        // resolver.resolve will return null if the promise isn't pending
        const ok = self.resolver.castToPromiseResolver().resolve(context.v8_context, js_value) orelse return;
        if (!ok) {
            return error.FailedToResolvePromise;
        }
    }

    pub fn reject(self: PersistentPromiseResolver, value: anytype) !void {
        const context = self.context;
        const js_value = try context.zigValueToJs(value);

        // resolver.reject will return null if the promise isn't pending
        const ok = self.resolver.castToPromiseResolver().reject(context.v8_context, js_value) orelse return;
        if (!ok) {
            return error.FailedToRejectPromise;
        }
    }
};

pub const Promise = v8.Promise;

// When doing jsValueToZig, string ([]const u8) are managed by the
// call_arena. That means that if the API wants to persist the string
// (which is relatively common), it needs to dupe it again.
// If the parameter is an Env.String rather than a []const u8, then
// the page's arena will be used (rather than the call arena).
pub const String = struct {
    string: []const u8,
};

pub const Exception = struct {
    inner: v8.Value,
    context: *const Context,

    // the caller needs to deinit the string returned
    pub fn exception(self: Exception, allocator: Allocator) ![]const u8 {
        return self.context.valueToString(self.inner, .{ .allocator = allocator });
    }
};

pub const Value = struct {
    value: v8.Value,
    context: *const Context,

    // the caller needs to deinit the string returned
    pub fn toString(self: Value, allocator: Allocator) ![]const u8 {
        return self.context.valueToString(self.value, .{ .allocator = allocator });
    }

    pub fn fromJson(ctx: *Context, json: []const u8) !Value {
        const json_string = v8.String.initUtf8(ctx.isolate, json);
        const value = try v8.Json.parse(ctx.v8_context, json_string);
        return Value{ .context = ctx, .value = value };
    }
};

pub const ValueIterator = struct {
    count: u32,
    idx: u32 = 0,
    js_obj: v8.Object,
    context: *const Context,

    pub fn next(self: *ValueIterator) !?Value {
        const idx = self.idx;
        if (idx == self.count) {
            return null;
        }
        self.idx += 1;

        const context = self.context;
        const js_val = try self.js_obj.getAtIndex(context.v8_context, idx);
        return context.createValue(js_val);
    }
};

pub fn UndefinedOr(comptime T: type) type {
    return union(enum) {
        undefined: void,
        value: T,
    };
}

// An interface for types that want to have their jsScopeEnd function be
// called when the call context ends
const CallScopeEndCallback = struct {
    ptr: *anyopaque,
    callScopeEndFn: *const fn (ptr: *anyopaque) void,

    fn init(ptr: anytype) CallScopeEndCallback {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const gen = struct {
            pub fn callScopeEnd(pointer: *anyopaque) void {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.jsCallScopeEnd(self);
            }
        };

        return .{
            .ptr = ptr,
            .callScopeEndFn = gen.callScopeEnd,
        };
    }

    pub fn callScopeEnd(self: CallScopeEndCallback) void {
        self.callScopeEndFn(self.ptr);
    }
};

// Callback called on global's property missing.
// Return true to intercept the execution or false to let the call
// continue the chain.
pub const GlobalMissingCallback = struct {
    ptr: *anyopaque,
    missingFn: *const fn (ptr: *anyopaque, name: []const u8, ctx: *Context) bool,

    pub fn init(ptr: anytype) GlobalMissingCallback {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);

        const gen = struct {
            pub fn missing(pointer: *anyopaque, name: []const u8, ctx: *Context) bool {
                const self: T = @ptrCast(@alignCast(pointer));
                return ptr_info.pointer.child.missing(self, name, ctx);
            }
        };

        return .{
            .ptr = ptr,
            .missingFn = gen.missing,
        };
    }

    pub fn missing(self: GlobalMissingCallback, name: []const u8, ctx: *Context) bool {
        return self.missingFn(self.ptr, name, ctx);
    }
};

// Attributes that return a primitive type are setup directly on the
// FunctionTemplate when the Env is setup. More complex types need a v8.Context
// and cannot be set directly on the FunctionTemplate.
// We default to saying types are primitives because that's mostly what
// we have. If we add a new complex type that isn't explictly handled here,
// we'll get a compiler error in simpleZigValueToJs, and can then explicitly
// add the type here.
pub fn isComplexAttributeType(ti: std.builtin.Type) bool {
    return switch (ti) {
        .array => true,
        else => false,
    };
}

// These are simple types that we can convert to JS with only an isolate. This
// is separated from the Caller's zigValueToJs to make it available when we
// don't have a caller (i.e., when setting static attributes on types)
pub fn simpleZigValueToJs(isolate: v8.Isolate, value: anytype, comptime fail: bool) if (fail) v8.Value else ?v8.Value {
    switch (@typeInfo(@TypeOf(value))) {
        .void => return v8.initUndefined(isolate).toValue(),
        .null => return v8.initNull(isolate).toValue(),
        .bool => return v8.getValue(if (value) v8.initTrue(isolate) else v8.initFalse(isolate)),
        .int => |n| switch (n.signedness) {
            .signed => {
                if (value >= -2_147_483_648 and value <= 2_147_483_647) {
                    return v8.Integer.initI32(isolate, @intCast(value)).toValue();
                }
                if (comptime n.bits <= 64) {
                    return v8.getValue(v8.BigInt.initI64(isolate, @intCast(value)));
                }
                @compileError(@typeName(value) ++ " is not supported");
            },
            .unsigned => {
                if (value <= 4_294_967_295) {
                    return v8.Integer.initU32(isolate, @intCast(value)).toValue();
                }
                if (comptime n.bits <= 64) {
                    return v8.getValue(v8.BigInt.initU64(isolate, @intCast(value)));
                }
                @compileError(@typeName(value) ++ " is not supported");
            },
        },
        .comptime_int => {
            if (value >= 0) {
                if (value <= 4_294_967_295) {
                    return v8.Integer.initU32(isolate, @intCast(value)).toValue();
                }
                return v8.BigInt.initU64(isolate, @intCast(value)).toValue();
            }
            if (value >= -2_147_483_648) {
                return v8.Integer.initI32(isolate, @intCast(value)).toValue();
            }
            return v8.BigInt.initI64(isolate, @intCast(value)).toValue();
        },
        .comptime_float => return v8.Number.init(isolate, value).toValue(),
        .float => |f| switch (f.bits) {
            64 => return v8.Number.init(isolate, value).toValue(),
            32 => return v8.Number.init(isolate, @floatCast(value)).toValue(),
            else => @compileError(@typeName(value) ++ " is not supported"),
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return v8.String.initUtf8(isolate, value).toValue();
            }
            if (ptr.size == .one) {
                const one_info = @typeInfo(ptr.child);
                if (one_info == .array and one_info.array.child == u8) {
                    return v8.String.initUtf8(isolate, value).toValue();
                }
            }
        },
        .array => return simpleZigValueToJs(isolate, &value, fail),
        .optional => {
            if (value) |v| {
                return simpleZigValueToJs(isolate, v, fail);
            }
            return v8.initNull(isolate).toValue();
        },
        .@"struct" => {
            const T = @TypeOf(value);
            if (@hasDecl(T, "_TYPED_ARRAY_ID_KLUDGE")) {
                const values = value.values;
                const value_type = @typeInfo(@TypeOf(values)).pointer.child;
                const len = values.len;
                const bits = switch (@typeInfo(value_type)) {
                    .int => |n| n.bits,
                    .float => |f| f.bits,
                    else => @compileError("Invalid TypeArray type: " ++ @typeName(value_type)),
                };

                var array_buffer: v8.ArrayBuffer = undefined;
                if (len == 0) {
                    array_buffer = v8.ArrayBuffer.init(isolate, 0);
                } else {
                    const buffer_len = len * bits / 8;
                    const backing_store = v8.BackingStore.init(isolate, buffer_len);
                    const data: [*]u8 = @ptrCast(@alignCast(backing_store.getData()));
                    @memcpy(data[0..buffer_len], @as([]const u8, @ptrCast(values))[0..buffer_len]);
                    array_buffer = v8.ArrayBuffer.initWithBackingStore(isolate, &backing_store.toSharedPtr());
                }

                switch (@typeInfo(value_type)) {
                    .int => |n| switch (n.signedness) {
                        .unsigned => switch (n.bits) {
                            8 => return v8.Uint8Array.init(array_buffer, 0, len).toValue(),
                            16 => return v8.Uint16Array.init(array_buffer, 0, len).toValue(),
                            32 => return v8.Uint32Array.init(array_buffer, 0, len).toValue(),
                            64 => return v8.BigUint64Array.init(array_buffer, 0, len).toValue(),
                            else => {},
                        },
                        .signed => switch (n.bits) {
                            8 => return v8.Int8Array.init(array_buffer, 0, len).toValue(),
                            16 => return v8.Int16Array.init(array_buffer, 0, len).toValue(),
                            32 => return v8.Int32Array.init(array_buffer, 0, len).toValue(),
                            64 => return v8.BigInt64Array.init(array_buffer, 0, len).toValue(),
                            else => {},
                        },
                    },
                    .float => |f| switch (f.bits) {
                        32 => return v8.Float32Array.init(array_buffer, 0, len).toValue(),
                        64 => return v8.Float64Array.init(array_buffer, 0, len).toValue(),
                        else => {},
                    },
                    else => {},
                }
                // We normally don't fail in this function unless fail == true
                // but this can never be valid.
                @compileError("Invalid TypeArray type: " ++ @typeName(value_type));
            }
        },
        .@"union" => return simpleZigValueToJs(isolate, std.meta.activeTag(value), fail),
        .@"enum" => {
            const T = @TypeOf(value);
            if (@hasDecl(T, "toString")) {
                return simpleZigValueToJs(isolate, value.toString(), fail);
            }
        },
        else => {},
    }
    if (fail) {
        @compileError("Unsupported Zig type " ++ @typeName(@TypeOf(value)));
    }
    return null;
}

pub fn _createException(isolate: v8.Isolate, msg: []const u8) v8.Value {
    return v8.Exception.initError(v8.String.initUtf8(isolate, msg));
}

pub fn classNameForStruct(comptime Struct: type) []const u8 {
    if (@hasDecl(Struct, "js_name")) {
        return Struct.js_name;
    }
    @setEvalBranchQuota(10_000);
    const full_name = @typeName(Struct);
    const last = std.mem.lastIndexOfScalar(u8, full_name, '.') orelse return full_name;
    return full_name[last + 1 ..];
}

// When we return a Zig object to V8, we put it on the heap and pass it into
// v8 as an *anyopaque (i.e. void *). When V8 gives us back the value, say, as a
// function parameter, we know what type it _should_ be. Above, in Caller.method
// (for example), we know all the parameter types. So if a Zig function takes
// a single parameter (its receiver), we know what that type is.
//
// In a simple/perfect world, we could use this knowledge to cast the *anyopaque
// to the parameter type:
//   const arg: @typeInfo(@TypeOf(function)).@"fn".params[0] = @ptrCast(v8_data);
//
// But there are 2 reasons we can't do that.
//
// == Reason 1 ==
// The JS code might pass the wrong type:
//
//   var cat = new Cat();
//   cat.setOwner(new Cat());
//
// The zig _setOwner method expects the 2nd parameter to be an *Owner, but
// the JS code passed a *Cat.
//
// To solve this issue, we tag every returned value so that we can check what
// type it is. In the above case, we'd expect an *Owner, but the tag would tell
// us that we got a *Cat. We use the type index in our Types lookup as the tag.
//
// == Reason 2 ==
// Because of prototype inheritance, even "correct" code can be a challenge. For
// example, say the above JavaScript is fixed:
//
//   var cat = new Cat();
//   cat.setOwner(new Owner("Leto"));
//
// The issue is that setOwner might not expect an *Owner, but rather a
// *Person, which is the prototype for Owner. Now our Zig code is expecting
// a *Person, but it was (correctly) given an *Owner.
// For this reason, we also store the prototype's type index.
//
// One of the prototype mechanisms that we support is via composition. Owner
// can have a "proto: *Person" field. For this reason, we also store the offset
// of the proto field, so that, given an intFromPtr(*Owner) we can access its
// proto field.
//
// The other prototype mechanism that we support is for netsurf, where we just
// cast one type to another. In this case, we'll store an offset of -1 (as a
// sentinel to indicate that we should just cast directly).
pub const TaggedAnyOpaque = struct {
    // The type of object this is. The type is captured as an index, which
    // corresponds to both a field in TYPE_LOOKUP and the index of
    // PROTOTYPE_TABLE
    index: u16,

    // Ptr to the Zig instance. Between the context where it's called (i.e.
    // we have the comptime parameter info for all functions), and the index field
    // we can figure out what type this is.
    ptr: *anyopaque,

    // When we're asked to describe an object via the Inspector, we _must_ include
    // the proper subtype (and description) fields in the returned JSON.
    // V8 will give us a Value and ask us for the subtype. From the v8.Value we
    // can get a v8.Object, and from the v8.Object, we can get out TaggedAnyOpaque
    // which is where we store the subtype.
    subtype: ?types.Sub,
};

// These are here, and not in Inspector.zig, because Inspector.zig isn't always
// included (e.g. in the wpt build).

// This is called from V8. Whenever the v8 inspector has to describe a value
// it'll call this function to gets its [optional] subtype - which, from V8's
// point of view, is an arbitrary string.
pub export fn v8_inspector__Client__IMPL__valueSubtype(
    _: *v8.c.InspectorClientImpl,
    c_value: *const v8.C_Value,
) callconv(.c) [*c]const u8 {
    const external_entry = Inspector.getTaggedAnyOpaque(.{ .handle = c_value }) orelse return null;
    return if (external_entry.subtype) |st| @tagName(st) else null;
}

// Same as valueSubType above, but for the optional description field.
// From what I can tell, some drivers _need_ the description field to be
// present, even if it's empty. So if we have a subType for the value, we'll
// put an empty description.
pub export fn v8_inspector__Client__IMPL__descriptionForValueSubtype(
    _: *v8.c.InspectorClientImpl,
    v8_context: *const v8.C_Context,
    c_value: *const v8.C_Value,
) callconv(.c) [*c]const u8 {
    _ = v8_context;

    // We _must_ include a non-null description in order for the subtype value
    // to be included. Besides that, I don't know if the value has any meaning
    const external_entry = Inspector.getTaggedAnyOpaque(.{ .handle = c_value }) orelse return null;
    return if (external_entry.subtype == null) null else "";
}
