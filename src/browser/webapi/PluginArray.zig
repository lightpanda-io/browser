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

const js = @import("../js/js.zig");
const std = @import("std");

pub fn registerTypes() []const type {
    return &.{ PluginArray, Plugin };
}

pub const Plugin = struct {
    _name: []const u8 = "",
    _filename: []const u8 = "",
    _description: []const u8 = "",

    pub fn getName(self: *const Plugin) []const u8 {
        return self._name;
    }

    pub fn getFilename(self: *const Plugin) []const u8 {
        return self._filename;
    }

    pub fn getDescription(self: *const Plugin) []const u8 {
        return self._description;
    }

    pub fn getLength(_: *const Plugin) usize {
        return 2;
    }

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
    };
};

const builtin_plugins = [_]Plugin{
    .{
        ._name = "PDF Viewer",
        ._filename = "internal-pdf-viewer",
        ._description = "Portable Document Format",
    },
    .{
        ._name = "Chrome PDF Viewer",
        ._filename = "internal-pdf-viewer",
        ._description = "Portable Document Format",
    },
    .{
        ._name = "Chromium PDF Viewer",
        ._filename = "internal-pdf-viewer",
        ._description = "Portable Document Format",
    },
    .{
        ._name = "Microsoft Edge PDF Viewer",
        ._filename = "internal-pdf-viewer",
        ._description = "Portable Document Format",
    },
    .{
        ._name = "WebKit built-in PDF",
        ._filename = "internal-pdf-viewer",
        ._description = "Portable Document Format",
    },
};

const PluginArray = @This();

_pad: bool = false,
_items: [builtin_plugins.len]Plugin = builtin_plugins,

pub fn getBuiltinPlugin(index: usize) *Plugin {
    return @constCast(&builtin_plugins[index]);
}

pub fn refresh(_: *const PluginArray) void {}

pub fn getLength(_: *const PluginArray) usize {
    return builtin_plugins.len;
}

pub fn getAtIndex(self: *const PluginArray, index: usize) ?*Plugin {
    if (index >= self._items.len) {
        return null;
    }
    return @constCast(&self._items[index]);
}

pub fn getByName(self: *const PluginArray, name: []const u8) ?*Plugin {
    for (&self._items) |*plugin| {
        if (std.mem.eql(u8, plugin._name, name)) {
            return @constCast(plugin);
        }
    }
    return null;
}

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
    pub const @"[int]" = bridge.indexed(PluginArray.getAtIndex, null, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(PluginArray.getByName, null, null, .{ .null_as_undefined = true });
    pub const item = bridge.function(_item, .{});
    fn _item(self: *const PluginArray, index: i32) ?*Plugin {
        if (index < 0) {
            return null;
        }
        return self.getAtIndex(@intCast(index));
    }
    pub const namedItem = bridge.function(PluginArray.getByName, .{});
};
