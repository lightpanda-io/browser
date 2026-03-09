const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const CSSRule = @import("CSSRule.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");

const CSSStyleSheet = @This();

_href: ?[]const u8 = null,
_title: []const u8 = "",
_disabled: bool = false,
_css_rules: ?*CSSRuleList = null,
_owner_rule: ?*CSSRule = null,
_owner_node: ?*Element = null,
_rules: []ParsedRule = &.{},

const ParsedRule = struct {
    selector_text: []const u8,
    declarations_text: []const u8,
    rule: *CSSRule,
};

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
    try self.refreshRuleList(page);
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
    try self.replaceSync(text, page);
    return page.js.local.?.resolvePromise({});
}

pub fn replaceSync(self: *CSSStyleSheet, text: []const u8, page: *Page) !void {
    var parsed: std.ArrayList(ParsedRule) = .{};
    defer parsed.deinit(page.arena);

    var cursor: usize = 0;
    while (cursor < text.len) {
        const selector_start = skipWhitespaceAndComments(text, cursor);
        if (selector_start >= text.len) break;

        const open_index = std.mem.indexOfScalarPos(u8, text, selector_start, '{') orelse break;
        const close_index = findMatchingBrace(text, open_index) orelse break;
        cursor = close_index + 1;

        const selector_text = std.mem.trim(u8, text[selector_start..open_index], &std.ascii.whitespace);
        const declarations_text = std.mem.trim(u8, text[open_index + 1 .. close_index], &std.ascii.whitespace);
        if (selector_text.len == 0 or declarations_text.len == 0) continue;
        if (selector_text[0] == '@') continue;

        const rule_text = std.mem.trim(u8, text[selector_start .. close_index + 1], &std.ascii.whitespace);
        const rule = try CSSRule.init(.style, page);
        try rule.setCssText(rule_text, page);

        try parsed.append(page.arena, .{
            .selector_text = try page.dupeString(selector_text),
            .declarations_text = try page.dupeString(declarations_text),
            .rule = rule,
        });
    }

    self._rules = try page.arena.dupe(ParsedRule, parsed.items);
    try self.refreshRuleList(page);
}

pub fn applyMatchingRules(self: *const CSSStyleSheet, element: *Element, decl: *CSSStyleDeclaration, page: *Page) !void {
    if (self._disabled) return;

    for (self._rules) |entry| {
        if (!(try element.matches(entry.selector_text, page))) {
            continue;
        }
        try decl.applyDeclarationsText(entry.declarations_text, page);
    }
}

fn refreshRuleList(self: *CSSStyleSheet, page: *Page) !void {
    const rules = if (self._css_rules) |rules| rules else return;
    var out: std.ArrayList(*CSSRule) = .{};
    defer out.deinit(page.arena);
    for (self._rules) |entry| {
        try out.append(page.arena, entry.rule);
    }
    try rules.setRules(page, out.items);
}

fn skipWhitespaceAndComments(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return text.len;
            i = end + 2;
            continue;
        }
        break;
    }
    return i;
}

fn findMatchingBrace(text: []const u8, open_index: usize) ?usize {
    var depth: usize = 0;
    var i = open_index;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
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
