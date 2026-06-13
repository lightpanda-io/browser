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

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../../Frame.zig");

const js = @import("js.zig");
const Caller = @import("Caller.zig");
const Context = @import("Context.zig");
const registry = @import("../registry.zig");

const v8 = js.v8;
const IS_DEBUG = @import("builtin").mode == .Debug;

pub fn Builder(comptime T: type) type {
    return struct {
        pub const @"type" = T;
        pub const ClassId = u16;

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
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        dom_exception: bool = false,
        // When true, the constructor function receives `new.target` (as a
        // js.Function) as its first parameter. Used by HTMLElement to support
        // direct instantiation of custom elements via `new MyElement()`.
        new_target: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Constructor {
        return .{
            .arity = comptime Function.getArity(@TypeOf(func), if (opts.new_target) 1 else 0),
            .func = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return;
                    }
                    defer caller.deinit();

                    // Constructors are a JS-execution boundary, just like
                    // [CEReactions] methods. Open a reactions scope so any
                    // callbacks queued by the user's constructor body (or
                    // by attribute_changed reactions queued before invocation)
                    // drain at the constructor's exit, not later.
                    const ce_frame: ?*Frame = switch (caller.local.ctx.global) {
                        .frame => |frame| frame,
                        .worker => null,
                    };
                    const ce_checkpoint: usize = if (ce_frame) |frame| frame._ce_reactions.push() else 0;
                    defer if (ce_frame) |frame| frame._ce_reactions.popAndInvoke(ce_checkpoint, frame);

                    caller.constructor(T, func, handle.?, .{
                        .dom_exception = opts.dom_exception,
                        .new_target = opts.new_target,
                    });
                }
            }.wrap,
        };
    }
};

pub const Function = struct {
    static: bool,
    arity: usize,
    noop: bool = false,
    wpt_only: bool = false,
    exposed: Caller.Function.Opts.Exposed = .both,
    cache: ?Caller.Function.Opts.Caching = null,
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    fn init(comptime T: type, comptime func: anytype, comptime opts: Caller.Function.Opts) Function {
        return .{
            .cache = opts.cache,
            .static = opts.static,
            .wpt_only = opts.wpt_only,
            .exposed = opts.exposed,
            // Non-static methods receive `self` as their first param; static
            // methods don't, so don't skip the first param for them.
            .arity = getArity(@TypeOf(func), if (opts.static) 0 else 1),
            .func = if (opts.noop) noopFunction else struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    Caller.Function.call(T, handle.?, func, opts);
                }
            }.wrap,
        };
    }

    pub fn noopFunction(_: ?*const v8.FunctionCallbackInfo) callconv(.c) void {}

    fn getArity(comptime T: type, comptime start: usize) usize {
        const Execution = js.Execution;

        const Page = @import("../../Page.zig");
        const Session = @import("../../Session.zig");

        var count: usize = 0;
        var params = @typeInfo(T).@"fn".params;
        for (params[start..]) |p| { // start at 1, skip self
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

pub const Accessor = struct {
    static: bool = false,
    deletable: bool = true,
    wpt_only: bool = false,
    exposed: Caller.Function.Opts.Exposed = .both,
    cache: ?Caller.Function.Opts.Caching = null,
    getter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,
    setter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,

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
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    Caller.Function.call(T, handle.?, getter, getter_opts);
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(setter)) != .null) {
            accessor.setter = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    Caller.Function.call(T, handle.?, setter, opts);
                }
            }.wrap;
        }

        return accessor;
    }
};

