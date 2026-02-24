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
const builtin = @import("builtin");
const reflect = @import("reflect.zig");

const log = @import("../log.zig");
const String = @import("../string.zig").String;

const SlabAllocator = @import("../slab.zig").SlabAllocator;

const Page = @import("Page.zig");
const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const UIEvent = @import("webapi/event/UIEvent.zig");
const MouseEvent = @import("webapi/event/MouseEvent.zig");
const Element = @import("webapi/Element.zig");
const Document = @import("webapi/Document.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const XMLHttpRequestEventTarget = @import("webapi/net/XMLHttpRequestEventTarget.zig");
const Blob = @import("webapi/Blob.zig");
const AbstractRange = @import("webapi/AbstractRange.zig");

const Allocator = std.mem.Allocator;

const IS_DEBUG = builtin.mode == .Debug;
const assert = std.debug.assert;

// Shared across all frames of a Page.
const Factory = @This();

_arena: Allocator,
_slab: SlabAllocator,

pub fn init(arena: Allocator) !*Factory {
    const self = try arena.create(Factory);
    self.* = .{
        ._arena = arena,
        ._slab = SlabAllocator.init(arena, 128),
    };
    return self;
}

// this is a root object
pub fn eventTarget(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    const chain = try PrototypeChain(
        &.{ EventTarget, @TypeOf(child) },
    ).allocate(allocator);

    const event_ptr = chain.get(0);
    event_ptr.* = .{
        ._type = unionInit(EventTarget.Type, chain.get(1)),
    };
    chain.setLeaf(1, child);

    return chain.get(1);
}

pub fn standaloneEventTarget(self: *Factory, child: anytype) !*EventTarget {
    const allocator = self._slab.allocator();
    const et = try allocator.create(EventTarget);
    et.* = .{ ._type = unionInit(EventTarget.Type, child) };
    return et;
}

// this is a root object
pub fn event(_: *const Factory, arena: Allocator, typ: String, child: anytype) !*@TypeOf(child) {
    const chain = try PrototypeChain(
        &.{ Event, @TypeOf(child) },
    ).allocate(arena);

    // Special case: Event has a _type_string field, so we need manual setup
    const event_ptr = chain.get(0);
    event_ptr.* = try eventInit(arena, typ, chain.get(1));
    chain.setLeaf(1, child);

    return chain.get(1);
}

pub fn uiEvent(_: *const Factory, arena: Allocator, typ: String, child: anytype) !*@TypeOf(child) {
    const chain = try PrototypeChain(
        &.{ Event, UIEvent, @TypeOf(child) },
    ).allocate(arena);

    // Special case: Event has a _type_string field, so we need manual setup
    const event_ptr = chain.get(0);
    event_ptr.* = try eventInit(arena, typ, chain.get(1));
    chain.setMiddle(1, UIEvent.Type);
    chain.setLeaf(2, child);

    return chain.get(2);
}

pub fn mouseEvent(_: *const Factory, arena: Allocator, typ: String, mouse: MouseEvent, child: anytype) !*@TypeOf(child) {
    const chain = try PrototypeChain(
        &.{ Event, UIEvent, MouseEvent, @TypeOf(child) },
    ).allocate(arena);

    // Special case: Event has a _type_string field, so we need manual setup
    const event_ptr = chain.get(0);
    event_ptr.* = try eventInit(arena, typ, chain.get(1));
    chain.setMiddle(1, UIEvent.Type);

    // Set MouseEvent with all its fields
    const mouse_ptr = chain.get(2);
    mouse_ptr.* = mouse;
    mouse_ptr._proto = chain.get(1);
    mouse_ptr._type = unionInit(MouseEvent.Type, chain.get(3));

    chain.setLeaf(3, child);

    return chain.get(3);
}

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
            ptr.* = .{ ._type = unionInit(T, self.get(1)) };
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

fn eventInit(arena: Allocator, typ: String, value: anytype) !Event {
    // Round to 2ms for privacy (browsers do this)
    const raw_timestamp = @import("../datetime.zig").milliTimestamp(.monotonic);
    const time_stamp = (raw_timestamp / 2) * 2;

    return .{
        ._rc = 0,
        ._arena = arena,
        ._type = unionInit(Event.Type, value),
        ._type_string = typ,
        ._time_stamp = time_stamp,
    };
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
        ._slice = "",
        ._mime = "",
    };
    chain.setLeaf(1, child);

    return chain.get(1);
}

