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
const assert = std.debug.assert;
const builtin = @import("builtin");
const reflect = @import("reflect.zig");
const IS_DEBUG = builtin.mode == .Debug;

const log = @import("../log.zig");
const String = @import("../string.zig").String;

const SlabAllocator = @import("../slab.zig").SlabAllocator;

const Page = @import("Page.zig");
const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const Element = @import("webapi/Element.zig");
const Document = @import("webapi/Document.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const XMLHttpRequestEventTarget = @import("webapi/net/XMLHttpRequestEventTarget.zig");
const Blob = @import("webapi/Blob.zig");

const Factory = @This();
_page: *Page,
_slab: SlabAllocator,

pub const FactoryAllocationKind = union(enum) {
    /// Allocated as part of a Factory PrototypeChain
    chain: []u8,
    /// Allocated standalone via factory.create()
    standalone,
};

fn PrototypeChain(comptime types: []const type) type {
    return struct {
        const Self = @This();
        memory: []u8,

        fn totalSize() usize {
            var size: usize = 0;
            for (types) |T| {
                size = std.mem.alignForward(usize, size, @alignOf(T));
                size += @sizeOf(T);
            }
            return size;
        }

        fn maxAlign() std.mem.Alignment {
            var alignment: std.mem.Alignment = .@"1";

            for (types) |T| {
                alignment = std.mem.Alignment.max(alignment, std.mem.Alignment.of(T));
            }

            return alignment;
        }

        fn getType(comptime index: usize) type {
            return types[index];
        }

        fn allocate(allocator: std.mem.Allocator) !Self {
            const size = comptime Self.totalSize();
            const alignment = comptime Self.maxAlign();

            const memory = try allocator.alignedAlloc(u8, alignment, size);
            return .{ .memory = memory };
        }

        fn get(self: *const Self, comptime index: usize) *getType(index) {
            var offset: usize = 0;
            inline for (types, 0..) |T, i| {
                offset = std.mem.alignForward(usize, offset, @alignOf(T));

                if (i == index) {
                    return @as(*T, @ptrCast(@alignCast(self.memory.ptr + offset)));
                }
                offset += @sizeOf(T);
            }
            unreachable;
        }

        fn set(self: *const Self, comptime index: usize, value: getType(index)) void {
            const ptr = self.get(index);
            ptr.* = value;
        }

        fn setRoot(self: *const Self, comptime T: type) void {
            const ptr = self.get(0);
            ptr.* = .{ ._type = unionInit(T, self.get(1)), ._allocation = FactoryAllocationKind{ .chain = self.memory } };
        }

        fn setMiddle(self: *const Self, comptime index: usize, comptime T: type) void {
            assert(index >= 1);
            assert(index < types.len);

            const ptr = self.get(index);
            ptr.* = .{ ._proto = self.get(index - 1), ._type = unionInit(T, self.get(index + 1)) };
        }

        fn setMiddleWithValue(self: *const Self, comptime index: usize, comptime T: type, value: anytype) void {
            assert(index >= 1);

            const ptr = self.get(index);
            ptr.* = .{ ._proto = self.get(index - 1), ._type = unionInit(T, value) };
        }

        fn setLeaf(self: *const Self, comptime index: usize, value: anytype) void {
            assert(index >= 1);

            const ptr = self.get(index);
            ptr.* = value;
            ptr._proto = self.get(index - 1);
        }
    };
}

fn AutoPrototypeChain(comptime types: []const type) type {
    return struct {
        fn create(allocator: std.mem.Allocator, leaf_value: anytype) !*@TypeOf(leaf_value) {
            const chain = try PrototypeChain(types).allocate(allocator);

            const RootType = types[0];
            chain.setRoot(RootType.Type);

            inline for (1..types.len - 1) |i| {
                const MiddleType = types[i];
                chain.setMiddle(i, MiddleType.Type);
            }

            chain.setLeaf(types.len - 1, leaf_value);
            return chain.get(types.len - 1);
        }
    };
}

pub fn init(page: *Page) Factory {
    return .{
        ._page = page,
        ._slab = SlabAllocator.init(page.arena, 128),
    };
}

// this is a root object
pub fn eventTarget(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    const chain = try PrototypeChain(
        &.{ EventTarget, @TypeOf(child) },
    ).allocate(allocator);

    chain.setRoot(EventTarget.Type);
    chain.setLeaf(1, child);

    return chain.get(1);
}

// this is a root object
pub fn event(self: *Factory, typ: []const u8, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();

    // Special case: Event has a _type_string field, so we need manual setup
    const chain = try PrototypeChain(
        &.{ Event, @TypeOf(child) },
    ).allocate(allocator);

    const event_ptr = chain.get(0);
    event_ptr.* = .{
        ._type = unionInit(Event.Type, chain.get(1)),
        ._type_string = try String.init(self._page.arena, typ, .{}),
        ._allocation = FactoryAllocationKind{ .chain = chain.memory },
    };
    chain.setLeaf(1, child);

    return chain.get(1);
}

pub fn blob(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();

    // Special case: Blob has slice and mime fields, so we need manual setup
    const chain = try PrototypeChain(
        &.{ Blob, @TypeOf(child) },
    ).allocate(allocator);

    const blob_ptr = chain.get(0);
    blob_ptr.* = .{
        ._type = unionInit(Blob.Type, chain.get(1)),
        ._allocation = FactoryAllocationKind{ .chain = chain.memory },
        .slice = "",
        .mime = "",
    };
    chain.setLeaf(1, child);

    return chain.get(1);
}

pub fn node(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    return try AutoPrototypeChain(
        &.{ EventTarget, Node, @TypeOf(child) },
    ).create(allocator, child);
}

pub fn document(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    return try AutoPrototypeChain(
        &.{ EventTarget, Node, Document, @TypeOf(child) },
    ).create(allocator, child);
}

pub fn documentFragment(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    return try AutoPrototypeChain(
        &.{ EventTarget, Node, Node.DocumentFragment, @TypeOf(child) },
    ).create(allocator, child);
}

pub fn element(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    return try AutoPrototypeChain(
        &.{ EventTarget, Node, Element, @TypeOf(child) },
    ).create(allocator, child);
}

pub fn htmlElement(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    return try AutoPrototypeChain(
        &.{ EventTarget, Node, Element, Element.Html, @TypeOf(child) },
    ).create(allocator, child);
}

pub fn svgElement(self: *Factory, tag_name: []const u8, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();

    // will never allocate, can't fail
    const tag_name_str = String.init(self._page.arena, tag_name, .{}) catch unreachable;

    const chain = try PrototypeChain(
        &.{ EventTarget, Node, Element, Element.Svg, @TypeOf(child) },
    ).allocate(allocator);

    chain.setRoot(EventTarget.Type);
    chain.setMiddle(1, Node.Type);
    chain.setMiddle(2, Element.Type);

    // Manually set Element.Svg with the tag_name
    chain.set(3, .{
        ._proto = chain.get(2),
        ._tag_name = tag_name_str,
        ._type = unionInit(Element.Svg.Type, chain.get(4)),
    });

    chain.setLeaf(4, child);
    return chain.get(4);
}

pub fn xhrEventTarget(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();

    return try AutoPrototypeChain(
        &.{ EventTarget, XMLHttpRequestEventTarget, @TypeOf(child) },
    ).create(allocator, child);
}

pub fn destroy(self: *Factory, value: anytype) void {
    const S = reflect.Struct(@TypeOf(value));
    const allocator = self._slab.allocator();

    if (comptime IS_DEBUG) {
        // We should always destroy from the leaf down.
        if (@hasField(S, "_type") and @typeInfo(@TypeOf(value._type)) == .@"union") {
            // A Event{._type == .generic} (or any other similar types)
            // _should_ be destoyed directly. The _type = .generic is a pseudo
            // child
            if (S != Event or value._type != .generic) {
                log.fatal(.bug, "factory.destroy.event", .{ .type = @typeName(S) });
                unreachable;
            }
        }
    }

    const allocation_kind = self.destroyChain(value, true) orelse return;
    switch (allocation_kind) {
        .chain => |buf| allocator.free(buf),
        .standalone => {},
    }
}

fn destroyChain(self: *Factory, value: anytype, comptime first: bool) ?FactoryAllocationKind {
    const S = reflect.Struct(@TypeOf(value));
    const allocator = self._slab.allocator();

    // This is initially called from a deinit. We don't want to call that
    // same deinit. So when this is the first time destroyChain is called
    // we don't call deinit (because we're in that deinit)
    if (!comptime first) {
        // But if it isn't the first time
        if (@hasDecl(S, "deinit")) {
            // And it has a deinit, we'll call it
            switch (@typeInfo(@TypeOf(S.deinit)).@"fn".params.len) {
                1 => value.deinit(),
                2 => value.deinit(self._page),
                else => @compileLog(@typeName(S) ++ " has an invalid deinit function"),
            }
        }
    }

    if (@hasField(S, "_proto")) {
        return self.destroyChain(value._proto, false);
    } else if (@hasDecl(S, "JsApi")) {
        // Doesn't have a _proto, but has a JsApi.
        if (self._page.js.removeTaggedMapping(@intFromPtr(value))) |tagged| {
            allocator.destroy(tagged);
        }
    } else if (@hasField(S, "_allocation")) {
        return value._allocation;
    } else return null;
}

pub fn createT(self: *Factory, comptime T: type) !*T {
    const allocator = self._slab.allocator();
    return try allocator.create(T);
}

pub fn create(self: *Factory, value: anytype) !*@TypeOf(value) {
    const ptr = try self.createT(@TypeOf(value));
    ptr.* = value;
    return ptr;
}

fn unionInit(comptime T: type, value: anytype) T {
    const V = @TypeOf(value);
    const field_name = comptime unionFieldName(T, V);
    return @unionInit(T, field_name, value);
}

// There can be friction between comptime and runtime. Comptime has to
// account for all possible types, even if some runtime flow makes certain
// cases impossible. At runtime, we always call `unionFieldName` with the
// correct struct or pointer type. But at comptime time, `unionFieldName`
// is called with both variants (S and *S). So we use reflect.Struct().
// This only works because we never have a union with a field S and another
// field *S.
fn unionFieldName(comptime T: type, comptime V: type) []const u8 {
    inline for (@typeInfo(T).@"union".fields) |field| {
        if (reflect.Struct(field.type) == reflect.Struct(V)) {
            return field.name;
        }
    }
    @compileError(@typeName(V) ++ " is not a valid type for " ++ @typeName(T) ++ ".type");
}
