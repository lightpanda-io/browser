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
const builtin = @import("builtin");
const reflect = @import("reflect.zig");
const IS_DEBUG = builtin.mode == .Debug;

const log = @import("../log.zig");
const String = @import("../string.zig").String;

const SlabAllocator = @import("../slab.zig").SlabAllocator(16);

const Page = @import("Page.zig");
const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const Element = @import("webapi/Element.zig");
const Document = @import("webapi/Document.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const XMLHttpRequestEventTarget = @import("webapi/net/XMLHttpRequestEventTarget.zig");
const Blob = @import("webapi/Blob.zig");

const MemoryPoolAligned = std.heap.MemoryPoolAligned;

// 1. Generally, wrapping an ArenaAllocator within an ArenaAllocator doesn't make
// much sense. But wrapping a MemoryPool within an Arena does. Specifically, by
// doing so, we solve a major issue with Arena: freed memory can be re-used [for
// more of the same size].
// 2. Normally, you have a MemoryPool(T) where T is a `User` or something. Then
// the MemoryPool can be used for creating users. But in reality, that memory
// created by that pool could be re-used for anything with the same size (or less)
// than a User (and a compatible alignment). So that's what we do - we have size
// (and alignment) based pools.
const Factory = @This();
_page: *Page,
_slab: SlabAllocator,

pub fn init(page: *Page) Factory {
    return .{
        ._page = page,
        ._slab = SlabAllocator.init(page.arena),
    };
}

// this is a root object
pub fn eventTarget(self: *Factory, child: anytype) !*@TypeOf(child) {
    const child_ptr = try self.createT(@TypeOf(child));
    child_ptr.* = child;

    const et = try self.createT(EventTarget);
    child_ptr._proto = et;
    et.* = .{ ._type = unionInit(EventTarget.Type, child_ptr) };
    return child_ptr;
}

pub fn node(self: *Factory, child: anytype) !*@TypeOf(child) {
    const child_ptr = try self.createT(@TypeOf(child));
    child_ptr.* = child;
    child_ptr._proto = try self.eventTarget(Node{
        ._proto = undefined,
        ._type = unionInit(Node.Type, child_ptr),
    });
    return child_ptr;
}

pub fn document(self: *Factory, child: anytype) !*@TypeOf(child) {
    const child_ptr = try self.createT(@TypeOf(child));
    child_ptr.* = child;
    child_ptr._proto = try self.node(Document{
        ._proto = undefined,
        ._type = unionInit(Document.Type, child_ptr),
    });
    return child_ptr;
}

pub fn documentFragment(self: *Factory, child: anytype) !*@TypeOf(child) {
    const child_ptr = try self.createT(@TypeOf(child));
    child_ptr.* = child;
    child_ptr._proto = try self.node(Node.DocumentFragment{
        ._proto = undefined,
        ._type = unionInit(Node.DocumentFragment.Type, child_ptr),
    });
    return child_ptr;
}

pub fn element(self: *Factory, child: anytype) !*@TypeOf(child) {
    const child_ptr = try self.createT(@TypeOf(child));
    child_ptr.* = child;
    child_ptr._proto = try self.node(Element{
        ._proto = undefined,
        ._type = unionInit(Element.Type, child_ptr),
    });
    return child_ptr;
}

pub fn htmlElement(self: *Factory, child: anytype) !*@TypeOf(child) {
    if (comptime fieldIsPointer(Element.Html.Type, @TypeOf(child))) {
        const child_ptr = try self.createT(@TypeOf(child));
        child_ptr.* = child;
        child_ptr._proto = try self.element(Element.Html{
            ._proto = undefined,
            ._type = unionInit(Element.Html.Type, child_ptr),
        });
        return child_ptr;
    }

    // Our union type fields are usually pointers. But, at the leaf, they
    // can be struct (if all they contain is the `_proto` field, then we might
    // as well store it directly in the struct).

    const html = try self.element(Element.Html{
        ._proto = undefined,
        ._type = unionInit(Element.Html.Type, child),
    });
    const field_name = comptime unionFieldName(Element.Html.Type, @TypeOf(child));
    var child_ptr = &@field(html._type, field_name);
    child_ptr._proto = html;
    return child_ptr;
}

pub fn svgElement(self: *Factory, tag_name: []const u8, child: anytype) !*@TypeOf(child) {
    if (@TypeOf(child) == Element.Svg) {
        return self.element(child);
    }

    // will never allocate, can't fail
    const tag_name_str = String.init(self._page.arena, tag_name, .{}) catch unreachable;

    if (comptime fieldIsPointer(Element.Svg.Type, @TypeOf(child))) {
        const child_ptr = try self.createT(@TypeOf(child));
        child_ptr.* = child;
        child_ptr._proto = try self.element(Element.Svg{
            ._proto = undefined,
            ._tag_name = tag_name_str,
            ._type = unionInit(Element.Svg.Type, child_ptr),
        });
        return child_ptr;
    }

    // Our union type fields are usually pointers. But, at the leaf, they
    // can be struct (if all they contain is the `_proto` field, then we might
    // as well store it directly in the struct).
    const svg = try self.element(Element.Svg{
        ._proto = undefined,
        ._tag_name = tag_name_str,
        ._type = unionInit(Element.Svg.Type, child),
    });
    const field_name = comptime unionFieldName(Element.Svg.Type, @TypeOf(child));
    var child_ptr = &@field(svg._type, field_name);
    child_ptr._proto = svg;
    return child_ptr;
}

// this is a root object
pub fn event(self: *Factory, typ: []const u8, child: anytype) !*@TypeOf(child) {
    const child_ptr = try self.createT(@TypeOf(child));
    child_ptr.* = child;

    const e = try self.createT(Event);
    child_ptr._proto = e;
    e.* = .{
        ._type = unionInit(Event.Type, child_ptr),
        ._type_string = try String.init(self._page.arena, typ, .{}),
    };
    return child_ptr;
}

pub fn xhrEventTarget(self: *Factory, child: anytype) !*@TypeOf(child) {
    const et = try self.eventTarget(XMLHttpRequestEventTarget{
        ._proto = undefined,
        ._type = unionInit(XMLHttpRequestEventTarget.Type, child),
    });
    const field_name = comptime unionFieldName(XMLHttpRequestEventTarget.Type, @TypeOf(child));
    var child_ptr = &@field(et._type, field_name);
    child_ptr._proto = et;
    return child_ptr;
}

pub fn blob(self: *Factory, child: anytype) !*@TypeOf(child) {
    const child_ptr = try self.createT(@TypeOf(child));
    child_ptr.* = child;

    const b = try self.createT(Blob);
    child_ptr._proto = b;
    b.* = .{
        ._type = unionInit(Blob.Type, child_ptr),
        .slice = "",
        .mime = "",
    };
    return child_ptr;
}

pub fn create(self: *Factory, value: anytype) !*@TypeOf(value) {
    const ptr = try self.createT(@TypeOf(value));
    ptr.* = value;
    return ptr;
}

pub fn createT(self: *Factory, comptime T: type) !*T {
    const allocator = self._slab.allocator();
    return try allocator.create(T);
}

pub fn destroy(self: *Factory, value: anytype) void {
    const S = reflect.Struct(@TypeOf(value));
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

    self.destroyChain(value, true);
}

fn destroyChain(self: *Factory, value: anytype, comptime first: bool) void {
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
        self.destroyChain(value._proto, false);
    } else if (@hasDecl(S, "JsApi")) {
        // Doesn't have a _proto, but has a JsApi.
        if (self._page.js.removeTaggedMapping(@intFromPtr(value))) |tagged| {
            allocator.destroy(tagged);
        }
    }

    // Leaf types are allowed by be placed directly within their _proto
    // (which makes sense when the @sizeOf(Leaf) == 8). These don't need to
    // be (cannot be) freed. But we'll still free the chain.
    if (comptime wasAllocated(S)) {
        allocator.destroy(value);
    }
}

fn wasAllocated(comptime S: type) bool {
    // Whether it's heap allocate or not, we should have a pointer.
    // (If it isn't heap allocated, it'll be a pointer from the proto's type
    // e.g. &html._type.title)
    if (!@hasField(S, "_proto")) {
        // a root is always on the heap.
        return true;
    }

    // the _proto type
    const P = reflect.Struct(std.meta.fieldInfo(S, ._proto).type);

    // the _proto._type type (the parent's _type union)
    const U = std.meta.fieldInfo(P, ._type).type;
    inline for (@typeInfo(U).@"union".fields) |field| {
        if (field.type == S) {
            // One of the types in the proto's _type union is this non-pointer
            // structure, so it isn't heap allocted.
            return false;
        }
    }
    return true;
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

fn fieldIsPointer(comptime T: type, comptime V: type) bool {
    inline for (@typeInfo(T).@"union".fields) |field| {
        if (field.type == V) {
            return false;
        }
        if (field.type == *V) {
            return true;
        }
    }
    @compileError(@typeName(V) ++ " is not a valid type for " ++ @typeName(T) ++ ".type");
}
