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

const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const Page = @import("../page.zig").Page;

const Env = @import("../env.zig").Env;
const Element = @import("element.zig").Element;

pub const Interfaces = .{
    IntersectionObserver,
    IntersectionObserverEntry,
};

// This is supposed to listen to change between the root and observation targets.
// However, our rendered stores everything as 1 pixel sized boxes in a long row that never changes.
// As such, there are no changes to intersections between the root and any target.
// Instead we keep a list of all entries that are being observed.
// The callback is called with all entries everytime a new entry is added(observed).
// Potentially we should also call the callback at a regular interval.
// The returned Entries are phony, they always indicate full intersection.
// https://developer.mozilla.org/en-US/docs/Web/API/IntersectionObserver
pub const IntersectionObserver = struct {
    page: *Page,
    callback: Env.Function,
    options: IntersectionObserverOptions,

    observed_entries: std.ArrayListUnmanaged(IntersectionObserverEntry),

    // new IntersectionObserver(callback)
    // new IntersectionObserver(callback, options) [not supported yet]
    pub fn constructor(callback: Env.Function, options_: ?IntersectionObserverOptions, page: *Page) !IntersectionObserver {
        var options = IntersectionObserverOptions{
            .root = parser.documentToNode(parser.documentHTMLToDocument(page.window.document)),
            .rootMargin = "0px 0px 0px 0px",
            .threshold = .{ .single = 0.0 },
        };
        if (options_) |*o| {
            if (o.root) |root| {
                options.root = root;
            } // Other properties are not used due to the way we render
        }

        return .{
            .page = page,
            .callback = callback,
            .options = options,
            .observed_entries = .{},
        };
    }

    pub fn _disconnect(self: *IntersectionObserver) !void {
        self.observed_entries = .{}; // We don't free as it is on an arena
    }

    pub fn _observe(self: *IntersectionObserver, target_element: *parser.Element) !void {
        for (self.observed_entries.items) |*observer| {
            if (observer.target == target_element) {
                return; // Already observed
            }
        }

        try self.observed_entries.append(self.page.arena, .{
            .page = self.page,
            .target = target_element,
            .options = &self.options,
        });

        var result: Env.Function.Result = undefined;
        self.callback.tryCall(void, .{self.observed_entries.items}, &result) catch {
            log.debug(.user_script, "callback error", .{
                .err = result.exception,
                .stack = result.stack,
                .source = "intersection observer",
            });
        };
    }

    pub fn _unobserve(self: *IntersectionObserver, target: *parser.Element) !void {
        for (self.observed_entries.items, 0..) |*observer, index| {
            if (observer.target == target) {
                _ = self.observed_entries.swapRemove(index);
                break;
            }
        }
    }

    pub fn _takeRecords(self: *IntersectionObserver) []IntersectionObserverEntry {
        return self.observed_entries.items;
    }
};

const IntersectionObserverOptions = struct {
    root: ?*parser.Node, // Element or Document
    rootMargin: ?[]const u8,
    threshold: ?Threshold,

    const Threshold = union(enum) {
        single: f32,
        list: []const f32,
    };
};

// https://developer.mozilla.org/en-US/docs/Web/API/IntersectionObserverEntry
// https://w3c.github.io/IntersectionObserver/#intersection-observer-entry
pub const IntersectionObserverEntry = struct {
    page: *Page,
    target: *parser.Element,
    options: *IntersectionObserverOptions,

    // Returns the bounds rectangle of the target element as a DOMRectReadOnly. The bounds are computed as described in the documentation for Element.getBoundingClientRect().
    pub fn get_boundingClientRect(self: *const IntersectionObserverEntry) !Element.DOMRect {
        return Element._getBoundingClientRect(self.target, self.page);
    }

    // Returns the ratio of the intersectionRect to the boundingClientRect.
    pub fn get_intersectionRatio(_: *const IntersectionObserverEntry) f32 {
        return 1.0;
    }

    // Returns a DOMRectReadOnly representing the target's visible area.
    pub fn get_intersectionRect(self: *const IntersectionObserverEntry) !Element.DOMRect {
        return Element._getBoundingClientRect(self.target, self.page);
    }

    // A Boolean value which is true if the target element intersects with the
    // intersection observer's root. If this is true, then, the
    // IntersectionObserverEntry describes a transition into a state of
    // intersection; if it's false, then you know the transition is from
    // intersecting to not-intersecting.
    pub fn get_isIntersecting(_: *const IntersectionObserverEntry) bool {
        return true;
    }

    // Returns a DOMRectReadOnly for the intersection observer's root.
    pub fn get_rootBounds(self: *const IntersectionObserverEntry) !Element.DOMRect {
        const root = self.options.root.?;
        if (@intFromPtr(root) == @intFromPtr(self.page.window.document)) {
            return self.page.renderer.boundingRect();
        }

        const root_type = try parser.nodeType(root);

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
    pub fn get_target(self: *const IntersectionObserverEntry) *parser.Element {
        return self.target;
    }

    // TODO: pub fn get_time(self: *const IntersectionObserverEntry)
};

const testing = @import("../../testing.zig");
test "Browser: DOM.IntersectionObserver" {
    try testing.htmlRunner("dom/intersection_observer.html");
}
