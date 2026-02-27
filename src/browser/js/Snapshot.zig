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
const bridge = @import("bridge.zig");
const log = @import("../../log.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

const v8 = js.v8;
const JsApis = bridge.JsApis;
const Allocator = std.mem.Allocator;

const Snapshot = @This();

const embedded_snapshot_blob = if (@import("build_config").snapshot_path) |path| @embedFile(path) else "";

// When creating our Snapshot, we use local function templates for every Zig type.
// You cannot, from what I can tell, create persisted FunctionTemplates at
// snapshot creation time. But you can embedd those templates (or any other v8
// Data) so that it's available to contexts created from the snapshot. This is
// the starting index of those function templates, which we can extract. At
// creation time, in debug, we assert that this is actually a consecutive integer
// sequence
data_start: usize,

// The snapshot data (v8.StartupData is a ptr to the data and len).
startup_data: v8.StartupData,

// V8 doesn't know how to serialize external references, and pretty much any hook
// into Zig is an external reference (e.g. every accessor and function callback).
// When we create the snapshot, we give it an array with the address of every
// external reference. When we load the snapshot, we need to give it the same
// array with the exact same number of entries in the same order (but, of course
// cross-process, the value (address) might be different).
external_references: [countExternalReferences()]isize,

// Track whether this snapshot owns its data (was created in-process)
// If false, the data points into embedded_snapshot_blob and will not be freed
owns_data: bool = false,

pub fn load() !Snapshot {
    if (loadEmbedded()) |snapshot| {
        return snapshot;
    }
    return create();
}

fn loadEmbedded() ?Snapshot {
    // Binary format: [data_start: usize][blob data]
    const min_size = @sizeOf(usize) + 1000;
    if (embedded_snapshot_blob.len < min_size) {
        // our blob should be in the MB, this is just a quick sanity check
        return null;
    }

    const data_start = std.mem.readInt(usize, embedded_snapshot_blob[0..@sizeOf(usize)], .little);
    const blob = embedded_snapshot_blob[@sizeOf(usize)..];

    const startup_data = v8.StartupData{ .data = blob.ptr, .raw_size = @intCast(blob.len) };
    if (!v8.v8__StartupData__IsValid(startup_data)) {
        return null;
    }

    return .{
        .owns_data = false,
        .data_start = data_start,
        .startup_data = startup_data,
        .external_references = collectExternalReferences(),
    };
}

pub fn deinit(self: Snapshot) void {
    // Only free if we own the data (was created in-process)
    if (self.owns_data) {
        // V8 allocated this with `new char[]`, so we need to use the C++ delete[] operator
        v8.v8__StartupData__DELETE(self.startup_data.data);
    }
}

pub fn write(self: Snapshot, writer: *std.Io.Writer) !void {
    if (!self.isValid()) {
        return error.InvalidSnapshot;
    }

    try writer.writeInt(usize, self.data_start, .little);
    try writer.writeAll(self.startup_data.data[0..@intCast(self.startup_data.raw_size)]);
}

pub fn fromEmbedded(self: Snapshot) bool {
    // if the snapshot comes from the embedFile, then it'll be flagged as not
    // owning (aka, not needing to free) the data.
    return self.owns_data == false;
}

fn isValid(self: Snapshot) bool {
    return v8.v8__StartupData__IsValid(self.startup_data);
}

pub fn create() !Snapshot {
    var external_references = collectExternalReferences();

    var params: v8.CreateParams = undefined;
    v8.v8__Isolate__CreateParams__CONSTRUCT(&params);
    params.array_buffer_allocator = v8.v8__ArrayBuffer__Allocator__NewDefaultAllocator();
    defer v8.v8__ArrayBuffer__Allocator__DELETE(params.array_buffer_allocator.?);
    params.external_references = @ptrCast(&external_references);

    const snapshot_creator = v8.v8__SnapshotCreator__CREATE(&params);
    defer v8.v8__SnapshotCreator__DESTRUCT(snapshot_creator);

    var data_start: usize = 0;
    const isolate = v8.v8__SnapshotCreator__getIsolate(snapshot_creator).?;

    {
        // CreateBlob, which we'll call once everything is setup, MUST NOT
        // be called from an active HandleScope. Hence we have this scope to
        // clean it up before we call CreateBlob
        var handle_scope: v8.HandleScope = undefined;
        v8.v8__HandleScope__CONSTRUCT(&handle_scope, isolate);
        defer v8.v8__HandleScope__DESTRUCT(&handle_scope);

        // Create templates (constructors only) FIRST
        var templates: [JsApis.len]*v8.FunctionTemplate = undefined;
        inline for (JsApis, 0..) |JsApi, i| {
            @setEvalBranchQuota(10_000);
            templates[i] = generateConstructor(JsApi, isolate);
            attachClass(JsApi, isolate, templates[i]);
        }

        // Set up prototype chains BEFORE attaching properties
        // This must come before attachClass so inheritance is set up first
        inline for (JsApis, 0..) |JsApi, i| {
            if (comptime protoIndexLookup(JsApi)) |proto_index| {
                v8.v8__FunctionTemplate__Inherit(templates[i], templates[proto_index]);
            }
        }

        // Set up the global template to inherit from Window's template
        // This way the global object gets all Window properties through inheritance
        const context = v8.v8__Context__New(isolate, null, null);
        v8.v8__Context__Enter(context);
        defer v8.v8__Context__Exit(context);

        // Add templates to context snapshot
        var last_data_index: usize = 0;
        inline for (JsApis, 0..) |_, i| {
            @setEvalBranchQuota(10_000);
            const data_index = v8.v8__SnapshotCreator__AddData(snapshot_creator, @ptrCast(templates[i]));
            if (i == 0) {
                data_start = data_index;
                last_data_index = data_index;
            } else {
                // This isn't strictly required, but it means we only need to keep
                // the first data_index. This is based on the assumption that
                // addDataWithContext always increases by 1. If we ever hit this
                // error, then that assumption is wrong and we should capture
                // all the indexes explicitly in an array.
                if (data_index != last_data_index + 1) {
                    return error.InvalidDataIndex;
                }
                last_data_index = data_index;
            }
        }

        // Realize all templates by getting their functions and attaching to global
        const global_obj = v8.v8__Context__Global(context);

        inline for (JsApis, 0..) |JsApi, i| {
            const func = v8.v8__FunctionTemplate__GetFunction(templates[i], context);

            // Attach to global if it has a name
            if (@hasDecl(JsApi.Meta, "name")) {
                if (@hasDecl(JsApi.Meta, "constructor_alias")) {
                    const alias = JsApi.Meta.constructor_alias;
                    const v8_class_name = v8.v8__String__NewFromUtf8(isolate, alias.ptr, v8.kNormal, @intCast(alias.len));
                    var maybe_result: v8.MaybeBool = undefined;
                    v8.v8__Object__Set(global_obj, context, v8_class_name, func, &maybe_result);

                    // @TODO: This is wrong. This name should be registered with the
                    // illegalConstructorCallback. I.e. new Image() is OK, but
                    // new HTMLImageElement() isn't.
                    // But we _have_ to register the name, i.e. HTMLImageElement
                    // has to be registered so, for now, instead of creating another
                    // template, we just hook it into the constructor.
                    const name = JsApi.Meta.name;
                    const illegal_class_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                    var maybe_result2: v8.MaybeBool = undefined;
                    v8.v8__Object__DefineOwnProperty(global_obj, context, illegal_class_name, func, 0, &maybe_result2);
                } else {
                    const name = JsApi.Meta.name;
                    const v8_class_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                    var maybe_result: v8.MaybeBool = undefined;
                    var properties: v8.PropertyAttribute = v8.None;
                    if (@hasDecl(JsApi.Meta, "enumerable") and JsApi.Meta.enumerable == false) {
                        properties |= v8.DontEnum;
                    }
                    v8.v8__Object__DefineOwnProperty(global_obj, context, v8_class_name, func, properties, &maybe_result);
                }
            }
        }

        {
            // If we want to overwrite the built-in console, we have to
            // delete the built-in one.
            const console_key = v8.v8__String__NewFromUtf8(isolate, "console", v8.kNormal, 7);
            var maybe_deleted: v8.MaybeBool = undefined;
            v8.v8__Object__Delete(global_obj, context, console_key, &maybe_deleted);
            if (maybe_deleted.value == false) {
                return error.ConsoleDeleteError;
            }
        }

        // This shouldn't be necessary, but it is:
        // https://groups.google.com/g/v8-users/c/qAQQBmbi--8
        // TODO: see if newer V8 engines have a way around this.
        inline for (JsApis, 0..) |JsApi, i| {
            if (comptime protoIndexLookup(JsApi)) |proto_index| {
                const proto_func = v8.v8__FunctionTemplate__GetFunction(templates[proto_index], context);
                const proto_obj: *const v8.Object = @ptrCast(proto_func);

                const self_func = v8.v8__FunctionTemplate__GetFunction(templates[i], context);
                const self_obj: *const v8.Object = @ptrCast(self_func);

                var maybe_result: v8.MaybeBool = undefined;
                v8.v8__Object__SetPrototype(self_obj, context, proto_obj, &maybe_result);
            }
        }

        {
            // Custom exception
            // TODO: this is an horrible hack, I can't figure out how to do this cleanly.
            const code_str = "DOMException.prototype.__proto__ = Error.prototype";
            const code = v8.v8__String__NewFromUtf8(isolate, code_str.ptr, v8.kNormal, @intCast(code_str.len));
            const script = v8.v8__Script__Compile(context, code, null) orelse return error.ScriptCompileFailed;
            _ = v8.v8__Script__Run(script, context) orelse return error.ScriptRunFailed;
        }

        v8.v8__SnapshotCreator__setDefaultContext(snapshot_creator, context);
    }

    const blob = v8.v8__SnapshotCreator__createBlob(snapshot_creator, v8.kKeep);

    return .{
        .owns_data = true,
        .data_start = data_start,
        .external_references = external_references,
        .startup_data = blob,
    };
}

// Helper to check if a JsApi has a NamedIndexed handler
fn hasNamedIndexedGetter(comptime JsApi: type) bool {
    const declarations = @typeInfo(JsApi).@"struct".decls;
    inline for (declarations) |d| {
        const value = @field(JsApi, d.name);
        const T = @TypeOf(value);
        if (T == bridge.NamedIndexed) {
            return true;
        }
    }
    return false;
}

// Count total callbacks needed for external_references array
fn countExternalReferences() comptime_int {
    @setEvalBranchQuota(100_000);

    var count: comptime_int = 0;

    // +1 for the illegal constructor callback shared by various types
    count += 1;

    // +1 for the noop function shared by various types
    count += 1;

    inline for (JsApis) |JsApi| {
        // Constructor (only if explicit)
        if (@hasDecl(JsApi, "constructor")) {
            count += 1;
        }

        // Callable (htmldda)
        if (@hasDecl(JsApi, "callable")) {
            count += 1;
        }

        // All other callbacks
        const declarations = @typeInfo(JsApi).@"struct".decls;
        inline for (declarations) |d| {
            const value = @field(JsApi, d.name);
            const T = @TypeOf(value);
            if (T == bridge.Accessor) {
                count += 1; // getter
                if (value.setter != null) {
                    count += 1;
                }
            } else if (T == bridge.Function) {
                count += 1;
            } else if (T == bridge.Iterator) {
                count += 1;
            } else if (T == bridge.Indexed) {
                count += 1;
                if (value.enumerator != null) {
                    count += 1;
                }
            } else if (T == bridge.NamedIndexed) {
                count += 1; // getter
                if (value.setter != null) count += 1;
                if (value.deleter != null) count += 1;
            }
        }
    }

    // In debug mode, add unknown property callbacks for types without NamedIndexed
    if (comptime IS_DEBUG) {
        inline for (JsApis) |JsApi| {
            if (!hasNamedIndexedGetter(JsApi)) {
                count += 1;
            }
        }
    }

    return count + 1; // +1 for null terminator
}

fn collectExternalReferences() [countExternalReferences()]isize {
    var idx: usize = 0;
    var references = std.mem.zeroes([countExternalReferences()]isize);

    references[idx] = @bitCast(@intFromPtr(&illegalConstructorCallback));
    idx += 1;

    references[idx] = @bitCast(@intFromPtr(&bridge.Function.noopFunction));
    idx += 1;

    inline for (JsApis) |JsApi| {
        if (@hasDecl(JsApi, "constructor")) {
            references[idx] = @bitCast(@intFromPtr(JsApi.constructor.func));
            idx += 1;
        }

        if (@hasDecl(JsApi, "callable")) {
            references[idx] = @bitCast(@intFromPtr(JsApi.callable.func));
            idx += 1;
        }

        const declarations = @typeInfo(JsApi).@"struct".decls;
        inline for (declarations) |d| {
            const value = @field(JsApi, d.name);
            const T = @TypeOf(value);
            if (T == bridge.Accessor) {
                references[idx] = @bitCast(@intFromPtr(value.getter));
                idx += 1;
                if (value.setter) |setter| {
                    references[idx] = @bitCast(@intFromPtr(setter));
                    idx += 1;
                }
            } else if (T == bridge.Function) {
                references[idx] = @bitCast(@intFromPtr(value.func));
                idx += 1;
            } else if (T == bridge.Iterator) {
                references[idx] = @bitCast(@intFromPtr(value.func));
                idx += 1;
            } else if (T == bridge.Indexed) {
                references[idx] = @bitCast(@intFromPtr(value.getter));
                idx += 1;
                if (value.enumerator) |enumerator| {
                    references[idx] = @bitCast(@intFromPtr(enumerator));
                    idx += 1;
                }
            } else if (T == bridge.NamedIndexed) {
                references[idx] = @bitCast(@intFromPtr(value.getter));
                idx += 1;
                if (value.setter) |setter| {
                    references[idx] = @bitCast(@intFromPtr(setter));
                    idx += 1;
                }
                if (value.deleter) |deleter| {
                    references[idx] = @bitCast(@intFromPtr(deleter));
                    idx += 1;
                }
            }
        }
    }

    // In debug mode, collect unknown property callbacks for types without NamedIndexed
    if (comptime IS_DEBUG) {
        inline for (JsApis) |JsApi| {
            if (!hasNamedIndexedGetter(JsApi)) {
                references[idx] = @bitCast(@intFromPtr(bridge.unknownObjectPropertyCallback(JsApi)));
                idx += 1;
            }
        }
    }

    return references;
}

// Even if a struct doesn't have a `constructor` function, we still
// `generateConstructor`, because this is how we create our
// FunctionTemplate. Such classes exist, but they can't be instantiated
// via `new ClassName()` - but they could, for example, be created in
// Zig and returned from a function call, which is why we need the
// FunctionTemplate.
fn generateConstructor(comptime JsApi: type, isolate: *v8.Isolate) *v8.FunctionTemplate {
    const callback = blk: {
        if (@hasDecl(JsApi, "constructor")) {
            break :blk JsApi.constructor.func;
        }

        // Use shared illegal constructor callback
        break :blk illegalConstructorCallback;
    };

    const template = @constCast(v8.v8__FunctionTemplate__New__DEFAULT2(isolate, callback).?);
    {
        const internal_field_count = comptime countInternalFields(JsApi);
        if (internal_field_count > 0) {
            const instance_template = v8.v8__FunctionTemplate__InstanceTemplate(template);
            v8.v8__ObjectTemplate__SetInternalFieldCount(instance_template, internal_field_count);
        }
    }
    const name_str = if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi);
    const class_name = v8.v8__String__NewFromUtf8(isolate, name_str.ptr, v8.kNormal, @intCast(name_str.len));
    v8.v8__FunctionTemplate__SetClassName(template, class_name);
    return template;
}

