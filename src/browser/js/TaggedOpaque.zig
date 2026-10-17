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

const js = @import("js.zig");

const reflect = @import("../reflect.zig");
const Factory = @import("../Factory.zig");

const v8 = js.v8;
const bridge = js.bridge;
const JsApis = bridge.JsApis;
const JsApiLookup = bridge.JsApiLookup;
const Allocator = std.mem.Allocator;

// When we return a Zig object to V8, we put it on the heap and pass it into
// v8 as an *anyopaque (i.e. void *). When V8 gives us back the value, say, as a
// function parameter, we know what type it _should_ be.
//
// In a simple/perfect world, we could use this knowledge to cast the *anyopaque
// to the parameter type:
//   const arg: @typeInfo(@TypeOf(function)).@"fn".param_types[0].? = @ptrCast(v8_data);
//
// But there are 2 reasons we can't do that.
//
// == Reason 1 ==
// The JS code might pass the wrong type:
//
//   var cat = new Cat();
//   cat.setOwner(new Cat());
//
// The zig_setOwner method expects the 2nd parameter to be an *Owner, but
// the JS code passed a *Cat.
//
// To solve this issue, we tag every returned value so that we can check what
// type it is. In the above case, we'd expect an *Owner, but the tag would tell
// us that we got a *Cat.
//
// == Reason 2 ==
// Because of prototype inheritance, even "correct" code can be a challenge. For
// example, say the above JavaScript is fixed:
//
//   var cat = new Cat();
//   cat.setOwner(new Owner("Leto"));
//
// The issue is that setOwner might not expect an *Owner, but rather a
// *Person, which is the prototype for Owner. Now our Zig code is expecting
// a *Person, but it was (correctly) given an *Owner.
//
// == How we solve both ==
// The tag is a `rank`: every JsApi type is numbered in depth-first order over
// the inheritance tree, so a type and all of its descendants get one
// contiguous block of ranks:
//
//   EventTarget              0  [0, 6)
//     Node                   1  [1, 5)
//       Element              2  [2, 4)
//         HTMLElement        3  [3, 4)
//       Document             4  [4, 5)
//     Window                 5  [5, 6)
//
// If the JsObject represents an HTMLElement, the stored rank will be 3. If
// we're trying to call a method in Window, it'll fail because 3 isn't in [5-6),
// the window's prototype chain. But, if we're trying to call a method on Node,
// it'll be allowed because HTMLElement *is* in the Node's range of [1,5).
// Or:  T.lo <= rank < T.lo+count.
//
// That answers the "is it a T" question. But we need to actually turn it into
// T (e.g. the HTMLElement into a Node). This is simple pointer math since our
// Factory allocates the whole chain in one block. We store the base address
// (e.g. the address of the EventTarget) and know the offset between that and
// the target (e.g. the Node). Factory.chainOffsetOf is used throughout the code
// for this purpose.
const TaggedOpaque = @This();

// Address of the start of the instance's prototype chain allocation (where
// the root prototype lives), e.g. the address of EventTarget for an Anchor.
base: usize,

// The instance's most specific type, as a rank (see above).
rank: Rank,

const Rank = u16;

// Tag for an instance of T, where T is the most specific type of value.
pub fn init(comptime T: type, value: *T) TaggedOpaque {
    return .{
        .base = @intFromPtr(value) - comptime Factory.chainOffsetOf(T, T),
        .rank = comptime rangeOf(T).lo,
    };
}

// Reverses the mapZigInstanceToJs, making sure that our TaggedOpaque
// contains a ptr to the correct type.
pub fn fromJS(comptime R: type, js_obj_handle: *const v8.Object) !R {
    const ti = @typeInfo(R);
    if (ti != .pointer) {
        @compileError("non-pointer Zig parameter type: " ++ @typeName(R));
    }

    const T = ti.pointer.child;
    const JsApi = bridge.Struct(T).JsApi;

    if (@hasDecl(JsApi.Meta, "empty_with_no_proto")) {
        // Empty structs aren't stored as TOAs and there's no data
        // stored in the JSObject's IntenrnalField. Why bother when
        // we can just return an empty struct here?
        return @constCast(@as(*const T, &.{}));
    }

    const tao = fromObject(js_obj_handle) orelse return error.InvalidArgument;
    return tao.as(T) orelse error.InvalidArgument;
}

