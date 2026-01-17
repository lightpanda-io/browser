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
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Node = @import("Node.zig");
const Element = @import("Element.zig");
const log = @import("../../log.zig");

pub fn registerTypes() []const type {
    return &.{
        MutationObserver,
        MutationRecord,
    };
}

const MutationObserver = @This();

_callback: js.Function.Global,
_observing: std.ArrayList(Observing) = .{},
_pending_records: std.ArrayList(*MutationRecord) = .{},
/// Intrusively linked to next element (see Page.zig).
node: std.DoublyLinkedList.Node = .{},

const Observing = struct {
    target: *Node,
    options: ObserveOptions,
};

pub const ObserveOptions = struct {
    attributes: bool = false,
    attributeOldValue: bool = false,
    childList: bool = false,
    characterData: bool = false,
    characterDataOldValue: bool = false,
    subtree: bool = false,
    attributeFilter: ?[]const []const u8 = null,
};

pub fn init(callback: js.Function.Global, page: *Page) !*MutationObserver {
    return page._factory.create(MutationObserver{
        ._callback = callback,
    });
}

pub fn observe(self: *MutationObserver, target: *Node, options: ObserveOptions, page: *Page) !void {
    // Deep copy attributeFilter if present
    var copied_options = options;
    if (options.attributeFilter) |filter| {
        const filter_copy = try page.arena.alloc([]const u8, filter.len);
        for (filter, 0..) |name, i| {
            filter_copy[i] = try page.arena.dupe(u8, name);
        }
        copied_options.attributeFilter = filter_copy;
    }

    if (options.characterDataOldValue) {
        copied_options.characterData = true;
    }

    // Check if already observing this target
    for (self._observing.items) |*obs| {
        if (obs.target == target) {
            obs.options = copied_options;
            return;
        }
    }

    // Register with page if this is our first observation
    if (self._observing.items.len == 0) {
        try page.registerMutationObserver(self);
    }

    try self._observing.append(page.arena, .{
        .target = target,
        .options = copied_options,
    });
}

pub fn disconnect(self: *MutationObserver, page: *Page) void {
    page.unregisterMutationObserver(self);
    self._observing.clearRetainingCapacity();
    self._pending_records.clearRetainingCapacity();
}

pub fn takeRecords(self: *MutationObserver, page: *Page) ![]*MutationRecord {
    const records = try page.call_arena.dupe(*MutationRecord, self._pending_records.items);
    self._pending_records.clearRetainingCapacity();
    return records;
}

// Called when an attribute changes on any element
pub fn notifyAttributeChange(
    self: *MutationObserver,
    target: *Element,
    attribute_name: []const u8,
    old_value: ?[]const u8,
    page: *Page,
) !void {
    const target_node = target.asNode();

    for (self._observing.items) |obs| {
        if (obs.target != target_node) {
            if (!obs.options.subtree) {
                continue;
            }
            if (!obs.target.contains(target_node)) {
                continue;
            }
        }
        if (!obs.options.attributes) {
            continue;
        }
        if (obs.options.attributeFilter) |filter| {
            for (filter) |name| {
                if (std.mem.eql(u8, name, attribute_name)) {
                    break;
                }
            } else {
                continue;
            }
        }

        const record = try page._factory.create(MutationRecord{
            ._type = .attributes,
            ._target = target_node,
            ._attribute_name = try page.arena.dupe(u8, attribute_name),
            ._old_value = if (obs.options.attributeOldValue and old_value != null)
                try page.arena.dupe(u8, old_value.?)
            else
                null,
            ._added_nodes = &.{},
            ._removed_nodes = &.{},
            ._previous_sibling = null,
            ._next_sibling = null,
        });

        try self._pending_records.append(page.arena, record);

        try page.scheduleMutationDelivery();
        break;
    }
}

// Called when character data changes on a text node
pub fn notifyCharacterDataChange(
    self: *MutationObserver,
    target: *Node,
    old_value: ?[]const u8,
    page: *Page,
) !void {
    for (self._observing.items) |obs| {
        if (obs.target != target) {
            if (!obs.options.subtree) {
                continue;
            }
            if (!obs.target.contains(target)) {
                continue;
            }
        }
        if (!obs.options.characterData) {
            continue;
        }

        const record = try page._factory.create(MutationRecord{
            ._type = .characterData,
            ._target = target,
            ._attribute_name = null,
            ._old_value = if (obs.options.characterDataOldValue and old_value != null)
                try page.arena.dupe(u8, old_value.?)
            else
                null,
            ._added_nodes = &.{},
            ._removed_nodes = &.{},
            ._previous_sibling = null,
            ._next_sibling = null,
        });

        try self._pending_records.append(page.arena, record);

        try page.scheduleMutationDelivery();
        break;
    }
}

