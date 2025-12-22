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
const Window = @import("../webapi/Window.zig");

const v8 = js.v8;
const JsApis = bridge.JsApis;
const Allocator = std.mem.Allocator;

const Snapshot = @This();

const embedded_snapshot_blob = if (@import("build_config").snapshot_path) |path| @embedFile(path) else "";

// When creating our Snapshot, we use local function templates for every Zig type.
// You cannot, from what I can tell, create persisted FunctionTemplates at
// snapshot creation time. But you can embedd those templates (or any other v8
// Data) so that it's available to contexts created from the snapshot. This is
// the starting index of those function templtes, which we can extract. At
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
// If false, the data points into embedded_snapshot_blob and should not be freed
owns_data: bool = false,

pub fn load(allocator: Allocator) !Snapshot {
    if (loadEmbedded()) |snapshot| {
        return snapshot;
    }
    return create(allocator);
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
    if (!v8.SnapshotCreator.startupDataIsValid(startup_data)) {
        return null;
    }

    return .{
        .owns_data = false,
        .data_start = data_start,
        .startup_data = startup_data,
        .external_references = collectExternalReferences(),
    };
}

pub fn deinit(self: Snapshot, allocator: Allocator) void {
    // Only free if we own the data (was created in-process)
    if (self.owns_data) {
        allocator.free(self.startup_data.data[0..@intCast(self.startup_data.raw_size)]);
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
    // owneing (aka, not needing to free) the data.
    return self.owns_data == false;
}

fn isValid(self: Snapshot) bool {
    return v8.SnapshotCreator.startupDataIsValid(self.startup_data);
}

pub fn create(allocator: Allocator) !Snapshot {
    var external_references = collectExternalReferences();

    var params = v8.initCreateParams();
    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    defer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);
    params.external_references = @ptrCast(&external_references);

    var snapshot_creator: v8.SnapshotCreator = undefined;
    v8.SnapshotCreator.init(&snapshot_creator, &params);
    defer snapshot_creator.deinit();

    var data_start: usize = 0;
    const isolate = snapshot_creator.getIsolate();

    {
        // CreateBlob, which we'll call once everything is setup, MUST NOT
        // be called from an active HandleScope. Hence we have this scope to
        // clean it up before we call CreateBlob
        var handle_scope: v8.HandleScope = undefined;
        v8.HandleScope.init(&handle_scope, isolate);
        defer handle_scope.deinit();

        // Create templates (constructors only) FIRST
        var templates: [JsApis.len]v8.FunctionTemplate = undefined;
        inline for (JsApis, 0..) |JsApi, i| {
            @setEvalBranchQuota(10_000);
            templates[i] = generateConstructor(JsApi, isolate);
            attachClass(JsApi, isolate, templates[i]);
        }

        // Set up prototype chains BEFORE attaching properties
        // This must come before attachClass so inheritance is set up first
        inline for (JsApis, 0..) |JsApi, i| {
            if (comptime protoIndexLookup(JsApi)) |proto_index| {
                templates[i].inherit(templates[proto_index]);
            }
        }

        // Set up the global template to inherit from Window's template
        // This way the global object gets all Window properties through inheritance
        const js_global = v8.FunctionTemplate.initDefault(isolate);
        js_global.setClassName(v8.String.initUtf8(isolate, "Window"));

        // Find Window in JsApis by name (avoids circular import)
        const window_index = comptime bridge.JsApiLookup.getId(Window.JsApi);
        js_global.inherit(templates[window_index]);

        const global_template = js_global.getInstanceTemplate();

        const context = v8.Context.init(isolate, global_template, null);
        context.enter();
        defer context.exit();

        // Add templates to context snapshot
        var last_data_index: usize = 0;
        inline for (JsApis, 0..) |_, i| {
            @setEvalBranchQuota(10_000);
            const data_index = snapshot_creator.addDataWithContext(context, @ptrCast(templates[i].handle));
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
        const global_obj = context.getGlobal();

        inline for (JsApis, 0..) |JsApi, i| {
            const func = templates[i].getFunction(context);

            // Attach to global if it has a name
            if (@hasDecl(JsApi.Meta, "name")) {
                const class_name = if (@hasDecl(JsApi.Meta, "constructor_alias"))
                    JsApi.Meta.constructor_alias
                else
                    JsApi.Meta.name;
                const v8_class_name = v8.String.initUtf8(isolate, class_name);
                _ = global_obj.setValue(context, v8_class_name, func);
            }
        }

        {
            // If we want to overwrite the built-in console, we have to
            // delete the built-in one.
            const console_key = v8.String.initUtf8(isolate, "console");
            if (global_obj.deleteValue(context, console_key) == false) {
                return error.ConsoleDeleteError;
            }
        }

        // This shouldn't be necessary, but it is:
        // https://groups.google.com/g/v8-users/c/qAQQBmbi--8
        // TODO: see if newer V8 engines have a way around this.
        inline for (JsApis, 0..) |JsApi, i| {
            if (comptime protoIndexLookup(JsApi)) |proto_index| {
                const proto_obj = templates[proto_index].getFunction(context).toObject();
                const self_obj = templates[i].getFunction(context).toObject();
                _ = self_obj.setPrototype(context, proto_obj);
            }
        }

        {
            // Custom exception
            // TODO: this is an horrible hack, I can't figure out how to do this cleanly.
            const code = v8.String.initUtf8(isolate, "DOMException.prototype.__proto__ = Error.prototype");
            _ = try (try v8.Script.compile(context, code, null)).run(context);
        }

        snapshot_creator.setDefaultContext(context);
    }

    const blob = snapshot_creator.createBlob(v8.FunctionCodeHandling.kKeep);
    const owned = try allocator.dupe(u8, blob.data[0..@intCast(blob.raw_size)]);

    return .{
        .owns_data = true,
        .data_start = data_start,
        .external_references = external_references,
        .startup_data = .{ .data = owned.ptr, .raw_size = @intCast(owned.len) },
    };
}

// Count total callbacks needed for external_references array
fn countExternalReferences() comptime_int {
    @setEvalBranchQuota(100_000);

    // +1 for the illegal constructor callback
    var count: comptime_int = 1;

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
                if (value.setter != null) count += 1; // setter
            } else if (T == bridge.Function) {
                count += 1;
            } else if (T == bridge.Iterator) {
                count += 1;
            } else if (T == bridge.Indexed) {
                count += 1;
            } else if (T == bridge.NamedIndexed) {
                count += 1; // getter
                if (value.setter != null) count += 1;
                if (value.deleter != null) count += 1;
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

    return references;
}

// Even if a struct doesn't have a `constructor` function, we still
// `generateConstructor`, because this is how we create our
// FunctionTemplate. Such classes exist, but they can't be instantiated
// via `new ClassName()` - but they could, for example, be created in
// Zig and returned from a function call, which is why we need the
// FunctionTemplate.
fn generateConstructor(comptime JsApi: type, isolate: v8.Isolate) v8.FunctionTemplate {
    const callback = blk: {
        if (@hasDecl(JsApi, "constructor")) {
            break :blk JsApi.constructor.func;
        }

        // Use shared illegal constructor callback
        break :blk illegalConstructorCallback;
    };

    const template = v8.FunctionTemplate.initCallback(isolate, callback);
    if (!@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
        template.getInstanceTemplate().setInternalFieldCount(1);
    }
    const class_name = v8.String.initUtf8(isolate, if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi));
    template.setClassName(class_name);
    return template;
}