// We create a TAO for every Zig -> v8.Object and every time a function/accessor
// is called on that v8.Object, we need to turn the v8.Object -> Zig via the
// TAO. The TAO is a ptr and u16. The mechanism for this link the v8.Object's
// InternalField, which lets us stuff a usize into N fields. Givent hat TAO is
// base addr (usize) + rank (u16), that leaves us with 3 options:
// 1 - bit stuff it in a single InternalField
// 2 - use 2 internal fields
// 3 - heap allocate and store the heap-allocated address in 1 internal field.
//
// Historically, we did #3.
// We now use #1 and fallback to #3 (and, realistically, we expect #1 to almost
// always be used). Specifically, when the base addr fits in 48 bits, we pack it
// with the the rank and use a bit to indicate this is a compact representation.
// Else, the TAO is heap-allocated:

//   compact:   [ rank:16 | base:46 | 1 | 0 ]   (no allocation)
//   expanded:  pointer to a TaggedOpaque        (allocated in `arena`)
//
// Put differently, compact is what we normally get: user-space addresses fit in
// 48 bits and base is at least 4-byte aligned, which leaves bit 1 free for the
// flag. Expanded is the fallback for when either isn't true. Bit 0 stays clear
// in both forms: V8 requires internal field pointers to be 2-byte aligned.
const compact_flag: usize = 0b10;
const address_bits = 48;
const address_mask: usize = (1 << address_bits) - 1;

// Store the tag into a JS object's internal field.
pub fn store(self: TaggedOpaque, js_obj_handle: *const v8.Object, arena: Allocator) !void {
    const raw = self.compact() orelse blk: {
        // Use the identity arena so the TAO survives context destruction: V8
        // objects are stored in identity_map (session-level) and may be
        // referenced after their creating context is destroyed (e.g., via
        // microtasks).
        const tao = try arena.create(TaggedOpaque);
        tao.* = self;
        break :blk @intFromPtr(tao);
    };
    v8.v8__Object__SetAlignedPointerInInternalField(js_obj_handle, 0, @ptrFromInt(raw));
}

// Read the tag back from a JS object. Null if it isn't one of ours.
pub fn fromObject(js_obj_handle: *const v8.Object) ?TaggedOpaque {
    if (v8.v8__Object__InternalFieldCount(js_obj_handle) == 0) {
        return null;
    }
    const ptr = v8.v8__Object__GetAlignedPointerFromInternalField(js_obj_handle, 0) orelse return null;
    return decode(@intFromPtr(ptr));
}

fn compact(self: TaggedOpaque) ?usize {
    if (self.base & 0b11 != 0 or self.base & ~address_mask != 0) {
        return null;
    }
    return self.base | compact_flag | (@as(usize, self.rank) << address_bits);
}

fn decode(raw: usize) ?TaggedOpaque {
    if (raw & compact_flag != 0) {
        return .{
            .base = raw & address_mask & ~@as(usize, 0b11),
            .rank = @intCast(raw >> address_bits),
        };
    }
    if (raw % @alignOf(TaggedOpaque) != 0) {
        return null;
    }
    const tao: *const TaggedOpaque = @ptrFromInt(raw);
    return tao.*;
}

// Whether the instance is a T: its own type, or one it inherits from.
pub fn is(self: TaggedOpaque, comptime T: type) bool {
    const range = comptime rangeOf(T);
    // One compare covers both bounds: when rank < lo the subtraction wraps
    // around to a huge number.
    return @as(u32, self.rank) -% range.lo < range.count;
}

// The instance as a T: its own type, or one it inherits from. Null otherwise.
pub fn as(self: TaggedOpaque, comptime T: type) ?*T {
    if (self.is(T) == false) {
        return null;
    }
    return @ptrFromInt(self.base + comptime Factory.chainOffsetOf(T, T));
}

// The block of ranks owned by a type: its own rank (lo) followed by all
// of its descendants.
const Range = struct {
    lo: Rank,
    count: Rank,
};

fn rangeOf(comptime T: type) Range {
    const JsApi = bridge.Struct(T).JsApi;
    if (!JsApiLookup.has(JsApi)) {
        @compileError("unknown Zig type: " ++ @typeName(T));
    }
    return ranges[JsApiLookup.getId(JsApi)];
}

// The JsApiLookup id of each JsApi's prototype, or null for a root.
const parents: [JsApis.len]?usize = blk: {
    @setEvalBranchQuota(100_000);
    var result: [JsApis.len]?usize = undefined;
    for (JsApis, 0..) |JsApi, i| {
        const Proto = reflect.Proto(JsApi.bridge.type) orelse {
            result[i] = null;
            continue;
        };
        result[i] = JsApiLookup.getId(Proto.JsApi);
    }
    break :blk result;
};

