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

const CSS = @import("webapi/CSS.zig");
const Element = @import("webapi/Element.zig");
const Frame = @import("Frame.zig");
const Selector = @import("webapi/selector/Selector.zig");

const Allocator = std.mem.Allocator;

const SelectorPath = @This();

// Tight set for the target's own segment, so the selector stays clean.
const stable_attrs = [_][]const u8{ "data-testid", "name" };
// Broader set for a `:has()` descendant: distinguishing a subtree from its
// siblings only needs *some* differing attribute.
const descriptor_attrs = [_][]const u8{ "id", "data-testid", "name", "type", "value", "placeholder", "aria-label" };

const max_has_descendants = 64;

arena: Allocator,
frame: *Frame,

/// `arena` holds the returned selector and all scratch strings; `frame` is the
/// document the selector resolves against. Borrows both — nothing to deinit.
pub fn init(arena: Allocator, frame: *Frame) SelectorPath {
    return .{ .arena = arena, .frame = frame };
}

/// Builds the simplest CSS selector that resolves to `target` under first-match
/// semantics (`Selector.querySelector`, as click/fill resolve), verifying every
/// candidate against the live DOM. Anchors the target's most distinctive local
/// segment (`#id`, a stable attribute, a `:has()` on a distinguishing
/// descendant, or `:nth-of-type`) on only the ancestors that shrink the match
/// set — e.g. `input[name="acct"]` for the first such input,
/// `form:has(input[value="create account"]) input[name="acct"]` for the second.
pub fn build(self: SelectorPath, target: *Element) !?[]const u8 {
    if (try self.buildGreedy(target)) |sel| return sel;
    return try self.buildStrictPath(target);
}

fn buildGreedy(self: SelectorPath, target: *Element) !?[]const u8 {
    var candidate = try self.localSegment(target);
    if (self.isFirstMatch(target, candidate)) return candidate;
    var count = self.matchCount(candidate);
    var el = target.parentElement();
    while (el) |ancestor| {
        el = ancestor.parentElement();
        const trial = try std.fmt.allocPrint(self.arena, "{s} {s}", .{ try self.localSegment(ancestor), candidate });
        const trial_count = self.matchCount(trial);
        if (trial_count != 0 and trial_count < count) {
            candidate = trial;
            count = trial_count;
            if (self.isFirstMatch(target, candidate)) return candidate;
        }
    }
    return null;
}

fn buildStrictPath(self: SelectorPath, target: *Element) !?[]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    var el: ?*Element = target;
    while (el) |current| {
        try segments.insert(self.arena, 0, try self.localSegment(current));
        const candidate = try std.mem.join(self.arena, " > ", segments.items);
        if (self.isFirstMatch(target, candidate)) return candidate;
        el = current.parentElement();
    }
    return null;
}

/// The most distinctive selector for `el` alone: an `#id` that resolves to it,
/// else its tag qualified by stable attributes and — when that still matches a
/// sibling — a `:has()` distinguisher (preferred) or positional `:nth-of-type`.
fn localSegment(self: SelectorPath, el: *Element) ![]const u8 {
    if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
        if (id.len != 0) {
            const id_sel = try std.fmt.allocPrint(self.arena, "#{s}", .{try CSS.escape(id, self.frame)});
            if (self.isFirstMatch(el, id_sel)) return id_sel;
        }
    }

    const base = (try self.qualifyByAttrs(el.getTagNameLower(), el, &stable_attrs)).sel;

    if (!self.siblingMatches(el, base)) return base;
    if (try self.hasSegment(el, base)) |sel| return sel;
    if (nthOfType(el)) |n| return try std.fmt.allocPrint(self.arena, "{s}:nth-of-type({d})", .{ base, n });
    return base;
}

/// A `base:has(descendant)` segment resolving to `el`, found by scanning its
/// descendants for an attribute descriptor that distinguishes it from its
/// same-`base` siblings. Null when none does (caller falls back to position).
fn hasSegment(self: SelectorPath, el: *Element, base: []const u8) !?[]const u8 {
    var queue: std.ArrayList(*Element) = .empty;
    try self.enqueueChildren(&queue, el);

    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const d = queue.items[i];
        try self.enqueueChildren(&queue, d);

        const desc = (try self.descriptor(d)) orelse continue;
        const candidate = try std.fmt.allocPrint(self.arena, "{s}:has({s})", .{ base, desc });
        if (self.isFirstMatch(el, candidate)) return candidate;
    }
    return null;
}

/// Stops at `max_has_descendants` — the scan never examines more, so enqueuing
/// past it is wasted on large subtrees.
fn enqueueChildren(self: SelectorPath, queue: *std.ArrayList(*Element), el: *Element) !void {
    var child = el.firstElementChild();
    while (child) |c| : (child = c.nextElementSibling()) {
        if (queue.items.len >= max_has_descendants) return;
        try queue.append(self.arena, c);
    }
}

