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
const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;
const Node = @import("node.zig").Node;
const Element = @import("element.zig").Element;

pub const Interfaces = .{
    IntersectionObserver,
    Entry,
};

// This implementation attempts to be as less wrong as possible. Since we don't
// render, or know how things are positioned, our best guess isn't very good.
const IntersectionObserver = @This();
page: *Page,
root: *parser.Node,
callback: js.Function,
event_node: parser.EventNode,
observed_entries: std.ArrayList(Entry),
pending_elements: std.ArrayList(*parser.Element),
ready_elements: std.ArrayList(*parser.Element),

pub fn constructor(callback: js.Function, opts_: ?IntersectionObserverOptions, page: *Page) !*IntersectionObserver {
    const opts = opts_ orelse IntersectionObserverOptions{};

    const self = try page.arena.create(IntersectionObserver);
    self.* = .{
        .page = page,
        .callback = callback,
        .ready_elements = .{},
        .observed_entries = .{},
        .pending_elements = .{},
        .event_node = .{ .func = mutationCallback },
        .root = opts.root orelse parser.documentToNode(parser.documentHTMLToDocument(page.window.document)),
    };

    _ = try parser.eventTargetAddEventListener(
        parser.toEventTarget(parser.Node, self.root),
        "DOMNodeInserted",
        &self.event_node,
        false,
    );

    _ = try parser.eventTargetAddEventListener(
        parser.toEventTarget(parser.Node, self.root),
        "DOMNodeRemoved",
        &self.event_node,
        false,
    );

    return self;
}

pub fn _disconnect(self: *IntersectionObserver) !void {
    // We don't free as it is on an arena
    self.ready_elements = .{};
    self.observed_entries = .{};
    self.pending_elements = .{};
}

pub fn _observe(self: *IntersectionObserver, target_element: *parser.Element, page: *Page) !void {
    for (self.observed_entries.items) |*observer| {
        if (observer.target == target_element) {
            return; // Already observed
        }
    }

    if (self.isPending(target_element)) {
        return; // Already pending
    }

    for (self.ready_elements.items) |element| {
        if (element == target_element) {
            return; // Already primed
        }
    }

    // We can never fire callbacks synchronously. Code like React expects any
    // callback to fire in the future (e.g. via microtasks).
    try self.ready_elements.append(self.page.arena, target_element);
    if (self.ready_elements.items.len == 1) {
        // this is our first ready entry, schedule a callback
        try page.scheduler.add(self, processReady, 0, .{
            .name = "intersection ready",
        });
    }
}

pub fn _unobserve(self: *IntersectionObserver, target: *parser.Element) !void {
    if (self.removeObserved(target)) {
        return;
    }

    for (self.ready_elements.items, 0..) |el, index| {
        if (el == target) {
            _ = self.ready_elements.swapRemove(index);
            return;
        }
    }

    for (self.pending_elements.items, 0..) |el, index| {
        if (el == target) {
            _ = self.pending_elements.swapRemove(index);
            return;
        }
    }
}

pub fn _takeRecords(self: *IntersectionObserver) []Entry {
    return self.observed_entries.items;
}

fn processReady(ctx: *anyopaque) ?u32 {
    const self: *IntersectionObserver = @ptrCast(@alignCast(ctx));
    self._processReady() catch |err| {
        log.err(.web_api, "intersection ready", .{ .err = err });
    };
    return null;
}

fn _processReady(self: *IntersectionObserver) !void {
    defer self.ready_elements.clearRetainingCapacity();
    for (self.ready_elements.items) |element| {
        // IntersectionObserver probably doesn't work like what your intuition
        // thinks. As long as a node has a parent, even if that parent isn't
        // connected and even if the two nodes don't intersect, it'll fire the
        // callback once.
        if (try Node.get_parentNode(@ptrCast(element)) == null) {
            if (!self.isPending(element)) {
                try self.pending_elements.append(self.page.arena, element);
            }
            continue;
        }
        try self.forceObserve(element);
    }
}

fn isPending(self: *IntersectionObserver, element: *parser.Element) bool {
    for (self.pending_elements.items) |el| {
        if (el == element) {
            return true;
        }
    }
    return false;
}

fn mutationCallback(en: *parser.EventNode, event: *parser.Event) void {
    const mutation_event = parser.eventToMutationEvent(event);
    const self: *IntersectionObserver = @fieldParentPtr("event_node", en);
    self._mutationCallback(mutation_event) catch |err| {
        log.err(.web_api, "mutation callback", .{ .err = err, .source = "intersection observer" });
    };
}