// Called when children are added or removed from a node
pub fn notifyChildListChange(
    self: *MutationObserver,
    target: *Node,
    added_nodes: []const *Node,
    removed_nodes: []const *Node,
    previous_sibling: ?*Node,
    next_sibling: ?*Node,
    page: *Page,
) !void {
    for (self._observing.items) |obs| {
        if (obs.target != target) {
            if (!obs.options.subtree) {
                continue;
            }
            if (!obs.target.contains(target)) {
                continue;
            }
        }
        if (!obs.options.childList) {
            continue;
        }

        const record = try page._factory.create(MutationRecord{
            ._type = .childList,
            ._target = target,
            ._attribute_name = null,
            ._old_value = null,
            ._added_nodes = try page.arena.dupe(*Node, added_nodes),
            ._removed_nodes = try page.arena.dupe(*Node, removed_nodes),
            ._previous_sibling = previous_sibling,
            ._next_sibling = next_sibling,
        });

        try self._pending_records.append(page.arena, record);

        try page.scheduleMutationDelivery();
        break;
    }
}

pub fn deliverRecords(self: *MutationObserver, page: *Page) !void {
    if (self._pending_records.items.len == 0) {
        return;
    }

    // Take a copy of the records and clear the list before calling callback
    // This ensures mutations triggered during the callback go into a fresh list
    const records = try self.takeRecords(page);
    var caught: js.TryCatch.Caught = undefined;
    self._callback.local().tryCall(void, .{ records, self }, &caught) catch |err| {
        log.err(.page, "MutObserver.deliverRecords", .{ .err = err, .caught = caught });
        return err;
    };
}

pub const MutationRecord = struct {
    _type: Type,
    _target: *Node,
    _attribute_name: ?[]const u8,
    _old_value: ?[]const u8,
    _added_nodes: []const *Node,
    _removed_nodes: []const *Node,
    _previous_sibling: ?*Node,
    _next_sibling: ?*Node,

    pub const Type = enum {
        attributes,
        childList,
        characterData,
    };

    pub fn getType(self: *const MutationRecord) []const u8 {
        return switch (self._type) {
            .attributes => "attributes",
            .childList => "childList",
            .characterData => "characterData",
        };
    }

    pub fn getTarget(self: *const MutationRecord) *Node {
        return self._target;
    }

    pub fn getAttributeNamespace(self: *const MutationRecord) ?[]const u8 {
        if (self._attribute_name != null) {
            return "http://www.w3.org/1999/xhtml";
        }
        return null;
    }

    pub fn getAttributeName(self: *const MutationRecord) ?[]const u8 {
        return self._attribute_name;
    }

    pub fn getOldValue(self: *const MutationRecord) ?[]const u8 {
        return self._old_value;
    }

    pub fn getAddedNodes(self: *const MutationRecord) []const *Node {
        return self._added_nodes;
    }

    pub fn getRemovedNodes(self: *const MutationRecord) []const *Node {
        return self._removed_nodes;
    }

    pub fn getPreviousSibling(self: *const MutationRecord) ?*Node {
        return self._previous_sibling;
    }

    pub fn getNextSibling(self: *const MutationRecord) ?*Node {
        return self._next_sibling;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MutationRecord);

        pub const Meta = struct {
            pub const name = "MutationRecord";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(MutationRecord.getType, null, .{});
        pub const target = bridge.accessor(MutationRecord.getTarget, null, .{});
        pub const attributeName = bridge.accessor(MutationRecord.getAttributeName, null, .{});
        pub const attributeNamespace = bridge.accessor(MutationRecord.getAttributeNamespace, null, .{});
        pub const oldValue = bridge.accessor(MutationRecord.getOldValue, null, .{});
        pub const addedNodes = bridge.accessor(MutationRecord.getAddedNodes, null, .{});
        pub const removedNodes = bridge.accessor(MutationRecord.getRemovedNodes, null, .{});
        pub const previousSibling = bridge.accessor(MutationRecord.getPreviousSibling, null, .{});
        pub const nextSibling = bridge.accessor(MutationRecord.getNextSibling, null, .{});
    };
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(MutationObserver);

    pub const Meta = struct {
        pub const name = "MutationObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(MutationObserver.init, .{});

    pub const observe = bridge.function(MutationObserver.observe, .{});
    pub const disconnect = bridge.function(MutationObserver.disconnect, .{});
    pub const takeRecords = bridge.function(MutationObserver.takeRecords, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: MutationObserver" {
    try testing.htmlRunner("mutation_observer", .{});
}
