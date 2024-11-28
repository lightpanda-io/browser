// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const parser = @import("netsurf");
const generate = @import("../generate.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const Element = @import("../dom/element.zig").Element;
const URL = @import("../url/url.zig").URL;
const Node = @import("../dom/node.zig").Node;

// HTMLElement interfaces
pub const Interfaces = .{
    HTMLElement,
    HTMLUnknownElement,
    HTMLAnchorElement,
    HTMLAreaElement,
    HTMLAudioElement,
    HTMLAppletElement,
    HTMLBRElement,
    HTMLBaseElement,
    HTMLBodyElement,
    HTMLButtonElement,
    HTMLCanvasElement,
    HTMLDListElement,
    HTMLDataElement,
    HTMLDataListElement,
    HTMLDialogElement,
    HTMLDirectoryElement,
    HTMLDivElement,
    HTMLEmbedElement,
    HTMLFieldSetElement,
    HTMLFontElement,
    HTMLFormElement,
    HTMLFrameElement,
    HTMLFrameSetElement,
    HTMLHRElement,
    HTMLHeadElement,
    HTMLHeadingElement,
    HTMLHtmlElement,
    HTMLIFrameElement,
    HTMLImageElement,
    HTMLInputElement,
    HTMLLIElement,
    HTMLLabelElement,
    HTMLLegendElement,
    HTMLLinkElement,
    HTMLMapElement,
    HTMLMetaElement,
    HTMLMeterElement,
    HTMLModElement,
    HTMLOListElement,
    HTMLObjectElement,
    HTMLOptGroupElement,
    HTMLOptionElement,
    HTMLOutputElement,
    HTMLParagraphElement,
    HTMLParamElement,
    HTMLPictureElement,
    HTMLPreElement,
    HTMLProgressElement,
    HTMLQuoteElement,
    HTMLScriptElement,
    HTMLSelectElement,
    HTMLSourceElement,
    HTMLSpanElement,
    HTMLStyleElement,
    HTMLTableElement,
    HTMLTableCaptionElement,
    HTMLTableCellElement,
    HTMLTableColElement,
    HTMLTableRowElement,
    HTMLTableSectionElement,
    HTMLTemplateElement,
    HTMLTextAreaElement,
    HTMLTimeElement,
    HTMLTitleElement,
    HTMLTrackElement,
    HTMLUListElement,
    HTMLVideoElement,
    CSSProperties,
};
const Generated = generate.Union.compile(Interfaces);
pub const Union = Generated._union;
pub const Tags = Generated._enum;

// Abstract class
// --------------

const CSSProperties = struct {
    pub const mem_guarantied = true;
};

pub const HTMLElement = struct {
    pub const Self = parser.ElementHTML;
    pub const prototype = *Element;
    pub const mem_guarantied = true;

    pub fn get_style(_: *parser.ElementHTML) CSSProperties {
        return .{};
    }

    pub fn get_innerText(e: *parser.ElementHTML) ![]const u8 {
        const n = @as(*parser.Node, @ptrCast(e));
        return try parser.nodeTextContent(n) orelse "";
    }

    pub fn set_innerText(e: *parser.ElementHTML, s: []const u8) !void {
        const n = @as(*parser.Node, @ptrCast(e));

        // create text node.
        const doc = try parser.nodeOwnerDocument(n) orelse return error.NoDocument;
        const t = try parser.documentCreateTextNode(doc, s);

        // remove existing children.
        try Node.removeChildren(n);

        // attach the text node.
        _ = try parser.nodeAppendChild(n, @as(*parser.Node, @ptrCast(t)));
    }
};

// Deprecated HTMLElements in Chrome (2023/03/15)
// HTMLContentelement
// HTMLShadowElement

// Abstract sub-classes
// --------------------

pub const HTMLMediaElement = struct {
    pub const Self = parser.MediaElement;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

// HTML elements
// -------------

pub const HTMLUnknownElement = struct {
    pub const Self = parser.Unknown;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

// https://html.spec.whatwg.org/#the-a-element
pub const HTMLAnchorElement = struct {
    pub const Self = parser.Anchor;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;

    pub fn get_target(self: *parser.Anchor) ![]const u8 {
        return try parser.anchorGetTarget(self);
    }

    pub fn set_target(self: *parser.Anchor, href: []const u8) !void {
        return try parser.anchorSetTarget(self, href);
    }

    pub fn get_download(_: *parser.Anchor) ![]const u8 {
        return ""; // TODO
    }

    pub fn get_href(self: *parser.Anchor) ![]const u8 {
        return try parser.anchorGetHref(self);
    }

    pub fn set_href(self: *parser.Anchor, href: []const u8) !void {
        return try parser.anchorSetHref(self, href);
    }

    pub fn get_hreflang(self: *parser.Anchor) ![]const u8 {
        return try parser.anchorGetHrefLang(self);
    }

    pub fn set_hreflang(self: *parser.Anchor, href: []const u8) !void {
        return try parser.anchorSetHrefLang(self, href);
    }

    pub fn get_type(self: *parser.Anchor) ![]const u8 {
        return try parser.anchorGetType(self);
    }

    pub fn set_type(self: *parser.Anchor, t: []const u8) !void {
        return try parser.anchorSetType(self, t);
    }

    pub fn get_rel(self: *parser.Anchor) ![]const u8 {
        return try parser.anchorGetRel(self);
    }

    pub fn set_rel(self: *parser.Anchor, t: []const u8) !void {
        return try parser.anchorSetRel(self, t);
    }

    pub fn get_text(self: *parser.Anchor) !?[]const u8 {
        return try parser.nodeTextContent(parser.anchorToNode(self));
    }

    pub fn set_text(self: *parser.Anchor, v: []const u8) !void {
        return try parser.nodeSetTextContent(parser.anchorToNode(self), v);
    }

    inline fn url(self: *parser.Anchor, alloc: std.mem.Allocator) !URL {
        const href = try parser.anchorGetHref(self);
        return URL.constructor(alloc, href, null); // TODO inject base url
    }

    // TODO return a disposable string
    pub fn get_origin(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return try u.get_origin(alloc);
    }

    // TODO return a disposable string
    pub fn get_protocol(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return u.get_protocol(alloc);
    }

    pub fn set_protocol(self: *parser.Anchor, alloc: std.mem.Allocator, v: []const u8) !void {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        u.uri.scheme = v;
        const href = try u.format(alloc);
        defer alloc.free(href);

        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_host(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return try u.get_host(alloc);
    }

    pub fn set_host(self: *parser.Anchor, alloc: std.mem.Allocator, v: []const u8) !void {
        // search : separator
        var p: ?u16 = null;
        var h: []const u8 = undefined;
        for (v, 0..) |c, i| {
            if (c == ':') {
                h = v[0..i];
                p = try std.fmt.parseInt(u16, v[i + 1 ..], 10);
                break;
            }
        }

        var u = try url(self, alloc);
        defer u.deinit(alloc);

        if (p) |pp| {
            u.uri.host = .{ .raw = h };
            u.uri.port = pp;
        } else {
            u.uri.host = .{ .raw = v };
            u.uri.port = null;
        }

        const href = try u.format(alloc);
        defer alloc.free(href);

        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_hostname(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return try alloc.dupe(u8, u.get_hostname());
    }

    pub fn set_hostname(self: *parser.Anchor, alloc: std.mem.Allocator, v: []const u8) !void {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        u.uri.host = .{ .raw = v };
        const href = try u.format(alloc);
        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_port(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return try u.get_port(alloc);
    }

    pub fn set_port(self: *parser.Anchor, alloc: std.mem.Allocator, v: ?[]const u8) !void {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        if (v != null and v.?.len > 0) {
            u.uri.port = try std.fmt.parseInt(u16, v.?, 10);
        } else {
            u.uri.port = null;
        }

        const href = try u.format(alloc);
        defer alloc.free(href);

        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_username(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return try alloc.dupe(u8, u.get_username());
    }

    pub fn set_username(self: *parser.Anchor, alloc: std.mem.Allocator, v: ?[]const u8) !void {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        if (v) |vv| {
            u.uri.user = .{ .raw = vv };
        } else {
            u.uri.user = null;
        }
        const href = try u.format(alloc);
        defer alloc.free(href);

        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_password(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return try alloc.dupe(u8, u.get_password());
    }

    pub fn set_password(self: *parser.Anchor, alloc: std.mem.Allocator, v: ?[]const u8) !void {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        if (v) |vv| {
            u.uri.password = .{ .raw = vv };
        } else {
            u.uri.password = null;
        }
        const href = try u.format(alloc);
        defer alloc.free(href);

        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_pathname(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return try alloc.dupe(u8, u.get_pathname());
    }

    pub fn set_pathname(self: *parser.Anchor, alloc: std.mem.Allocator, v: []const u8) !void {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        u.uri.path = .{ .raw = v };
        const href = try u.format(alloc);
        defer alloc.free(href);

        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_search(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return try u.get_search(alloc);
    }

    pub fn set_search(self: *parser.Anchor, alloc: std.mem.Allocator, v: ?[]const u8) !void {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        if (v) |vv| {
            u.uri.query = .{ .raw = vv };
        } else {
            u.uri.query = null;
        }
        const href = try u.format(alloc);
        defer alloc.free(href);

        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_hash(self: *parser.Anchor, alloc: std.mem.Allocator) ![]const u8 {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        return try u.get_hash(alloc);
    }

    pub fn set_hash(self: *parser.Anchor, alloc: std.mem.Allocator, v: ?[]const u8) !void {
        var u = try url(self, alloc);
        defer u.deinit(alloc);

        if (v) |vv| {
            u.uri.fragment = .{ .raw = vv };
        } else {
            u.uri.fragment = null;
        }
        const href = try u.format(alloc);
        defer alloc.free(href);

        try parser.anchorSetHref(self, href);
    }

    pub fn deinit(_: *parser.Anchor, _: std.mem.Allocator) void {}
};

pub const HTMLAppletElement = struct {
    pub const Self = parser.Applet;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLAreaElement = struct {
    pub const Self = parser.Area;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLAudioElement = struct {
    pub const Self = parser.Audio;
    pub const prototype = *HTMLMediaElement;
    pub const mem_guarantied = true;
};

pub const HTMLBRElement = struct {
    pub const Self = parser.BR;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLBaseElement = struct {
    pub const Self = parser.Base;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLBodyElement = struct {
    pub const Self = parser.Body;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLButtonElement = struct {
    pub const Self = parser.Button;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLCanvasElement = struct {
    pub const Self = parser.Canvas;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLDListElement = struct {
    pub const Self = parser.DList;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLDataElement = struct {
    pub const Self = parser.Data;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLDataListElement = struct {
    pub const Self = parser.DataList;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLDialogElement = struct {
    pub const Self = parser.Dialog;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLDirectoryElement = struct {
    pub const Self = parser.Directory;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLDivElement = struct {
    pub const Self = parser.Div;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLEmbedElement = struct {
    pub const Self = parser.Embed;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLFieldSetElement = struct {
    pub const Self = parser.FieldSet;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLFontElement = struct {
    pub const Self = parser.Font;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLFormElement = struct {
    pub const Self = parser.Form;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLFrameElement = struct {
    pub const Self = parser.Frame;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLFrameSetElement = struct {
    pub const Self = parser.FrameSet;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLHRElement = struct {
    pub const Self = parser.HR;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLHeadElement = struct {
    pub const Self = parser.Head;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLHeadingElement = struct {
    pub const Self = parser.Heading;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLHtmlElement = struct {
    pub const Self = parser.Html;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLIFrameElement = struct {
    pub const Self = parser.IFrame;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLImageElement = struct {
    pub const Self = parser.Image;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLInputElement = struct {
    pub const Self = parser.Input;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLLIElement = struct {
    pub const Self = parser.LI;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLLabelElement = struct {
    pub const Self = parser.Label;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLLegendElement = struct {
    pub const Self = parser.Legend;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLLinkElement = struct {
    pub const Self = parser.Link;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLMapElement = struct {
    pub const Self = parser.Map;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLMetaElement = struct {
    pub const Self = parser.Meta;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLMeterElement = struct {
    pub const Self = parser.Meter;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLModElement = struct {
    pub const Self = parser.Mod;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLOListElement = struct {
    pub const Self = parser.OList;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLObjectElement = struct {
    pub const Self = parser.Object;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLOptGroupElement = struct {
    pub const Self = parser.OptGroup;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLOptionElement = struct {
    pub const Self = parser.Option;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLOutputElement = struct {
    pub const Self = parser.Output;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLParagraphElement = struct {
    pub const Self = parser.Paragraph;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLParamElement = struct {
    pub const Self = parser.Param;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLPictureElement = struct {
    pub const Self = parser.Picture;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLPreElement = struct {
    pub const Self = parser.Pre;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLProgressElement = struct {
    pub const Self = parser.Progress;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLQuoteElement = struct {
    pub const Self = parser.Quote;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

// https://html.spec.whatwg.org/#the-script-element
pub const HTMLScriptElement = struct {
    pub const Self = parser.Script;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;

    pub fn get_src(self: *parser.Script) !?[]const u8 {
        return try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "src",
        ) orelse "";
    }

    pub fn set_src(self: *parser.Script, v: []const u8) !void {
        return try parser.elementSetAttribute(
            parser.scriptToElt(self),
            "src",
            v,
        );
    }

    pub fn get_type(self: *parser.Script) !?[]const u8 {
        return try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "type",
        ) orelse "";
    }

    pub fn set_type(self: *parser.Script, v: []const u8) !void {
        return try parser.elementSetAttribute(
            parser.scriptToElt(self),
            "type",
            v,
        );
    }

    pub fn get_text(self: *parser.Script) !?[]const u8 {
        return try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "text",
        ) orelse "";
    }

    pub fn set_text(self: *parser.Script, v: []const u8) !void {
        return try parser.elementSetAttribute(
            parser.scriptToElt(self),
            "text",
            v,
        );
    }

    pub fn get_integrity(self: *parser.Script) !?[]const u8 {
        return try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "integrity",
        ) orelse "";
    }

    pub fn set_integrity(self: *parser.Script, v: []const u8) !void {
        return try parser.elementSetAttribute(
            parser.scriptToElt(self),
            "integrity",
            v,
        );
    }

    pub fn get_async(self: *parser.Script) !bool {
        _ = try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "async",
        ) orelse return false;

        return true;
    }

    pub fn set_async(self: *parser.Script, v: bool) !void {
        if (v) {
            return try parser.elementSetAttribute(parser.scriptToElt(self), "async", "");
        }

        return try parser.elementRemoveAttribute(parser.scriptToElt(self), "async");
    }

    pub fn get_defer(self: *parser.Script) !bool {
        _ = try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "defer",
        ) orelse false;
        return true;
    }

    pub fn set_defer(self: *parser.Script, v: bool) !void {
        if (v) {
            return try parser.elementSetAttribute(parser.scriptToElt(self), "defer", "");
        }

        return try parser.elementRemoveAttribute(parser.scriptToElt(self), "defer");
    }

    pub fn get_noModule(self: *parser.Script) !bool {
        _ = try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "nomodule",
        ) orelse false;
        return true;
    }

    pub fn set_noModule(self: *parser.Script, v: bool) !void {
        if (v) {
            return try parser.elementSetAttribute(parser.scriptToElt(self), "nomodule", "");
        }

        return try parser.elementRemoveAttribute(parser.scriptToElt(self), "nomodule");
    }
};

pub const HTMLSelectElement = struct {
    pub const Self = parser.Select;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLSourceElement = struct {
    pub const Self = parser.Source;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLSpanElement = struct {
    pub const Self = parser.Span;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLStyleElement = struct {
    pub const Self = parser.Style;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTableElement = struct {
    pub const Self = parser.Table;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTableCaptionElement = struct {
    pub const Self = parser.TableCaption;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTableCellElement = struct {
    pub const Self = parser.TableCell;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTableColElement = struct {
    pub const Self = parser.TableCol;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTableRowElement = struct {
    pub const Self = parser.TableRow;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTableSectionElement = struct {
    pub const Self = parser.TableSection;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTemplateElement = struct {
    pub const Self = parser.Template;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTextAreaElement = struct {
    pub const Self = parser.TextArea;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTimeElement = struct {
    pub const Self = parser.Time;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTitleElement = struct {
    pub const Self = parser.Title;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLTrackElement = struct {
    pub const Self = parser.Track;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLUListElement = struct {
    pub const Self = parser.UList;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub const HTMLVideoElement = struct {
    pub const Self = parser.Video;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
};

pub fn toInterface(comptime T: type, e: *parser.Element) !T {
    const elem: *align(@alignOf(*parser.Element)) parser.Element = @alignCast(e);
    const tag = try parser.elementHTMLGetTagType(@as(*parser.ElementHTML, @ptrCast(elem)));
    return switch (tag) {
        .abbr, .acronym, .address, .article, .aside, .b, .basefont, .bdi, .bdo, .bgsound, .big, .center, .cite, .code, .dd, .details, .dfn, .dt, .em, .figcaption, .figure, .footer, .header, .hgroup, .i, .isindex, .keygen, .kbd, .main, .mark, .marquee, .menu, .menuitem, .nav, .nobr, .noframes, .noscript, .rp, .rt, .ruby, .s, .samp, .section, .small, .spacer, .strike, .strong, .sub, .summary, .sup, .tt, .u, .wbr, ._var => .{ .HTMLElement = @as(*parser.ElementHTML, @ptrCast(elem)) },
        .a => .{ .HTMLAnchorElement = @as(*parser.Anchor, @ptrCast(elem)) },
        .applet => .{ .HTMLAppletElement = @as(*parser.Applet, @ptrCast(elem)) },
        .area => .{ .HTMLAreaElement = @as(*parser.Area, @ptrCast(elem)) },
        .audio => .{ .HTMLAudioElement = @as(*parser.Audio, @ptrCast(elem)) },
        .base => .{ .HTMLBaseElement = @as(*parser.Base, @ptrCast(elem)) },
        .body => .{ .HTMLBodyElement = @as(*parser.Body, @ptrCast(elem)) },
        .br => .{ .HTMLBRElement = @as(*parser.BR, @ptrCast(elem)) },
        .button => .{ .HTMLButtonElement = @as(*parser.Button, @ptrCast(elem)) },
        .canvas => .{ .HTMLCanvasElement = @as(*parser.Canvas, @ptrCast(elem)) },
        .dl => .{ .HTMLDListElement = @as(*parser.DList, @ptrCast(elem)) },
        .data => .{ .HTMLDataElement = @as(*parser.Data, @ptrCast(elem)) },
        .datalist => .{ .HTMLDataListElement = @as(*parser.DataList, @ptrCast(elem)) },
        .dialog => .{ .HTMLDialogElement = @as(*parser.Dialog, @ptrCast(elem)) },
        .dir => .{ .HTMLDirectoryElement = @as(*parser.Directory, @ptrCast(elem)) },
        .div => .{ .HTMLDivElement = @as(*parser.Div, @ptrCast(elem)) },
        .embed => .{ .HTMLEmbedElement = @as(*parser.Embed, @ptrCast(elem)) },
        .fieldset => .{ .HTMLFieldSetElement = @as(*parser.FieldSet, @ptrCast(elem)) },
        .font => .{ .HTMLFontElement = @as(*parser.Font, @ptrCast(elem)) },
        .form => .{ .HTMLFormElement = @as(*parser.Form, @ptrCast(elem)) },
        .frame => .{ .HTMLFrameElement = @as(*parser.Frame, @ptrCast(elem)) },
        .frameset => .{ .HTMLFrameSetElement = @as(*parser.FrameSet, @ptrCast(elem)) },
        .hr => .{ .HTMLHRElement = @as(*parser.HR, @ptrCast(elem)) },
        .head => .{ .HTMLHeadElement = @as(*parser.Head, @ptrCast(elem)) },
        .h1, .h2, .h3, .h4, .h5, .h6 => .{ .HTMLHeadingElement = @as(*parser.Heading, @ptrCast(elem)) },
        .html => .{ .HTMLHtmlElement = @as(*parser.Html, @ptrCast(elem)) },
        .iframe => .{ .HTMLIFrameElement = @as(*parser.IFrame, @ptrCast(elem)) },
        .img => .{ .HTMLImageElement = @as(*parser.Image, @ptrCast(elem)) },
        .input => .{ .HTMLInputElement = @as(*parser.Input, @ptrCast(elem)) },
        .li => .{ .HTMLLIElement = @as(*parser.LI, @ptrCast(elem)) },
        .label => .{ .HTMLLabelElement = @as(*parser.Label, @ptrCast(elem)) },
        .legend => .{ .HTMLLegendElement = @as(*parser.Legend, @ptrCast(elem)) },
        .link => .{ .HTMLLinkElement = @as(*parser.Link, @ptrCast(elem)) },
        .map => .{ .HTMLMapElement = @as(*parser.Map, @ptrCast(elem)) },
        .meta => .{ .HTMLMetaElement = @as(*parser.Meta, @ptrCast(elem)) },
        .meter => .{ .HTMLMeterElement = @as(*parser.Meter, @ptrCast(elem)) },
        .ins, .del => .{ .HTMLModElement = @as(*parser.Mod, @ptrCast(elem)) },
        .ol => .{ .HTMLOListElement = @as(*parser.OList, @ptrCast(elem)) },
        .object => .{ .HTMLObjectElement = @as(*parser.Object, @ptrCast(elem)) },
        .optgroup => .{ .HTMLOptGroupElement = @as(*parser.OptGroup, @ptrCast(elem)) },
        .option => .{ .HTMLOptionElement = @as(*parser.Option, @ptrCast(elem)) },
        .output => .{ .HTMLOutputElement = @as(*parser.Output, @ptrCast(elem)) },
        .p => .{ .HTMLParagraphElement = @as(*parser.Paragraph, @ptrCast(elem)) },
        .param => .{ .HTMLParamElement = @as(*parser.Param, @ptrCast(elem)) },
        .picture => .{ .HTMLPictureElement = @as(*parser.Picture, @ptrCast(elem)) },
        .pre => .{ .HTMLPreElement = @as(*parser.Pre, @ptrCast(elem)) },
        .progress => .{ .HTMLProgressElement = @as(*parser.Progress, @ptrCast(elem)) },
        .blockquote, .q => .{ .HTMLQuoteElement = @as(*parser.Quote, @ptrCast(elem)) },
        .script => .{ .HTMLScriptElement = @as(*parser.Script, @ptrCast(elem)) },
        .select => .{ .HTMLSelectElement = @as(*parser.Select, @ptrCast(elem)) },
        .source => .{ .HTMLSourceElement = @as(*parser.Source, @ptrCast(elem)) },
        .span => .{ .HTMLSpanElement = @as(*parser.Span, @ptrCast(elem)) },
        .style => .{ .HTMLStyleElement = @as(*parser.Style, @ptrCast(elem)) },
        .table => .{ .HTMLTableElement = @as(*parser.Table, @ptrCast(elem)) },
        .caption => .{ .HTMLTableCaptionElement = @as(*parser.TableCaption, @ptrCast(elem)) },
        .th, .td => .{ .HTMLTableCellElement = @as(*parser.TableCell, @ptrCast(elem)) },
        .col, .colgroup => .{ .HTMLTableColElement = @as(*parser.TableCol, @ptrCast(elem)) },
        .tr => .{ .HTMLTableRowElement = @as(*parser.TableRow, @ptrCast(elem)) },
        .thead, .tbody, .tfoot => .{ .HTMLTableSectionElement = @as(*parser.TableSection, @ptrCast(elem)) },
        .template => .{ .HTMLTemplateElement = @as(*parser.Template, @ptrCast(elem)) },
        .textarea => .{ .HTMLTextAreaElement = @as(*parser.TextArea, @ptrCast(elem)) },
        .time => .{ .HTMLTimeElement = @as(*parser.Time, @ptrCast(elem)) },
        .title => .{ .HTMLTitleElement = @as(*parser.Title, @ptrCast(elem)) },
        .track => .{ .HTMLTrackElement = @as(*parser.Track, @ptrCast(elem)) },
        .ul => .{ .HTMLUListElement = @as(*parser.UList, @ptrCast(elem)) },
        .video => .{ .HTMLVideoElement = @as(*parser.Video, @ptrCast(elem)) },
        .undef => .{ .HTMLUnknownElement = @as(*parser.Unknown, @ptrCast(elem)) },
    };
}

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var anchor = [_]Case{
        .{ .src = "let a = document.getElementById('link')", .ex = "undefined" },
        .{ .src = "a.target", .ex = "" },
        .{ .src = "a.target = '_blank'", .ex = "_blank" },
        .{ .src = "a.target", .ex = "_blank" },
        .{ .src = "a.target = ''", .ex = "" },

        .{ .src = "a.href", .ex = "foo" },
        .{ .src = "a.href = 'https://lightpanda.io/'", .ex = "https://lightpanda.io/" },
        .{ .src = "a.href", .ex = "https://lightpanda.io/" },

        .{ .src = "a.origin", .ex = "https://lightpanda.io" },

        .{ .src = "a.host = 'lightpanda.io:443'", .ex = "lightpanda.io:443" },
        .{ .src = "a.host", .ex = "lightpanda.io:443" },
        .{ .src = "a.port", .ex = "443" },
        .{ .src = "a.hostname", .ex = "lightpanda.io" },

        .{ .src = "a.host = 'lightpanda.io'", .ex = "lightpanda.io" },
        .{ .src = "a.host", .ex = "lightpanda.io" },
        .{ .src = "a.port", .ex = "" },
        .{ .src = "a.hostname", .ex = "lightpanda.io" },

        .{ .src = "a.host", .ex = "lightpanda.io" },
        .{ .src = "a.hostname", .ex = "lightpanda.io" },
        .{ .src = "a.hostname = 'foo.bar'", .ex = "foo.bar" },
        .{ .src = "a.href", .ex = "https://foo.bar/" },

        .{ .src = "a.search", .ex = "" },
        .{ .src = "a.search = 'q=bar'", .ex = "q=bar" },
        .{ .src = "a.search", .ex = "?q=bar" },
        .{ .src = "a.href", .ex = "https://foo.bar/?q=bar" },

        .{ .src = "a.hash", .ex = "" },
        .{ .src = "a.hash = 'frag'", .ex = "frag" },
        .{ .src = "a.hash", .ex = "#frag" },
        .{ .src = "a.href", .ex = "https://foo.bar/?q=bar#frag" },

        .{ .src = "a.port", .ex = "" },
        .{ .src = "a.port = '443'", .ex = "443" },
        .{ .src = "a.host", .ex = "foo.bar:443" },
        .{ .src = "a.hostname", .ex = "foo.bar" },
        .{ .src = "a.href", .ex = "https://foo.bar:443/?q=bar#frag" },
        .{ .src = "a.port = null", .ex = "null" },
        .{ .src = "a.href", .ex = "https://foo.bar/?q=bar#frag" },

        .{ .src = "a.href = 'foo'", .ex = "foo" },

        .{ .src = "a.type", .ex = "" },
        .{ .src = "a.type = 'text/html'", .ex = "text/html" },
        .{ .src = "a.type", .ex = "text/html" },
        .{ .src = "a.type = ''", .ex = "" },

        .{ .src = "a.text", .ex = "OK" },
        .{ .src = "a.text = 'foo'", .ex = "foo" },
        .{ .src = "a.text", .ex = "foo" },
        .{ .src = "a.text = 'OK'", .ex = "OK" },
    };
    try checkCases(js_env, &anchor);

    var script = [_]Case{
        .{ .src = "let script = document.createElement('script')", .ex = "undefined" },
        .{ .src = "script.src = 'foo.bar'", .ex = "foo.bar" },

        .{ .src = "script.async = true", .ex = "true" },
        .{ .src = "script.async", .ex = "true" },
        .{ .src = "script.async = false", .ex = "false" },
        .{ .src = "script.async", .ex = "false" },
    };
    try checkCases(js_env, &script);

    var innertext = [_]Case{
        .{ .src = "const backup = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "document.getElementById('content').innerText = 'foo';", .ex = "foo" },
        .{ .src = "document.getElementById('content').innerText", .ex = "foo" },
        .{ .src = "document.getElementById('content').innerHTML = backup; true;", .ex = "true" },
    };
    try checkCases(js_env, &innertext);
}
