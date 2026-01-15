const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const CSSRule = @import("CSSRule.zig");

const CSSStyleSheet = @This();

_href: ?[]const u8 = null,
_title: []const u8 = "",
_disabled: bool = false,
_css_rules: ?*CSSRuleList = null,
_owner_rule: ?*CSSRule = null,

pub fn init(page: *Page) !*CSSStyleSheet {
    return page._factory.create(CSSStyleSheet{});
}

pub fn getOwnerNode(self: *const CSSStyleSheet) ?*CSSStyleSheet {
    _ = self;
    return null;
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
    _ = self;
    _ = rule;
    _ = index;
    _ = page;
    return 0;
}

pub fn deleteRule(self: *CSSStyleSheet, index: u32, page: *Page) !void {
    _ = self;
    _ = index;
    _ = page;
}

pub fn replace(self: *CSSStyleSheet, text: []const u8, page: *Page) !js.Promise {
    _ = self;
    _ = text;
    // TODO: clear self.css_rules
    return page.js.local.?.resolvePromise({});
}

pub fn replaceSync(self: *CSSStyleSheet, text: []const u8) !void {
    _ = self;
    _ = text;
    // TODO: clear self.css_rules
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