/// A `tag[attr="v"]…` selector from `d`'s stable attributes, or null when it has
/// none (a bare tag rarely distinguishes a subtree).
fn descriptor(self: SelectorPath, d: *Element) !?[]const u8 {
    const qualified = try self.qualifyByAttrs(d.getTagNameLower(), d, &descriptor_attrs);
    return if (qualified.added) qualified.sel else null;
}

/// Appends a `[attr="v"]` clause to `base` for each present, plain-valued
/// attribute in `attrs`; `added` reports whether any was. Values needing
/// escaping are skipped — we have no second escaper.
fn qualifyByAttrs(self: SelectorPath, base: []const u8, el: *Element, comptime attrs: []const []const u8) !struct { sel: []const u8, added: bool } {
    var sel = base;
    var added = false;
    inline for (attrs) |attr| {
        if (el.getAttributeSafe(comptime .wrap(attr))) |value| {
            if (value.len != 0 and isPlainAttrValue(value)) {
                sel = try std.fmt.allocPrint(self.arena, "{s}[{s}=\"{s}\"]", .{ sel, attr, value });
                added = true;
            }
        }
    }
    return .{ .sel = sel, .added = added };
}

fn siblingMatches(self: SelectorPath, el: *Element, sel: []const u8) bool {
    const parent = el.parentElement() orelse return false;
    var child = parent.firstElementChild();
    while (child) |c| : (child = c.nextElementSibling()) {
        if (c != el and (Selector.matches(c, sel, self.frame) catch false)) return true;
    }
    return false;
}

fn matchCount(self: SelectorPath, candidate: []const u8) usize {
    const root = self.frame.window._document.asNode();
    const list = Selector.querySelectorAll(root, candidate, self.frame) catch return 0;
    defer list.deinit(self.frame._page);
    return list.getLength();
}

/// 1-based position of `el` among same-tag siblings, or null when it is the only
/// element of its tag in the parent (a bare tag then suffices).
fn nthOfType(el: *Element) ?usize {
    const tag = el.getTagNameLower();
    var index: usize = 1;
    var has_sibling = false;

    var prev = el.previousElementSibling();
    while (prev) |p| : (prev = p.previousElementSibling()) {
        if (std.mem.eql(u8, p.getTagNameLower(), tag)) {
            index += 1;
            has_sibling = true;
        }
    }
    var next = el.nextElementSibling();
    while (next) |n| : (next = n.nextElementSibling()) {
        if (std.mem.eql(u8, n.getTagNameLower(), tag)) {
            has_sibling = true;
            break;
        }
    }
    return if (has_sibling) index else null;
}

fn isPlainAttrValue(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\"\\\n") == null;
}

/// Mirrors how click/fill resolve a selector: the same `Selector.querySelector`
/// first-match against the document.
fn isFirstMatch(self: SelectorPath, target: *Element, candidate: []const u8) bool {
    const root = self.frame.window._document.asNode();
    const first = (Selector.querySelector(root, candidate, self.frame) catch return false) orelse return false;
    return first == target;
}

const testing = @import("../testing.zig");

fn expectSelector(comptime selector: []const u8, comptime expected: []const u8) !void {
    var frame = try testing.pageTest("selector_path.html", .{});
    defer testing.reset();
    defer frame._session.removePage();

    const root = frame.window._document.asNode();
    const target = (try Selector.querySelector(root, selector, frame)) orelse return error.TargetNotFound;

    const built = (try init(testing.arena_allocator, frame).build(target)) orelse return error.NoSelector;
    try testing.expectString(expected, built);

    const resolved = (try Selector.querySelector(root, built, frame)) orelse return error.NoMatch;
    try testing.expect(resolved == target);
}

test "SelectorPath: unique id" {
    try expectSelector("#list", "#list");
}

test "SelectorPath: stable attribute" {
    try expectSelector("span[data-testid=\"price\"]", "span[data-testid=\"price\"]");
}

test "SelectorPath: nth-of-type, target is first match" {
    // #list is the first <ul>, so its 2nd <li> is already the first match.
    try expectSelector("#list > li:nth-of-type(2)", "li:nth-of-type(2)");
}

test "SelectorPath: anchors on an ancestor when not the first match" {
    // The 2nd <li> of the second list is not the first `li:nth-of-type(2)`.
    try expectSelector("#other > ul > li:nth-of-type(2)", "#other li:nth-of-type(2)");
}

test "SelectorPath: duplicate id resolves first, others anchor" {
    // `#save` resolves to the first <button id="save">; the second can't use it.
    try expectSelector("#main > button", "#save");
    try expectSelector("#other > button", "#other button");
}

test "SelectorPath: shared attribute, first match vs :has() disambiguation" {
    // Both forms hold <input name="acct">: the first is the first match; the
    // second anchors relationally on its distinguishing submit button.
    try expectSelector("form:nth-of-type(1) input[name=\"acct\"]", "input[name=\"acct\"]");
    try expectSelector(
        "form:nth-of-type(2) input[name=\"acct\"]",
        "form:has(input[type=\"submit\"][value=\"create account\"]) input[name=\"acct\"]",
    );
}
