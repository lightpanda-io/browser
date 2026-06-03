const std = @import("std");

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Marquee = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Marquee) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Marquee) *Node {
    return self.asElement().asNode();
}

pub fn getBehavior(self: *Marquee) []const u8 {
    const valid_behavior = [_][]const u8{
        "scroll", "slide", "alternate",
    };
    return HtmlElement.reflectEnumerated(self.asElement().getAttributeSafe(comptime .wrap("behavior")), &valid_behavior, "scroll", "scroll").?;
}

pub fn setBehavior(self: *Marquee, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("behavior"), .wrap(value), frame);
}

pub fn getDirection(self: *Marquee) []const u8 {
    const valid_direction = [_][]const u8{
        "up", "right", "down", "left",
    };
    return HtmlElement.reflectEnumerated(self.asElement().getAttributeSafe(comptime .wrap("direction")), &valid_direction, "left", "left").?;
}

pub fn setDirection(self: *Marquee, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("direction"), .wrap(value), frame);
}

pub fn getBgColor(self: *Marquee) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("bgcolor")) orelse "";
}

pub fn setBgColor(self: *Marquee, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("bgcolor"), .wrap(value), frame);
}

pub fn getHeight(self: *Marquee) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("height")) orelse "";
}

pub fn setHeight(self: *Marquee, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(value), frame);
}

pub fn getWidth(self: *Marquee) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("width")) orelse "";
}

pub fn setWidth(self: *Marquee, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(value), frame);
}

pub fn getHspace(self: *Marquee) u32 {
    return getU32(self, "hspace", 0);
}

pub fn setHspace(self: *Marquee, value: u32, frame: *Frame) !void {
    try setU32(self, "hspace", value, 0, frame);
}

pub fn getVspace(self: *Marquee) u32 {
    return getU32(self, "vspace", 0);
}

pub fn setVspace(self: *Marquee, value: u32, frame: *Frame) !void {
    try setU32(self, "vspace", value, 0, frame);
}

pub fn getScrollAmount(self: *Marquee) u32 {
    return getU32(self, "scrollamount", 6);
}

pub fn setScrollAmount(self: *Marquee, value: u32, frame: *Frame) !void {
    try setU32(self, "scrollamount", value, 6, frame);
}

pub fn getScrollDelay(self: *Marquee) u32 {
    return getU32(self, "scrolldelay", 85);
}

pub fn setScrollDelay(self: *Marquee, value: u32, frame: *Frame) !void {
    try setU32(self, "scrolldelay", value, 85, frame);
}

pub fn getTrueSpeed(self: *Marquee) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("truespeed")) != null;
}

pub fn setTrueSpeed(self: *Marquee, truespeed: bool, frame: *Frame) !void {
    if (truespeed) {
        try self.asElement().setAttributeSafe(comptime .wrap("truespeed"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("truespeed"), frame);
    }
}

// Reflects an `unsigned long` content attribute: parses with the "rules for
// parsing non-negative integers" (the lax integer parser, then rejecting a
// negative result), so a valid value lands in [0, 2147483647].
fn getU32(self: *Marquee, comptime attr: []const u8, default: u32) u32 {
    const value = self.asElement().getAttributeSafe(comptime .wrap(attr)) orelse return default;
    const parsed = HtmlElement.parseInteger(value) orelse return default;

    if (parsed < 0) {
        return default;
    }
    return @intCast(parsed);
}

fn setU32(self: *Marquee, comptime attr: []const u8, value: u32, default: u32, frame: *Frame) !void {
    const written = if (value > 2147483647) default else value;
    var buf: [10]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{written}) catch unreachable;
    try self.asElement().setAttributeSafe(comptime .wrap(attr), .wrap(str), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Marquee);

    pub const Meta = struct {
        pub const name = "HTMLMarqueeElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const behavior = bridge.accessor(Marquee.getBehavior, Marquee.setBehavior, .{ .ce_reactions = true });
    pub const bgColor = bridge.accessor(Marquee.getBgColor, Marquee.setBgColor, .{ .ce_reactions = true });
    pub const direction = bridge.accessor(Marquee.getDirection, Marquee.setDirection, .{ .ce_reactions = true });
    pub const height = bridge.accessor(Marquee.getHeight, Marquee.setHeight, .{ .ce_reactions = true });
    pub const hspace = bridge.accessor(Marquee.getHspace, Marquee.setHspace, .{ .ce_reactions = true });
    pub const scrollAmount = bridge.accessor(Marquee.getScrollAmount, Marquee.setScrollAmount, .{ .ce_reactions = true });
    pub const scrollDelay = bridge.accessor(Marquee.getScrollDelay, Marquee.setScrollDelay, .{ .ce_reactions = true });
    pub const trueSpeed = bridge.accessor(Marquee.getTrueSpeed, Marquee.setTrueSpeed, .{ .ce_reactions = true });
    pub const vspace = bridge.accessor(Marquee.getVspace, Marquee.setVspace, .{ .ce_reactions = true });
    pub const width = bridge.accessor(Marquee.getWidth, Marquee.setWidth, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Marquee" {
    try testing.htmlRunner("element/html/marquee.html", .{});
}
