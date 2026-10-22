const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const CSSRule = @import("CSSRule.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const CSSStyleProperties = @import("CSSStyleProperties.zig");

const CSSStyleRule = @This();

pub const Proto = CSSRule;

_proto: *CSSRule,
_selector_text: []const u8 = "",
_style: ?*CSSStyleProperties = null,
/// The rules nested in this rule's block (CSS Nesting), null when there are
/// none. A nested style rule keeps its selector as written (`&.active`).
_rules: ?*CSSRuleList = null,

pub fn init(frame: *Frame) !*CSSStyleRule {
    const style_rule = try frame._factory.chained(.{
        CSSRule{ ._type = undefined },
        CSSStyleRule{ ._proto = undefined },
    });
    style_rule._proto._type = .{ .style = style_rule };
    return style_rule;
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
                .style => |nested| try nested.getCssText(frame),
                else => rule._text,
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
