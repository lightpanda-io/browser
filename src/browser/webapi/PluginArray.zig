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

pub fn registerTypes() []const type {
    return &.{ PluginArray, Plugin };
}

const PluginArray = @This();

_pad: bool = false,

/// Chrome 131 reports 5 PDF-related plugins. An empty PluginArray is a
/// bot fingerprint signal for anti-bot systems.
const chrome_plugins = [_]Plugin{
    .{ ._name = "PDF Viewer", ._description = "Portable Document Format", ._filename = "internal-pdf-viewer" },
    .{ ._name = "Chrome PDF Viewer", ._description = "Portable Document Format", ._filename = "internal-pdf-viewer" },
    .{ ._name = "Chromium PDF Viewer", ._description = "Portable Document Format", ._filename = "internal-pdf-viewer" },
    .{ ._name = "Microsoft Edge PDF Viewer", ._description = "Portable Document Format", ._filename = "internal-pdf-viewer" },
    .{ ._name = "WebKit built-in PDF", ._description = "Portable Document Format", ._filename = "internal-pdf-viewer" },
};

pub fn refresh(_: *const PluginArray) void {}

pub fn getAtIndex(_: *const PluginArray, index: usize) ?*const Plugin {
    if (index < chrome_plugins.len) {
        return &chrome_plugins[index];
    }
    return null;
}

pub fn getByName(_: *const PluginArray, name: []const u8) ?*const Plugin {
    for (&chrome_plugins) |*p| {
        if (std.mem.eql(u8, p._name, name)) {
            return p;
        }
    }
    return null;
}

const std = @import("std");

const Plugin = struct {
    _name: []const u8,
    _description: []const u8,
    _filename: []const u8,

    pub fn getName(self: *const Plugin) []const u8 {
        return self._name;
    }
    pub fn getDescription(self: *const Plugin) []const u8 {
        return self._description;
    }
    pub fn getFilename(self: *const Plugin) []const u8 {
        return self._filename;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Plugin);
        pub const Meta = struct {
            pub const name = "Plugin";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const @"name" = bridge.accessor(Plugin.getName, null, .{});
        pub const description = bridge.accessor(Plugin.getDescription, null, .{});
        pub const filename = bridge.accessor(Plugin.getFilename, null, .{});
        pub const length = bridge.property(1, .{ .template = false });
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(PluginArray);

    pub const Meta = struct {
        pub const name = "PluginArray";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const length = bridge.property(5, .{ .template = false });
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
