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

// CSS animations don't run here, but pages wait on their events (a view that
// slides out and shows the next one on animationend). An element that starts
// having an animation gets animationstart after its delay and animationend
// after its duration; losing it first fires animationcancel. The changes are
// checked once per task, as a browser restyles once per frame.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../Frame.zig");
const Animation = @import("../css/Animation.zig");

const Node = @import("../webapi/Node.zig");
const Element = @import("../webapi/Element.zig");
const TreeWalker = @import("../webapi/TreeWalker.zig");
const AnimationEvent = @import("../webapi/event/AnimationEvent.zig");

const log = lp.log;
const String = lp.String;

// An event task waiting longer than this is scheduled with blocks_done = false:
// a page waits on short animations (Microsoft's login slides for 250ms), not on
// long or endless ones.
const BLOCKING_MS = 250;

pub const State = struct {
    // Per element, one per animation-name it has, finished ones included: an
    // animation restarts only once its name goes away and comes back.
    animations: std.ArrayList(*CssAnimation) = .empty,

    // The subtrees to check, unless the whole document is.
    pending: std.AutoArrayHashMapUnmanaged(*Element, void) = .empty,
    whole_document: bool = false,
    check_scheduled: bool = false,

    // Taken out by the check, which fires their animationcancel once its tree
    // walk is over.
    cancelled: std.ArrayList(*CssAnimation) = .empty,
};

/// An attribute of `element` changed, or it was inserted.
pub fn elementChanged(frame: *Frame, element: *Element) void {
    if (frame._session.experimental_features.animation == false) {
        return;
    }
    const owner = element.ownerFrame(frame) orelse return;
    const state = &owner._css_animations;
    if (state.whole_document == false) {
        state.pending.put(owner.page_arena, element, {}) catch |err| {
            log.err(.frame, "css animations pending", .{ .err = err });
            return;
        };
    }
    scheduleCheck(owner);
}

/// A stylesheet changed, or the parser inserted nodes.
pub fn documentChanged(frame: *Frame) void {
    if (frame._session.experimental_features.animation == false) {
        return;
    }
    frame._css_animations.whole_document = true;
    scheduleCheck(frame);
}

fn scheduleCheck(frame: *Frame) void {
    const state = &frame._css_animations;
    if (state.check_scheduled) {
        return;
    }
    frame.js.scheduler.add(frame, check, 0, .{ .name = "css_animations.check" }) catch |err| {
        log.err(.frame, "css animations check", .{ .err = err });
        return;
    };
    state.check_scheduled = true;
}

fn check(ctx: *anyopaque) !?u32 {
    const frame: *Frame = @ptrCast(@alignCast(ctx));
    const state = &frame._css_animations;
    state.check_scheduled = false;

    // An element that left the document gets no more events. WebKit fires it
    // an animationcancel; no removal hook schedules this check yet.
    var i: usize = 0;
    while (i < state.animations.items.len) {
        const animation = state.animations.items[i];
        if (inDocument(frame, animation.element)) {
            i += 1;
            continue;
        }
        _ = state.animations.swapRemove(i);
        animation.release();
    }

    if (state.animations.items.len > 0 or frame._style_manager.hasAnyKeyframes()) {
        if (state.whole_document) {
            updateSubtree(frame, frame.document.asNode());
        } else {
            for (state.pending.keys()) |element| {
                if (inDocument(frame, element)) {
                    updateSubtree(frame, element.asNode());
                }
            }
        }
    }
    state.pending.clearRetainingCapacity();
    state.whole_document = false;

    const resets = frame.js.scheduler.resets;
    for (state.cancelled.items) |animation| {
        if (animation.phase != .finished) {
            animation.dispatch(.wrap("animationcancel"), animation.elapsed()) catch |err| {
                log.warn(.frame, "animationcancel", .{ .err = err });
            };
            if (frame.js.scheduler.resets != resets) {
                // A handler tore the frame down (e.g. removed its iframe): the
                // reset's finalizers freed the animations that had a task, so
                // none of these can be touched. The rest go with the page arena.
                break;
            }
        }
        animation.release();
    }
    state.cancelled.clearRetainingCapacity();
    return null;
}

fn inDocument(frame: *Frame, element: *Element) bool {
    return element.asNode().isConnected() and element.ownerFrame(frame) == frame;
}

fn updateSubtree(frame: *Frame, root: *Node) void {
    var tw = TreeWalker.Full.Elements.init(root, .{});
    while (tw.next()) |element| {
        update(frame, element) catch |err| {
            log.err(.frame, "css animations update", .{ .err = err });
        };
    }
}

fn update(frame: *Frame, element: *Element) !void {
    const state = &frame._css_animations;
    const sm = &frame._style_manager;
    // display:none, here or above, runs no animation
    const declared: Animation = if (sm.isHidden(element, .{})) .{} else sm.animation(element);

    var i: usize = 0;
    while (i < state.animations.items.len) {
        const animation = state.animations.items[i];
        if (animation.element != element or (hasName(declared, animation.name) and sm.hasKeyframes(animation.name))) {
            i += 1;
            continue;
        }
        try state.cancelled.append(frame.page_arena, animation);
        _ = state.animations.swapRemove(i);
    }

    for (0..declared.count()) |index| {
        const timing = declared.timing(index) orelse continue;
        if (sm.hasKeyframes(timing.name) == false or isRunning(state, element, timing.name)) {
            continue;
        }
        try CssAnimation.start(frame, element, timing);
    }
}

fn hasName(declared: Animation, name: []const u8) bool {
    for (0..declared.count()) |index| {
        const timing = declared.timing(index) orelse continue;
        if (std.mem.eql(u8, timing.name, name)) {
            return true;
        }
    }
    return false;
}

