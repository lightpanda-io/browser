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

const std = @import("std");
const js = @import("js.zig");
const log = @import("../../log.zig");

const v8 = js.v8;

const Caller = @import("Caller.zig");

pub fn Builder(comptime T: type) type {
    return struct {
        pub const @"type" = T;

        pub fn constructor(comptime func: anytype, comptime opts: Constructor.Opts) Constructor {
            return Constructor.init(T, func, opts);
        }

        pub fn accessor(comptime getter: anytype, comptime setter: anytype, comptime opts: Accessor.Opts) Accessor {
            return Accessor.init(T, getter, setter, opts);
        }

        pub fn function(comptime func: anytype, comptime opts: Function.Opts) Function {
            return Function.init(T, func, opts);
        }

        pub fn indexed(comptime getter_func: anytype, comptime opts: Indexed.Opts) Indexed {
            return Indexed.init(T, getter_func, opts);
        }

        pub fn namedIndexed(comptime getter_func: anytype, comptime opts: NamedIndexed.Opts) NamedIndexed {
            return NamedIndexed.init(T, getter_func, opts);
        }

        pub fn iterator(comptime func: anytype, comptime opts: Iterator.Opts) Iterator {
            return Iterator.init(T, func, opts);
        }

        pub fn property(value: anytype) Property.GetType(@TypeOf(value)) {
            return Property.GetType(@TypeOf(value)).init(value);
        }

        pub fn prototypeChain() [prototypeChainLength(T)]js.PrototypeChainEntry {
            var entries: [prototypeChainLength(T)]js.PrototypeChainEntry = undefined;

            entries[0] = .{
                .offset = 0,
                .index = @field(JS_API_LOOKUP, @typeName(T.JsApi)),
            };

            if (entries.len == 1) {
                return entries;
            }

            var Prototype = T;
            for (entries[1..]) |*entry| {
                const Next = PrototypeType(Prototype).?;
                entry.* = .{
                    .index = @field(JS_API_LOOKUP, @typeName(Next.JsApi)),
                    .offset = @offsetOf(Prototype, "_proto"),
                };
                Prototype = Next;
            }
            return entries;
        }
    };
}

