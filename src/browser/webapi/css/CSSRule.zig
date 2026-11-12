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
const Factory = @import("../../Factory.zig");

const RuleStore = @import("../../css/RuleStore.zig");

const GenericRule = @import("GenericRule.zig");
const CSSStyleRule = @import("CSSStyleRule.zig");
const CSSStyleSheet = @import("CSSStyleSheet.zig");

/// A view of one entry in a RuleStore. The sheet keeps one view per rule
/// (see CSSStyleSheet.ruleView), so a rule read twice is the same object.
const CSSRule = @This();

pub const Type = enum(u8) {
    style,
    generic,
};

_type: Type,
_id: u32,

// The rule's position in `_store` when last seen: inserts and deletes shift it.
_hint: u32,

// Either the sheet's `_store`, a rule's nested one, or `_detached_store`.
_store: *RuleStore,

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .style => CSSStyleRule,
        .generic => GenericRule,
    };
}

fn tagOf(comptime T: type) Type {
    if (T == CSSStyleRule) {
        return .style;
    }
    if (T == GenericRule) {
        return .generic;
    }
    @compileError(@typeName(T) ++ " is not a CSSRule subtype");
}

// Takes a const rule but returns a mutable subtype; see Node.subtype.
pub fn subtype(self: *const CSSRule, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, CSSRule);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // The arithmetic rides on the factory allocating the chain in one
        // block; the _proto_canary back pointer checks it.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *const CSSRule, comptime T: type) ?*T {
    if (self._type != comptime tagOf(T)) {
        return null;
    }
    return self.subtype(T);
}

pub fn as(self: *const CSSRule, comptime T: type) *T {
    return self.is(T).?;
}

/// The rule's entry. Only valid until the list next changes.
pub fn entry(self: *CSSRule) *RuleStore.Entry {
    const index = self._store.indexOf(self._id, self._hint).?;
    self._hint = index;
    return &self._store.entries()[index];
}

pub fn changed(self: *const CSSRule, frame: *Frame) void {
    if (self._store._detached) {
        // removed from the sheet. Not in any cascade
        return;
    }
    self._store._sheet.rulesModified(frame);
}

pub fn getType(self: *CSSRule) u16 {
    return self.entry()._kind.ruleType();
}

pub fn getCssText(self: *CSSRule, frame: *Frame) ![]const u8 {
    return switch (self._type) {
        .style => self.subtype(CSSStyleRule).getCssText(frame),
        .generic => self.entry().text(),
    };
}

fn getParentRule(_: *const CSSRule) ?*CSSRule {
    return null;
}

fn getParentStyleSheet(self: *const CSSRule) ?*CSSStyleSheet {
    if (self._store._detached) {
        return null;
    }
    return self._store._sheet;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSRule);

    pub const Meta = struct {
        pub const name = "CSSRule";
        pub var class_id: bridge.ClassId = undefined;
    };

    // Spec rule-type constants. Wrapped with `bridge.property(.template)` so
    // they're exposed on the JS-side `CSSRule` constructor (e.g.
    // `CSSRule.KEYFRAMES_RULE === 7`). Without the wrapping these are plain
    // Zig declarations that never reach JS, and code reading them gets
    // `undefined`.
    pub const STYLE_RULE = bridge.property(1, .{ .template = true });
    pub const CHARSET_RULE = bridge.property(2, .{ .template = true });
    pub const IMPORT_RULE = bridge.property(3, .{ .template = true });
    pub const MEDIA_RULE = bridge.property(4, .{ .template = true });
    pub const FONT_FACE_RULE = bridge.property(5, .{ .template = true });
    pub const PAGE_RULE = bridge.property(6, .{ .template = true });
    pub const KEYFRAMES_RULE = bridge.property(7, .{ .template = true });
    pub const KEYFRAME_RULE = bridge.property(8, .{ .template = true });
    pub const MARGIN_RULE = bridge.property(9, .{ .template = true });
    pub const NAMESPACE_RULE = bridge.property(10, .{ .template = true });
    pub const COUNTER_STYLE_RULE = bridge.property(11, .{ .template = true });
    pub const SUPPORTS_RULE = bridge.property(12, .{ .template = true });
    pub const DOCUMENT_RULE = bridge.property(13, .{ .template = true });
    pub const FONT_FEATURE_VALUES_RULE = bridge.property(14, .{ .template = true });
    pub const VIEWPORT_RULE = bridge.property(15, .{ .template = true });
    pub const REGION_STYLE_RULE = bridge.property(16, .{ .template = true });

    pub const @"type" = bridge.accessor(CSSRule.getType, null, .{});
    pub const cssText = bridge.accessor(CSSRule.getCssText, null, .{});
    pub const parentRule = bridge.accessor(CSSRule.getParentRule, null, .{});
    pub const parentStyleSheet = bridge.accessor(CSSRule.getParentStyleSheet, null, .{});
};
