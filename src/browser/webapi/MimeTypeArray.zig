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
const PluginArrayMod = @import("PluginArray.zig");
const Plugin = PluginArrayMod.Plugin;

pub fn registerTypes() []const type {
    return &.{ MimeTypeArray, MimeType };
}

pub const MimeType = struct {
    _type: []const u8 = "",
    _description: []const u8 = "",
    _suffixes: []const u8 = "",
    _enabled_plugin_index: usize = 0,

    pub fn getType(self: *const MimeType) []const u8 {
        return self._type;
    }

    pub fn getDescription(self: *const MimeType) []const u8 {
        return self._description;
    }

    pub fn getSuffixes(self: *const MimeType) []const u8 {
        return self._suffixes;
    }

    pub fn getEnabledPlugin(self: *const MimeType) *Plugin {
        return PluginArrayMod.getBuiltinPlugin(self._enabled_plugin_index);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeType);

        pub const Meta = struct {
            pub const name = "MimeType";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(MimeType.getType, null, .{});
        pub const description = bridge.accessor(MimeType.getDescription, null, .{});
        pub const suffixes = bridge.accessor(MimeType.getSuffixes, null, .{});
        pub const enabledPlugin = bridge.accessor(MimeType.getEnabledPlugin, null, .{});
    };
};

const builtin_mime_types = [_]MimeType{
    .{
        ._type = "application/pdf",
        ._description = "Portable Document Format",
        ._suffixes = "pdf",
        ._enabled_plugin_index = 0,
    },
    .{
        ._type = "text/pdf",
        ._description = "Portable Document Format",
        ._suffixes = "pdf",
        ._enabled_plugin_index = 0,
    },
};

const MimeTypeArray = @This();

_pad: bool = false,
_items: [builtin_mime_types.len]MimeType = builtin_mime_types,

pub fn getLength(_: *const MimeTypeArray) usize {
    return builtin_mime_types.len;
}

pub fn getAtIndex(self: *const MimeTypeArray, index: usize) ?*MimeType {
    if (index >= self._items.len) {
        return null;
    }
    return @constCast(&self._items[index]);
}

pub fn getByName(self: *const MimeTypeArray, name: []const u8) ?*MimeType {
    for (&self._items) |*mime_type| {
        if (std.mem.eql(u8, mime_type._type, name)) {
            return @constCast(mime_type);
        }
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MimeTypeArray);

    pub const Meta = struct {
        pub const name = "MimeTypeArray";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const length = bridge.accessor(MimeTypeArray.getLength, null, .{});
    pub const @"[int]" = bridge.indexed(MimeTypeArray.getAtIndex, null, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(MimeTypeArray.getByName, null, null, .{ .null_as_undefined = true });
    pub const item = bridge.function(_item, .{});
    fn _item(self: *const MimeTypeArray, index: i32) ?*MimeType {
        if (index < 0) {
            return null;
        }
        return self.getAtIndex(@intCast(index));
    }
    pub const namedItem = bridge.function(MimeTypeArray.getByName, .{});
};
