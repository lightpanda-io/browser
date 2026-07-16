const std = @import("std");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Source = @This();

_proto: *HtmlElement,

pub fn asElement(self: *Source) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Source) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Source) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Source, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *Source, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub fn getSrcset(self: *const Source) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("srcset")) orelse "";
}

pub fn setSrcset(self: *Source, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("srcset"), .wrap(value), frame);
}

pub fn getSizes(self: *const Source) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("sizes")) orelse "";
}

pub fn setSizes(self: *Source, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("sizes"), .wrap(value), frame);
}

pub fn getMedia(self: *const Source) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("media")) orelse "";
}

pub fn setMedia(self: *Source, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("media"), .wrap(value), frame);
}

pub fn getType(self: *const Source) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse "";
}

pub fn setType(self: *Source, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(value), frame);
}

pub fn getWidth(self: *const Source) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setWidth(self: *Source, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);
}

pub fn getHeight(self: *const Source) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setHeight(self: *Source, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Source);

    pub const Meta = struct {
        pub const name = "HTMLSourceElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const height = bridge.accessor(Source.getHeight, Source.setHeight, .{ .ce_reactions = true });
    pub const media = bridge.accessor(Source.getMedia, Source.setMedia, .{ .ce_reactions = true });
    pub const sizes = bridge.accessor(Source.getSizes, Source.setSizes, .{ .ce_reactions = true });
    pub const src = bridge.accessor(Source.getSrc, Source.setSrc, .{ .ce_reactions = true });
    pub const srcset = bridge.accessor(Source.getSrcset, Source.setSrcset, .{ .ce_reactions = true });
    pub const @"type" = bridge.accessor(Source.getType, Source.setType, .{ .ce_reactions = true });
    pub const width = bridge.accessor(Source.getWidth, Source.setWidth, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Source" {
    try testing.htmlRunner("element/html/source.html", .{});
}
