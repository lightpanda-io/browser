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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Parser = @import("../../css/Parser.zig");
const RuleStore = @import("../../css/RuleStore.zig");
const StyleManager = @import("../../StyleManager.zig");

const Element = @import("../Element.zig");

const CSSRuleList = @import("CSSRuleList.zig");
const CSSRule = @import("CSSRule.zig");
const GenericRule = @import("GenericRule.zig");
const CSSStyleRule = @import("CSSStyleRule.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");

const log = lp.log;
const Entry = RuleStore.Entry;

const CSSStyleSheet = @This();

const CSSError = error{
    OutOfMemory,
    IndexSizeError,
    WriteFailed,
    StringTooLarge,
    SyntaxError,
    NotAllowedError,
};

_href: ?[]const u8 = null,
_title: []const u8 = "",
_disabled: bool = false,

// false for a <style> that hasn't been parsed into _store yet.
_parsed: bool,

// internal compact representation of the rules. Like Attribute.List.
_store: RuleStore,

// Rules removed from the sheet that JS still holds.
_detached_store: RuleStore,

_next_rule_id: u32 = 0,
// like Page.attribute_lookup, ensure identity to a CSSRule which are lazily
// materialized from the RuleStore.
_rule_views: std.AutoHashMapUnmanaged(u32, *CSSRule) = .empty,

_owner_rule: ?*CSSRule = null,
_owner_node: ?*Element = null,
_css_rules: ?*CSSRuleList = null,
_constructed: bool = false, // only when true can it be replaced

pub fn init(frame: *Frame) !*CSSStyleSheet {
    const self = try frame._factory.create(CSSStyleSheet{ ._constructed = true, ._parsed = true, ._store = undefined, ._detached_store = undefined });
    self._store = .{ ._sheet = self };
    self._detached_store = .{ ._sheet = self, ._detached = true };
    return self;
}

pub fn initWithOwner(owner: *Element, frame: *Frame) !*CSSStyleSheet {
    const self = try frame._factory.create(CSSStyleSheet{ ._owner_node = owner, ._parsed = false, ._store = undefined, ._detached_store = undefined });
    self._store = .{ ._sheet = self };
    self._detached_store = .{ ._sheet = self, ._detached = true };
    return self;
}

pub fn getOwnerNode(self: *const CSSStyleSheet) ?*Element {
    return self._owner_node;
}

fn ownerStyleManager(self: *const CSSStyleSheet, frame: *Frame) ?*StyleManager {
    const owner = self._owner_node orelse return null;
    return &(owner.ownerFrame(frame) orelse return null)._style_manager;
}

/// A rule in the sheet changed through its view.
pub fn rulesModified(self: *const CSSStyleSheet, frame: *Frame) void {
    if (self.ownerStyleManager(frame)) |style_manager| {
        style_manager.sheetModified();
    }
}

pub fn getHref(self: *const CSSStyleSheet) ?[]const u8 {
    return self._href;
}

pub fn getTitle(self: *const CSSStyleSheet) []const u8 {
    return self._title;
}

fn getDisabled(self: *const CSSStyleSheet) bool {
    return self._disabled;
}

pub fn setDisabled(self: *CSSStyleSheet, disabled: bool, frame: *Frame) void {
    if (self._disabled == disabled) {
        return;
    }
    self._disabled = disabled;
    self.rulesModified(frame);
}

fn getCssRules(self: *CSSStyleSheet, frame: *Frame) !*CSSRuleList {
    if (self._css_rules) |rules| {
        return rules;
    }
    try self.ensureParsed(frame);
    const rules = try CSSRuleList.init(&self._store, frame);
    self._css_rules = rules;
    return rules;
}

/// Parses a <style>'s text into the rules, if it isn't yet.
pub fn ensureParsed(self: *CSSStyleSheet, frame: *Frame) !void {
    if (self._parsed) {
        return;
    }
    if (self.getOwnerNode()) |owner| {
        if (owner.is(Element.Html.Style)) |style| {
            // Same cascade as the text StyleManager already parsed: no notify.
            const text = try style.asNode().getTextContentAlloc(frame.local_arena);
            try self.parseInto(text, .append, frame);
        }
    }
    self._parsed = true;
}

/// The <style>'s text changed. Its rules are parsed again when next needed.
pub fn textChanged(self: *CSSStyleSheet, frame: *Frame) !void {
    try self.removeAll(frame);
    self._parsed = false;
    self._css_rules = null;
}

fn getOwnerRule(self: *const CSSStyleSheet) ?*CSSRule {
    return self._owner_rule;
}

/// The view of the rule at `index` in `list`, one of this sheet's.
pub fn ruleView(self: *CSSStyleSheet, store: *RuleStore, index: u32, frame: *Frame) !*CSSRule {
    const entry = &store.entries()[index];
    const gop = try self._rule_views.getOrPut(frame._factory.storageAllocator(), entry._id);
    if (gop.found_existing) {
        const view = gop.value_ptr.*;
        view._hint = index;
        return view;
    }
    errdefer self._rule_views.removeByPtr(gop.key_ptr);
    const view = switch (entry._kind) {
        .style => (try CSSStyleRule.init(store, entry._id, index, frame)).asCSSRule(),
        else => (try GenericRule.init(store, entry._id, index, frame)).asCSSRule(),
    };
    gop.value_ptr.* = view;
    return view;
}

