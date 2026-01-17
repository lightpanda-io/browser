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
const Page = @import("../Page.zig");

const v8 = js.v8;

const Caller = @import("Caller.zig");
const Context = @import("Context.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

pub fn Builder(comptime T: type) type {
    return struct {
        pub const @"type" = T;
        pub const ClassId = u16;

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

        pub fn namedIndexed(comptime getter_func: anytype, setter_func: anytype, deleter_func: anytype, comptime opts: NamedIndexed.Opts) NamedIndexed {
            return NamedIndexed.init(T, getter_func, setter_func, deleter_func, opts);
        }

        pub fn iterator(comptime func: anytype, comptime opts: Iterator.Opts) Iterator {
            return Iterator.init(T, func, opts);
        }

        pub fn callable(comptime func: anytype, comptime opts: Callable.Opts) Callable {
            return Callable.init(T, func, opts);
        }

        pub fn property(value: anytype) Property {
            switch (@typeInfo(@TypeOf(value))) {
                .comptime_int, .int => return .{ .int = value },
                else => {},
            }
            @compileError("Property for " ++ @typeName(@TypeOf(value)) ++ " hasn't been defined yet");
        }

        const PrototypeChainEntry = @import("TaggedOpaque.zig").PrototypeChainEntry;
        pub fn prototypeChain() [prototypeChainLength(T)]PrototypeChainEntry {
            var entries: [prototypeChainLength(T)]PrototypeChainEntry = undefined;

            entries[0] = .{ .offset = 0, .index = JsApiLookup.getId(T.JsApi) };

            if (entries.len == 1) {
                return entries;
            }

            var Prototype = T;
            inline for (entries[1..]) |*entry| {
                const Next = PrototypeType(Prototype).?;
                entry.* = .{
                    .index = JsApiLookup.getId(Next.JsApi),
                    .offset = @offsetOf(Prototype, "_proto"),
                };
                Prototype = Next;
            }
            return entries;
        }
    };
}

pub const Constructor = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        dom_exception: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Constructor {
        return .{ .func = struct {
            fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                caller.init(v8_isolate);
                defer caller.deinit();

                caller.constructor(T, func, handle.?, .{
                    .dom_exception = opts.dom_exception,
                });
            }
        }.wrap };
    }
};