pub fn countInternalFields(comptime JsApi: type) u8 {
    var last_used_id = 0;
    var cache_count: u8 = 0;

    inline for (@typeInfo(JsApi).@"struct".decls) |d| {
        const name: [:0]const u8 = d.name;
        const value = @field(JsApi, name);
        const definition = @TypeOf(value);

        switch (definition) {
            inline bridge.Accessor, bridge.Function => {
                const cache = value.cache orelse continue;
                if (cache != .internal) {
                    continue;
                }
                // We assert that they are declared in-order. This isn't necessary
                // but I don't want to do anything fancy to look for gaps or
                // duplicates.
                const internal_id = cache.internal;
                if (internal_id != last_used_id + 1) {
                    @compileError(@typeName(JsApi) ++ "." ++ name ++ " has a non-monotonic cache index");
                }
                last_used_id = internal_id;
                cache_count += 1; // this is just last_used, but it's more explicit this way
            },
            else => {},
        }
    }

    if (@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
        return cache_count;
    }

    // we need cache_count internal fields, + 1 for the TAO pointer (the v8 -> Zig)
    // mapping) itself.
    return cache_count + 1;
}

// Attaches JsApi members to the prototype template (normal case)
fn attachClass(comptime JsApi: type, isolate: *v8.Isolate, template: *v8.FunctionTemplate) void {
    const instance = v8.v8__FunctionTemplate__InstanceTemplate(template);
    const prototype = v8.v8__FunctionTemplate__PrototypeTemplate(template);

    const declarations = @typeInfo(JsApi).@"struct".decls;
    var has_named_index_getter = false;

    inline for (declarations) |d| {
        const name: [:0]const u8 = d.name;
        const value = @field(JsApi, name);
        const definition = @TypeOf(value);

        switch (definition) {
            bridge.Accessor => {
                const js_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                const getter_callback = @constCast(v8.v8__FunctionTemplate__New__Config(isolate, &.{ .callback = value.getter }).?);
                if (value.setter == null) {
                    if (value.static) {
                        v8.v8__Template__SetAccessorProperty__DEFAULT(@ptrCast(template), js_name, getter_callback);
                    } else {
                        v8.v8__ObjectTemplate__SetAccessorProperty__DEFAULT(prototype, js_name, getter_callback);
                    }
                } else {
                    if (comptime IS_DEBUG) {
                        std.debug.assert(value.static == false);
                    }
                    const setter_callback = @constCast(v8.v8__FunctionTemplate__New__Config(isolate, &.{ .callback = value.setter.? }).?);
                    v8.v8__ObjectTemplate__SetAccessorProperty__DEFAULT2(prototype, js_name, getter_callback, setter_callback);
                }
            },
            bridge.Function => {
                const function_template = @constCast(v8.v8__FunctionTemplate__New__Config(isolate, &.{ .callback = value.func, .length = value.arity }).?);
                const js_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));
                if (value.static) {
                    v8.v8__Template__Set(@ptrCast(template), js_name, @ptrCast(function_template), v8.None);
                } else {
                    v8.v8__Template__Set(@ptrCast(prototype), js_name, @ptrCast(function_template), v8.None);
                }
            },
            bridge.Indexed => {
                var configuration: v8.IndexedPropertyHandlerConfiguration = .{
                    .getter = value.getter,
                    .enumerator = value.enumerator,
                    .setter = null,
                    .query = null,
                    .deleter = null,
                    .definer = null,
                    .descriptor = null,
                    .data = null,
                    .flags = 0,
                };
                v8.v8__ObjectTemplate__SetIndexedHandler(instance, &configuration);
            },
            bridge.NamedIndexed => {
                var configuration: v8.NamedPropertyHandlerConfiguration = .{
                    .getter = value.getter,
                    .setter = value.setter,
                    .query = null,
                    .deleter = value.deleter,
                    .enumerator = null,
                    .definer = null,
                    .descriptor = null,
                    .data = null,
                    .flags = v8.kOnlyInterceptStrings | v8.kNonMasking,
                };
                v8.v8__ObjectTemplate__SetNamedHandler(instance, &configuration);
                has_named_index_getter = true;
            },
            bridge.Iterator => {
                const function_template = @constCast(v8.v8__FunctionTemplate__New__Config(isolate, &.{ .callback = value.func }).?);
                const js_name = if (value.async)
                    v8.v8__Symbol__GetAsyncIterator(isolate)
                else
                    v8.v8__Symbol__GetIterator(isolate);
                v8.v8__Template__Set(@ptrCast(prototype), js_name, @ptrCast(function_template), v8.None);
            },
            bridge.Property => {
                const js_value = switch (value.value) {
                    .null => js.simpleZigValueToJs(.{ .handle = isolate }, null, true, false),
                    inline .bool, .int, .float, .string => |v| js.simpleZigValueToJs(.{ .handle = isolate }, v, true, false),
                };
                const js_name = v8.v8__String__NewFromUtf8(isolate, name.ptr, v8.kNormal, @intCast(name.len));

                {
                    const flags = if (value.readonly) v8.ReadOnly + v8.DontDelete else 0;
                    v8.v8__Template__Set(@ptrCast(prototype), js_name, js_value, flags);
                }

                if (value.template) {
                    // apply it both to the type itself (e.g. Node.Elem)
                    v8.v8__Template__Set(@ptrCast(template), js_name, js_value, v8.ReadOnly + v8.DontDelete);
                }
            },
            bridge.Constructor => {}, // already handled in generateConstructor
            else => {},
        }
    }

    if (@hasDecl(JsApi.Meta, "htmldda")) {
        v8.v8__ObjectTemplate__MarkAsUndetectable(instance);
        v8.v8__ObjectTemplate__SetCallAsFunctionHandler(instance, JsApi.Meta.callable.func);
    }

    if (@hasDecl(JsApi.Meta, "name")) {
        const js_name = v8.v8__Symbol__GetToStringTag(isolate);
        const js_value = v8.v8__String__NewFromUtf8(isolate, JsApi.Meta.name.ptr, v8.kNormal, @intCast(JsApi.Meta.name.len));
        v8.v8__Template__Set(@ptrCast(instance), js_name, js_value, v8.ReadOnly + v8.DontDelete);
    }

    if (comptime IS_DEBUG) {
        if (!has_named_index_getter) {
            var configuration: v8.NamedPropertyHandlerConfiguration = .{
                .getter = bridge.unknownObjectPropertyCallback(JsApi),
                .setter = null,
                .query = null,
                .deleter = null,
                .enumerator = null,
                .definer = null,
                .descriptor = null,
                .data = null,
                .flags = v8.kOnlyInterceptStrings | v8.kNonMasking,
            };
            v8.v8__ObjectTemplate__SetNamedHandler(instance, &configuration);
        }
    }
}

fn protoIndexLookup(comptime JsApi: type) ?bridge.JsApiLookup.BackingInt {
    @setEvalBranchQuota(2000);
    comptime {
        const T = JsApi.bridge.type;
        if (!@hasField(T, "_proto")) {
            return null;
        }
        const Ptr = std.meta.fieldInfo(T, ._proto).type;
        const F = @typeInfo(Ptr).pointer.child;
        return bridge.JsApiLookup.getId(F.JsApi);
    }
}

// Shared illegal constructor callback for types without explicit constructors
fn illegalConstructorCallback(raw_info: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
    const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(raw_info);
    log.warn(.js, "Illegal constructor call", .{});

    const message = v8.v8__String__NewFromUtf8(isolate, "Illegal Constructor", v8.kNormal, 19);
    const js_exception = v8.v8__Exception__TypeError(message);

    _ = v8.v8__Isolate__ThrowException(isolate, js_exception);
    var return_value: v8.ReturnValue = undefined;
    v8.v8__FunctionCallbackInfo__GetReturnValue(raw_info, &return_value);
    v8.v8__ReturnValue__Set(return_value, js_exception);
}
