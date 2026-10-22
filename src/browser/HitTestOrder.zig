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

pub fn context(parent: ?*const HitTestOrder, z: i32, order: usize) HitTestOrder {
    return .{
        .parent = parent,
        .depth = if (parent) |p| p.depth + 1 else 0,
        .phase = if (z < 0) .negative else if (z > 0) .positive else .positioned,
        .z = z,
        .order = order,
    };
}

pub fn box(parent: ?*const HitTestOrder, positioned: bool, order: usize) HitTestOrder {
    var key = context(parent, 0, order);
    key.phase = if (positioned) .positioned else .normal;
    return key;
}

/// Lexicographic comparison of context paths, without recursion or copying
/// ancestor paths. A context's own box is before all of its descendants.
pub fn above(self: *const HitTestOrder, other: *const HitTestOrder) bool {
    var a = self;
    var b = other;
    while (a.depth > b.depth) a = a.parent.?;
    while (b.depth > a.depth) b = b.parent.?;
    if (a == b) return self.depth > other.depth;
    while (a.parent != b.parent) {
        a = a.parent.?;
        b = b.parent.?;
    }
    if (a.phase != b.phase) return @backingInt(a.phase) > @backingInt(b.phase);
    if (a.z != b.z) return a.z > b.z;
    return a.order > b.order;
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
    const normal = box(&root, false, 6);
    try std.testing.expect(normal.above(&negative));
    try std.testing.expect(negative.above(&root));
}
