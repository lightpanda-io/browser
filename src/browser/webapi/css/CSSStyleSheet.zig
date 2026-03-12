const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const CSSRule = @import("CSSRule.zig");
const CSSStyleRule = @import("CSSStyleRule.zig");
const Parser = @import("../../css/Parser.zig");

const CSSStyleSheet = @This();

_href: ?[]const u8 = null,
_title: []const u8 = "",
_disabled: bool = false,
_css_rules: ?*CSSRuleList = null,
_owner_rule: ?*CSSRule = null,
_owner_node: ?*Element = null,

pub fn init(page: *Page) !*CSSStyleSheet {
    return page._factory.create(CSSStyleSheet{});
}

pub fn initWithOwner(owner: *Element, page: *Page) !*CSSStyleSheet {
    return page._factory.create(CSSStyleSheet{ ._owner_node = owner });
}

pub fn getOwnerNode(self: *const CSSStyleSheet) ?*Element {
    return self._owner_node;
}

pub fn getHref(self: *const CSSStyleSheet) ?[]const u8 {
    return self._href;
}

pub fn getTitle(self: *const CSSStyleSheet) []const u8 {
    return self._title;
}

pub fn getDisabled(self: *const CSSStyleSheet) bool {
    return self._disabled;
}

pub fn setDisabled(self: *CSSStyleSheet, disabled: bool) void {
    self._disabled = disabled;
}

pub fn getCssRules(self: *CSSStyleSheet, page: *Page) !*CSSRuleList {
    if (self._css_rules) |rules| return rules;
    const rules = try CSSRuleList.init(page);
    self._css_rules = rules;
    return rules;
}

pub fn getOwnerRule(self: *const CSSStyleSheet) ?*CSSRule {
    return self._owner_rule;
}

pub fn insertRule(self: *CSSStyleSheet, rule: []const u8, index: u32, page: *Page) !u32 {
    var it = Parser.parseStylesheet(rule);
    const parsed_rule = it.next() orelse return error.SyntaxError;

    const style_rule = try CSSStyleRule.init(page);
    try style_rule.setSelectorText(parsed_rule.selector, page);

    const style = try style_rule.getStyle(page);
    try style.setCssText(parsed_rule.block, page);

    const rules = try self.getCssRules(page);
    try rules.insert(index, style_rule._proto, page);
    return index;
}

pub fn deleteRule(self: *CSSStyleSheet, index: u32, page: *Page) !void {
    const rules = try self.getCssRules(page);
    rules.remove(index);
}

pub fn replace(self: *CSSStyleSheet, text: []const u8, page: *Page) !js.Promise {
    try self.replaceSync(text, page);
    return page.js.local.?.resolvePromise({});
}

pub fn replaceSync(self: *CSSStyleSheet, text: []const u8, page: *Page) !void {
    const rules = try self.getCssRules(page);
    rules.clear();

    var it = Parser.parseStylesheet(text);
    var index: u32 = 0;
    while (it.next()) |parsed_rule| {
        const style_rule = try CSSStyleRule.init(page);
        try style_rule.setSelectorText(parsed_rule.selector, page);

        const style = try style_rule.getStyle(page);
        try style.setCssText(parsed_rule.block, page);

        try rules.insert(index, style_rule._proto, page);
        index += 1;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleSheet);

    pub const Meta = struct {
        pub const name = "CSSStyleSheet";
        pub const prototype_chain = bridge.prototypeChain();
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
    try testing.htmlRunner("css/stylesheet.html", .{});
}