pub fn insertRule(self: *CSSStyleSheet, rule: []const u8, maybe_index: ?u32, frame: *Frame) !u32 {
    const requested_index = maybe_index orelse 0;
    var it = Parser.parseStylesheet(rule);
    const parsed_rule = it.next() orelse return error.SyntaxError;

    if (it.next() != null) return error.SyntaxError;

    try self.ensureParsed(frame);

    var entry = try self.parseRule(parsed_rule, frame);
    errdefer self.freeEntry(&entry, frame);

    // Per spec, an index > rules.length should throw IndexSizeError. But because
    // we don't process @import and @font-face, indexes that code hard-codes can
    // be off. As a workaround, we clamp to the tail.
    // See #2214 (and the sibling #1970 / #1972 tolerance for at-rules).
    const length = self._store.length();
    const index = if (requested_index > length) length else requested_index;
    if (index != requested_index) {
        log.debug(.not_implemented, "insertRule clamped index", .{});
    }
    try self._store.insert(frame._factory.storageAllocator(), index, entry);
    if (self.ownerStyleManager(frame)) |style_manager| {
        style_manager.ruleInserted(self, index);
    }

    return index;
}

fn deleteRule(self: *CSSStyleSheet, index: u32, frame: *Frame) !void {
    try self.ensureParsed(frame);
    if (index >= self._store.length()) {
        return error.IndexSizeError;
    }
    try self.removeRule(&self._store, index, frame);
    self.rulesModified(frame);
}

pub fn replace(self: *CSSStyleSheet, text: []const u8, frame: *Frame) CSSError!js.Promise {
    if (self._constructed == false) {
        return error.NotAllowedError;
    }
    try self.replaceRules(text, frame);
    return frame.js.local.?.resolvePromise(self);
}

fn replaceSync(self: *CSSStyleSheet, text: []const u8, frame: *Frame) CSSError!void {
    if (self._constructed == false) {
        return error.NotAllowedError;
    }
    return self.replaceRules(text, frame);
}

/// replaceSync without the constructed-sheet check, for loading a <link>.
pub fn replaceRules(self: *CSSStyleSheet, text: []const u8, frame: *Frame) CSSError!void {
    try self.parseInto(text, .replace, frame);
    self._parsed = true;
}

/// With `.replace`, a failed parse leaves the old rules as they were.
fn parseInto(self: *CSSStyleSheet, text: []const u8, comptime mode: enum { append, replace }, frame: *Frame) CSSError!void {
    // Collect on scratch so that we don't strand small un-releasable memory
    // as our list grows.
    const scratch = try frame.getArena(.medium, "CSSStyleSheet.parseInto");
    defer scratch.release();

    const arena = scratch.allocator();

    var parsed: std.ArrayList(Entry) = .empty;
    errdefer for (parsed.items) |*entry| {
        self.freeEntry(entry, frame);
    };

    var it = Parser.parseStylesheet(text);
    while (it.next()) |parsed_rule| {
        var entry = try self.parseRule(parsed_rule, frame);
        errdefer self.freeEntry(&entry, frame);
        try parsed.append(arena, entry);
    }

    if (mode == .replace) {
        // Before the old rules are freed: the cascade holds their selectors
        self.rulesModified(frame);
        try self.removeAll(frame);
    }
    try self._store.appendSlice(frame._factory.storageAllocator(), parsed.items);
}

fn parseRule(self: *CSSStyleSheet, parsed_rule: Parser.Rule, frame: *Frame) CSSError!Entry {
    return switch (parsed_rule) {
        .style => |s| self.parseStyleRule(s.selector, s.block, 0, frame),
        .at_rule => |a| self.parseAtRule(a.keyword, a.text, frame),
    };
}

/// A style rule from source: its declarations, and the rules nested in its
/// block (CSS Nesting) as child rules.
fn parseStyleRule(self: *CSSStyleSheet, selector: []const u8, block: []const u8, depth: u8, frame: *Frame) CSSError!Entry {
    const allocator = frame._factory.storageAllocator();
    var entry = try Entry.init(allocator, .style, selector, try self.nextRuleId());
    errdefer self.freeEntry(&entry, frame);
    entry._block = try CSSStyleDeclaration.parseBlock(block, frame);

    // Same nesting cap as StyleManager's cascade side
    if (depth >= StyleManager.MAX_AT_RULE_NESTING or std.mem.findScalar(u8, block, '{') == null) {
        return entry;
    }
    var it = Parser.parseStyleBlock(block);
    while (it.nextItem()) |item| {
        var nested = switch (item) {
            .declaration => continue,
            .rule => |r| try self.parseStyleRule(r.selector, r.block, depth + 1, frame),
            .at_rule => |a| try self.parseAtRule(a.keyword, a.text, frame),
        };
        errdefer self.freeEntry(&nested, frame);
        // Created on the first nested rule: most rules have none.
        const children = entry._children orelse blk: {
            const children = try RuleStore.init(allocator, self);
            entry._children = children;
            break :blk children;
        };
        try children.append(allocator, nested);
    }
    if (entry._children) |children| {
        try children.trim(allocator);
    }
    return entry;
}

