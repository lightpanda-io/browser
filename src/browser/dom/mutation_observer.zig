// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

const NodeList = @import("nodelist.zig").NodeList;

pub const Interfaces = .{
    MutationObserver,
    MutationRecord,
};

const Walker = @import("../dom/walker.zig").WalkerChildren;

// WEB IDL https://dom.spec.whatwg.org/#interface-mutationobserver
pub const MutationObserver = struct {
    page: *Page,
    cbk: js.Function,
    scheduled: bool,
    observers: std.ArrayListUnmanaged(*Observer),

    // List of records which were observed. When the call scope ends, we need to
    // execute our callback with it.
    observed: std.ArrayListUnmanaged(MutationRecord),

    pub fn constructor(cbk: js.Function, page: *Page) !MutationObserver {
        return .{
            .cbk = cbk,
            .page = page,
            .observed = .{},
            .scheduled = false,
            .observers = .empty,
        };
    }

    pub fn _observe(self: *MutationObserver, node: *parser.Node, options_: ?Options) !void {
        const arena = self.page.arena;
        var options = options_ orelse Options{};
        if (options.attributeFilter.len > 0) {
            options.attributeFilter = try arena.dupe([]const u8, options.attributeFilter);
        }

        const observer = try arena.create(Observer);
        observer.* = .{
            .node = node,
            .options = options,
            .mutation_observer = self,
            .event_node = .{ .id = self.cbk.id, .func = Observer.handle },
        };

        try self.observers.append(arena, observer);

        // register node's events
        if (options.childList or options.subtree) {
            observer.dom_node_inserted_listener = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMNodeInserted",
                &observer.event_node,
                false,
            );
            observer.dom_node_removed_listener = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMNodeRemoved",
                &observer.event_node,
                false,
            );
        }
        if (options.attr()) {
            observer.dom_node_attribute_modified_listener = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMAttrModified",
                &observer.event_node,
                false,
            );
        }
        if (options.cdata()) {
            observer.dom_cdata_modified_listener = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMCharacterDataModified",
                &observer.event_node,
                false,
            );
        }
        if (options.subtree) {
            observer.dom_subtree_modified_listener = try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                "DOMSubtreeModified",
                &observer.event_node,
                false,
            );
        }
    }

    fn callback(ctx: *anyopaque) ?u32 {
        const self: *MutationObserver = @ptrCast(@alignCast(ctx));
        self.scheduled = false;

        const records = self.observed.items;
        if (records.len == 0) {
            return null;
        }

        defer self.observed.clearRetainingCapacity();

        var result: js.Function.Result = undefined;
        self.cbk.tryCallWithThis(void, self, .{records}, &result) catch {
            log.debug(.user_script, "callback error", .{
                .err = result.exception,
                .stack = result.stack,
                .source = "mutation observer",
            });
        };
        return null;
    }

    pub fn _disconnect(self: *MutationObserver) !void {
        for (self.observers.items) |observer| {
            const event_target = parser.toEventTarget(parser.Node, observer.node);
            if (observer.dom_node_inserted_listener) |listener| {
                try parser.eventTargetRemoveEventListener(
                    event_target,
                    "DOMNodeInserted",
                    listener,
                    false,
                );
            }

            if (observer.dom_node_removed_listener) |listener| {
                try parser.eventTargetRemoveEventListener(
                    event_target,
                    "DOMNodeRemoved",
                    listener,
                    false,
                );
            }

            if (observer.dom_node_attribute_modified_listener) |listener| {
                try parser.eventTargetRemoveEventListener(
                    event_target,
                    "DOMAttrModified",
                    listener,
                    false,
                );
            }

            if (observer.dom_cdata_modified_listener) |listener| {
                try parser.eventTargetRemoveEventListener(
                    event_target,
                    "DOMCharacterDataModified",
                    listener,
                    false,
                );
            }

            if (observer.dom_subtree_modified_listener) |listener| {
                try parser.eventTargetRemoveEventListener(
                    event_target,
                    "DOMSubtreeModified",
                    listener,
                    false,
                );
            }
        }
        self.observers.clearRetainingCapacity();
    }

    // TODO
    pub fn _takeRecords(_: *const MutationObserver) ?[]const u8 {
        return &[_]u8{};
    }
};

pub const MutationRecord = struct {
    type: []const u8,
    target: *parser.Node,
    added_nodes: NodeList = .{},
    removed_nodes: NodeList = .{},
    previous_sibling: ?*parser.Node = null,
    next_sibling: ?*parser.Node = null,
    attribute_name: ?[]const u8 = null,
    attribute_namespace: ?[]const u8 = null,
    old_value: ?[]const u8 = null,

    pub fn get_type(self: *const MutationRecord) []const u8 {
        return self.type;
    }

    pub fn get_addedNodes(self: *MutationRecord) *NodeList {
        return &self.added_nodes;
    }

    pub fn get_removedNodes(self: *MutationRecord) *NodeList {
        return &self.removed_nodes;
    }

    pub fn get_target(self: *const MutationRecord) *parser.Node {
        return self.target;
    }

    pub fn get_attributeName(self: *const MutationRecord) ?[]const u8 {
        return self.attribute_name;
    }

    pub fn get_attributeNamespace(self: *const MutationRecord) ?[]const u8 {
        return self.attribute_namespace;
    }

    pub fn get_previousSibling(self: *const MutationRecord) ?*parser.Node {
        return self.previous_sibling;
    }

    pub fn get_nextSibling(self: *const MutationRecord) ?*parser.Node {
        return self.next_sibling;
    }

    pub fn get_oldValue(self: *const MutationRecord) ?[]const u8 {
        return self.old_value;
    }
};