fn _mutationCallback(self: *IntersectionObserver, event: *parser.MutationEvent) !void {
    const event_type = parser.eventType(@ptrCast(event));

    if (std.mem.eql(u8, event_type, "DOMNodeInserted")) {
        const node = parser.mutationEventRelatedNode(event) catch return orelse return;
        if (parser.nodeType(node) != .element) {
            return;
        }
        const el: *parser.Element = @ptrCast(node);
        if (self.removePending(el)) {
            // It was pending (because it wasn't in the root), but now it is
            // we should observe it.
            try self.forceObserve(el);
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "DOMNodeRemoved")) {
        const node = parser.mutationEventRelatedNode(event) catch return orelse return;
        if (parser.nodeType(node) != .element) {
            return;
        }

        const el: *parser.Element = @ptrCast(node);
        if (self.removeObserved(el)) {
            // It _was_ observed, it no longer is in our root, but if it was
            // to get re-added, it should be observed again (I think), so
            // we add it to our pending list
            try self.pending_elements.append(self.page.arena, el);
        }

        return;
    }

    // impossible event type
    unreachable;
}

// Exists to skip the checks made _observe when called from a DOMNodeInserted
// event. In such events, the event handler has alread done the necessary
// checks.
fn forceObserve(self: *IntersectionObserver, target: *parser.Element) !void {
    try self.observed_entries.append(self.page.arena, .{
        .page = self.page,
        .root = self.root,
        .target = target,
    });

    var result: js.Function.Result = undefined;
    self.callback.tryCall(void, .{self.observed_entries.items}, &result) catch {
        log.debug(.user_script, "callback error", .{
            .err = result.exception,
            .stack = result.stack,
            .source = "intersection observer",
        });
    };
}

fn removeObserved(self: *IntersectionObserver, target: *parser.Element) bool {
    for (self.observed_entries.items, 0..) |*observer, index| {
        if (observer.target == target) {
            _ = self.observed_entries.swapRemove(index);
            return true;
        }
    }
    return false;
}

fn removePending(self: *IntersectionObserver, target: *parser.Element) bool {
    for (self.pending_elements.items, 0..) |el, index| {
        if (el == target) {
            _ = self.pending_elements.swapRemove(index);
            return true;
        }
    }
    return false;
}

const IntersectionObserverOptions = struct {
    root: ?*parser.Node = null, // Element or Document
    rootMargin: ?[]const u8 = "0px 0px 0px 0px",
    threshold: ?Threshold = .{ .single = 0.0 },

    const Threshold = union(enum) {
        single: f32,
        list: []const f32,
    };
};

// https://developer.mozilla.org/en-US/docs/Web/API/Entry
// https://w3c.github.io/IntersectionObserver/#intersection-observer-entry
pub const Entry = struct {
    page: *Page,
    root: *parser.Node,
    target: *parser.Element,

    // Returns the bounds rectangle of the target element as a DOMRectReadOnly. The bounds are computed as described in the documentation for Element.getBoundingClientRect().
    pub fn get_boundingClientRect(self: *const Entry) !Element.DOMRect {
        return Element._getBoundingClientRect(self.target, self.page);
    }

    // Returns the ratio of the intersectionRect to the boundingClientRect.
    pub fn get_intersectionRatio(_: *const Entry) f32 {
        return 1.0;
    }

    // Returns a DOMRectReadOnly representing the target's visible area.
    pub fn get_intersectionRect(self: *const Entry) !Element.DOMRect {
        return Element._getBoundingClientRect(self.target, self.page);
    }

    // A Boolean value which is true if the target element intersects with the
    // intersection observer's root. If this is true, then, the
    // Entry describes a transition into a state of
    // intersection; if it's false, then you know the transition is from
    // intersecting to not-intersecting.
    pub fn get_isIntersecting(_: *const Entry) bool {
        return true;
    }

    // Returns a DOMRectReadOnly for the intersection observer's root.
    pub fn get_rootBounds(self: *const Entry) !Element.DOMRect {
        const root = self.root;
        if (@intFromPtr(root) == @intFromPtr(self.page.window.document)) {
            return self.page.renderer.boundingRect();
        }

        const root_type = parser.nodeType(root);

        var element: *parser.Element = undefined;
        switch (root_type) {
            .element => element = parser.nodeToElement(root),
            .document => {
                const doc = parser.nodeToDocument(root);
                element = (try parser.documentGetDocumentElement(doc)).?;
            },
            else => return error.InvalidState,
        }

        return Element._getBoundingClientRect(element, self.page);
    }

    // The Element whose intersection with the root changed.
    pub fn get_target(self: *const Entry) *parser.Element {
        return self.target;
    }

    // TODO: pub fn get_time(self: *const Entry)
};

const testing = @import("../../testing.zig");
test "Browser: DOM.IntersectionObserver" {
    try testing.htmlRunner("dom/intersection_observer.html");
}
