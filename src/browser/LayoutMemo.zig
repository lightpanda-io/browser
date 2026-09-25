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
const lp = @import("lightpanda");

const Frame = @import("Frame.zig");
const Element = @import("webapi/Element.zig");

// Per-element layout values that take a walk to derive. They hold while the
// style version and the viewport do: DOM, text and style changes all bump the
// version.
const LayoutMemo = @This();

arena: *lp.Arena,

version: usize = 0,
viewport_width: u32 = 0,
viewport_height: u32 = 0,

// Null: no sized ancestor, so the text isn't measured.
line_widths: std.AutoHashMapUnmanaged(*Element, ?f64) = .empty,
text_heights: std.AutoHashMapUnmanaged(*Element, f64) = .empty,

pub fn init(frame: *Frame) !LayoutMemo {
    return .{ .arena = try frame.getArena(.medium, "LayoutMemo") };
}

pub fn deinit(self: *LayoutMemo) void {
    self.arena.release();
}

/// Drops every entry stored before the page last changed.
pub fn sync(self: *LayoutMemo, frame: *Frame) void {
    const version = frame.page.style_version;
    const viewport = frame.page.getViewport();
    if (self.version == version and self.viewport_width == viewport.width and self.viewport_height == viewport.height) {
        return;
    }
    self.line_widths.clearRetainingCapacity();
    self.text_heights.clearRetainingCapacity();
    self.version = version;
    self.viewport_width = viewport.width;
    self.viewport_height = viewport.height;
}

// A failed put only costs a recompute.
pub fn putLineWidth(self: *LayoutMemo, el: *Element, width: ?f64) void {
    self.line_widths.put(self.arena.allocator(), el, width) catch {};
}

pub fn putTextHeight(self: *LayoutMemo, el: *Element, height: f64) void {
    self.text_heights.put(self.arena.allocator(), el, height) catch {};
}

const testing = @import("../testing.zig");
test "LayoutMemo: reuse and invalidation" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    const memo = &frame._layout_memo;

    const div = try frame.window._document.createElement("div", null, frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(),
        \\<div style="width: 100px"><p>one two three</p></div>
    );
    const box = div.asNode().firstChild().?.as(Element);
    const p = box.asNode().firstChild().?.as(Element);

    const short = p.getElementAxis(frame, .height).value;
    try testing.expectEqual(1, memo.text_heights.count());
    // The walk stops at the sized box
    try testing.expectEqual(2, memo.line_widths.count());
    try testing.expectEqual(short, p.getElementAxis(frame, .height).value);
    try testing.expectEqual(1, memo.text_heights.count());

    // Editing the text bumps the style version, so nothing stale is served
    try p.asNode().setTextContent("one two three four five six seven eight nine ten", frame);
    try testing.expect(p.getElementAxis(frame, .height).value > short);
}