// Indexed by JsApiLookup id.
const ranges: [JsApis.len]Range = blk: {
    @setEvalBranchQuota(1_000_000);
    const N = JsApis.len;
    if (N > std.math.maxInt(Rank)) {
        @compileError("too many JsApis for TaggedOpaque.Rank");
    }

    // Each type's count is itself + all its descendants: walk up from every
    // type, adding 1 to itself and to each of its ancestors.
    var count: [N]Rank = @splat(0);
    var depth: [N]usize = undefined;
    var max_depth: usize = 0;
    for (0..N) |i| {
        var d: usize = 0;
        var current: ?usize = i;
        while (current) |c| : (current = parents[c]) {
            count[c] += 1;
            d += 1;
        }
        depth[i] = d;
        max_depth = @max(max_depth, d);
    }

    // Hand out ranks, parents before children (shallowest first). A type
    // takes the first free rank in its parent's block and reserves `count`
    // ranks for itself and its subtree. `next[i]` is the next free rank
    // inside type i's block.
    var result: [N]Range = undefined;
    var next: [N]Rank = undefined;
    var next_root: Rank = 0;
    for (1..max_depth + 1) |d| {
        for (0..N) |i| {
            if (depth[i] != d) {
                continue;
            }
            const lo = if (parents[i]) |p| blk2: {
                const lo = next[p];
                next[p] += count[i];
                break :blk2 lo;
            } else blk2: {
                const lo = next_root;
                next_root += count[i];
                break :blk2 lo;
            };
            result[i] = .{ .lo = lo, .count = count[i] };
            next[i] = lo + 1;
        }
    }
    break :blk result;
};

const testing = std.testing;
test "TaggedOpaque: ranges match the prototype chains" {
    // For every pair of types, the range check must agree with walking the
    // prototype chain.
    for (0..JsApis.len) |child| {
        const rank = ranges[child].lo;
        for (0..JsApis.len) |ancestor| {
            const range = ranges[ancestor];
            const in_range = rank >= range.lo and rank < range.lo + range.count;

            var current: ?usize = child;
            const in_chain = while (current) |c| : (current = parents[c]) {
                if (c == ancestor) break true;
            } else false;

            try testing.expectEqual(in_chain, in_range);
        }
    }
}

test "TaggedOpaque: compact form" {
    const tao: TaggedOpaque = .{ .base = 0x7fff_1234_5670, .rank = 700 };
    const raw = tao.compact().?;
    try testing.expectEqual(0, raw & 1);
    try testing.expectEqual(compact_flag, raw & compact_flag);
    try testing.expectEqual(tao, decode(raw).?);

    // largest rank, base at the top of the address range
    const edge: TaggedOpaque = .{ .base = address_mask & ~@as(usize, 0b11), .rank = std.math.maxInt(Rank) };
    try testing.expectEqual(edge, decode(edge.compact().?).?);
}

test "TaggedOpaque: expanded form" {
    // Addresses past 48 bits, or not 4-byte aligned, can't be compacted.
    try testing.expectEqual(null, (TaggedOpaque{ .base = 1 << 50, .rank = 1 }).compact());
    try testing.expectEqual(null, (TaggedOpaque{ .base = 0x1002, .rank = 1 }).compact());

    // Expanded: field 0 holds a pointer to the TAO itself.
    const tao: TaggedOpaque = .{ .base = 1 << 50, .rank = 42 };
    try testing.expectEqual(0, @intFromPtr(&tao) & compact_flag);
    try testing.expectEqual(tao, decode(@intFromPtr(&tao)).?);

    // Neither form: not one of ours.
    try testing.expectEqual(null, decode(0x1004));
}

test "TaggedOpaque: as" {
    const EventTarget = @import("../webapi/EventTarget.zig");
    const Node = @import("../webapi/Node.zig");
    const Element = @import("../webapi/Element.zig");
    const Document = @import("../webapi/Document.zig");
    const Html = Element.Html;

    const helpers = @import("../../testing.zig");
    const frame = try helpers.createFrame();
    defer helpers.test_session.closeAllPages();

    const element = try frame.document.createElement("div", null, frame);
    const div = element.as(Html.Div);

    const tao = init(Html.Div, div);
    // A real allocation is compact.
    try testing.expect(tao.compact() != null);
    try testing.expectEqual(div, tao.as(Html.Div).?);
    try testing.expectEqual(element.as(Html), tao.as(Html).?);
    try testing.expectEqual(element, tao.as(Element).?);
    try testing.expectEqual(element.asNode(), tao.as(Node).?);
    try testing.expectEqual(element.asEventTarget(), tao.as(EventTarget).?);
    try testing.expectEqual(null, tao.as(Document));
    try testing.expectEqual(null, tao.as(Html.Anchor));
}
