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

// The quickjs flavor of the bridge: turns JsApi declarations into quickjs
// C-function trampolines. The engine-agnostic registry (type lists,
// lookup, prototype chains) lives in ../registry.zig.
const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../../Frame.zig");

const js = @import("js.zig");
const Caller = @import("Caller.zig");
const registry = @import("../registry.zig");

const q = js.q;
const IS_DEBUG = @import("builtin").mode == .Debug;

pub const Struct = registry.Struct;
pub const JsApiLookup = registry.JsApiLookup;
pub const SubType = registry.SubType;
pub const PageJsApis = registry.PageJsApis;
pub const WorkerJsApis = registry.WorkerJsApis;
pub const JsApis = registry.JsApis;

pub const Realm = enum {
    window,
    worker,

    fn asExposed(comptime self: Realm) Caller.Function.Opts.Exposed {
        return switch (self) {
            .window => .window,
            .worker => .worker,
        };
    }
};

pub fn Builder(comptime T: type) type {
    return struct {
        pub const @"type" = T;
        pub const ClassId = q.JSClassID;

        pub fn constructor(comptime func: anytype, comptime opts: Constructor.Opts) Constructor {
            return Constructor.init(T, func, opts);
        }

        pub fn accessor(comptime getter: anytype, comptime setter: anytype, comptime opts: Caller.Function.Opts) Accessor {
            return Accessor.init(T, getter, setter, opts);
        }

        pub fn function(comptime func: anytype, comptime opts: Caller.Function.Opts) Function {
            return Function.init(T, func, opts);
        }

        pub fn indexed(comptime getter_func: anytype, comptime enumerator_func: anytype, comptime opts: Indexed.Opts) Indexed {
            return Indexed.init(T, getter_func, enumerator_func, opts);
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

        pub fn property(value: anytype, opts: Property.Opts) Property {
            switch (@typeInfo(@TypeOf(value))) {
                .bool => return Property.init(.{ .bool = value }, opts),
                .null => return Property.init(.null, opts),
                .comptime_int, .int => return Property.init(.{ .int = value }, opts),
                .comptime_float, .float => return Property.init(.{ .float = value }, opts),
                .pointer => |ptr| switch (ptr.size) {
                    .one => {
                        const one_info = @typeInfo(ptr.child);
                        if (one_info == .array and one_info.array.child == u8) {
                            return Property.init(.{ .string = value }, opts);
                        }
                    },
                    else => {},
                },
                else => {},
            }
            @compileError("Property for " ++ @typeName(@TypeOf(value)) ++ " hasn't been defined yet");
        }

        pub fn prototypeChain() [registry.prototypeChainLength(T)]registry.PrototypeChainEntry {
            return registry.prototypeChain(T);
        }
    };
}

pub const Constructor = struct {
    arity: c_int,
    func: q.JSCFunction,

    const Opts = struct {
        dom_exception: bool = false,
        new_target: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Constructor {
        return .{
            .arity = @intCast(comptime Function.getArity(@TypeOf(func), if (opts.new_target) 1 else 0)),
            .func = struct {
                fn wrap(qctx: ?*q.JSContext, new_target: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst) callconv(.c) q.JSValue {
                    return Caller.constructor(T, func, qctx.?, new_target, argc, argv, .{
                        .dom_exception = opts.dom_exception,
                        .new_target = opts.new_target,
                    });
                }
            }.wrap,
        };
    }

    pub fn illegal(qctx: ?*q.JSContext, _: q.JSValueConst, _: c_int, _: [*c]q.JSValueConst) callconv(.c) q.JSValue {
        return q.JS_ThrowTypeError(qctx, "Illegal Constructor");
    }
};

pub const Function = struct {
    static: bool,
    arity: usize,
    noop: bool = false,
    wpt_only: bool = false,
    exposed: Caller.Function.Opts.Exposed = .both,
    cache: ?Caller.Function.Opts.Caching = null,
    func: q.JSCFunction,

    fn init(comptime T: type, comptime func: anytype, comptime opts: Caller.Function.Opts) Function {
        return .{
            .cache = opts.cache,
            .static = opts.static,
            .wpt_only = opts.wpt_only,
            .exposed = opts.exposed,
            .arity = getArity(@TypeOf(func), if (opts.static) 0 else 1),
            .func = if (opts.noop) noopFunction else struct {
                fn wrap(qctx: ?*q.JSContext, js_this: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst) callconv(.c) q.JSValue {
                    return Caller.Function.call(T, qctx.?, js_this, argc, argv, func, opts);
                }
            }.wrap,
        };
    }

    pub fn noopFunction(_: ?*q.JSContext, _: q.JSValueConst, _: c_int, _: [*c]q.JSValueConst) callconv(.c) q.JSValue {
        return js.UNDEFINED;
    }

    fn getArity(comptime T: type, comptime start: usize) usize {
        const Execution = js.Execution;

        const Page = @import("../../Page.zig");
        const Session = @import("../../Session.zig");

        var count: usize = 0;
        var params = @typeInfo(T).@"fn".params;
        for (params[start..]) |p| {
            const PT = p.type.?;
            if (PT == *Frame or PT == *const Frame) {
                break;
            }
            if (PT == *Page or PT == *const Page) {
                break;
            }
            if (PT == *Execution or PT == *const Execution) {
                break;
            }
            if (PT == *Session or PT == *const Session) {
                break;
            }
            if (@typeInfo(PT) == .optional) {
                break;
            }
            count += 1;
        }
        return count;
    }
};

const GetterFn = *const fn (?*q.JSContext, q.JSValueConst) callconv(.c) q.JSValue;
const SetterFn = *const fn (?*q.JSContext, q.JSValueConst, q.JSValueConst) callconv(.c) q.JSValue;

pub const Accessor = struct {
    static: bool = false,
    deletable: bool = true,
    wpt_only: bool = false,
    exposed: Caller.Function.Opts.Exposed = .both,
    cache: ?Caller.Function.Opts.Caching = null,
    getter: ?GetterFn = null,
    setter: ?SetterFn = null,

    fn init(comptime T: type, comptime getter: anytype, comptime setter: anytype, comptime opts: Caller.Function.Opts) Accessor {
        var accessor = Accessor{
            .cache = opts.cache,
            .static = opts.static,
            .wpt_only = opts.wpt_only,
            .deletable = opts.deletable,
            .exposed = opts.exposed,
        };

        if (@typeInfo(@TypeOf(getter)) != .null) {
            const getter_opts = if (opts.ce_reactions == false) opts else blk: {
                var o = opts;
                o.ce_reactions = false;
                break :blk o;
            };

            accessor.getter = struct {
                fn wrap(qctx: ?*q.JSContext, js_this: q.JSValueConst) callconv(.c) q.JSValue {
                    return Caller.Function.call(T, qctx.?, js_this, 0, null, getter, getter_opts);
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(setter)) != .null) {
            accessor.setter = struct {
                fn wrap(qctx: ?*q.JSContext, js_this: q.JSValueConst, js_value: q.JSValueConst) callconv(.c) q.JSValue {
                    var args = [_]q.JSValue{js_value};
                    return Caller.Function.call(T, qctx.?, js_this, 1, &args, setter, opts);
                }
            }.wrap;
        }

        return accessor;
    }
};

// quickjs exotic-method signatures.
const GetOwnPropertyFn = *const fn (?*q.JSContext, [*c]q.JSPropertyDescriptor, q.JSValueConst, q.JSAtom) callconv(.c) c_int;
const SetPropertyFn = *const fn (?*q.JSContext, q.JSValueConst, q.JSAtom, q.JSValueConst, q.JSValueConst, c_int) callconv(.c) c_int;
const DeletePropertyFn = *const fn (?*q.JSContext, q.JSValueConst, q.JSAtom) callconv(.c) c_int;

const GetOwnPropertyNamesFn = @FieldType(q.JSClassExoticMethods, "get_own_property_names");

// Indexed properties (e.g. nodeList[1]) are implemented via the class'
// exotic get_own_property, dispatching on integer atoms. When an enumerator
// is supplied, get_names lists those indices via get_own_property_names so
// Object.keys / for..in / spread / Array.from see them.
pub const Indexed = struct {
    get_own: GetOwnPropertyFn,
    get_names: GetOwnPropertyNamesFn = null,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime enumerator: anytype, comptime opts: Opts) Indexed {
        var indexed = Indexed{
            .get_own = struct {
                fn wrap(qctx: ?*q.JSContext, desc: [*c]q.JSPropertyDescriptor, js_this: q.JSValueConst, prop: q.JSAtom) callconv(.c) c_int {
                    if (prop & js.JS_ATOM_TAG_INT == 0) {
                        return 0;
                    }
                    const index: u32 = prop & ~js.JS_ATOM_TAG_INT;

                    var caller: Caller = undefined;
                    if (!caller.init(qctx.?)) {
                        return -1;
                    }
                    defer caller.deinit();

                    const result = caller.getIndex(T, getter, js_this, index, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    }) catch |err| {
                        _ = Caller.handleError(T, @TypeOf(getter), &caller.local, err, .{});
                        return -1;
                    };
                    return fillDescriptor(qctx.?, desc, result);
                }
            }.wrap,
        };

        if (@typeInfo(@TypeOf(enumerator)) != .null) {
            indexed.get_names = struct {
                fn wrap(qctx: ?*q.JSContext, ptab: [*c][*c]q.JSPropertyEnum, plen: [*c]u32, js_this: q.JSValueConst) callconv(.c) c_int {
                    var caller: Caller = undefined;
                    if (!caller.init(qctx.?)) {
                        return -1;
                    }
                    defer caller.deinit();

                    const arr = caller.getEnumerator(T, enumerator, js_this) catch {
                        return -1;
                    };
                    const n = arr.len();
                    if (n == 0) {
                        ptab.* = null;
                        plen.* = 0;
                        return 0;
                    }

                    const tab: [*c]q.JSPropertyEnum = @ptrCast(@alignCast(q.js_mallocz(qctx, @sizeOf(q.JSPropertyEnum) * n) orelse return -1));
                    for (0..n) |i| {
                        const value = arr.get(@intCast(i)) catch {
                            for (0..i) |j| q.JS_FreeAtom(qctx, tab[j].atom);
                            q.js_free(qctx, tab);
                            return -1;
                        };
                        tab[i].atom = q.JS_ValueToAtom(qctx, value.handle);
                        tab[i].is_enumerable = true;
                    }
                    ptab.* = tab;
                    plen.* = @intCast(n);
                    return 0;
                }
            }.wrap;
        }

        return indexed;
    }
};

pub const NamedIndexed = struct {
    get_own: GetOwnPropertyFn,
    set_property: ?SetPropertyFn = null,
    delete_property: ?DeletePropertyFn = null,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
        ce_reactions: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, setter: anytype, deleter: anytype, comptime opts: Opts) NamedIndexed {
        const getter_fn = struct {
            fn wrap(qctx: ?*q.JSContext, desc: [*c]q.JSPropertyDescriptor, js_this: q.JSValueConst, prop: q.JSAtom) callconv(.c) c_int {
                if (prop & js.JS_ATOM_TAG_INT != 0) {
                    return 0;
                }

                // Emulate v8's `kOnlyInterceptStrings | kNonMasking` named
                // interceptor. quickjs consults this exotic get_own_property
                // *before* walking the prototype, so without these guards a
                // named getter (e.g. Storage's `[str]`) would shadow every
                // prototype member: `localStorage.setItem` and even
                // `Object.prototype.toString` would resolve to the getter
                // (returning undefined) instead of the real method.
                //
                // kOnlyInterceptStrings: don't intercept symbol keys.
                const key = q.JS_AtomToValue(qctx, prop);
                defer q.JS_FreeValue(qctx, key);
                if (q.JS_IsSymbol(key)) {
                    return 0;
                }

                // kNonMasking: per WebIDL, named properties don't override
                // members already on the prototype chain (no
                // [LegacyOverrideBuiltIns]). Defer to the prototype when the
                // name resolves there.
                const proto = q.JS_GetPrototype(qctx, js_this);
                defer q.JS_FreeValue(qctx, proto);
                if (!q.JS_IsNull(proto) and q.JS_HasProperty(qctx, proto, prop) == 1) {
                    return 0;
                }

                var caller: Caller = undefined;
                if (!caller.init(qctx.?)) {
                    return -1;
                }
                defer caller.deinit();

                const result = caller.getNamedIndex(T, getter, js_this, prop, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                }) catch |err| {
                    _ = Caller.handleError(T, @TypeOf(getter), &caller.local, err, .{});
                    return -1;
                };
                return fillDescriptor(qctx.?, desc, result);
            }
        }.wrap;

        const setter_fn = if (@typeInfo(@TypeOf(setter)) == .null) null else struct {
            fn wrap(qctx: ?*q.JSContext, js_this: q.JSValueConst, prop: q.JSAtom, js_value: q.JSValueConst, receiver: q.JSValueConst, flags: c_int) callconv(.c) c_int {
                _ = receiver;
                _ = flags;
                if (prop & js.JS_ATOM_TAG_INT != 0) {
                    return 0;
                }

                var caller: Caller = undefined;
                if (!caller.init(qctx.?)) {
                    return -1;
                }
                defer caller.deinit();

                const ce_frame: ?*Frame = if (comptime opts.ce_reactions) switch (caller.local.ctx.global) {
                    .frame => |frame| frame,
                    .worker => null,
                } else null;
                var ce_checkpoint: usize = undefined;
                if (comptime opts.ce_reactions) {
                    if (ce_frame) |frame| ce_checkpoint = frame._ce_reactions.push();
                }
                defer if (comptime opts.ce_reactions) {
                    if (ce_frame) |frame| frame._ce_reactions.popAndInvoke(ce_checkpoint, frame);
                };

                const result = caller.setNamedIndex(T, setter, js_this, prop, js_value, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                }) catch |err| {
                    _ = Caller.handleError(T, @TypeOf(setter), &caller.local, err, .{});
                    return -1;
                };
                return @intFromBool(result.handled);
            }
        }.wrap;

        const deleter_fn = if (@typeInfo(@TypeOf(deleter)) == .null) null else struct {
            fn wrap(qctx: ?*q.JSContext, js_this: q.JSValueConst, prop: q.JSAtom) callconv(.c) c_int {
                if (prop & js.JS_ATOM_TAG_INT != 0) {
                    return 0;
                }

                var caller: Caller = undefined;
                if (!caller.init(qctx.?)) {
                    return -1;
                }
                defer caller.deinit();

                const ce_frame: ?*Frame = if (comptime opts.ce_reactions) switch (caller.local.ctx.global) {
                    .frame => |frame| frame,
                    .worker => null,
                } else null;
                var ce_checkpoint: usize = undefined;
                if (comptime opts.ce_reactions) {
                    if (ce_frame) |frame| ce_checkpoint = frame._ce_reactions.push();
                }
                defer if (comptime opts.ce_reactions) {
                    if (ce_frame) |frame| frame._ce_reactions.popAndInvoke(ce_checkpoint, frame);
                };

                const result = caller.deleteNamedIndex(T, deleter, js_this, prop, .{}) catch |err| {
                    _ = Caller.handleError(T, @TypeOf(deleter), &caller.local, err, .{});
                    return -1;
                };
                return @intFromBool(result.handled);
            }
        }.wrap;

        return .{
            .get_own = getter_fn,
            .set_property = setter_fn,
            .delete_property = deleter_fn,
        };
    }
};

