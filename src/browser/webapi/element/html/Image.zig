const std = @import("std");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const URL = @import("../../../URL.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Event = @import("../../Event.zig");
const log = @import("../../../../log.zig");

const Image = @This();
_proto: *HtmlElement,

pub fn constructor(w_: ?u32, h_: ?u32, page: *Page) !*Image {
    const node = try page.createElementNS(.html, "img", null);
    const el = node.as(Element);

    if (w_) |w| blk: {
        const w_string = std.fmt.bufPrint(&page.buf, "{d}", .{w}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("width"), .wrap(w_string), page);
    }
    if (h_) |h| blk: {
        const h_string = std.fmt.bufPrint(&page.buf, "{d}", .{h}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("height"), .wrap(h_string), page);
    }
    return el.as(Image);
}

pub fn asElement(self: *Image) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Image) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Image, page: *Page) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }

    // Always resolve the src against the page URL
    return URL.resolve(page.call_arena, page.base(), src, .{});
}

pub fn setSrc(self: *Image, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), page);

    const event_target = self.asNode().asEventTarget();

    // Have to do this since `Scheduler` only allow passing a single arg.
    const SetSrcCallback = struct {
        page: *Page,
        event_target: *@import("../../EventTarget.zig"),
    };
    const args = try page._factory.create(SetSrcCallback{
        .page = page,
        .event_target = event_target,
    });
    errdefer page._factory.destroy(args);

    // We don't actually fetch the media, here we fake the load call.
    try page.scheduler.add(
        args,
        struct {
            fn wrap(raw: *anyopaque) anyerror!?u32 {
                const _args: *SetSrcCallback = @ptrCast(@alignCast(raw));
                const _page = _args.page;
                defer _page._factory.destroy(_args);
                // Dispatch.
                const event = try Event.initTrusted("load", .{}, _page);
                try _page._event_manager.dispatch(_args.event_target, event);

                return null;
            }
        }.wrap,
        25,
        .{
            .low_priority = false,
            .name = "Image.setSrc",
        },
    );
}

pub fn getAlt(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("alt")) orelse "";
}

pub fn setAlt(self: *Image, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("alt"), .wrap(value), page);
}

pub fn getWidth(self: *const Image) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setWidth(self: *Image, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), page);
}

pub fn getHeight(self: *const Image) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setHeight(self: *Image, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), page);
}

pub fn getCrossOrigin(self: *const Image) ?[]const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("crossorigin"));
}

pub fn setCrossOrigin(self: *Image, value: ?[]const u8, page: *Page) !void {
    if (value) |v| {
        return self.asElement().setAttributeSafe(comptime .wrap("crossorigin"), .wrap(v), page);
    }
    return self.asElement().removeAttribute(comptime .wrap("crossorigin"), page);
}

pub fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("loading")) orelse "eager";
}

pub fn setLoading(self: *Image, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("loading"), .wrap(value), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);

    pub const Meta = struct {
        pub const name = "HTMLImageElement";
        pub const constructor_alias = "Image";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Image.constructor, .{});
    pub const src = bridge.accessor(Image.getSrc, Image.setSrc, .{});
    pub const alt = bridge.accessor(Image.getAlt, Image.setAlt, .{});
    pub const width = bridge.accessor(Image.getWidth, Image.setWidth, .{});
    pub const height = bridge.accessor(Image.getHeight, Image.setHeight, .{});
    pub const crossOrigin = bridge.accessor(Image.getCrossOrigin, Image.setCrossOrigin, .{});
    pub const loading = bridge.accessor(Image.getLoading, Image.setLoading, .{});
};

/// Argument passed to `dispatchLoadEvent`.
const CallbackParams = struct { page: *Page, element: *Element };

/// Callback passed to `Scheduler` to execute load listeners.
fn dispatchLoadEvent(raw: *anyopaque) !?u32 {
    const _args: *CallbackParams = @ptrCast(@alignCast(raw));
    const _page = _args.page;
    defer _page._factory.destroy(_args);

    const _element = _args.element;
    const _img = _element.as(Image);
    const event_target = _element.asEventTarget();
    const event = try Event.initTrusted("load", .{}, _page);

    // If onload provided, dispatch with it.
    if (_img.getOnLoad(_page)) |_on_load| {
        var ls: js.Local.Scope = undefined;
        _page.js.localScope(&ls);
        defer ls.deinit();

        try _page._event_manager.dispatchWithFunction(
            event_target,
            event,
            _on_load.local(&ls.local),
            .{ .context = "Image.onload" },
        );
        return null;
    }

    // Dispatch to addEventListener listeners.
    try _page._event_manager.dispatch(event_target, event);
    return null;
}

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}
