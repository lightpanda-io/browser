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
//
// When a reaction is enqueued without an active scope (e.g. a Web API path
// that wasn't tagged `.ce_reactions = true`, or a non-WebIDL entry point),
// it goes on the backup queue instead and a microtask is scheduled to drain
// it. This matches the spec's "backup element queue" so missing bridge tags
// degrade to delayed reactions rather than crashes.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("Frame.zig");
const Element = @import("webapi/Element.zig");
const Document = @import("webapi/Document.zig");
const Custom = @import("webapi/element/html/Custom.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Self = @This();

allocator: Allocator,
queue: std.ArrayList(Reaction) = .empty,

backup_scheduled: bool = false,
backup_queue: std.ArrayList(Reaction) = .empty,

// Number of currently-open scopes (push() that hasn't been pop'd). When 0,
// enqueues route to the backup queue and rely on a microtask to drain.
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
    // Index, not slice: firing a reaction can recursively enqueue (via JS
    // callbacks doing DOM mutations), which may realloc queue.items and
    // invalidate any captured slice.
    var i = checkpoint;
    while (i < self.queue.items.len) : (i += 1) {
        Custom.fireReaction(self.queue.items[i], frame);
    }
    self.queue.items.len = checkpoint;
    self.active_scopes -= 1;
}

/// Drain the backup queue. Called from the scheduled microtask. `backup_scheduled`
/// stays true while draining so new enqueues append to backup_queue and get picked
/// up by the same loop instead of scheduling a redundant microtask.
pub fn drainBackup(self: *Self, frame: *Frame) void {
    var i: usize = 0;
    while (i < self.backup_queue.items.len) : (i += 1) {
        Custom.fireReaction(self.backup_queue.items[i], frame);
    }
    self.backup_queue.clearRetainingCapacity();
    self.backup_scheduled = false;
}

fn route(self: *Self, frame: *Frame, reaction: Reaction) !void {
    if (self.active_scopes > 0) {
        try self.queue.append(self.allocator, reaction);
        return;
    }
    if (comptime IS_DEBUG) {
        lp.log.err(.bug, "custom element scope", .{ .note = "Missing explicit reaction scope, using fallback. This log is only generated in debug builds." });
    }
    try self.backup_queue.append(self.allocator, reaction);
    if (!self.backup_scheduled) {
        try frame.scheduleCustomElementBackupDrain();
        self.backup_scheduled = true;
    }
}

pub fn enqueueConnected(self: *Self, frame: *Frame, element: *Element) !void {
    try self.route(frame, .{ .connected = element });
}

pub fn enqueueMove(self: *Self, frame: *Frame, element: *Element) !void {
    try self.route(frame, .{ .move = element });
}

pub fn enqueueDisconnected(self: *Self, frame: *Frame, element: *Element) !void {
    try self.route(frame, .{ .disconnected = element });
}

pub fn enqueueAdopted(self: *Self, frame: *Frame, element: *Element, old_document: *Document, new_document: *Document) !void {
    try self.route(frame, .{ .adopted = .{
        .element = element,
        .old_document = old_document,
        .new_document = new_document,
    } });
}

pub fn enqueueAttributeChanged(
    self: *Self,
    frame: *Frame,
    element: *Element,
    name: String,
    old_value: ?String,
    new_value: ?String,
    namespace: ?String,
) !void {
    try self.route(frame, .{ .attribute_changed = .{
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
    move: *Element,
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