pub fn abstractRange(self: *Factory, child: anytype, page: *Page) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    const chain = try PrototypeChain(&.{ AbstractRange, @TypeOf(child) }).allocate(allocator);

    const doc = page.document.asNode();
    chain.set(0, AbstractRange{
        ._type = unionInit(AbstractRange.Type, chain.get(1)),
        ._end_offset = 0,
        ._start_offset = 0,
        ._end_container = doc,
        ._start_container = doc,
    });
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

pub fn htmlMediaElement(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    return try AutoPrototypeChain(
        &.{ EventTarget, Node, Element, Element.Html, Element.Html.Media, @TypeOf(child) },
    ).create(allocator, child);
}

pub fn svgElement(self: *Factory, tag_name: []const u8, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    const ChildT = @TypeOf(child);

    if (ChildT == Element.Svg) {
        return self.element(child);
    }

    const chain = try PrototypeChain(
        &.{ EventTarget, Node, Element, Element.Svg, ChildT },
    ).allocate(allocator);

    chain.setRoot(EventTarget.Type);
    chain.setMiddle(1, Node.Type);
    chain.setMiddle(2, Element.Type);

    // will never allocate, can't fail
    const tag_name_str = String.init(self._arena, tag_name, .{}) catch unreachable;

    // Manually set Element.Svg with the tag_name
    chain.set(3, .{
        ._proto = chain.get(2),
        ._tag_name = tag_name_str,
        ._type = unionInit(Element.Svg.Type, chain.get(4)),
    });

    chain.setLeaf(4, child);
    return chain.get(4);
}

pub fn xhrEventTarget(_: *const Factory, allocator: Allocator, child: anytype) !*@TypeOf(child) {
    return try AutoPrototypeChain(
        &.{ EventTarget, XMLHttpRequestEventTarget, @TypeOf(child) },
    ).create(allocator, child);
}

pub fn textTrackCue(self: *Factory, child: anytype) !*@TypeOf(child) {
    const allocator = self._slab.allocator();
    const TextTrackCue = @import("webapi/media/TextTrackCue.zig");

    return try AutoPrototypeChain(
        &.{ EventTarget, TextTrackCue, @TypeOf(child) },
    ).create(allocator, child);
}

pub fn destroy(self: *Factory, value: anytype) void {
    const S = reflect.Struct(@TypeOf(value));

    if (comptime IS_DEBUG) {
        // We should always destroy from the leaf down.
        if (@hasDecl(S, "_prototype_root")) {
            // A Event{._type == .generic} (or any other similar types)
            // _should_ be destoyed directly. The _type = .generic is a pseudo
            // child
            if (S != Event or value._type != .generic) {
                log.fatal(.bug, "factory.destroy.event", .{ .type = @typeName(S) });
                unreachable;
            }
        }
    }

    if (comptime @hasField(S, "_proto")) {
        self.destroyChain(value, 0, std.mem.Alignment.@"1");
    } else {
        self.destroyStandalone(value);
    }
}

pub fn destroyStandalone(self: *Factory, value: anytype) void {
    const allocator = self._slab.allocator();
    allocator.destroy(value);
}

fn destroyChain(
    self: *Factory,
    value: anytype,
    old_size: usize,
    old_align: std.mem.Alignment,
) void {
    const S = reflect.Struct(@TypeOf(value));
    const allocator = self._slab.allocator();

    // aligns the old size to the alignment of this element
    const current_size = std.mem.alignForward(usize, old_size, @alignOf(S));
    const new_size = current_size + @sizeOf(S);
    const new_align = std.mem.Alignment.max(old_align, std.mem.Alignment.of(S));

    if (@hasField(S, "_proto")) {
        self.destroyChain(value._proto, new_size, new_align);
    } else {
        // no proto so this is the head of the chain.
        // we use this as the ptr to the start of the chain.
        // and we have summed up the length.
        assert(@hasDecl(S, "_prototype_root"));

        const memory_ptr: [*]u8 = @ptrCast(@constCast(value));
        const len = std.mem.alignForward(usize, new_size, new_align.toByteUnits());
        allocator.rawFree(memory_ptr[0..len], new_align, @returnAddress());
    }
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