fn parseAtRule(self: *CSSStyleSheet, keyword: []const u8, text: []const u8, frame: *Frame) CSSError!Entry {
    return Entry.init(frame._factory.storageAllocator(), .ofAtRule(keyword), text, try self.nextRuleId());
}

fn nextRuleId(self: *CSSStyleSheet) !u32 {
    const id = self._next_rule_id;
    self._next_rule_id = std.math.add(u32, id, 1) catch return error.OutOfMemory;
    return id;
}

fn removeRule(self: *CSSStyleSheet, store: *RuleStore, index: u32, frame: *Frame) !void {
    const id = store.entries()[index]._id;
    const view = self._rule_views.get(id) orelse {
        // JS never saw it: free it
        var entry = store.take(index);
        self.freeEntry(&entry, frame);
        return;
    };

    // Reserved first, so nothing can fail once the entry is taken.
    try self._detached_store.ensureUnusedCapacity(frame._factory.storageAllocator(), 1);
    self.detach(view, store.take(index));
}

fn removeAll(self: *CSSStyleSheet, frame: *Frame) !void {
    const store = &self._store;

    const rule_views_count = self._rule_views.count();
    if (rule_views_count == 0) {
        // common fast path, no rule has been given to JS, everything can
        // be directly freed.
        for (store.entries()) |*entry| {
            self.freeEntry(entry, frame);
        }
        store._len = 0;
        return;
    }

    // The most rules that we can possibly detach is the smallest of these two
    const viewed = @min(rule_views_count, store.length());
    if (viewed > 0) {
        try self._detached_store.ensureUnusedCapacity(frame._factory.storageAllocator(), viewed);
    }

    for (store.entries()) |*entry| {
        if (self._rule_views.get(entry._id)) |view| {
            self.detach(view, entry.*);
        } else {
            self.freeEntry(entry, frame);
        }
    }
    store._len = 0;
}

/// JS holds the rule: it keeps working, out of the sheet.
fn detach(self: *CSSStyleSheet, view: *CSSRule, entry: Entry) void {
    if (entry._children) |children| {
        children.markDetached();
    }
    const detached = &self._detached_store;
    detached.appendAssumeCapacity(entry);
    view._store = detached;
    view._hint = detached.length() - 1;
    // Only a list JS can index looks rules up by id, and this one isn't. Its
    // nested rules keep theirs.
    _ = self._rule_views.remove(entry._id);
}

/// Frees an entry no view holds.
fn freeEntry(self: *CSSStyleSheet, entry: *Entry, frame: *Frame) void {
    if (comptime lp.IS_DEBUG) {
        // A nested rule's view comes from its parent's, so neither the entry
        // nor anything nested in it can have one
        std.debug.assert(self._rule_views.contains(entry._id) == false);
    }
    const allocator = frame._factory.storageAllocator();
    if (entry._children) |children| {
        for (children.entries()) |*child| {
            self.freeEntry(child, frame);
        }
        children.deinit(allocator);
    }
    entry.deinit(allocator);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleSheet);

    pub const Meta = struct {
        pub const name = "CSSStyleSheet";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(CSSStyleSheet.init, .{});
    pub const ownerNode = bridge.accessor(CSSStyleSheet.getOwnerNode, null, .{ .null_as_undefined = true });
    pub const href = bridge.accessor(CSSStyleSheet.getHref, null, .{ .null_as_undefined = true });
    pub const title = bridge.accessor(CSSStyleSheet.getTitle, null, .{});
    pub const disabled = bridge.accessor(CSSStyleSheet.getDisabled, CSSStyleSheet.setDisabled, .{});
    pub const cssRules = bridge.accessor(CSSStyleSheet.getCssRules, null, .{});
    pub const ownerRule = bridge.accessor(CSSStyleSheet.getOwnerRule, null, .{});
    pub const insertRule = bridge.function(CSSStyleSheet.insertRule, .{});
    pub const deleteRule = bridge.function(CSSStyleSheet.deleteRule, .{});
    pub const replace = bridge.function(CSSStyleSheet.replace, .{});
    pub const replaceSync = bridge.function(CSSStyleSheet.replaceSync, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CSSStyleSheet" {
    testing.silenceLog(&.{.js});
    try testing.htmlRunner("css/stylesheet.html", .{});
}

test "WebApi: CSSRule views" {
    try testing.htmlRunner("css/rule_views.html", .{});
}

test "WebApi: layer @-rule cascade" {
    try testing.htmlRunner("css/layer_at_rule_cascade.html", .{});
}

test "WebApi: layer order cascade" {
    try testing.htmlRunner("css/layer_order_cascade.html", .{});
}

test "WebApi: CSS nesting" {
    try testing.htmlRunner("css/nesting.html", .{});
}
