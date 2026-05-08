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

// Implements the spec's "custom element reactions" mechanism: callbacks
// (connectedCallback, disconnectedCallback, adoptedCallback,
// attributeChangedCallback) are enqueued during DOM mutation and invoked at
// the outer algorithm boundary, not synchronously mid-mutation.
//
// The "stack of element queues" is collapsed to a single flat ArrayList plus
// per-scope checkpoint indices: push() captures items.len, popAndInvoke()
// drains items[checkpoint..] and truncates. Nested scopes work naturally —
// inside a callback, a new scope captures its own checkpoint past the current
// length, drains its own range, and the outer iteration continues from where
// it left off.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("Frame.zig");
const Element = @import("webapi/Element.zig");
const Document = @import("webapi/Document.zig");
const Custom = @import("webapi/element/html/Custom.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const Self = @This();

allocator: Allocator,
queue: std.ArrayList(Reaction) = .empty,
// Number of currently-open scopes (push() that hasn't been pop'd). Every
// enqueue must happen inside a scope — that's the leak-detection invariant.
// Checked in debug at enqueue time so leaks surface where the bug is, not
// later at some unrelated boundary.
active_scopes: u32 = 0,

/// Open a new reactions scope. Returns a checkpoint to be passed to popAndInvoke.
pub fn push(self: *Self) usize {
    self.active_scopes += 1;
    return self.queue.items.len;
}

/// Drain reactions queued at indices >= checkpoint, then truncate. Reactions
/// enqueued within a nested scope drain at that scope's pop, before this loop
/// sees them.
pub fn popAndInvoke(self: *Self, checkpoint: usize, frame: *Frame) void {
    for (self.queue.items[checkpoint..]) |reaction| {
        Custom.fireReaction(reaction, frame);
    }
    self.queue.items.len = checkpoint;
    self.active_scopes -= 1;
}

inline fn assertScopeActive(self: *const Self) void {
    lp.assert(self.active_scopes > 0, "ce_reactions enqueue without active scope", .{});
}

pub fn enqueueConnected(self: *Self, element: *Element) !void {
    self.assertScopeActive();
    try self.queue.append(self.allocator, .{ .connected = element });
}

pub fn enqueueDisconnected(self: *Self, element: *Element) !void {
    self.assertScopeActive();
    try self.queue.append(self.allocator, .{ .disconnected = element });
}

pub fn enqueueAdopted(self: *Self, element: *Element, old_document: *Document, new_document: *Document) !void {
    self.assertScopeActive();
    try self.queue.append(self.allocator, .{ .adopted = .{
        .element = element,
        .old_document = old_document,
        .new_document = new_document,
    } });
}

pub fn enqueueAttributeChanged(
    self: *Self,
    element: *Element,
    name: String,
    old_value: ?String,
    new_value: ?String,
    namespace: ?String,
) !void {
    self.assertScopeActive();
    try self.queue.append(self.allocator, .{ .attribute_changed = .{
        .name = name,
        .element = element,
        .old_value = old_value,
        .new_value = new_value,
        .namespace = namespace,
    } });
}

pub const Reaction = union(enum) {
    connected: *Element,
    disconnected: *Element,
    adopted: Adopted,
    attribute_changed: AttributeChanged,

    pub const Adopted = struct {
        element: *Element,
        old_document: *Document,
        new_document: *Document,
    };

    pub const AttributeChanged = struct {
        element: *Element,
        name: String,
        old_value: ?String,
        new_value: ?String,
        namespace: ?String,
    };
};