// Attaches JsApi members to the prototype template (normal case)
fn attachClass(comptime JsApi: type, isolate: v8.Isolate, template: v8.FunctionTemplate) void {
    const target = template.getPrototypeTemplate();
    const declarations = @typeInfo(JsApi).@"struct".decls;
    inline for (declarations) |d| {
        const name: [:0]const u8 = d.name;
        const value = @field(JsApi, name);
        const definition = @TypeOf(value);

        switch (definition) {
            bridge.Accessor => {
                const js_name = v8.String.initUtf8(isolate, name).toName();
                const getter_callback = v8.FunctionTemplate.initCallback(isolate, value.getter);
                if (value.setter == null) {
                    if (value.static) {
                        template.setAccessorGetter(js_name, getter_callback);
                    } else {
                        target.setAccessorGetter(js_name, getter_callback);
                    }
                } else {
                    std.debug.assert(value.static == false);
                    const setter_callback = v8.FunctionTemplate.initCallback(isolate, value.setter);
                    target.setAccessorGetterAndSetter(js_name, getter_callback, setter_callback);
                }
            },
            bridge.Function => {
                const function_template = v8.FunctionTemplate.initCallback(isolate, value.func);
                const js_name: v8.Name = v8.String.initUtf8(isolate, name).toName();
                if (value.static) {
                    template.set(js_name, function_template, v8.PropertyAttribute.None);
                } else {
                    target.set(js_name, function_template, v8.PropertyAttribute.None);
                }
            },
            bridge.Indexed => {
                const configuration = v8.IndexedPropertyHandlerConfiguration{
                    .getter = value.getter,
                };
                target.setIndexedProperty(configuration, null);
            },
            bridge.NamedIndexed => template.getInstanceTemplate().setNamedProperty(.{
                .getter = value.getter,
                .setter = value.setter,
                .deleter = value.deleter,
                .flags = v8.PropertyHandlerFlags.OnlyInterceptStrings | v8.PropertyHandlerFlags.NonMasking,
            }, null),
            bridge.Iterator => {
                const function_template = v8.FunctionTemplate.initCallback(isolate, value.func);
                const js_name = if (value.async)
                    v8.Symbol.getAsyncIterator(isolate).toName()
                else
                    v8.Symbol.getIterator(isolate).toName();
                target.set(js_name, function_template, v8.PropertyAttribute.None);
            },
            bridge.Property => {
                const js_value = switch (value) {
                    .int => |v| js.simpleZigValueToJs(isolate, v, true, false),
                };

                const js_name = v8.String.initUtf8(isolate, name).toName();
                // apply it both to the type itself
                template.set(js_name, js_value, v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);

                // and to instances of the type
                target.set(js_name, js_value, v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);
            },
            bridge.Constructor => {}, // already handled in generateConstructor
            else => {},
        }
    }

    if (@hasDecl(JsApi.Meta, "htmldda")) {
        const instance_template = template.getInstanceTemplate();
        instance_template.markAsUndetectable();
        instance_template.setCallAsFunctionHandler(JsApi.Meta.callable.func);
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
fn illegalConstructorCallback(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.c) void {
    const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
    const iso = info.getIsolate();
    log.warn(.js, "Illegal constructor call", .{});
    const js_exception = iso.throwException(js._createException(iso, "Illegal Constructor"));
    info.getReturnValue().set(js_exception);
}