fn fillDescriptor(qctx: *q.JSContext, desc: [*c]q.JSPropertyDescriptor, result: Caller.IndexedResult) c_int {
    if (!result.handled) {
        return 0;
    }
    if (desc == null) {
        // existence check only
        return 1;
    }
    // The descriptor's value is owned by quickjs once we return 1.
    desc.*.value = q.JS_DupValue(qctx, result.value);
    desc.*.flags = q.JS_PROP_ENUMERABLE;
    desc.*.getter = js.UNDEFINED;
    desc.*.setter = js.UNDEFINED;
    return 1;
}

pub const Iterator = struct {
    func: q.JSCFunction,
    async: bool,

    const Opts = struct {
        async: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime struct_or_func: anytype, comptime opts: Opts) Iterator {
        if (@typeInfo(@TypeOf(struct_or_func)) == .type) {
            // the type itself is the iterator: [Symbol.iterator] returns this
            return .{
                .async = opts.async,
                .func = struct {
                    fn wrap(qctx: ?*q.JSContext, js_this: q.JSValueConst, _: c_int, _: [*c]q.JSValueConst) callconv(.c) q.JSValue {
                        return q.JS_DupValue(qctx, js_this);
                    }
                }.wrap,
            };
        }

        return .{
            .async = opts.async,
            .func = struct {
                fn wrap(qctx: ?*q.JSContext, js_this: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst) callconv(.c) q.JSValue {
                    return Caller.Function.call(T, qctx.?, js_this, argc, argv, struct_or_func, .{
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap,
        };
    }
};

pub const Callable = struct {
    func: ClassCallFn,

    pub const ClassCallFn = @FieldType(q.JSClassDef, "call");

    const Opts = struct {
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Callable {
        return .{
            .func = struct {
                fn wrap(qctx: ?*q.JSContext, func_obj: q.JSValueConst, js_this: q.JSValueConst, argc: c_int, argv: [*c]q.JSValueConst, flags: c_int) callconv(.c) q.JSValue {
                    _ = js_this;
                    _ = flags;
                    // func_obj is the callable object holding our Zig instance
                    return Caller.Function.call(T, qctx.?, func_obj, argc, argv, func, .{
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap,
        };
    }
};

pub const Property = struct {
    value: Value,
    template: bool,
    readonly: bool,

    const Value = union(enum) {
        null,
        int: i64,
        float: f64,
        bool: bool,
        string: []const u8,
    };

    const Opts = struct {
        template: bool,
        readonly: bool = true,
    };

    fn init(value: Value, opts: Opts) Property {
        return .{
            .value = value,
            .template = opts.template,
            .readonly = opts.readonly,
        };
    }
};

// Builds the exotic-methods table for a class, merging the Indexed (int
// atom) and NamedIndexed (string atom) declarations.
pub fn buildExotic(comptime JsApi: type) q.JSClassExoticMethods {
    comptime var indexed: ?Indexed = null;
    comptime var named: ?NamedIndexed = null;

    comptime {
        for (@typeInfo(JsApi).@"struct".decls) |d| {
            const value = @field(JsApi, d.name);
            if (@TypeOf(value) == Indexed) {
                indexed = value;
            } else if (@TypeOf(value) == NamedIndexed) {
                named = value;
            }
        }
    }

    const i = indexed;
    const n = named;

    return .{
        .get_own_property = struct {
            fn wrap(qctx: ?*q.JSContext, desc: [*c]q.JSPropertyDescriptor, obj: q.JSValueConst, prop: q.JSAtom) callconv(.c) c_int {
                if (comptime i != null) {
                    const ret = i.?.get_own(qctx, desc, obj, prop);
                    if (ret != 0) {
                        return ret;
                    }
                }
                if (comptime n != null) {
                    return n.?.get_own(qctx, desc, obj, prop);
                }
                return 0;
            }
        }.wrap,
        .get_own_property_names = if (i) |iv| iv.get_names else null,
        .delete_property = if (n) |nv| nv.delete_property else null,
        .define_own_property = null,
        .has_property = null,
        .get_property = null,
        .set_property = if (n) |nv| nv.set_property else null,
    };
}

// Attaches a JsApi's members to `target` (its prototype object, or the
// global object when flatten=true; see the v8 Snapshot's attachClass).
// Returns the constructor (an owned reference), if the type has a name.
pub fn attachClass(comptime JsApi: type, comptime realm: Realm, qctx: *q.JSContext, target: q.JSValue, comptime flatten: bool) !?q.JSValue {
    const wpt_extensions_enabled = lp.build_config.wpt_extensions;

    const class_name = comptime if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi);

    var constructor: ?q.JSValue = null;
    if (comptime !flatten) {
        if (@hasDecl(JsApi, "constructor")) {
            const value = JsApi.constructor;
            constructor = q.JS_NewCFunction2(qctx, value.func, class_name, value.arity, q.JS_CFUNC_constructor, 0);
            _ = q.JS_SetConstructor(qctx, constructor.?, target);
        } else if (@hasDecl(JsApi.Meta, "name")) {
            constructor = q.JS_NewCFunction2(qctx, Constructor.illegal, JsApi.Meta.name, 0, q.JS_CFUNC_constructor, 0);
            _ = q.JS_SetConstructor(qctx, constructor.?, target);
        }
    }

    // Namespace objects (e.g. console) should expose their members as own
    // enumerable properties. We can't attach per-instance properties with
    // quickjs, so the members go on the prototype but stay enumerable.
    const own_properties = @hasDecl(JsApi.Meta, "own_properties") and JsApi.Meta.own_properties;

    const declarations = @typeInfo(JsApi).@"struct".decls;
    inline for (declarations) |d| {
        const name: [:0]const u8 = d.name;
        const value = @field(JsApi, name);
        const definition = @TypeOf(value);

        const skip = comptime blk: {
            if (flatten) {
                // [Global] flattening only mirrors non-static accessors/methods
                switch (definition) {
                    Accessor, Function => {},
                    else => break :blk true,
                }
            }
            break :blk false;
        };

        if (comptime !skip) switch (definition) {
            Accessor => attach: {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    break :attach;
                }
                if (comptime value.exposed != .both) {
                    if (comptime value.exposed != realm.asExposed()) {
                        break :attach;
                    }
                }
                if (comptime flatten) {
                    if (value.static) break :attach;
                }

                comptime var prop_flags: u8 = q.JS_PROP_WRITABLE;
                if (comptime value.deletable) {
                    prop_flags |= q.JS_PROP_CONFIGURABLE;
                }
                if (comptime own_properties) {
                    prop_flags |= q.JS_PROP_ENUMERABLE;
                }

                if (comptime flatten) {
                    // The global object already has built-ins (parseInt,
                    // globalThis, ...); JS_SetPropertyFunctionList aborts on
                    // redefinition, so define explicitly instead.
                    const atom = q.JS_NewAtomLen(qctx, name.ptr, name.len);
                    defer q.JS_FreeAtom(qctx, atom);
                    const getter_val = if (value.getter) |g|
                        q.JS_NewCFunction2(qctx, @ptrCast(g), "get " ++ name, 0, q.JS_CFUNC_getter, 0)
                    else
                        js.UNDEFINED;
                    const setter_val = if (value.setter) |s|
                        q.JS_NewCFunction2(qctx, @ptrCast(s), "set " ++ name, 1, q.JS_CFUNC_setter, 0)
                    else
                        js.UNDEFINED;
                    _ = q.JS_DefinePropertyGetSet(qctx, target, atom, getter_val, setter_val, prop_flags);
                } else {
                    const entries = [_]q.JSCFunctionListEntry{.{
                        .name = name,
                        .prop_flags = prop_flags,
                        .def_type = q.JS_DEF_CGETSET,
                        .magic = 0,
                        .u = .{ .getset = .{
                            .get = if (value.getter) |g| .{ .getter = g } else std.mem.zeroes(q.JSCFunctionType),
                            .set = if (value.setter) |s| .{ .setter = s } else std.mem.zeroes(q.JSCFunctionType),
                        } },
                    }};
                    const attach_target = if (value.static) constructor.? else target;
                    _ = q.JS_SetPropertyFunctionList(qctx, attach_target, &entries, entries.len);
                }
            },
            Function => attach: {
                if (value.wpt_only and wpt_extensions_enabled == false) {
                    break :attach;
                }
                if (comptime value.exposed != .both) {
                    if (comptime value.exposed != realm.asExposed()) {
                        break :attach;
                    }
                }
                if (comptime flatten) {
                    if (value.static) break :attach;
                }

                if (comptime flatten) {
                    const func = q.JS_NewCFunction(qctx, value.func, name, @intCast(value.arity));
                    _ = q.JS_DefinePropertyValueStr(qctx, target, name, func, q.JS_PROP_WRITABLE | q.JS_PROP_CONFIGURABLE);
                } else if (value.static and !own_properties) {
                    const func = q.JS_NewCFunction(qctx, value.func, name, @intCast(value.arity));
                    _ = q.JS_DefinePropertyValueStr(qctx, constructor.?, name, func, q.JS_PROP_WRITABLE | q.JS_PROP_CONFIGURABLE);
                } else {
                    comptime var prop_flags: u8 = q.JS_PROP_WRITABLE | q.JS_PROP_CONFIGURABLE;
                    if (comptime own_properties) {
                        prop_flags |= q.JS_PROP_ENUMERABLE;
                    }
                    const entries = [_]q.JSCFunctionListEntry{.{
                        .name = name,
                        .prop_flags = prop_flags,
                        .def_type = q.JS_DEF_CFUNC,
                        .magic = 0,
                        .u = .{ .func = .{
                            .length = @intCast(value.arity),
                            .cproto = q.JS_CFUNC_generic,
                            .cfunc = .{ .generic = value.func },
                        } },
                    }};
                    _ = q.JS_SetPropertyFunctionList(qctx, target, &entries, entries.len);
                }
            },
            Iterator => {
                const symbol_name = if (value.async) "[Symbol.asyncIterator]" else "[Symbol.iterator]";
                const entries = [_]q.JSCFunctionListEntry{.{
                    .name = symbol_name,
                    .prop_flags = q.JS_PROP_WRITABLE | q.JS_PROP_CONFIGURABLE,
                    .def_type = q.JS_DEF_CFUNC,
                    .magic = 0,
                    .u = .{ .func = .{
                        .length = 0,
                        .cproto = q.JS_CFUNC_generic,
                        .cfunc = .{ .generic = value.func },
                    } },
                }};
                _ = q.JS_SetPropertyFunctionList(qctx, target, &entries, entries.len);
            },
            Property => {
                const js_value: q.JSValue = switch (value.value) {
                    .null => js.NULL,
                    .bool => |v| if (v) js.TRUE else js.FALSE,
                    .int => |v| q.JS_NewInt64(qctx, v),
                    .float => |v| q.JS_NewFloat64(qctx, v),
                    .string => |v| q.JS_NewStringLen(qctx, v.ptr, v.len),
                };
                const flags: c_int = if (value.readonly) q.JS_PROP_ENUMERABLE else q.JS_PROP_C_W_E;
                _ = q.JS_DefinePropertyValueStr(qctx, target, name, js_value, flags);
                if (value.template) {
                    const dup: q.JSValue = switch (value.value) {
                        .null => js.NULL,
                        .bool => |v| if (v) js.TRUE else js.FALSE,
                        .int => |v| q.JS_NewInt64(qctx, v),
                        .float => |v| q.JS_NewFloat64(qctx, v),
                        .string => |v| q.JS_NewStringLen(qctx, v.ptr, v.len),
                    };
                    _ = q.JS_DefinePropertyValueStr(qctx, constructor.?, name, dup, q.JS_PROP_ENUMERABLE);
                }
            },
            // handled at class-definition time (Env.init)
            Constructor, Indexed, NamedIndexed, Callable => {},
            else => {},
        };
    }

    if (comptime !flatten) {
        if (@hasDecl(JsApi.Meta, "name")) {
            const entries = [_]q.JSCFunctionListEntry{.{
                .name = "[Symbol.toStringTag]",
                .prop_flags = 0,
                .def_type = q.JS_DEF_PROP_STRING,
                .magic = 0,
                .u = .{ .str = JsApi.Meta.name },
            }};
            _ = q.JS_SetPropertyFunctionList(qctx, target, &entries, entries.len);
        }
    }

    return constructor;
}
