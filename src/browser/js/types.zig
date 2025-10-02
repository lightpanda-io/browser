const std = @import("std");

const generate = @import("generate.zig");

const Interfaces = generate.Tuple(.{
    @import("../crypto/crypto.zig").Crypto,
    @import("../console/console.zig").Console,
    @import("../css/css.zig").Interfaces,
    @import("../cssom/cssom.zig").Interfaces,
    @import("../dom/dom.zig").Interfaces,
    @import("../dom/shadow_root.zig").ShadowRoot,
    @import("../encoding/encoding.zig").Interfaces,
    @import("../events/event.zig").Interfaces,
    @import("../html/html.zig").Interfaces,
    @import("../iterator/iterator.zig").Interfaces,
    @import("../storage/storage.zig").Interfaces,
    @import("../url/url.zig").Interfaces,
    @import("../xhr/xhr.zig").Interfaces,
    @import("../xhr/form_data.zig").Interfaces,
    @import("../xhr/File.zig"),
    @import("../xmlserializer/xmlserializer.zig").Interfaces,
    @import("../fetch/fetch.zig").Interfaces,
    @import("../streams/streams.zig").Interfaces,
});

pub const Types = @typeInfo(Interfaces).@"struct".fields;

// Imagine we have a type Cat which has a getter:
//
//    fn get_owner(self: *Cat) *Owner {
//        return self.owner;
//    }
//
// When we execute caller.getter, we'll end up doing something like:
//   const res = @call(.auto, Cat.get_owner, .{cat_instance});
//
// How do we turn `res`, which is an *Owner, into something we can return
// to v8? We need the ObjectTemplate associated with Owner. How do we
// get that? Well, we store all the ObjectTemplates in an array that's
// tied to env. So we do something like:
//
//    env.templates[index_of_owner].initInstance(...);
//
// But how do we get that `index_of_owner`? `Lookup` is a struct
// that looks like:
//
// const Lookup = struct {
//     comptime cat: usize = 0,
//     comptime owner: usize = 1,
//     ...
// }
//
// So to get the template index of `owner`, we can do:
//
//  const index_id = @field(type_lookup, @typeName(@TypeOf(res));
//
pub const Lookup = blk: {
    var fields: [Types.len]std.builtin.Type.StructField = undefined;
    for (Types, 0..) |s, i| {

        // This prototype type check has nothing to do with building our
        // Lookup. But we put it here, early, so that the rest of the
        // code doesn't have to worry about checking if Struct.prototype is
        // a pointer.
        const Struct = s.defaultValue().?;
        if (@hasDecl(Struct, "prototype") and @typeInfo(Struct.prototype) != .pointer) {
            @compileError(std.fmt.comptimePrint("Prototype '{s}' for type '{s} must be a pointer", .{ @typeName(Struct.prototype), @typeName(Struct) }));
        }

        fields[i] = .{
            .name = @typeName(Receiver(Struct)),
            .type = usize,
            .is_comptime = true,
            .alignment = @alignOf(usize),
            .default_value_ptr = &i,
        };
    }
    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .decls = &.{},
        .is_tuple = false,
        .fields = &fields,
    } });
};

pub const LOOKUP = Lookup{};

// Creates a list where the index of a type contains its prototype index
//   const Animal = struct{};
//   const Cat = struct{
//       pub const prototype = *Animal;
// };
//
// Would create an array: [0, 0]
// Animal, at index, 0, has no prototype, so we set it to itself
// Cat, at index 1, has an Animal prototype, so we set it to 0.
//
// When we're trying to pass an argument to a Zig function, we'll know the
// target type (the function parameter type), and we'll have a
// TaggedAnyOpaque which will have the index of the type of that parameter.
// We'll use the PROTOTYPE_TABLE to see if the TaggedAnyType should be
// cast to a prototype.
pub const PROTOTYPE_TABLE = blk: {
    var table: [Types.len]u16 = undefined;
    for (Types, 0..) |s, i| {
        var prototype_index = i;
        const Struct = s.defaultValue().?;
        if (@hasDecl(Struct, "prototype")) {
            const TI = @typeInfo(Struct.prototype);
            const proto_name = @typeName(Receiver(TI.pointer.child));
            prototype_index = @field(LOOKUP, proto_name);
        }
        table[i] = prototype_index;
    }
    break :blk table;
};

// This is essentially meta data for each type. Each is stored in env.meta_lookup
// The index for a type can be retrieved via:
//   const index = @field(TYPE_LOOKUP, @typeName(Receiver(Struct)));
//   const meta = env.meta_lookup[index];
pub const Meta = struct {
    // Every type is given a unique index. That index is used to lookup various
    // things, i.e. the prototype chain.
    index: u16,

    // We store the type's subtype here, so that when we create an instance of
    // the type, and bind it to JavaScript, we can store the subtype along with
    // the created TaggedAnyOpaque.s
    subtype: ?Sub,

    // If this type has composition-based prototype, represents the byte-offset
    // from ptr where the `proto` field is located. A negative offsets is used
    // to indicate that the prototype field is behind a pointer.
    proto_offset: i32,
};

pub const Sub = enum {
    @"error",
    array,
    arraybuffer,
    dataview,
    date,
    generator,
    iterator,
    map,
    node,
    promise,
    proxy,
    regexp,
    set,
    typedarray,
    wasmvalue,
    weakmap,
    weakset,
    webassemblymemory,
};

// When we map a Zig instance into a JsObject, we'll normally store the a
// TaggedAnyOpaque (TAO) inside of the JsObject's internal field. This requires
// ensuring that the instance template has an InternalFieldCount of 1. However,
// for empty objects, we don't need to store the TAO, because we can't just cast
// one empty object to another, so for those, as an optimization, we do not set
// the InternalFieldCount.
pub fn isEmpty(comptime T: type) bool {
    return @typeInfo(T) != .@"opaque" and @sizeOf(T) == 0 and @hasDecl(T, "js_legacy_factory") == false;
}

// If we have a struct:
// const Cat = struct {
//    pub fn meow(self: *Cat) void { ... }
// }
// Then obviously, the receiver of its methods are going to be a *Cat (or *const Cat)
//
// However, we can also do:
// const Cat = struct {
//    pub const Self = OtherImpl;
//    pub fn meow(self: *OtherImpl) void { ... }
// }
// In which case, as we see above, the receiver is derived from the Self declaration
pub fn Receiver(comptime Struct: type) type {
    return if (@hasDecl(Struct, "Self")) Struct.Self else Struct;
}
