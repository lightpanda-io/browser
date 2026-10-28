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

/// An approximate paint-order key within one stacking context. Contexts form
/// a linked tree, not a global z-index sort: descendants cannot escape the
/// ancestor context even when their own z-index is very large.
const HitTestOrder = @This();
parent: ?*const HitTestOrder = null,
depth: usize = 0,
phase: enum { negative, normal, positioned, positive } = .normal,
z: i32 = 0,
order: usize = 0,
jump: ?*const HitTestOrder = null,

pub fn context(parent: ?*const HitTestOrder, z: i32, order: usize) HitTestOrder {
    return .{
        .parent = parent,
        .depth = if (parent) |p| p.depth + 1 else 0,
        .phase = if (z < 0) .negative else if (z > 0) .positive else .positioned,
        .z = z,
        .order = order,
        .jump = if (parent) |p| blk: {
            const first = p.jump orelse break :blk p;
            const second = first.jump orelse break :blk p;
            break :blk if (p.depth - first.depth == first.depth - second.depth) second else p;
        } else null,
    };
}

pub fn box(parent: ?*const HitTestOrder, order: usize) HitTestOrder {
    var key = context(parent, 0, order);
    key.phase = .normal;
    return key;
}

/// Lexicographic comparison of context paths, without recursion or copying
/// ancestor paths. A context's own box is before all of its descendants.
pub fn above(self: *const HitTestOrder, other: *const HitTestOrder) bool {
    var a = self.ancestorAtDepth(@min(self.depth, other.depth));
    var b = other.ancestorAtDepth(a.depth);
    if (a == b) return self.depth > other.depth;
    while (a.parent != b.parent) {
        if (a.jump != b.jump) {
            a = a.jump.?;
            b = b.jump.?;
        } else {
            a = a.parent.?;
            b = b.parent.?;
        }
    }
    if (a.phase != b.phase) return @backingInt(a.phase) > @backingInt(b.phase);
    if (a.z != b.z) return a.z > b.z;
    return a.order > b.order;
}

// Equal-length adjacent jumps combine on push. One extra pointer per key
// lets both depth alignment and common-ancestor discovery skip whole paths.
fn ancestorAtDepth(self: *const HitTestOrder, depth: usize) *const HitTestOrder {
    var key = self;
    while (key.depth > depth) {
        const jump = key.jump.?;
        key = if (jump.depth >= depth) jump else key.parent.?;
    }
    return key;
}

test "HitTestOrder: contexts are atomic and ancestors paint first" {
    const root = context(null, 0, 0);
    const front = context(&root, 2, 1);
    const back = context(&root, 1, 2);
    const deep = context(&back, 999, 3);
    const deeper = context(&deep, 1000, 4);
    try std.testing.expect(front.above(&deeper));
    try std.testing.expect(!deeper.above(&front));
    try std.testing.expect(deeper.above(&back));
    try std.testing.expect(!back.above(&deeper));
    const negative = context(&root, -1, 5);
    const normal = box(&root, 6);
    try std.testing.expect(normal.above(&negative));
    try std.testing.expect(negative.above(&root));
}

test "HitTestOrder: jumps preserve ancestry and deep branch ordering" {
    const root = context(null, 0, 0);
    var front: [512]HitTestOrder = undefined;
    var back: [512]HitTestOrder = undefined;
    for (0..front.len) |i| {
        front[i] = context(if (i == 0) &root else &front[i - 1], if (i == 0) 2 else 0, i + 1);
        back[i] = context(if (i == 0) &root else &back[i - 1], if (i == 0) 1 else 0, i + 513);
        for (0..i + 2) |depth| {
            const expected = if (depth == 0) &root else &front[depth - 1];
            try std.testing.expectEqual(expected, front[i].ancestorAtDepth(depth));
        }
        try std.testing.expect(front[i].above(&back[i]));
        try std.testing.expect(!back[i].above(&front[i]));
    }
    try std.testing.expect(front[511].above(&back[0]));
    try std.testing.expect(!back[0].above(&front[511]));
    try std.testing.expect(front[0].above(&back[511]));
    try std.testing.expect(!back[511].above(&front[0]));
}
