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

const CSSRule = @import("CSSRule.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const GenericRule = @import("GenericRule.zig");
const CSSStyleProperties = @import("CSSStyleProperties.zig");

const CSSStyleRule = @This();

pub const Proto = CSSRule;

_selector_text: []const u8 = "",
_style: ?*CSSStyleProperties = null,
/// The rules nested in this rule's block (CSS Nesting), null when there are
/// none. A nested style rule keeps its selector as written (`&.active`).
_rules: ?*CSSRuleList = null,
_proto_canary: if (lp.IS_DEBUG) *CSSRule else void = undefined,

pub fn init(frame: *Frame) !*CSSStyleRule {
    return frame._factory.chained(.{
        CSSRule{ ._type = .style },
        CSSStyleRule{},
    });
}

pub fn asCSSRule(self: *CSSStyleRule) *CSSRule {
    return Factory.protoOf(self);
}

fn getSelectorText(self: *const CSSStyleRule) []const u8 {
    return self._selector_text;
}

pub fn setSelectorText(self: *CSSStyleRule, text: []const u8, frame: *Frame) !void {
    self._selector_text = try frame.dupeString(text);
}

pub fn getStyle(self: *CSSStyleRule, frame: *Frame) !*CSSStyleProperties {
    if (self._style) |style| {
        return style;
    }
    const style = try CSSStyleProperties.init(null, false, frame);
    self._style = style;
    return style;
}

pub fn getCssRules(self: *CSSStyleRule, frame: *Frame) !*CSSRuleList {
    if (self._rules) |rules| {
        return rules;
    }
    const rules = try CSSRuleList.init(frame);
    self._rules = rules;
    return rules;
}

pub fn getCssText(self: *CSSStyleRule, frame: *Frame) ![]const u8 {
    const style_props = try self.getStyle(frame);
    const style = style_props.asCSSStyleDeclaration();
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    try buf.writer.print("{s} {{ ", .{self._selector_text});
    const start = buf.written().len;
    try style.format(&buf.writer);
    if (self._rules) |rules| {
        for (rules._rules.items) |rule| {
            if (buf.written().len > start) {
                try buf.writer.writeByte(' ');
            }
            const text = switch (rule._type) {
                .style => try rule.as(CSSStyleRule).getCssText(frame),
                .generic => rule.as(GenericRule)._text,
            };
            try buf.writer.writeAll(text);
        }
    }
    try buf.writer.writeAll(" }");
    return buf.written();
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
