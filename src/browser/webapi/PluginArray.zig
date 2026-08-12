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
const js = @import("../js/js.zig");

/// Chrome's built-in PDF viewer surface. Chrome reports exactly these five
/// plugins and two MIME types on every desktop build; an empty navigator.plugins
/// is one of the oldest headless tells there is.
pub fn registerTypes() []const type {
    return &.{ PluginArray, Plugin, MimeTypeArray, MimeType, PluginArray.Iterator, Plugin.Iterator, MimeTypeArray.Iterator };
}

const plugin_defs = [_]PluginDef{
    .{ .name = "PDF Viewer", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
    .{ .name = "Chrome PDF Viewer", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
    .{ .name = "Chromium PDF Viewer", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
    .{ .name = "Microsoft Edge PDF Viewer", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
    .{ .name = "WebKit built-in PDF", .filename = "internal-pdf-viewer", .description = "Portable Document Format" },
};

const mime_defs = [_]MimeDef{
    .{ .type_name = "application/pdf", .suffixes = "pdf", .description = "Portable Document Format" },
    .{ .type_name = "text/pdf", .suffixes = "pdf", .description = "Portable Document Format" },
};

const PluginDef = struct {
    name: []const u8,
    filename: []const u8,
    description: []const u8,
};

const MimeDef = struct {
    type_name: []const u8,
    suffixes: []const u8,
    description: []const u8,
};

fn pluginsStorage() *[plugin_defs.len]Plugin {
    const S = struct {
        var storage: [plugin_defs.len]Plugin = blk: {
            var arr: [plugin_defs.len]Plugin = undefined;
            for (&arr, plugin_defs, 0..) |*p, def, i| {
                p.* = .{
                    ._index = i,
                    ._name = def.name,
                    ._filename = def.filename,
                    ._description = def.description,
                };
            }
            break :blk arr;
        };
    };
    return &S.storage;
}

fn mimesStorage() *[mime_defs.len]MimeType {
    const S = struct {
        var storage: [mime_defs.len]MimeType = blk: {
            var arr: [mime_defs.len]MimeType = undefined;
            for (&arr, mime_defs, 0..) |*m, def, i| {
                m.* = .{
                    ._index = i,
                    ._plugin_index = 0,
                    ._type = def.type_name,
                    ._suffixes = def.suffixes,
                    ._description = def.description,
                };
            }
            break :blk arr;
        };
    };
    return &S.storage;
}

fn pluginMimesStorage() *[plugin_defs.len * mime_defs.len]MimeType {
    const S = struct {
        var storage: [plugin_defs.len * mime_defs.len]MimeType = blk: {
            var arr: [plugin_defs.len * mime_defs.len]MimeType = undefined;
            for (0..plugin_defs.len) |plugin_index| {
                for (mime_defs, 0..) |def, mime_index| {
                    arr[plugin_index * mime_defs.len + mime_index] = .{
                        ._index = mime_index,
                        ._plugin_index = plugin_index,
                        ._type = def.type_name,
                        ._suffixes = def.suffixes,
                        ._description = def.description,
                    };
                }
            }
            break :blk arr;
        };
    };
    return &S.storage;
}

pub const PluginArray = struct {
    _pad: bool = false,

    pub fn getLength(_: *const PluginArray) u32 {
        return plugin_defs.len;
    }

    pub fn refresh(_: *const PluginArray) void {}

    pub fn getAtIndex(_: *const PluginArray, index: usize) ?*Plugin {
        const storage = pluginsStorage();
        if (index >= storage.len) return null;
        return &storage[index];
    }

    pub fn getByName(_: *const PluginArray, name: []const u8) ?*Plugin {
        for (pluginsStorage()) |*p| {
            if (std.mem.eql(u8, p._name, name)) return p;
        }
        return null;
    }

    pub fn iterator(self: *PluginArray, exec: *const js.Execution) !*Iterator {
        return Iterator.init(.{ .index = 0, .list = self }, exec);
    }

    const GenericIterator = @import("collections/iterator.zig").Entry;
    pub const Iterator = GenericIterator(struct {
        index: u32,
        list: *PluginArray,

        pub fn next(self: *@This(), _: *const js.Execution) ?*Plugin {
            const plugin = self.list.getAtIndex(self.index) orelse return null;
            self.index += 1;
            return plugin;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PluginArray);

        pub const Meta = struct {
            pub const name = "PluginArray";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const length = bridge.accessor(PluginArray.getLength, null, .{});
        pub const refresh = bridge.function(PluginArray.refresh, .{});
        pub const @"[int]" = bridge.indexedReadWrite(PluginArray.getAtIndex, null, null, queryIndex, getIndexes, .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexed(PluginArray.getByName, null, null, getNames, queryName, .{ .null_as_undefined = true });
        pub const item = bridge.function(_item, .{});
        fn _item(self: *const PluginArray, index: i32) ?*Plugin {
            if (index < 0) return null;
            return self.getAtIndex(@intCast(index));
        }
        pub const namedItem = bridge.function(PluginArray.getByName, .{});
        pub const symbol_iterator = bridge.iterator(PluginArray.iterator, .{});

        fn getIndexes(_: *const PluginArray, exec: *const js.Execution) !js.Array {
            return indexArray(plugin_defs.len, exec);
        }

        fn getNames(_: *const PluginArray, exec: *const js.Execution) !js.Array {
            var arr = exec.js.local.?.newArray(plugin_defs.len);
            for (plugin_defs, 0..) |plugin, i| {
                _ = try arr.set(@intCast(i), plugin.name, .{});
            }
            return arr;
        }

        fn queryName(self: *const PluginArray, key: []const u8) !u32 {
            if (self.getByName(key) != null) return js.v8.ReadOnly | js.v8.DontEnum;
            return error.NotHandled;
        }

        fn queryIndex(_: *const PluginArray, index: u32) !u32 {
            if (index < plugin_defs.len) return js.v8.ReadOnly;
            return error.NotHandled;
        }
    };
};

pub const Plugin = struct {
    _index: usize,
    _name: []const u8,
    _filename: []const u8,
    _description: []const u8,

    pub fn getLength(_: *const Plugin) u32 {
        return mime_defs.len;
    }

    pub fn getName(self: *const Plugin) []const u8 {
        return self._name;
    }

    pub fn getFilename(self: *const Plugin) []const u8 {
        return self._filename;
    }

    pub fn getDescription(self: *const Plugin) []const u8 {
        return self._description;
    }

    pub fn getAtIndex(self: *const Plugin, index: usize) ?*MimeType {
        if (index >= mime_defs.len) return null;
        return &pluginMimesStorage()[self._index * mime_defs.len + index];
    }

    pub fn getByName(self: *const Plugin, name: []const u8) ?*MimeType {
        const start = self._index * mime_defs.len;
        for (pluginMimesStorage()[start .. start + mime_defs.len]) |*m| {
            if (std.mem.eql(u8, m._type, name)) return m;
        }
        return null;
    }

    pub fn iterator(self: *Plugin, exec: *const js.Execution) !*Iterator {
        return Iterator.init(.{ .index = 0, .plugin = self }, exec);
    }

    const GenericIterator = @import("collections/iterator.zig").Entry;
    pub const Iterator = GenericIterator(struct {
        index: u32,
        plugin: *Plugin,

        pub fn next(self: *@This(), _: *const js.Execution) ?*MimeType {
            const mime = self.plugin.getAtIndex(self.index) orelse return null;
            self.index += 1;
            return mime;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Plugin);
        pub const Meta = struct {
            pub const name = "Plugin";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(Plugin.getName, null, .{});
        pub const filename = bridge.accessor(Plugin.getFilename, null, .{});
        pub const description = bridge.accessor(Plugin.getDescription, null, .{});
        pub const length = bridge.accessor(Plugin.getLength, null, .{});
        pub const @"[int]" = bridge.indexedReadWrite(Plugin.getAtIndex, null, null, queryIndex, getIndexes, .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexed(Plugin.getByName, null, null, getNames, queryName, .{ .null_as_undefined = true });
        pub const item = bridge.function(_item, .{});
        fn _item(self: *const Plugin, index: i32) ?*MimeType {
            if (index < 0) return null;
            return self.getAtIndex(@intCast(index));
        }
        pub const namedItem = bridge.function(Plugin.getByName, .{});
        pub const symbol_iterator = bridge.iterator(Plugin.iterator, .{});

        fn getIndexes(_: *const Plugin, exec: *const js.Execution) !js.Array {
            return indexArray(mime_defs.len, exec);
        }

        fn getNames(_: *const Plugin, exec: *const js.Execution) !js.Array {
            var arr = exec.js.local.?.newArray(mime_defs.len);
            for (mime_defs, 0..) |mime, i| {
                _ = try arr.set(@intCast(i), mime.type_name, .{});
            }
            return arr;
        }

        fn queryName(self: *const Plugin, key: []const u8) !u32 {
            if (self.getByName(key) != null) return js.v8.ReadOnly | js.v8.DontEnum;
            return error.NotHandled;
        }

        fn queryIndex(_: *const Plugin, index: u32) !u32 {
            if (index < mime_defs.len) return js.v8.ReadOnly;
            return error.NotHandled;
        }
    };
};

pub const MimeTypeArray = struct {
    _pad: bool = false,

    pub fn getLength(_: *const MimeTypeArray) u32 {
        return mime_defs.len;
    }

    pub fn getAtIndex(_: *const MimeTypeArray, index: usize) ?*MimeType {
        const storage = mimesStorage();
        if (index >= storage.len) return null;
        return &storage[index];
    }

    pub fn getByName(_: *const MimeTypeArray, name: []const u8) ?*MimeType {
        for (mimesStorage()) |*m| {
            if (std.mem.eql(u8, m._type, name)) return m;
        }
        return null;
    }

    pub fn iterator(self: *MimeTypeArray, exec: *const js.Execution) !*Iterator {
        return Iterator.init(.{ .index = 0, .list = self }, exec);
    }

    const GenericIterator = @import("collections/iterator.zig").Entry;
    pub const Iterator = GenericIterator(struct {
        index: u32,
        list: *MimeTypeArray,

        pub fn next(self: *@This(), _: *const js.Execution) ?*MimeType {
            const mime = self.list.getAtIndex(self.index) orelse return null;
            self.index += 1;
            return mime;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeTypeArray);
        pub const Meta = struct {
            pub const name = "MimeTypeArray";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const length = bridge.accessor(MimeTypeArray.getLength, null, .{});
        pub const @"[int]" = bridge.indexedReadWrite(MimeTypeArray.getAtIndex, null, null, queryIndex, getIndexes, .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexed(MimeTypeArray.getByName, null, null, getNames, queryName, .{ .null_as_undefined = true });
        pub const item = bridge.function(_item, .{});
        fn _item(self: *const MimeTypeArray, index: i32) ?*MimeType {
            if (index < 0) return null;
            return self.getAtIndex(@intCast(index));
        }
        pub const namedItem = bridge.function(MimeTypeArray.getByName, .{});
        pub const symbol_iterator = bridge.iterator(MimeTypeArray.iterator, .{});

        fn getIndexes(_: *const MimeTypeArray, exec: *const js.Execution) !js.Array {
            return indexArray(mime_defs.len, exec);
        }

        fn getNames(_: *const MimeTypeArray, exec: *const js.Execution) !js.Array {
            var arr = exec.js.local.?.newArray(mime_defs.len);
            for (mime_defs, 0..) |mime, i| {
                _ = try arr.set(@intCast(i), mime.type_name, .{});
            }
            return arr;
        }

        fn queryName(self: *const MimeTypeArray, key: []const u8) !u32 {
            if (self.getByName(key) != null) return js.v8.ReadOnly | js.v8.DontEnum;
            return error.NotHandled;
        }

        fn queryIndex(_: *const MimeTypeArray, index: u32) !u32 {
            if (index < mime_defs.len) return js.v8.ReadOnly;
            return error.NotHandled;
        }
    };
};

fn indexArray(len: u32, exec: *const js.Execution) !js.Array {
    var arr = exec.js.local.?.newArray(len);
    for (0..len) |i| {
        _ = try arr.set(@intCast(i), i, .{});
    }
    return arr;
}

pub const MimeType = struct {
    _index: usize,
    _plugin_index: usize,
    _type: []const u8,
    _suffixes: []const u8,
    _description: []const u8,

    pub fn getType(self: *const MimeType) []const u8 {
        return self._type;
    }

    pub fn getSuffixes(self: *const MimeType) []const u8 {
        return self._suffixes;
    }

    pub fn getDescription(self: *const MimeType) []const u8 {
        return self._description;
    }

    pub fn getEnabledPlugin(self: *const MimeType) ?*Plugin {
        const storage = pluginsStorage();
        return &storage[self._plugin_index];
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeType);
        pub const Meta = struct {
            pub const name = "MimeType";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(MimeType.getType, null, .{});
        pub const suffixes = bridge.accessor(MimeType.getSuffixes, null, .{});
        pub const description = bridge.accessor(MimeType.getDescription, null, .{});
        pub const enabledPlugin = bridge.accessor(MimeType.getEnabledPlugin, null, .{});
    };
};
