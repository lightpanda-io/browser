const std = @import("std");

const log = @import("../../../../log.zig");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const ShadowRoot = @import("../../ShadowRoot.zig");

const Slot = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Slot) *Element {
    return self._proto._proto;
}

pub fn asConstElement(self: *const Slot) *const Element {
    return self._proto._proto;
}

pub fn asNode(self: *Slot) *Node {
    return self.asElement().asNode();
}

pub fn getName(self: *const Slot) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *Slot, name: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(name), page);
}

const AssignedNodesOptions = struct {
    flatten: bool = false,
};

pub fn assignedNodes(self: *Slot, opts_: ?AssignedNodesOptions, page: *Page) ![]const *Node {
    const opts = opts_ orelse AssignedNodesOptions{};
    var nodes: std.ArrayList(*Node) = .empty;
    try self.collectAssignedNodes(false, &nodes, opts, page);
    return nodes.items;
}

pub fn assignedElements(self: *Slot, opts_: ?AssignedNodesOptions, page: *Page) ![]const *Element {
    const opts = opts_ orelse AssignedNodesOptions{};
    var elements: std.ArrayList(*Element) = .empty;
    try self.collectAssignedNodes(true, &elements, opts, page);
    return elements.items;
}

fn CollectionType(comptime elements: bool) type {
    return if (elements) *std.ArrayList(*Element) else *std.ArrayList(*Node);
}

fn collectAssignedNodes(self: *Slot, comptime elements: bool, coll: CollectionType(elements), opts: AssignedNodesOptions, page: *Page) !void {
    // Find the shadow root this slot belongs to
    const shadow_root = self.findShadowRoot() orelse return;

    const slot_name = self.getName();
    const allocator = page.call_arena;

    const host = shadow_root.getHost();
    const initial_count = coll.items.len;
    var it = host.asNode().childrenIterator();
    while (it.next()) |child| {
        if (!isAssignedToSlot(child, slot_name)) {
            continue;
        }

        if (opts.flatten) {
            if (child.is(Slot)) |child_slot| {
                // Only flatten if the child slot is actually in a shadow tree
                if (child_slot.findShadowRoot()) |_| {
                    try child_slot.collectAssignedNodes(elements, coll, opts, page);
                    continue;
                }
                // Otherwise, treat it as a regular element and fall through
            }
        }

        if (comptime elements) {
            if (child.is(Element)) |el| {
                try coll.append(allocator, el);
            }
        } else {
            try coll.append(allocator, child);
        }
    }

    // If flatten is true and no assigned nodes were found, return fallback content
    if (opts.flatten and coll.items.len == initial_count) {
        var child_it = self.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (comptime elements) {
                if (child.is(Element)) |el| {
                    try coll.append(allocator, el);
                }
            } else {
                try coll.append(allocator, child);
            }
        }
    }
}

pub fn assign(self: *Slot, nodes: []const *Node) void {
    // Imperative slot assignment API
    // This would require storing manually assigned nodes
    // For now, this is a placeholder for the API
    _ = self;
    _ = nodes;

    // let's see if this is ever actually used
    log.warn(.not_implemented, "Slot.assign", .{});
}

fn findShadowRoot(self: *Slot) ?*ShadowRoot {
    // Walk up the parent chain to find the shadow root
    var parent = self.asNode()._parent;
    while (parent) |p| {
        if (p.is(ShadowRoot)) |shadow_root| {
            return shadow_root;
        }
        parent = p._parent;
    }
    return null;
}

fn isAssignedToSlot(node: *Node, slot_name: []const u8) bool {
    // Check if a node should be assigned to a slot with the given name
    if (node.is(Element)) |element| {
        // Get the slot attribute from the element
        const node_slot = element.getAttributeSafe(comptime .wrap("slot")) orelse "";

        // Match if:
        // - Both are empty (default slot)
        // - They match exactly
        return std.mem.eql(u8, node_slot, slot_name);
    }

    // Text nodes, comments, etc. are only assigned to the default slot
    // (when they have no preceding/following element siblings with slot attributes)
    // For simplicity, text nodes go to default slot if slot_name is empty
    return slot_name.len == 0;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Slot);

    pub const Meta = struct {
        pub const name = "HTMLSlotElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(Slot.getName, Slot.setName, .{});
    pub const assignedNodes = bridge.function(Slot.assignedNodes, .{});
    pub const assignedElements = bridge.function(Slot.assignedElements, .{});
    pub const assign = bridge.function(Slot.assign, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTMLSlotElement" {
    try testing.htmlRunner("element/html/slot.html", .{});
}
