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
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Http = @import("../../../../http/Http.zig");

const URL = @import("../../URL.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Event = @import("../../Event.zig");
const HtmlElement = @import("../Html.zig");
const CSSStyleSheet = @import("../../css/CSSStyleSheet.zig");
const STYLESHEET_ACCEPT_HEADER: [:0]const u8 = "Accept: text/css,*/*;q=0.1";

const Link = @This();
_proto: *HtmlElement,
_sheet: ?*CSSStyleSheet = null,
_stylesheet_load_scheduled: bool = false,

pub fn asElement(self: *Link) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Link) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Link) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Link, page: *Page) ![]const u8 {
    const element = self.asElement();
    const href = element.getAttributeSafe(comptime .wrap("href")) orelse return "";
    if (href.len == 0) {
        return "";
    }

    // Always resolve the href against the page URL
    return URL.resolve(page.call_arena, page.base(), href, .{ .encode = true });
}

pub fn setHref(self: *Link, value: []const u8, page: *Page) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("href"), .wrap(value), page);

    if (element.asNode().isConnected()) {
        try self.linkAddedCallback(page);
    }
}

pub fn getRel(self: *Link) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("rel")) orelse return "";
}

pub fn setRel(self: *Link, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("rel"), .wrap(value), page);
    if (self.asNode().isConnected()) {
        try self.linkAddedCallback(page);
    }
}

pub fn getAs(self: *const Link) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("as")) orelse "";
}

pub fn setAs(self: *Link, value: []const u8, page: *Page) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("as"), .wrap(value), page);
}

pub fn getCrossOrigin(self: *const Link) ?[]const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("crossOrigin"));
}

pub fn setCrossOrigin(self: *Link, value: []const u8, page: *Page) !void {
    var normalized: []const u8 = "anonymous";
    if (std.ascii.eqlIgnoreCase(value, "use-credentials")) {
        normalized = "use-credentials";
    }
    return self.asElement().setAttributeSafe(comptime .wrap("crossOrigin"), .wrap(normalized), page);
}

pub fn getSheet(self: *Link, page: *Page) !?*CSSStyleSheet {
    if (!self.asNode().isConnected()) {
        self._sheet = null;
        return null;
    }
    if (!self.isStylesheetLink()) {
        self._sheet = null;
        return null;
    }

    const href = try self.getHref(page);
    if (href.len == 0) {
        self._sheet = null;
        return null;
    }

    if (self._sheet == null) {
        self._sheet = try CSSStyleSheet.initWithOwner(self.asElement(), page);
    }

    self._sheet.?._href = try page.arena.dupe(u8, href);
    self._sheet.?._title = self.asElement().getAttributeSafe(comptime .wrap("title")) orelse "";
    return self._sheet.?;
}

pub fn linkAddedCallback(self: *Link, page: *Page) !void {
    // if we're planning on navigating to another page, don't trigger load event.
    if (page.isGoingAway()) {
        return;
    }

    const sheet = (try self.getSheet(page)) orelse return;
    _ = sheet;
    if (self._stylesheet_load_scheduled) {
        return;
    }

    self._stylesheet_load_scheduled = true;
    const callback = try page.arena.create(StylesheetLoadCallback);
    callback.* = .{
        .link = self,
        .page = page,
    };
    try page.js.scheduler.add(callback, StylesheetLoadCallback.run, 0, .{
        .name = "HTMLLinkElement.loadStylesheet",
        .low_priority = false,
    });
}

fn isStylesheetLink(self: *const Link) bool {
    const rel = self.asConstElement().getAttributeSafe(comptime .wrap("rel")) orelse return false;
    return std.ascii.eqlIgnoreCase(rel, "stylesheet");
}