pub const Function = struct {
    static: bool,
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

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
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    caller.init(v8_isolate);
                    defer caller.deinit();

                    if (comptime opts.static) {
                        caller.function(T, func, handle.?, .{
                            .dom_exception = opts.dom_exception,
                            .as_typed_array = opts.as_typed_array,
                            .null_as_undefined = opts.null_as_undefined,
                        });
                    } else {
                        caller.method(T, func, handle.?, .{
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
    static: bool = false,
    getter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,
    setter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,

    const Opts = struct {
        static: bool = false,
        cache: ?[]const u8 = null, // @ZIGDOM
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime setter: anytype, comptime opts: Opts) Accessor {
        var accessor = Accessor{
            .static = opts.static,
        };

        if (@typeInfo(@TypeOf(getter)) != .null) {
            accessor.getter = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    caller.init(v8_isolate);
                    defer caller.deinit();

                    caller.method(T, getter, handle.?, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(setter)) != .null) {
            accessor.setter = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    caller.init(v8_isolate);
                    defer caller.deinit();

                    caller.method(T, setter, handle.?, .{
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
    getter: *const fn (idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime opts: Opts) Indexed {
        return .{ .getter = struct {
            fn wrap(idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                caller.init(v8_isolate);
                defer caller.deinit();

                return caller.getIndex(T, getter, idx, handle.?, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap };
    }
};

pub const NamedIndexed = struct {
    getter: *const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,
    setter: ?*const fn (c_name: ?*const v8.Name, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,
    deleter: ?*const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, setter: anytype, deleter: anytype, comptime opts: Opts) NamedIndexed {
        const getter_fn = struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                caller.init(v8_isolate);
                defer caller.deinit();

                return caller.getNamedIndex(T, getter, c_name.?, handle.?, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap;

        const setter_fn = if (@typeInfo(@TypeOf(setter)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                caller.init(v8_isolate);
                defer caller.deinit();

                return caller.setNamedIndex(T, setter, c_name.?, c_value.?, handle.?, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap;

        const deleter_fn = if (@typeInfo(@TypeOf(deleter)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                caller.init(v8_isolate);
                defer caller.deinit();

                return caller.deleteNamedIndex(T, deleter, c_name.?, handle.?, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap;

        return .{
            .getter = getter_fn,
            .setter = setter_fn,
            .deleter = deleter_fn,
        };
    }
};

pub const Iterator = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,
    async: bool,

    const Opts = struct {
        async: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime struct_or_func: anytype, comptime opts: Opts) Iterator {
        if (@typeInfo(@TypeOf(struct_or_func)) == .type) {
            return .{
                .async = opts.async,
                .func = struct {
                    fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                        const info = Caller.FunctionCallbackInfo{ .handle = handle.? };
                        info.getReturnValue().set(info.getThis());
                    }
                }.wrap,
            };
        }

        return .{
            .async = opts.async,
            .func = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    caller.init(v8_isolate);
                    defer caller.deinit();
                    caller.method(T, struct_or_func, handle.?, .{});
                }
            }.wrap,
        };
    }
};

pub const Callable = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Callable {
        return .{ .func = struct {
            fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                caller.init(v8_isolate);
                defer caller.deinit();

                caller.method(T, func, handle.?, .{
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap };
    }
};

pub const Property = union(enum) {
    int: i64,
};

pub fn unknownPropertyCallback(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
    var caller: Caller = undefined;
    caller.init(v8_isolate);
    defer caller.deinit();

    const local = &caller.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const property: []const u8 = local.valueHandleToString(@ptrCast(c_name.?), .{}) catch {
        return 0;
    };

    const page = local.ctx.page;
    const document = page.document;

    if (document.getElementById(property, page)) |el| {
        const js_val = local.zigValueToJs(el, .{}) catch return 0;
        var pc = Caller.PropertyCallbackInfo{ .handle = handle.? };
        pc.getReturnValue().set(js_val);
        return 1;
    }

    if (comptime IS_DEBUG) {
        const ignored = std.StaticStringMap(void).initComptime(.{
            .{ "process", {} },
            .{ "ShadyDOM", {} },
            .{ "ShadyCSS", {} },

            .{ "litNonce", {} },
            .{ "litHtmlVersions", {} },
            .{ "litElementVersions", {} },
            .{ "litHtmlPolyfillSupport", {} },
            .{ "litElementHydrateSupport", {} },
            .{ "litElementPolyfillSupport", {} },
            .{ "reactiveElementVersions", {} },

            .{ "recaptcha", {} },
            .{ "grecaptcha", {} },
            .{ "___grecaptcha_cfg", {} },
            .{ "__recaptcha_api", {} },
            .{ "__google_recaptcha_client", {} },

            .{ "CLOSURE_FLAGS", {} },
        });
        if (!ignored.has(property)) {
            log.debug(.unknown_prop, "unknown global property", .{
                .info = "but the property can exist in pure JS",
                .stack = local.stackTrace() catch "???",
                .property = property,
            });
        }
    }

    // not intercepted
    return 0;
}

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

pub const JsApiLookup = struct {
    /// Integer type we use for `JsApiLookup` enum. Can be u8 at min.
    pub const BackingInt = std.math.IntFittingRange(0, @max(std.math.maxInt(u8), JsApis.len));

    /// Imagine we have a type `Cat` which has a getter:
    ///
    ///    fn get_owner(self: *Cat) *Owner {
    ///        return self.owner;
    ///    }
    ///
    /// When we execute `caller.getter`, we'll end up doing something like:
    ///
    ///    const res = @call(.auto, Cat.get_owner, .{cat_instance});
    ///
    /// How do we turn `res`, which is an *Owner, into something we can return
    /// to v8? We need the ObjectTemplate associated with Owner. How do we
    /// get that? Well, we store all the ObjectTemplates in an array that's
    /// tied to env. So we do something like:
    ///
    ///    env.templates[index_of_owner].initInstance(...);
    ///
    /// But how do we get that `index_of_owner`? `Index` is an enum
    /// that looks like:
    ///
    ///    pub const Enum = enum(BackingInt) {
    ///        cat = 0,
    ///        owner = 1,
    ///        ...
    ///    }
    ///
    /// (`BackingInt` is calculated at comptime regarding to interfaces we have)
    /// So to get the template index of `owner`, simply do:
    ///
    ///    const index_id = types.getId(@TypeOf(res));
    ///
    pub const Enum = blk: {
        var fields: [JsApis.len]std.builtin.Type.EnumField = undefined;
        for (JsApis, 0..) |JsApi, i| {
            fields[i] = .{ .name = @typeName(JsApi), .value = i };
        }

        break :blk @Type(.{
            .@"enum" = .{
                .fields = &fields,
                .tag_type = BackingInt,
                .is_exhaustive = true,
                .decls = &.{},
            },
        });
    };

    /// Returns a boolean indicating if a type exist in the lookup.
    pub inline fn has(t: type) bool {
        return @hasField(Enum, @typeName(t));
    }

    /// Returns the `Enum` for the given type.
    pub inline fn getIndex(t: type) Enum {
        return @field(Enum, @typeName(t));
    }

    /// Returns the ID for the given type.
    pub inline fn getId(t: type) BackingInt {
        return @intFromEnum(getIndex(t));
    }
};

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
    @import("../webapi/cdata/CDATASection.zig"),
    @import("../webapi/cdata/ProcessingInstruction.zig"),
    @import("../webapi/collections.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/CSS.zig"),
    @import("../webapi/css/CSSRule.zig"),
    @import("../webapi/css/CSSRuleList.zig"),
    @import("../webapi/css/CSSStyleDeclaration.zig"),
    @import("../webapi/css/CSSStyleRule.zig"),
    @import("../webapi/css/CSSStyleSheet.zig"),
    @import("../webapi/css/CSSStyleProperties.zig"),
    @import("../webapi/css/MediaQueryList.zig"),
    @import("../webapi/css/StyleSheetList.zig"),
    @import("../webapi/Document.zig"),
    @import("../webapi/HTMLDocument.zig"),
    @import("../webapi/XMLDocument.zig"),
    @import("../webapi/History.zig"),
    @import("../webapi/KeyValueList.zig"),
    @import("../webapi/DocumentFragment.zig"),
    @import("../webapi/DocumentType.zig"),
    @import("../webapi/ShadowRoot.zig"),
    @import("../webapi/DOMException.zig"),
    @import("../webapi/DOMImplementation.zig"),
    @import("../webapi/DOMTreeWalker.zig"),
    @import("../webapi/DOMNodeIterator.zig"),
    @import("../webapi/DOMRect.zig"),
    @import("../webapi/DOMParser.zig"),
    @import("../webapi/XMLSerializer.zig"),
    @import("../webapi/AbstractRange.zig"),
    @import("../webapi/Range.zig"),
    @import("../webapi/NodeFilter.zig"),
    @import("../webapi/Element.zig"),
    @import("../webapi/element/DOMStringMap.zig"),
    @import("../webapi/element/Attribute.zig"),
    @import("../webapi/element/Html.zig"),
    @import("../webapi/element/html/IFrame.zig"),
    @import("../webapi/element/html/Anchor.zig"),
    @import("../webapi/element/html/Area.zig"),
    @import("../webapi/element/html/Audio.zig"),
    @import("../webapi/element/html/Base.zig"),
    @import("../webapi/element/html/Body.zig"),
    @import("../webapi/element/html/BR.zig"),
    @import("../webapi/element/html/Button.zig"),
    @import("../webapi/element/html/Canvas.zig"),
    @import("../webapi/element/html/Custom.zig"),
    @import("../webapi/element/html/Data.zig"),
    @import("../webapi/element/html/DataList.zig"),
    @import("../webapi/element/html/Dialog.zig"),
    @import("../webapi/element/html/Directory.zig"),
    @import("../webapi/element/html/Div.zig"),
    @import("../webapi/element/html/Embed.zig"),
    @import("../webapi/element/html/FieldSet.zig"),
    @import("../webapi/element/html/Font.zig"),
    @import("../webapi/element/html/Form.zig"),
    @import("../webapi/element/html/Generic.zig"),
    @import("../webapi/element/html/Head.zig"),
    @import("../webapi/element/html/Heading.zig"),
    @import("../webapi/element/html/HR.zig"),
    @import("../webapi/element/html/Html.zig"),
    @import("../webapi/element/html/Image.zig"),
    @import("../webapi/element/html/Input.zig"),
    @import("../webapi/element/html/Label.zig"),
    @import("../webapi/element/html/Legend.zig"),
    @import("../webapi/element/html/LI.zig"),
    @import("../webapi/element/html/Link.zig"),
    @import("../webapi/element/html/Map.zig"),
    @import("../webapi/element/html/Media.zig"),
    @import("../webapi/element/html/Meta.zig"),
    @import("../webapi/element/html/Meter.zig"),
    @import("../webapi/element/html/Mod.zig"),
    @import("../webapi/element/html/Object.zig"),
    @import("../webapi/element/html/OL.zig"),
    @import("../webapi/element/html/OptGroup.zig"),
    @import("../webapi/element/html/Option.zig"),
    @import("../webapi/element/html/Output.zig"),
    @import("../webapi/element/html/Paragraph.zig"),
    @import("../webapi/element/html/Param.zig"),
    @import("../webapi/element/html/Pre.zig"),
    @import("../webapi/element/html/Progress.zig"),
    @import("../webapi/element/html/Quote.zig"),
    @import("../webapi/element/html/Script.zig"),
    @import("../webapi/element/html/Select.zig"),
    @import("../webapi/element/html/Slot.zig"),
    @import("../webapi/element/html/Source.zig"),
    @import("../webapi/element/html/Span.zig"),
    @import("../webapi/element/html/Style.zig"),
    @import("../webapi/element/html/Table.zig"),
    @import("../webapi/element/html/TableCaption.zig"),
    @import("../webapi/element/html/TableCell.zig"),
    @import("../webapi/element/html/TableCol.zig"),
    @import("../webapi/element/html/TableRow.zig"),
    @import("../webapi/element/html/TableSection.zig"),
    @import("../webapi/element/html/Template.zig"),
    @import("../webapi/element/html/TextArea.zig"),
    @import("../webapi/element/html/Time.zig"),
    @import("../webapi/element/html/Title.zig"),
    @import("../webapi/element/html/Track.zig"),
    @import("../webapi/element/html/Video.zig"),
    @import("../webapi/element/html/UL.zig"),
    @import("../webapi/element/html/Unknown.zig"),
    @import("../webapi/element/Svg.zig"),
    @import("../webapi/element/svg/Generic.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/CompositionEvent.zig"),
    @import("../webapi/event/CustomEvent.zig"),
    @import("../webapi/event/ErrorEvent.zig"),
    @import("../webapi/event/MessageEvent.zig"),
    @import("../webapi/event/ProgressEvent.zig"),
    @import("../webapi/event/NavigationCurrentEntryChangeEvent.zig"),
    @import("../webapi/event/PageTransitionEvent.zig"),
    @import("../webapi/event/PopStateEvent.zig"),
    @import("../webapi/event/UIEvent.zig"),
    @import("../webapi/event/MouseEvent.zig"),
    @import("../webapi/event/KeyboardEvent.zig"),
    @import("../webapi/MessageChannel.zig"),
    @import("../webapi/MessagePort.zig"),
    @import("../webapi/media/MediaError.zig"),
    @import("../webapi/media/TextTrackCue.zig"),
    @import("../webapi/media/VTTCue.zig"),
    @import("../webapi/animation/Animation.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Location.zig"),
    @import("../webapi/Navigator.zig"),
    @import("../webapi/net/FormData.zig"),
    @import("../webapi/net/Headers.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/streams/ReadableStream.zig"),
    @import("../webapi/streams/ReadableStreamDefaultReader.zig"),
    @import("../webapi/streams/ReadableStreamDefaultController.zig"),
    @import("../webapi/Node.zig"),
    @import("../webapi/storage/storage.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/Window.zig"),
    @import("../webapi/Performance.zig"),
    @import("../webapi/MutationObserver.zig"),
    @import("../webapi/IntersectionObserver.zig"),
    @import("../webapi/CustomElementRegistry.zig"),
    @import("../webapi/ResizeObserver.zig"),
    @import("../webapi/IdleDeadline.zig"),
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/Screen.zig"),
    @import("../webapi/PerformanceObserver.zig"),
    @import("../webapi/navigation/Navigation.zig"),
    @import("../webapi/navigation/NavigationEventTarget.zig"),
    @import("../webapi/navigation/NavigationHistoryEntry.zig"),
    @import("../webapi/navigation/NavigationActivation.zig"),
    @import("../webapi/canvas/CanvasRenderingContext2D.zig"),
    @import("../webapi/canvas/WebGLRenderingContext.zig"),
});