const Options = struct {
    childList: bool = false,
    attributes: bool = false,
    characterData: bool = false,
    subtree: bool = false,
    attributeOldValue: bool = false,
    characterDataOldValue: bool = false,
    attributeFilter: [][]const u8 = &.{},

    fn attr(self: Options) bool {
        return self.attributes or self.attributeOldValue or self.attributeFilter.len > 0;
    }

    fn cdata(self: Options) bool {
        return self.characterData or self.characterDataOldValue;
    }
};

const Observer = struct {
    node: *parser.Node,
    options: Options,

    // reference back to the MutationObserver so that we can access the arena
    // and batch the mutation records.
    mutation_observer: *MutationObserver,

    event_node: parser.EventNode,

    dom_node_inserted_listener: ?*parser.EventListener = null,
    dom_node_removed_listener: ?*parser.EventListener = null,
    dom_node_attribute_modified_listener: ?*parser.EventListener = null,
    dom_cdata_modified_listener: ?*parser.EventListener = null,
    dom_subtree_modified_listener: ?*parser.EventListener = null,

    fn appliesTo(
        self: *const Observer,
        target: *parser.Node,
        event_type: MutationEventType,
        event: *parser.MutationEvent,
    ) !bool {
        if (event_type == .DOMAttrModified and self.options.attributeFilter.len > 0) {
            const attribute_name = try parser.mutationEventAttributeName(event);
            for (self.options.attributeFilter) |needle| blk: {
                if (std.mem.eql(u8, attribute_name, needle)) {
                    break :blk;
                }
            }
            return false;
        }

        // mutation on any target is always ok.
        if (self.options.subtree) {
            return true;
        }

        // if target equals node, alway ok.
        if (target == self.node) {
            return true;
        }

        // no subtree, no same target and no childlist, always noky.
        if (!self.options.childList) {
            return false;
        }

        // target must be a child of o.node
        const walker = Walker{};
        var next: ?*parser.Node = null;
        while (true) {
            next = walker.get_next(self.node, next) catch break orelse break;
            if (next.? == target) {
                return true;
            }
        }

        return false;
    }

    fn handle(en: *parser.EventNode, event: *parser.Event) void {
        const self: *Observer = @fieldParentPtr("event_node", en);
        self._handle(event) catch |err| {
            log.err(.web_api, "handle error", .{ .err = err, .source = "mutation observer" });
        };
    }

    fn _handle(self: *Observer, event: *parser.Event) !void {
        var mutation_observer = self.mutation_observer;

        const node = blk: {
            const event_target = parser.eventTarget(event) orelse return;
            break :blk parser.eventTargetToNode(event_target);
        };

        const mutation_event = parser.eventToMutationEvent(event);
        const event_type = blk: {
            const t = parser.eventType(event);
            break :blk std.meta.stringToEnum(MutationEventType, t) orelse return;
        };

        if (try self.appliesTo(node, event_type, mutation_event) == false) {
            return;
        }

        var record = MutationRecord{
            .target = self.node,
            .type = event_type.recordType(),
        };

        const arena = mutation_observer.page.arena;
        switch (event_type) {
            .DOMAttrModified => {
                record.attribute_name = parser.mutationEventAttributeName(mutation_event) catch null;
                if (self.options.attributeOldValue) {
                    record.old_value = parser.mutationEventPrevValue(mutation_event);
                }
            },
            .DOMCharacterDataModified => {
                if (self.options.characterDataOldValue) {
                    record.old_value = parser.mutationEventPrevValue(mutation_event);
                }
            },
            .DOMNodeInserted => {
                if (parser.mutationEventRelatedNode(mutation_event) catch null) |related_node| {
                    try record.added_nodes.append(arena, related_node);
                }
            },
            .DOMNodeRemoved => {
                if (parser.mutationEventRelatedNode(mutation_event) catch null) |related_node| {
                    try record.removed_nodes.append(arena, related_node);
                }
            },
        }

        try mutation_observer.observed.append(arena, record);

        if (mutation_observer.scheduled == false) {
            mutation_observer.scheduled = true;
            try mutation_observer.page.scheduler.add(
                mutation_observer,
                MutationObserver.callback,
                0,
                .{ .name = "mutation_observer" },
            );
        }
    }
};

const MutationEventType = enum {
    DOMAttrModified,
    DOMCharacterDataModified,
    DOMNodeInserted,
    DOMNodeRemoved,

    fn recordType(self: MutationEventType) []const u8 {
        return switch (self) {
            .DOMAttrModified => "attributes",
            .DOMCharacterDataModified => "characterData",
            .DOMNodeInserted => "childList",
            .DOMNodeRemoved => "childList",
        };
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.MutationObserver" {
    try testing.htmlRunner("dom/mutation_observer.html");
}