fn dispatchLoad(self: *Link, page: *Page) !void {
    if (!page._event_manager.has_dom_load_listener and !self._proto.hasAttributeFunction(.onload, page)) {
        return;
    }

    const event = try Event.initTrusted(comptime .wrap("load"), .{}, page);
    try page._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

const StylesheetFetchContext = struct {
    html: *HtmlElement,
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    status: u16 = 0,
    finished: bool = false,
    failed: ?anyerror = null,
};

const StylesheetLoadCallback = struct {
    link: *Link,
    page: *Page,

    fn run(ctx: *anyopaque) !?u32 {
        const callback: *StylesheetLoadCallback = @ptrCast(@alignCast(ctx));
        callback.link._stylesheet_load_scheduled = false;

        if (callback.page.isGoingAway()) {
            return null;
        }

        const sheet = (try callback.link.getSheet(callback.page)) orelse return null;
        _ = sheet;
        callback.link.fetchStylesheet(callback.page) catch return null;
        try callback.link.dispatchLoad(callback.page);
        return null;
    }
};

fn fetchStylesheet(self: *Link, page: *Page) !void {
    const href = try self.getHref(page);
    if (href.len == 0) {
        return;
    }

    var arena = std.heap.ArenaAllocator.init(page.arena);
    defer arena.deinit();
    const temp = arena.allocator();
    const url = try temp.dupeZ(u8, href);

    var ctx = StylesheetFetchContext{
        .html = self._proto,
        .allocator = page.arena,
        .buffer = .{},
    };
    defer ctx.buffer.deinit(page.arena);

    var headers = try page._session.browser.http_client.newHeaders();
    try headers.add(STYLESHEET_ACCEPT_HEADER);
    try page.headersForRequest(page.arena, url, &headers);

    try page._session.browser.http_client.request(.{
        .url = url,
        .ctx = &ctx,
        .method = .GET,
        .frame_id = page._frame_id,
        .headers = headers,
        .cookie_jar = &page._session.cookie_jar,
        .resource_type = .stylesheet,
        .notification = page._session.notification,
        .header_callback = stylesheetHeaderCallback,
        .data_callback = stylesheetDataCallback,
        .done_callback = stylesheetDoneCallback,
        .error_callback = stylesheetErrorCallback,
    });

    while (!ctx.finished and ctx.failed == null) {
        _ = try page._session.browser.http_client.tick(50);
    }

    if (ctx.failed) |err| {
        return err;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Link);

    pub const Meta = struct {
        pub const name = "HTMLLinkElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const as = bridge.accessor(Link.getAs, Link.setAs, .{});
    pub const rel = bridge.accessor(Link.getRel, Link.setRel, .{});
    pub const href = bridge.accessor(Link.getHref, Link.setHref, .{});
    pub const sheet = bridge.accessor(Link.getSheet, null, .{ .null_as_undefined = true });
    pub const crossOrigin = bridge.accessor(Link.getCrossOrigin, Link.setCrossOrigin, .{});
    pub const relList = bridge.accessor(_getRelList, null, .{ .null_as_undefined = true });

    fn _getRelList(self: *Link, page: *Page) !?*@import("../../collections.zig").DOMTokenList {
        const element = self.asElement();
        // relList is only valid for HTML <link> elements, not SVG or MathML
        if (element._namespace != .html) {
            return null;
        }
        return element.getRelList(page);
    }
};

fn stylesheetHeaderCallback(transfer: *Http.Transfer) !bool {
    const ctx: *StylesheetFetchContext = @ptrCast(@alignCast(transfer.ctx));
    const response_header = transfer.response_header orelse return true;
    ctx.status = response_header.status;
    if (response_header.status >= 400) {
        ctx.failed = error.BadStatusCode;
    }
    return true;
}

fn stylesheetDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    const ctx: *StylesheetFetchContext = @ptrCast(@alignCast(transfer.ctx));
    try ctx.buffer.appendSlice(ctx.allocator, data);
}

fn stylesheetDoneCallback(ctx_ptr: *anyopaque) !void {
    const ctx: *StylesheetFetchContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.finished = true;
}

fn stylesheetErrorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
    const ctx: *StylesheetFetchContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.failed = err;
}

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Link" {
    try testing.htmlRunner("element/html/link.html", .{});
}
