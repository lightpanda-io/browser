const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const CSSRule = @import("CSSRule.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");

const CSSStyleRule = @This();

_proto: *CSSRule,
_selector_text: []const u8 = "",
_style: ?*CSSStyleDeclaration = null,

pub fn init(page: *Page) !*CSSStyleRule {
    const rule = try CSSRule.init(.style, page);
    return page._factory.create(CSSStyleRule{
        ._proto = rule,
    });
}

pub fn getSelectorText(self: *const CSSStyleRule) []const u8 {
    return self._selector_text;
}

pub fn setSelectorText(self: *CSSStyleRule, text: []const u8, page: *Page) !void {
    self._selector_text = try page.dupeString(text);
}

pub fn getStyle(self: *CSSStyleRule, page: *Page) !*CSSStyleDeclaration {
    if (self._style) |style| {
        return style;
    }
    const style = try CSSStyleDeclaration.init(null, false, page);
    self._style = style;
    return style;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleRule);

    pub const Meta = struct {
        pub const name = "CSSStyleRule";
        pub const prototype_chain = bridge.prototypeChain(CSSRule);
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const selectorText = bridge.accessor(CSSStyleRule.getSelectorText, CSSStyleRule.setSelectorText, .{});
    pub const style = bridge.accessor(CSSStyleRule.getStyle, null, .{});
};
