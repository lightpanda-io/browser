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

const js = @import("js.zig");
const v8 = js.v8;
const bridge = js.bridge;

// When we return a Zig object to V8, we put it on the heap and pass it into
// v8 as an *anyopaque (i.e. void *). When V8 gives us back the value, say, as a
// function parameter, we know what type it _should_ be.
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
// The zig_setOwner method expects the 2nd parameter to be an *Owner, but
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
// For this reason, we also store the prototype chain.
const TaggedOpaque = @This();

prototype_len: u16,
prototype_chain: [*]const PrototypeChainEntry,

// Ptr to the Zig instance. Between the context where it's called (i.e.
// we have the comptime parameter info for all functions), and the index field
// we can figure out what type this is.
value: *anyopaque,

// When we're asked to describe an object via the Inspector, we _must_ include
// the proper subtype (and description) fields in the returned JSON.
// V8 will give us a Value and ask us for the subtype. From the js.Value we
// can get a js.Object, and from the js.Object, we can get out TaggedOpaque
// which is where we store the subtype.
subtype: ?bridge.SubType,

pub const PrototypeChainEntry = struct {
    index: bridge.JsApiLookup.BackingInt,
    offset: u16, // offset to the _proto field
};

// Reverses the mapZigInstanceToJs, making sure that our TaggedOpaque
// contains a ptr to the correct type.
pub fn fromJS(comptime R: type, js_obj_handle: *const v8.Object) !R {
    const ti = @typeInfo(R);
    if (ti != .pointer) {
        @compileError("non-pointer Zig parameter type: " ++ @typeName(R));
    }

    const T = ti.pointer.child;
    const JsApi = bridge.Struct(T).JsApi;

    if (@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
        // Empty structs aren't stored as TOAs and there's no data
        // stored in the JSObject's IntenrnalField. Why bother when
        // we can just return an empty struct here?
        return @constCast(@as(*const T, &.{}));
    }

    const internal_field_count = v8.v8__Object__InternalFieldCount(js_obj_handle);
    // Special case for Window: the global object doesn't have internal fields
    // Window instance is stored in context.page.window instead
    if (internal_field_count == 0) {
        // Normally, this would be an error. All JsObject that map to a Zig type
        // are either `empty_with_no_proto` (handled above) or have an
        // interalFieldCount. The only exception to that is the Window...
        const isolate = v8.v8__Object__GetIsolate(js_obj_handle).?;
        const context = js.Context.fromIsolate(.{ .handle = isolate });

        const Window = @import("../webapi/Window.zig");
        if (T == Window) {
            return context.page.window;
        }

        // ... Or the window's prototype.
        // We could make this all comptime-fancy, but it's easier to hard-code
        // the EventTarget

        const EventTarget = @import("../webapi/EventTarget.zig");
        if (T == EventTarget) {
            return context.page.window._proto;
        }

        // Type not found in Window's prototype chain
        return error.InvalidArgument;
    }

    // if it isn't an empty struct, then the v8.Object should have an
    // InternalFieldCount > 0, since our toa pointer should be embedded
    // at index 0 of the internal field count.
    if (internal_field_count == 0) {
        return error.InvalidArgument;
    }

    if (!bridge.JsApiLookup.has(JsApi)) {
        @compileError("unknown Zig type: " ++ @typeName(R));
    }

    const internal_field_handle = v8.v8__Object__GetInternalField(js_obj_handle, 0).?;
    const tao: *TaggedOpaque = @ptrCast(@alignCast(v8.v8__External__Value(internal_field_handle)));
    const expected_type_index = bridge.JsApiLookup.getId(JsApi);

    const prototype_chain = tao.prototype_chain[0..tao.prototype_len];
    if (prototype_chain[0].index == expected_type_index) {
        return @ptrCast(@alignCast(tao.value));
    }

    // Ok, let's walk up the chain
    var ptr = @intFromPtr(tao.value);
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
