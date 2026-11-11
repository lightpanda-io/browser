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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");
const RuleStore = @import("../../css/RuleStore.zig");

const CSSRule = @import("CSSRule.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");
const CSSStyleProperties = @import("CSSStyleProperties.zig");

const CSSStyleRule = @This();

pub const Proto = CSSRule;

_rules: ?*CSSRuleList = null,
_style: ?*CSSStyleProperties = null,
_proto_canary: if (lp.IS_DEBUG) *CSSRule else void = undefined,

pub fn init(store: *RuleStore, id: u32, hint: u32, frame: *Frame) !*CSSStyleRule {
    return frame._factory.chained(.{
        CSSRule{ ._type = .style, ._store = store, ._id = id, ._hint = hint },
        CSSStyleRule{},
    });
}

pub fn asCSSRule(self: *CSSStyleRule) *CSSRule {
    return Factory.protoOf(self);
}

fn getSelectorText(self: *CSSStyleRule) []const u8 {
    return self.asCSSRule().entry().text();
}

fn setSelectorText(self: *CSSStyleRule, text: []const u8, frame: *Frame) !void {
    const rule = self.asCSSRule();
    try rule.entry().setText(frame._factory.storageAllocator(), text);
    rule.changed(frame);
}

fn getStyle(self: *CSSStyleRule, frame: *Frame) !*CSSStyleProperties {
    if (self._style) |style| {
        return style;
    }
    const style = try CSSStyleProperties.init(.{ .rule = self }, frame);
    self._style = style;
    return style;
}

/// The rules nested in this rule's block (CSS Nesting).
fn getCssRules(self: *CSSStyleRule, frame: *Frame) !*CSSRuleList {
    if (self._rules) |rules| {
        return rules;
    }
    const rule = self.asCSSRule();
    const entry = rule.entry();
    const children = entry._children orelse blk: {
        const children = try RuleStore.init(frame._factory.storageAllocator(), rule._store._sheet);
        children._detached = rule._store._detached;
        entry._children = children;
        break :blk children;
    };
    const rules = try CSSRuleList.init(children, frame);
    self._rules = rules;
    return rules;
}

pub fn getCssText(self: *CSSStyleRule, frame: *Frame) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    try writeCssText(self.asCSSRule().entry(), &buf, frame);
    return buf.written();
}

fn writeCssText(entry: *const RuleStore.Entry, buf: *std.Io.Writer.Allocating, frame: *Frame) !void {
    try buf.writer.print("{s} {{ ", .{entry.text()});
    const start = buf.written().len;
    try CSSStyleDeclaration.formatBlock(&entry._block, &buf.writer, frame);
    if (entry._children) |children| {
        for (children.entries()) |*child| {
            if (buf.written().len > start) {
                try buf.writer.writeByte(' ');
            }
            switch (child._kind) {
                .style => try writeCssText(child, buf, frame),
                else => try buf.writer.writeAll(child.text()),
            }
        }
    }
    try buf.writer.writeAll(" }");
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleRule);

    pub const Meta = struct {
        pub const name = "CSSStyleRule";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const selectorText = bridge.accessor(CSSStyleRule.getSelectorText, CSSStyleRule.setSelectorText, .{});
    pub const style = bridge.accessor(CSSStyleRule.getStyle, null, .{});
    pub const cssText = bridge.accessor(CSSStyleRule.getCssText, null, .{});
    pub const cssRules = bridge.accessor(CSSStyleRule.getCssRules, null, .{});
};
