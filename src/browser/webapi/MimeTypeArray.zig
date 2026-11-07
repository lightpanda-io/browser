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
const Frame = @import("../Frame.zig");
const GenericIterator = @import("collections/iterator.zig").Entry;

pub fn registerTypes() []const type {
    return &.{ MimeTypeArray, MimeType, ValueIterator };
}

const MimeTypeArray = @This();

_pad: bool = false,

pub fn getAtIndex(_: *const MimeTypeArray, index: usize) ?*MimeType {
    _ = index;
    return null;
}

pub fn getByName(_: *const MimeTypeArray, name: []const u8) ?*MimeType {
    _ = name;
    return null;
}

// Cannot be constructed, and we currently never return any, so no reason to
// implement anything on it (for now)
const MimeType = struct {
    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeType);
        pub const Meta = struct {
            pub const name = "MimeType";
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
    };
};

fn values(_: *const MimeTypeArray, frame: *Frame) !*ValueIterator {
    return .init(.{}, frame);
}

const ValueIterator = GenericIterator(Iterator, null);

const Iterator = struct {
    pub fn next(_: *Iterator, _: *Frame) ?*MimeType {
        return null;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(MimeTypeArray);

    pub const Meta = struct {
        pub const name = "MimeTypeArray";
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const length = bridge.property(0, .{ .template = false });
    pub const @"[int]" = bridge.indexed(MimeTypeArray.getAtIndex, null, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(MimeTypeArray.getByName, null, null, null, struct {
        fn wrap(_: *const MimeTypeArray, _: []const u8) !u32 {
            // No MIME type is ever exposed, so there are no named properties.
            return error.NotHandled;
        }
    }.wrap, .{ .null_as_undefined = true });

    pub const item = bridge.function(struct {
        fn wrap(self: *const MimeTypeArray, index: i32) ?*MimeType {
            if (index < 0) {
                return null;
            }
            return self.getAtIndex(@intCast(index));
        }
    }.wrap, .{});

    pub const namedItem = bridge.function(MimeTypeArray.getByName, .{});
    pub const symbol_iterator = bridge.iterator(MimeTypeArray.values, .{});
};