pub const Indexed = struct {
    getter: *const fn (idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,
    enumerator: ?*const fn (handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, comptime enumerator: anytype, comptime opts: Opts) Indexed {
        var indexed = Indexed{
            .enumerator = null,
            .getter = struct {
                fn wrap(idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return 0;
                    }
                    defer caller.deinit();

                    return caller.getIndex(T, getter, idx, handle.?, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap,
        };

        if (@typeInfo(@TypeOf(enumerator)) != .null) {
            indexed.enumerator = struct {
                fn wrap(handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return 0;
                    }
                    defer caller.deinit();
                    return caller.getEnumerator(T, enumerator, handle.?, .{});
                }
            }.wrap;
        }

        return indexed;
    }
};

pub const NamedIndexed = struct {
    getter: *const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8,
    setter: ?*const fn (c_name: ?*const v8.Name, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,
    deleter: ?*const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 = null,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
        // Mirrors [CEReactions] on a named-property setter/deleter (e.g.,
        // HTMLElement.dataset, which proxies setAttribute/removeAttribute).
        // Only applies to setter and deleter; getters don't mutate.
        ce_reactions: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, setter: anytype, deleter: anytype, comptime opts: Opts) NamedIndexed {
        const getter_fn = struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return 0;
                }
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
                if (!caller.init(v8_isolate)) {
                    return 0;
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
                if (!caller.init(v8_isolate)) {
                    return 0;
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
                    return Caller.Function.call(T, handle.?, struct_or_func, .{
                        .null_as_undefined = opts.null_as_undefined,
                    });
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
                Caller.Function.call(T, handle.?, func, .{
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap };
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

pub fn unknownWindowPropertyCallback(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;

    // During snapshot creation, there's no Context in embedder data yet.
    // I hate this check, but there doesn't seem to be a way to add this method
    // to the global, without triggering it during snapshot creation.
    const v8_context = v8.v8__Isolate__GetCurrentContext(v8_isolate) orelse return 0;
    const ctx: *Context = @ptrCast(@alignCast(v8.v8__Context__GetAlignedPointerFromEmbedderData(v8_context, 1) orelse return 0));

    var caller: Caller = undefined;
    caller.initWithContext(ctx, v8_context);
    defer caller.deinit();

    const local = &caller.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const property: []const u8 = js.String.toSlice(.{ .local = local, .handle = @ptrCast(c_name.?) }) catch {
        return 0;
    };

    // Only Page contexts have document.getElementById lookup
    switch (local.ctx.global) {
        .frame => |frame| {
            const document = frame.document;
            if (document.getElementById(property, frame)) |el| {
                const js_val = local.zigValueToJs(el, .{}) catch return 0;
                var pc = Caller.PropertyCallbackInfo{ .handle = handle.? };
                pc.getReturnValue().set(js_val);
                return 1;
            }
        },
        .worker => {}, // no global lookup in a worker
    }

    if (comptime IS_DEBUG) {
        if (std.mem.startsWith(u8, property, "__")) {
            // some frameworks will extend built-in types using a __ prefix
            // these should always be safe to ignore.
            return 0;
        }

        const ignored = std.StaticStringMap(void).initComptime(.{
            .{ "Deno", {} },
            .{ "process", {} },
            .{ "ShadyDOM", {} },
            .{ "ShadyCSS", {} },

            // a lot of sites seem to like having their own window.config.
            .{ "config", {} },

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
            .{ "__REACT_DEVTOOLS_GLOBAL_HOOK__", {} },
            .{ "ApplePaySession", {} },
        });
        if (!ignored.has(property)) {
            var buf: [2048]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "Window:{s}", .{property}) catch return 0;
            logUnknownProperty(local, key) catch return 0;
        }
    }

    // not intercepted
    return 0;
}

// Only used for debugging
pub fn unknownObjectPropertyCallback(comptime JsApi: type) *const fn (?*const v8.Name, ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
    if (comptime !IS_DEBUG) {
        @compileError("unknownObjectPropertyCallback should only be used in debug builds");
    }

    return struct {
        fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u8 {
            const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;

            var caller: Caller = undefined;
            if (!caller.init(v8_isolate)) {
                return 0;
            }
            defer caller.deinit();

            const local = &caller.local;

            var hs: js.HandleScope = undefined;
            hs.init(local.isolate);
            defer hs.deinit();

            const property: []const u8 = js.String.toSlice(.{ .local = local, .handle = @ptrCast(c_name.?) }) catch {
                return 0;
            };

            if (std.mem.startsWith(u8, property, "__")) {
                // some frameworks will extend built-in types using a __ prefix
                // these should always be safe to ignore.
                return 0;
            }

            if (std.mem.startsWith(u8, property, "jQuery")) {
                return 0;
            }

            if (JsApi == @import("../../webapi/cdata/Text.zig").JsApi or JsApi == @import("../../webapi/cdata/Comment.zig").JsApi) {
                if (std.mem.eql(u8, property, "tagName")) {
                    // knockout does this, a lot.
                    return 0;
                }
            }

            if (JsApi == @import("../../webapi/element/Html.zig").JsApi or JsApi == @import("../../webapi/Element.zig").JsApi or JsApi == @import("../../webapi/element/html/Custom.zig").JsApi) {
                // react ?
                if (std.mem.eql(u8, property, "props")) return 0;
                if (std.mem.eql(u8, property, "hydrated")) return 0;
                if (std.mem.eql(u8, property, "isHydrated")) return 0;
            }

            if (JsApi == @import("../../webapi/Console.zig").JsApi) {
                if (std.mem.eql(u8, property, "firebug")) return 0;
            }

            const ignored = std.StaticStringMap(void).initComptime(.{});
            if (!ignored.has(property)) {
                var buf: [2048]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi), property }) catch return 0;
                logUnknownProperty(local, key) catch return 0;
            }
            // not intercepted
            return 0;
        }
    }.wrap;
}

fn logUnknownProperty(local: *const js.Local, key: []const u8) !void {
    const ctx = local.ctx;
    const gop = try ctx.unknown_properties.getOrPut(ctx.arena, key);
    if (gop.found_existing) {
        gop.value_ptr.count += 1;
    } else {
        gop.key_ptr.* = try ctx.arena.dupe(u8, key);
        gop.value_ptr.* = .{
            .count = 1,
            .first_stack = try ctx.arena.dupe(u8, (try local.stackTrace()) orelse "???"),
        };
    }
}

// The engine-agnostic registry: type lists, lookup, prototype-chain
// machinery. Re-exported so existing `bridge.X` references keep working.
pub const Struct = registry.Struct;
pub const JsApiLookup = registry.JsApiLookup;
pub const SubType = registry.SubType;
pub const PageJsApis = registry.PageJsApis;
pub const WorkerJsApis = registry.WorkerJsApis;
pub const JsApis = registry.JsApis;
