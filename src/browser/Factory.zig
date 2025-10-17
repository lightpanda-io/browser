const std = @import("std");
const builtin = @import("builtin");
const reflect = @import("reflect.zig");
const IS_DEBUG = builtin.mode == .Debug;

const log = @import("../log.zig");
const String = @import("../string.zig").String;

const Page = @import("Page.zig");
const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const Element = @import("webapi/Element.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const XMLHttpRequestEventTarget = @import("webapi/net/XMLHttpRequestEventTarget.zig");

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
_size_1_8: MemoryPoolAligned([1]u8, .@"8"),
_size_8_8: MemoryPoolAligned([8]u8, .@"8"),
_size_16_8: MemoryPoolAligned([16]u8, .@"8"),
_size_24_8: MemoryPoolAligned([24]u8, .@"8"),
_size_32_8: MemoryPoolAligned([32]u8, .@"8"),
_size_32_16: MemoryPoolAligned([32]u8, .@"16"),
_size_40_8: MemoryPoolAligned([40]u8, .@"8"),
_size_48_16: MemoryPoolAligned([48]u8, .@"16"),
_size_56_8: MemoryPoolAligned([56]u8, .@"8"),
_size_64_16: MemoryPoolAligned([64]u8, .@"16"),
_size_72_8: MemoryPoolAligned([72]u8, .@"8"),
_size_80_16: MemoryPoolAligned([80]u8, .@"16"),
_size_88_8: MemoryPoolAligned([88]u8, .@"8"),
_size_96_16: MemoryPoolAligned([96]u8, .@"16"),
_size_104_8: MemoryPoolAligned([104]u8, .@"8"),
_size_112_8: MemoryPoolAligned([112]u8, .@"8"),
_size_120_8: MemoryPoolAligned([120]u8, .@"8"),
_size_128_8: MemoryPoolAligned([128]u8, .@"8"),
_size_144_8: MemoryPoolAligned([144]u8, .@"8"),
_size_456_8: MemoryPoolAligned([456]u8, .@"8"),
_size_520_8: MemoryPoolAligned([520]u8, .@"8"),
_size_648_8: MemoryPoolAligned([648]u8, .@"8"),

pub fn init(page: *Page) Factory {
    return .{
        ._page = page,
        ._size_1_8 = MemoryPoolAligned([1]u8, .@"8").init(page.arena),
        ._size_8_8 = MemoryPoolAligned([8]u8, .@"8").init(page.arena),
        ._size_16_8 = MemoryPoolAligned([16]u8, .@"8").init(page.arena),
        ._size_24_8 = MemoryPoolAligned([24]u8, .@"8").init(page.arena),
        ._size_32_8 = MemoryPoolAligned([32]u8, .@"8").init(page.arena),
        ._size_32_16 = MemoryPoolAligned([32]u8, .@"16").init(page.arena),
        ._size_40_8 = MemoryPoolAligned([40]u8, .@"8").init(page.arena),
        ._size_48_16 = MemoryPoolAligned([48]u8, .@"16").init(page.arena),
        ._size_56_8 = MemoryPoolAligned([56]u8, .@"8").init(page.arena),
        ._size_64_16 = MemoryPoolAligned([64]u8, .@"16").init(page.arena),
        ._size_72_8 = MemoryPoolAligned([72]u8, .@"8").init(page.arena),
        ._size_80_16 = MemoryPoolAligned([80]u8, .@"16").init(page.arena),
        ._size_88_8 = MemoryPoolAligned([88]u8, .@"8").init(page.arena),
        ._size_96_16 = MemoryPoolAligned([96]u8, .@"16").init(page.arena),
        ._size_104_8 = MemoryPoolAligned([104]u8, .@"8").init(page.arena),
        ._size_112_8 = MemoryPoolAligned([112]u8, .@"8").init(page.arena),
        ._size_120_8 = MemoryPoolAligned([120]u8, .@"8").init(page.arena),
        ._size_128_8 = MemoryPoolAligned([128]u8, .@"8").init(page.arena),
        ._size_144_8 = MemoryPoolAligned([144]u8, .@"8").init(page.arena),
        ._size_456_8 = MemoryPoolAligned([456]u8, .@"8").init(page.arena),
        ._size_520_8 = MemoryPoolAligned([520]u8, .@"8").init(page.arena),
        ._size_648_8 = MemoryPoolAligned([648]u8, .@"8").init(page.arena),
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
    const tag_name_str = String.init(undefined, tag_name, .{}) catch unreachable;

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

pub fn create(self: *Factory, value: anytype) !*@TypeOf(value) {
    const ptr = try self.createT(@TypeOf(value));
    ptr.* = value;
    return ptr;
}

pub fn createT(self: *Factory, comptime T: type) !*T {
    const SO = @sizeOf(T);
    if (comptime SO == 1) return @ptrCast(try self._size_1_8.create());
    if (comptime SO == 8) return @ptrCast(try self._size_8_8.create());
    if (comptime SO == 16) return @ptrCast(try self._size_16_8.create());
    if (comptime SO == 24) return @ptrCast(try self._size_24_8.create());
    if (comptime SO == 32) {
        if (comptime @alignOf(T) == 8) return @ptrCast(try self._size_32_8.create());
        if (comptime @alignOf(T) == 16) return @ptrCast(try self._size_32_16.create());
    }
    if (comptime SO == 40) return @ptrCast(try self._size_40_8.create());
    if (comptime SO == 48) return @ptrCast(try self._size_48_16.create());
    if (comptime SO == 56) return @ptrCast(try self._size_56_8.create());
    if (comptime SO == 64) return @ptrCast(try self._size_64_16.create());
    if (comptime SO == 72) return @ptrCast(try self._size_72_8.create());
    if (comptime SO == 80) return @ptrCast(try self._size_80_16.create());
    if (comptime SO == 88) return @ptrCast(try self._size_88_8.create());
    if (comptime SO == 96) return @ptrCast(try self._size_96_16.create());
    if (comptime SO == 104) return @ptrCast(try self._size_104_8.create());
    if (comptime SO == 112) return @ptrCast(try self._size_112_8.create());
    if (comptime SO == 120) return @ptrCast(try self._size_120_8.create());
    if (comptime SO == 128) return @ptrCast(try self._size_128_8.create());
    if (comptime SO == 144) return @ptrCast(try self._size_144_8.create());
    if (comptime SO == 456) return @ptrCast(try self._size_456_8.create());
    if (comptime SO == 520) return @ptrCast(try self._size_520_8.create());
    if (comptime SO == 648) return @ptrCast(try self._size_648_8.create());
    @compileError(std.fmt.comptimePrint("No pool configured for @sizeOf({d}), @alignOf({d}): ({s})", .{ SO, @alignOf(T), @typeName(T) }));
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
            self._size_24_8.destroy(@ptrCast(tagged));
        }
    }

    // Leaf types are allowed by be placed directly within their _proto
    // (which makes sense when the @sizeOf(Leaf) == 8). These don't need to
    // be (cannot be) freed. But we'll still free the chain.
    if (comptime wasAllocated(S)) {
        switch (@sizeOf(S)) {
            1 => self._size_1_8.destroy(@ptrCast(@alignCast(value))),
            8 => self._size_8_8.destroy(@ptrCast(@alignCast(value))),
            16 => self._size_16_8.destroy(@ptrCast(value)),
            24 => self._size_24_8.destroy(@ptrCast(value)),
            32 => {
                if (comptime @alignOf(S) == 8) {
                    self._size_32_8.destroy(@ptrCast(value));
                } else if (comptime @alignOf(S) == 16) {
                    self._size_32_16.destroy(@ptrCast(value));
                }
            },
            40 => self._size_40_8.destroy(@ptrCast(value)),
            48 => self._size_48_16.destroy(@ptrCast(@alignCast(value))),
            56 => self._size_56_8.destroy(@ptrCast(value)),
            64 => self._size_64_16.destroy(@ptrCast(@alignCast(value))),
            72 => self._size_72_8.destroy(@ptrCast(@alignCast(value))),
            80 => self._size_80_16.destroy(@ptrCast(@alignCast(value))),
            88 => self._size_88_8.destroy(@ptrCast(@alignCast(value))),
            96 => self._size_96_16.destroy(@ptrCast(@alignCast(value))),
            104 => self._size_104_8.destroy(@ptrCast(value)),
            112 => self._size_112_8.destroy(@ptrCast(value)),
            120 => self._size_120_8.destroy(@ptrCast(value)),
            128 => self._size_128_8.destroy(@ptrCast(value)),
            144 => self._size_144_8.destroy(@ptrCast(value)),
            456 => self._size_456_8.destroy(@ptrCast(value)),
            520 => self._size_520_8.destroy(@ptrCast(value)),
            648 => self._size_648_8.destroy(@ptrCast(value)),
            else => |SO| @compileError(std.fmt.comptimePrint("Don't know what I'm being asked to destroy @sizeOf({d}), @alignOf({d}): ({s})", .{ SO, @alignOf(S), @typeName(S) })),
        }
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