fn isRunning(state: *const State, element: *Element, name: []const u8) bool {
    for (state.animations.items) |animation| {
        if (animation.element == element and std.mem.eql(u8, animation.name, name)) {
            return true;
        }
    }
    return false;
}

const CssAnimation = struct {
    frame: *Frame,
    element: *Element,
    name: []const u8,
    // milliseconds; active is duration × iterations, inf for `infinite`
    delay: f64,
    active: f64,
    started_at: u64,
    phase: enum { delayed, active, finished } = .delayed,
    // A scheduler task holds it
    scheduled: bool = false,
    // Out of State.animations while a task still holds it: the task frees it.
    released: bool = false,

    fn start(frame: *Frame, element: *Element, timing: Animation.Timing) !void {
        const allocator = frame._factory.storageAllocator();
        // Its own copy: the rule text goes with the next stylesheet change
        const name = try allocator.dupe(u8, timing.name);
        errdefer allocator.free(name);

        const self = try frame._factory.create(CssAnimation{
            .frame = frame,
            .element = element,
            .name = name,
            .delay = timing.delay,
            // A zero duration is over at once, even repeated forever
            .active = if (timing.duration == 0) 0 else timing.duration * timing.iterations,
            .started_at = lp.datetime.milliTimestamp(.boot),
        });
        errdefer frame._factory.destroy(self);
        const state = &frame._css_animations;
        try state.animations.append(frame.page_arena, self);
        errdefer _ = state.animations.pop();
        try self.schedule(@max(self.delay, 0));
    }

    fn schedule(self: *CssAnimation, ms: f64) !void {
        const wait = std.math.lossyCast(u32, @ceil(ms));
        try self.frame.js.scheduler.add(self, run, wait, .{
            .name = "css_animations.event",
            .blocks_done = wait <= BLOCKING_MS,
            .finalizer = cancelled,
        });
        self.scheduled = true;
    }

    /// The scheduler dropped the task: the frame is going away.
    fn cancelled(ctx: *anyopaque) void {
        const self: *CssAnimation = @ptrCast(@alignCast(ctx));
        const animations = &self.frame._css_animations.animations;
        if (std.mem.findScalar(*CssAnimation, animations.items, self)) |index| {
            _ = animations.swapRemove(index);
        }
        self.destroy();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *CssAnimation = @ptrCast(@alignCast(ctx));
        self.scheduled = false;
        if (self.released) {
            self.destroy();
            return null;
        }
        if (inDocument(self.frame, self.element) == false) {
            // Dropped now, so that inserting the element back starts it again
            const animations = &self.frame._css_animations.animations;
            if (std.mem.findScalar(*CssAnimation, animations.items, self)) |index| {
                _ = animations.swapRemove(index);
            }
            self.destroy();
            return null;
        }
        switch (self.phase) {
            .delayed => {
                self.phase = .active;
                if (std.math.isFinite(self.active)) {
                    // A negative delay starts it that far in
                    try self.schedule(@max(self.active + @min(self.delay, 0), 0));
                }
                try self.dispatch(.wrap("animationstart"), @min(@max(-self.delay, 0), self.active));
            },
            .active => {
                self.phase = .finished;
                try self.dispatch(comptime .wrap("animationend"), self.active);
            },
            .finished => {},
        }
        return null;
    }

    fn elapsed(self: *const CssAnimation) f64 {
        const since: f64 = @floatFromInt(lp.datetime.milliTimestamp(.boot) - self.started_at);
        return std.math.clamp(since - self.delay, 0, self.active);
    }

    fn dispatch(self: *CssAnimation, typ: String, elapsed_ms: f64) !void {
        const event = try AnimationEvent.initTrusted(typ, .{
            .bubbles = true,
            // Chrome's are, though the spec says not
            .cancelable = true,
            .animationName = self.name,
            .elapsedTime = elapsed_ms / 1000,
        }, self.frame);
        try self.frame._event_manager.dispatch(self.element.asEventTarget(), event.asEvent());
    }

    /// Once out of State.animations.
    fn release(self: *CssAnimation) void {
        if (self.scheduled) {
            self.released = true;
            return;
        }
        self.destroy();
    }

    fn destroy(self: *CssAnimation) void {
        self.frame._factory.storageAllocator().free(self.name);
        self.frame._factory.destroy(self);
    }
};

const testing = @import("../../testing.zig");
test "css_animations: nothing is checked without the experimental feature" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    defer testing.test_session.experimental_features = .{};
    const state = &frame._css_animations;

    const doc = frame.document;
    const html = (try doc.createElement("html", null, frame)).asNode();
    _ = try doc.asNode().appendChild(html, frame);
    const body = (try doc.createElement("body", null, frame)).asNode();
    _ = try html.appendChild(body, frame);
    try Frame.parse.htmlAsChildren(frame, body,
        \\<style>@keyframes spin { to { opacity: 0 } } .spin { animation: spin 1s }</style>
        \\<div></div>
    );
    const div = body.lastChild().?.as(Element);
    try div.setAttribute(comptime .wrap("class"), comptime .wrap("spin"), frame);
    try testing.expectEqual(false, state.check_scheduled);
    try testing.expectEqual(false, state.whole_document);
    try testing.expectEqual(0, state.pending.count());

    testing.test_session.experimental_features.animation = true;
    try div.setAttribute(comptime .wrap("class"), comptime .wrap("spin x"), frame);
    try testing.expectEqual(true, state.check_scheduled);
    try testing.expectEqual(1, state.pending.count());
}
