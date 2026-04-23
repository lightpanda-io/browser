const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Parser = @import("../../css/Parser.zig");

const Element = @import("../Element.zig");

const CSSRuleList = @import("CSSRuleList.zig");
const CSSRule = @import("CSSRule.zig");
const CSSStyleRule = @import("CSSStyleRule.zig");

const log = lp.log;

const CSSStyleSheet = @This();

pub const CSSError = error{
    OutOfMemory,
    IndexSizeError,
    WriteFailed,
    StringTooLarge,
    SyntaxError,
};

_href: ?[]const u8 = null,
_title: []const u8 = "",
_disabled: bool = false,
_css_rules: ?*CSSRuleList = null,
_owner_rule: ?*CSSRule = null,
_owner_node: ?*Element = null,

pub fn init(frame: *Frame) !*CSSStyleSheet {
    return frame._factory.create(CSSStyleSheet{});
}

pub fn initWithOwner(owner: *Element, frame: *Frame) !*CSSStyleSheet {
    return frame._factory.create(CSSStyleSheet{ ._owner_node = owner });
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

pub fn getCssRules(self: *CSSStyleSheet, frame: *Frame) !*CSSRuleList {
    if (self._css_rules) |rules| return rules;

    const rules = try CSSRuleList.init(frame);
    self._css_rules = rules;

    if (self.getOwnerNode()) |owner| {
        if (owner.is(Element.Html.Style)) |style| {
            const text = try style.asNode().getTextContentAlloc(frame.call_arena);
            try self.replaceSync(text, frame);
        }
    }

    return rules;
}

pub fn getOwnerRule(self: *const CSSStyleSheet) ?*CSSRule {
    return self._owner_rule;
}

pub fn insertRule(self: *CSSStyleSheet, rule: []const u8, maybe_index: ?u32, frame: *Frame) !u32 {
    const requested_index = maybe_index orelse 0;
    var it = Parser.parseStylesheet(rule);
    const parsed_rule = it.next() orelse {
        if (it.has_skipped_at_rule) {
            log.debug(.not_implemented, "CSSStyleSheet.insertRule", .{});
            // Lightpanda currently skips at-rules (e.g., @keyframes, @media) in its
            // CSS parser. To prevent JS apps (like Expo/Reanimated) from crashing
            // during initialization, we simulate a successful insertion by returning
            // the requested index.
            return requested_index;
        }
        return error.SyntaxError;
    };

    if (it.next() != null) return error.SyntaxError;

    const style_rule = try CSSStyleRule.init(frame);
    try style_rule.setSelectorText(parsed_rule.selector, frame);

    const style_props = try style_rule.getStyle(frame);
    const style = style_props.asCSSStyleDeclaration();
    try style.setCssText(parsed_rule.block, frame);

    const rules = try self.getCssRules(frame);

    // Per spec, an index > rules.length should throw IndexSizeError. But because
    // we don't process @import and @font-face, indexes that code hard-codes can
    // be off. As a workaround, we clamp to the tail.
    // See #2214 (and the sibling #1970 / #1972 tolerance for at-rules).
    const length = rules.length();
    const index = if (requested_index > length) length else requested_index;
    if (index != requested_index) {
        log.debug(.not_implemented, "insertRule clamped index", .{});
    }
    try rules.insert(index, style_rule._proto, frame);

    // Notify StyleManager that rules have changed
    frame._style_manager.sheetModified();

    return index;
}

pub fn deleteRule(self: *CSSStyleSheet, index: u32, frame: *Frame) !void {
    const rules = try self.getCssRules(frame);
    try rules.remove(index);

    // Notify StyleManager that rules have changed
    frame._style_manager.sheetModified();
}

pub fn replace(self: *CSSStyleSheet, text: []const u8, frame: *Frame) CSSError!js.Promise {
    try self.replaceSync(text, frame);
    return frame.js.local.?.resolvePromise(self);
}

pub fn replaceSync(self: *CSSStyleSheet, text: []const u8, frame: *Frame) CSSError!void {
    const rules = try self.getCssRules(frame);
    rules.clear();

    var it = Parser.parseStylesheet(text);
    var index: u32 = 0;
    while (it.next()) |parsed_rule| {
        const style_rule = try CSSStyleRule.init(frame);
        try style_rule.setSelectorText(parsed_rule.selector, frame);

        const style_props = try style_rule.getStyle(frame);
        const style = style_props.asCSSStyleDeclaration();
        try style.setCssText(parsed_rule.block, frame);

        try rules.insert(index, style_rule._proto, frame);
        index += 1;
    }

    // Notify StyleManager that rules have changed
    frame._style_manager.sheetModified();
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
    pub const insertRule = bridge.function(CSSStyleSheet.insertRule, .{ .dom_exception = true });
    pub const deleteRule = bridge.function(CSSStyleSheet.deleteRule, .{ .dom_exception = true });
    pub const replace = bridge.function(CSSStyleSheet.replace, .{});
    pub const replaceSync = bridge.function(CSSStyleSheet.replaceSync, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CSSStyleSheet" {
    const filter: testing.LogFilter = .init(&.{.js});
    defer filter.deinit();
    try testing.htmlRunner("css/stylesheet.html", .{});
}