pub const Constructor = struct {
    func: *const fn (?*const v8.C_FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        dom_exception: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Constructor {
        return .{ .func = struct {
            fn wrap(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();

                caller.constructor(T, func, info, .{
                    .dom_exception = opts.dom_exception,
                });
            }
        }.wrap };
    }
};

pub const Function = struct {
    static: bool,
    func: *const fn (?*const v8.C_FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        static: bool = false,
        dom_exception: bool = false,
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Function {
        return .{
            .static = opts.static,
            .func = struct {
                fn wrap(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                    const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                    var caller = Caller.init(info);
                    defer caller.deinit();

                    if (comptime opts.static) {
                        caller.function(T, func, info, .{
                            .dom_exception = opts.dom_exception,
                            .as_typed_array = opts.as_typed_array,
                            .null_as_undefined = opts.null_as_undefined,
                        });
                    } else {
                        caller.method(T, func, info, .{
                            .dom_exception = opts.dom_exception,
                            .as_typed_array = opts.as_typed_array,
                            .null_as_undefined = opts.null_as_undefined,
                        });
                    }
                }
            }.wrap,
        };
    }
};

pub const Accessor = struct {
    getter: ?*const fn (?*const v8.C_FunctionCallbackInfo) callconv(.c) void = null,
    setter: ?*const fn (?*const v8.C_FunctionCallbackInfo) callconv(.c) void = null,

    const Opts = struct {
        cache: ?[]const u8 = null, // @ZIGDOM
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime setter: anytype, comptime opts: Opts) Accessor {
        var accessor = Accessor{};
        if (@typeInfo(@TypeOf(getter)) != .null) {
            accessor.getter = struct {
                fn wrap(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                    const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                    var caller = Caller.init(info);
                    defer caller.deinit();

                    caller.method(T, getter, info, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(setter)) != .null) {
            accessor.setter = struct {
                fn wrap(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                    const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                    std.debug.assert(info.length() == 1);

                    var caller = Caller.init(info);
                    defer caller.deinit();

                    caller.method(T, setter, info, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap;
        }

        return accessor;
    }
};

pub const Indexed = struct {
    getter: *const fn (idx: u32, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime opts: Opts) Indexed {
        return .{ .getter = struct {
            fn wrap(idx: u32, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8 {
                const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();
                return caller.getIndex(T, getter, idx, info, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap };
    }
};

pub const NamedIndexed = struct {
    getter: *const fn (c_name: ?*const v8.C_Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime opts: Opts) NamedIndexed {
        return .{ .getter = struct {
            fn wrap(c_name: ?*const v8.C_Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.c) u8 {
                const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();
                return caller.getNamedIndex(T, getter, .{ .handle = c_name.? }, info, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap };
    }
};

pub const Iterator = struct {
    func: *const fn (?*const v8.C_FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {};

    fn init(comptime T: type, comptime struct_or_func: anytype, comptime opts: Opts) Iterator {
        _ = opts;
        if (@typeInfo(@TypeOf(struct_or_func)) == .type) {
            return .{ .func = struct {
                fn wrap(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                    const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                    info.getReturnValue().set(info.getThis());
                }
            }.wrap };
        }

        return .{ .func = struct {
            fn wrap(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
                const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
                var caller = Caller.init(info);
                defer caller.deinit();
                caller.method(T, struct_or_func, info, .{});
            }
        }.wrap };
    }
};

pub const Property = struct {
    fn GetType(comptime T: type) type {
        switch (@typeInfo(T)) {
            .comptime_int, .int => return Int,
            else => @compileError("Property for " ++ @typeName(T) ++ " hasn't been defined yet"),
        }
    }

    pub const Int = struct {
        int: i64,
        pub fn init(value: i64) Int {
            return .{ .int = value };
        }
    };
};

// Given a Type, returns the length of the prototype chain, including self
fn prototypeChainLength(comptime T: type) usize {
    var l: usize = 1;
    var Next = T;
    while (PrototypeType(Next)) |N| {
        Next = N;
        l += 1;
    }
    return l;
}

// Given a Type, gets its prototype Type (if any)
fn PrototypeType(comptime T: type) ?type {
    if (!@hasField(T, "_proto")) {
        return null;
    }
    return Struct(std.meta.fieldInfo(T, ._proto).type);
}

fn flattenTypes(comptime Types: []const type) [countFlattenedTypes(Types)]type {
    var index: usize = 0;
    var flat: [countFlattenedTypes(Types)]type = undefined;
    for (Types) |T| {
        if (@hasDecl(T, "registerTypes")) {
            for (T.registerTypes()) |TT| {
                flat[index] = TT.JsApi;
                index += 1;
            }
        } else {
            flat[index] = T.JsApi;
            index += 1;
        }
    }
    return flat;
}

fn countFlattenedTypes(comptime Types: []const type) usize {
    var c: usize = 0;
    for (Types) |T| {
        c += if (@hasDecl(T, "registerTypes")) T.registerTypes().len else 1;
    }
    return c;
}

//  T => T
// *T => T
pub fn Struct(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => T,
        .pointer => |ptr| ptr.child,
        else => @compileError("Expecting Struct or *Struct, got: " ++ @typeName(T)),
    };
}

// Imagine we have a type Cat which has a getter:
//
//    fn getOwner(self: *Cat) *Owner {
//        return self.owner;
//    }
//
// When we execute caller.getter, we'll end up doing something like:
//   const res = @call(.auto, Cat.getOwner, .{cat_instance});
//
// How do we turn `res`, which is an *Owner, into something we can return
// to v8? We need the ObjectTemplate associated with Owner. How do we
// get that? Well, we store all the ObjectTemplates in an array that's
// tied to env. So we do something like:
//
//    env.templates[index_of_owner].initInstance(...);
//
// But how do we get that `index_of_owner`? `Lookup` is a struct
// that looks like:
//
// const Lookup = struct {
//     comptime cat: usize = 0,
//     comptime owner: usize = 1,
//     ...
// }
//
// So to get the template index of `owner`, we can do:
//
//  const index_id = @field(type_lookup, @typeName(@TypeOf(res));
//
pub const JsApiLookup = blk: {
    var fields: [JsApis.len]std.builtin.Type.StructField = undefined;
    for (JsApis, 0..) |JsApi, i| {
        fields[i] = .{
            .name = @typeName(JsApi),
            .type = u16,
            .is_comptime = true,
            .alignment = @alignOf(u16),
            .default_value_ptr = @ptrCast(&i),
        };
    }
    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .decls = &.{},
        .is_tuple = false,
        .fields = &fields,
    } });
};

pub const JS_API_LOOKUP = JsApiLookup{};

pub const SubType = enum {
    @"error",
    array,
    arraybuffer,
    dataview,
    date,
    generator,
    iterator,
    map,
    node,
    promise,
    proxy,
    regexp,
    set,
    typedarray,
    wasmvalue,
    weakmap,
    weakset,
    webassemblymemory,
};

pub const JsApis = flattenTypes(&.{
    @import("../webapi/AbortController.zig"),
    @import("../webapi/AbortSignal.zig"),
    @import("../webapi/CData.zig"),
    @import("../webapi/cdata/Comment.zig"),
    @import("../webapi/cdata/Text.zig"),
    @import("../webapi/collections.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/css/CSSStyleDeclaration.zig"),
    @import("../webapi/css/CSSStyleProperties.zig"),
    @import("../webapi/Document.zig"),
    @import("../webapi/HTMLDocument.zig"),
    @import("../webapi/DocumentFragment.zig"),
    @import("../webapi/DOMException.zig"),
    @import("../webapi/DOMTreeWalker.zig"),
    @import("../webapi/DOMNodeIterator.zig"),
    @import("../webapi/NodeFilter.zig"),
    @import("../webapi/Element.zig"),
    @import("../webapi/element/Attribute.zig"),
    @import("../webapi/element/Html.zig"),
    @import("../webapi/element/html/Anchor.zig"),
    @import("../webapi/element/html/Body.zig"),
    @import("../webapi/element/html/BR.zig"),
    @import("../webapi/element/html/Button.zig"),
    @import("../webapi/element/html/Custom.zig"),
    @import("../webapi/element/html/Div.zig"),
    @import("../webapi/element/html/Form.zig"),
    @import("../webapi/element/html/Generic.zig"),
    @import("../webapi/element/html/Head.zig"),
    @import("../webapi/element/html/Heading.zig"),
    @import("../webapi/element/html/HR.zig"),
    @import("../webapi/element/html/Html.zig"),
    @import("../webapi/element/html/Image.zig"),
    @import("../webapi/element/html/Input.zig"),
    @import("../webapi/element/html/LI.zig"),
    @import("../webapi/element/html/Link.zig"),
    @import("../webapi/element/html/Meta.zig"),
    @import("../webapi/element/html/OL.zig"),
    @import("../webapi/element/html/Option.zig"),
    @import("../webapi/element/html/Paragraph.zig"),
    @import("../webapi/element/html/Script.zig"),
    @import("../webapi/element/html/Select.zig"),
    @import("../webapi/element/html/Style.zig"),
    @import("../webapi/element/html/TextArea.zig"),
    @import("../webapi/element/html/Title.zig"),
    @import("../webapi/element/html/UL.zig"),
    @import("../webapi/element/html/Unknown.zig"),
    @import("../webapi/element/Svg.zig"),
    @import("../webapi/element/svg/Generic.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/ErrorEvent.zig"),
    @import("../webapi/event/ProgressEvent.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Location.zig"),
    @import("../webapi/Navigator.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/Node.zig"),
    @import("../webapi/storage/storage.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/Window.zig"),
    @import("../webapi/MutationObserver.zig"),
});
