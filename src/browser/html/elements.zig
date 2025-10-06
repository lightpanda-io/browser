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
const log = @import("../../log.zig");

const js = @import("../js/js.zig");
const parser = @import("../netsurf.zig");
const generate = @import("../js/generate.zig");
const Page = @import("../page.zig").Page;

const urlStitch = @import("../../url.zig").URL.stitch;
const URL = @import("../url/url.zig").URL;
const Node = @import("../dom/node.zig").Node;
const NodeUnion = @import("../dom/node.zig").Union;
const Element = @import("../dom/element.zig").Element;
const DataSet = @import("DataSet.zig");

const StyleSheet = @import("../cssom/StyleSheet.zig");
const CSSStyleDeclaration = @import("../cssom/CSSStyleDeclaration.zig");

// HTMLElement interfaces
pub const Interfaces = .{
    Element,
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
    HTMLFrameElement,
    HTMLFrameSetElement,
    HTMLHRElement,
    HTMLHeadElement,
    HTMLHeadingElement,
    HTMLHtmlElement,
    HTMLImageElement,
    HTMLImageElement.Factory,
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
    HTMLOutputElement,
    HTMLParagraphElement,
    HTMLParamElement,
    HTMLPictureElement,
    HTMLPreElement,
    HTMLProgressElement,
    HTMLQuoteElement,
    HTMLScriptElement,
    HTMLSourceElement,
    HTMLSpanElement,
    HTMLSlotElement,
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

    @import("form.zig").HTMLFormElement,
    @import("iframe.zig").HTMLIFrameElement,
    @import("select.zig").Interfaces,
};

pub const Union = generate.Union(Interfaces);

// Abstract class
// --------------

pub const HTMLElement = struct {
    pub const Self = parser.ElementHTML;
    pub const prototype = *Element;
    pub const subtype = .node;

    pub fn get_style(e: *parser.ElementHTML, page: *Page) !*CSSStyleDeclaration {
        const state = try page.getOrCreateNodeState(@ptrCast(e));
        return &state.style;
    }

    pub fn get_dataset(e: *parser.ElementHTML, page: *Page) !*DataSet {
        const state = try page.getOrCreateNodeState(@ptrCast(e));
        if (state.dataset) |*ds| {
            return ds;
        }
        state.dataset = DataSet{ .element = @ptrCast(e) };
        return &state.dataset.?;
    }

    pub fn get_innerText(e: *parser.ElementHTML) ![]const u8 {
        const n = @as(*parser.Node, @ptrCast(e));
        return parser.nodeTextContent(n) orelse "";
    }

    pub fn set_innerText(e: *parser.ElementHTML, s: []const u8) !void {
        const n = @as(*parser.Node, @ptrCast(e));

        // create text node.
        const doc = parser.nodeOwnerDocument(n) orelse return error.NoDocument;
        const t = try parser.documentCreateTextNode(doc, s);

        // remove existing children.
        try Node.removeChildren(n);

        // attach the text node.
        _ = try parser.nodeAppendChild(n, @as(*parser.Node, @ptrCast(@alignCast(t))));
    }

    pub fn _click(e: *parser.ElementHTML) !void {
        const event = try parser.mouseEventCreate();
        defer parser.mouseEventDestroy(event);
        try parser.mouseEventInit(event, "click", .{
            .x = 0,
            .y = 0,
            .bubbles = true,
            .cancelable = true,
        });
        _ = try parser.elementDispatchEvent(@ptrCast(e), @ptrCast(event));
    }

    const FocusOpts = struct {
        preventScroll: bool,
        focusVisible: bool,
    };
    pub fn _focus(e: *parser.ElementHTML, _: ?FocusOpts, page: *Page) !void {
        if (!page.isNodeAttached(@ptrCast(e))) {
            return;
        }

        const Document = @import("../dom/document.zig").Document;
        const root_node = parser.nodeGetRootNode(@ptrCast(e));
        try Document.setFocus(@ptrCast(root_node), e, page);
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
    pub const subtype = .node;
};

// HTML elements
// -------------

pub const HTMLUnknownElement = struct {
    pub const Self = parser.Unknown;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

// https://html.spec.whatwg.org/#the-a-element
pub const HTMLAnchorElement = struct {
    pub const Self = parser.Anchor;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_target(self: *parser.Anchor) ![]const u8 {
        return try parser.anchorGetTarget(self);
    }

    pub fn set_target(self: *parser.Anchor, href: []const u8) !void {
        return try parser.anchorSetTarget(self, href);
    }

    pub fn get_download(_: *const parser.Anchor) ![]const u8 {
        return ""; // TODO
    }

    pub fn get_href(self: *parser.Anchor) ![]const u8 {
        return try parser.anchorGetHref(self);
    }

    pub fn set_href(self: *parser.Anchor, href: []const u8, page: *const Page) !void {
        const full = try urlStitch(page.call_arena, href, page.url.raw, .{});
        return try parser.anchorSetHref(self, full);
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
        return parser.nodeTextContent(parser.anchorToNode(self));
    }

    pub fn set_text(self: *parser.Anchor, v: []const u8) !void {
        return try parser.nodeSetTextContent(parser.anchorToNode(self), v);
    }

    fn url(self: *parser.Anchor, page: *Page) !URL {
        // Although the URL.constructor union accepts an .{.element = X}, we
        // can't use this here because the behavior is different.
        //    URL.constructor(document.createElement('a')
        // should fail (a.href isn't a valid URL)
        // But
        //     document.createElement('a').host
        // should not fail, it should return an empty string
        if (try parser.elementGetAttribute(@ptrCast(@alignCast(self)), "href")) |href| {
            return URL.constructor(.{ .string = href }, null, page); // TODO inject base url
        }
        return .empty;
    }

    // TODO return a disposable string
    pub fn get_origin(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return try u.get_origin(page);
    }

    // TODO return a disposable string
    pub fn get_protocol(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return u.get_protocol(page);
    }

    pub fn set_protocol(self: *parser.Anchor, v: []const u8, page: *Page) !void {
        const arena = page.arena;
        var u = try url(self, page);

        u.uri.scheme = v;
        const href = try u.toString(arena);
        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_host(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return try u.get_host(page);
    }

    pub fn set_host(self: *parser.Anchor, v: []const u8, page: *Page) !void {
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

        const arena = page.arena;
        var u = try url(self, page);

        if (p) |pp| {
            u.uri.host = .{ .raw = h };
            u.uri.port = pp;
        } else {
            u.uri.host = .{ .raw = v };
            u.uri.port = null;
        }

        const href = try u.toString(arena);
        try parser.anchorSetHref(self, href);
    }

    pub fn get_hostname(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return u.get_hostname();
    }

    pub fn set_hostname(self: *parser.Anchor, v: []const u8, page: *Page) !void {
        const arena = page.arena;
        var u = try url(self, page);
        u.uri.host = .{ .raw = v };
        const href = try u.toString(arena);
        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_port(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return try u.get_port(page);
    }

    pub fn set_port(self: *parser.Anchor, v: ?[]const u8, page: *Page) !void {
        const arena = page.arena;
        var u = try url(self, page);

        if (v != null and v.?.len > 0) {
            u.uri.port = try std.fmt.parseInt(u16, v.?, 10);
        } else {
            u.uri.port = null;
        }

        const href = try u.toString(arena);
        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_username(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return u.get_username();
    }

    pub fn set_username(self: *parser.Anchor, v: ?[]const u8, page: *Page) !void {
        const arena = page.arena;
        var u = try url(self, page);

        if (v) |vv| {
            u.uri.user = .{ .raw = vv };
        } else {
            u.uri.user = null;
        }
        const href = try u.toString(arena);

        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_password(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return try page.arena.dupe(u8, u.get_password());
    }

    pub fn set_password(self: *parser.Anchor, v: ?[]const u8, page: *Page) !void {
        const arena = page.arena;
        var u = try url(self, page);

        if (v) |vv| {
            u.uri.password = .{ .raw = vv };
        } else {
            u.uri.password = null;
        }
        const href = try u.toString(arena);

        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_pathname(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return u.get_pathname();
    }

    pub fn set_pathname(self: *parser.Anchor, v: []const u8, page: *Page) !void {
        const arena = page.arena;
        var u = try url(self, page);
        u.uri.path = .{ .raw = v };
        const href = try u.toString(arena);

        try parser.anchorSetHref(self, href);
    }

    pub fn get_search(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return try u.get_search(page);
    }

    pub fn set_search(self: *parser.Anchor, v: ?[]const u8, page: *Page) !void {
        var u = try url(self, page);
        try u.set_search(v, page);

        const href = try u.toString(page.call_arena);
        try parser.anchorSetHref(self, href);
    }

    // TODO return a disposable string
    pub fn get_hash(self: *parser.Anchor, page: *Page) ![]const u8 {
        var u = try url(self, page);
        return try u.get_hash(page);
    }

    pub fn set_hash(self: *parser.Anchor, v: ?[]const u8, page: *Page) !void {
        const arena = page.arena;
        var u = try url(self, page);

        if (v) |vv| {
            u.uri.fragment = .{ .raw = vv };
        } else {
            u.uri.fragment = null;
        }
        const href = try u.toString(arena);

        try parser.anchorSetHref(self, href);
    }
};

pub const HTMLAppletElement = struct {
    pub const Self = parser.Applet;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLAreaElement = struct {
    pub const Self = parser.Area;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLAudioElement = struct {
    pub const Self = parser.Audio;
    pub const prototype = *HTMLMediaElement;
    pub const subtype = .node;
};

pub const HTMLBRElement = struct {
    pub const Self = parser.BR;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLBaseElement = struct {
    pub const Self = parser.Base;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLBodyElement = struct {
    pub const Self = parser.Body;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLButtonElement = struct {
    pub const Self = parser.Button;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLCanvasElement = struct {
    pub const Self = parser.Canvas;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLDListElement = struct {
    pub const Self = parser.DList;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLDataElement = struct {
    pub const Self = parser.Data;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLDataListElement = struct {
    pub const Self = parser.DataList;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLDialogElement = struct {
    pub const Self = parser.Dialog;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLDirectoryElement = struct {
    pub const Self = parser.Directory;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLDivElement = struct {
    pub const Self = parser.Div;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLEmbedElement = struct {
    pub const Self = parser.Embed;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLFieldSetElement = struct {
    pub const Self = parser.FieldSet;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLFontElement = struct {
    pub const Self = parser.Font;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLFrameElement = struct {
    pub const Self = parser.Frame;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLFrameSetElement = struct {
    pub const Self = parser.FrameSet;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLHRElement = struct {
    pub const Self = parser.HR;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLHeadElement = struct {
    pub const Self = parser.Head;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLHeadingElement = struct {
    pub const Self = parser.Heading;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLHtmlElement = struct {
    pub const Self = parser.Html;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLImageElement = struct {
    pub const Self = parser.Image;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_alt(self: *parser.Image) ![]const u8 {
        return try parser.imageGetAlt(self);
    }
    pub fn set_alt(self: *parser.Image, alt: []const u8) !void {
        try parser.imageSetAlt(self, alt);
    }
    pub fn get_src(self: *parser.Image) ![]const u8 {
        return try parser.imageGetSrc(self);
    }
    pub fn set_src(self: *parser.Image, src: []const u8) !void {
        try parser.imageSetSrc(self, src);
    }
    pub fn get_useMap(self: *parser.Image) ![]const u8 {
        return try parser.imageGetUseMap(self);
    }
    pub fn set_useMap(self: *parser.Image, use_map: []const u8) !void {
        try parser.imageSetUseMap(self, use_map);
    }
    pub fn get_height(self: *parser.Image) !u32 {
        return try parser.imageGetHeight(self);
    }
    pub fn set_height(self: *parser.Image, height: u32) !void {
        try parser.imageSetHeight(self, height);
    }
    pub fn get_width(self: *parser.Image) !u32 {
        return try parser.imageGetWidth(self);
    }
    pub fn set_width(self: *parser.Image, width: u32) !void {
        try parser.imageSetWidth(self, width);
    }
    pub fn get_isMap(self: *parser.Image) !bool {
        return try parser.imageGetIsMap(self);
    }
    pub fn set_isMap(self: *parser.Image, is_map: bool) !void {
        try parser.imageSetIsMap(self, is_map);
    }

    pub const Factory = struct {
        pub const js_name = "Image";
        pub const subtype = .node;

        pub const js_legacy_factory = true;
        pub const prototype = *HTMLImageElement;

        pub fn constructor(width: ?u32, height: ?u32, page: *const Page) !*parser.Image {
            const element = try parser.documentCreateElement(parser.documentHTMLToDocument(page.window.document), "img");
            const image: *parser.Image = @ptrCast(element);
            if (width) |width_| try parser.imageSetWidth(image, width_);
            if (height) |height_| try parser.imageSetHeight(image, height_);
            return image;
        }
    };
};

pub const HTMLInputElement = struct {
    pub const Self = parser.Input;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_defaultValue(self: *parser.Input) ![]const u8 {
        return try parser.inputGetDefaultValue(self);
    }
    pub fn set_defaultValue(self: *parser.Input, default_value: []const u8) !void {
        try parser.inputSetDefaultValue(self, default_value);
    }
    pub fn get_defaultChecked(self: *parser.Input) !bool {
        return try parser.inputGetDefaultChecked(self);
    }
    pub fn set_defaultChecked(self: *parser.Input, default_checked: bool) !void {
        try parser.inputSetDefaultChecked(self, default_checked);
    }
    pub fn get_form(self: *parser.Input) !?*parser.Form {
        return try parser.inputGetForm(self);
    }
    pub fn get_accept(self: *parser.Input) ![]const u8 {
        return try parser.inputGetAccept(self);
    }
    pub fn set_accept(self: *parser.Input, accept: []const u8) !void {
        try parser.inputSetAccept(self, accept);
    }
    pub fn get_alt(self: *parser.Input) ![]const u8 {
        return try parser.inputGetAlt(self);
    }
    pub fn set_alt(self: *parser.Input, alt: []const u8) !void {
        try parser.inputSetAlt(self, alt);
    }
    pub fn get_checked(self: *parser.Input) !bool {
        return try parser.inputGetChecked(self);
    }
    pub fn set_checked(self: *parser.Input, checked: bool) !void {
        try parser.inputSetChecked(self, checked);
    }
    pub fn get_disabled(self: *parser.Input) !bool {
        return try parser.inputGetDisabled(self);
    }
    pub fn set_disabled(self: *parser.Input, disabled: bool) !void {
        try parser.inputSetDisabled(self, disabled);
    }
    pub fn get_maxLength(self: *parser.Input) !i32 {
        return try parser.inputGetMaxLength(self);
    }
    pub fn set_maxLength(self: *parser.Input, max_length: i32) !void {
        try parser.inputSetMaxLength(self, max_length);
    }
    pub fn get_name(self: *parser.Input) ![]const u8 {
        return try parser.inputGetName(self);
    }
    pub fn set_name(self: *parser.Input, name: []const u8) !void {
        try parser.inputSetName(self, name);
    }
    pub fn get_readOnly(self: *parser.Input) !bool {
        return try parser.inputGetReadOnly(self);
    }
    pub fn set_readOnly(self: *parser.Input, read_only: bool) !void {
        try parser.inputSetReadOnly(self, read_only);
    }
    pub fn get_size(self: *parser.Input) !u32 {
        return try parser.inputGetSize(self);
    }
    pub fn set_size(self: *parser.Input, size: i32) !void {
        try parser.inputSetSize(self, size);
    }
    pub fn get_src(self: *parser.Input) ![]const u8 {
        return try parser.inputGetSrc(self);
    }
    pub fn set_src(self: *parser.Input, src: []const u8, page: *Page) !void {
        const new_src = try urlStitch(page.call_arena, src, page.url.raw, .{ .alloc = .if_needed });
        try parser.inputSetSrc(self, new_src);
    }
    pub fn get_type(self: *parser.Input) ![]const u8 {
        return try parser.inputGetType(self);
    }
    pub fn set_type(self: *parser.Input, type_: []const u8) !void {
        try parser.inputSetType(self, type_);
    }
    pub fn get_value(self: *parser.Input) ![]const u8 {
        return try parser.inputGetValue(self);
    }
    pub fn set_value(self: *parser.Input, value: []const u8) !void {
        try parser.inputSetValue(self, value);
    }
};

pub const HTMLLIElement = struct {
    pub const Self = parser.LI;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLLabelElement = struct {
    pub const Self = parser.Label;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLLegendElement = struct {
    pub const Self = parser.Legend;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLLinkElement = struct {
    pub const Self = parser.Link;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_rel(self: *parser.Link) ![]const u8 {
        return parser.linkGetRel(self);
    }

    pub fn set_rel(self: *parser.Link, rel: []const u8) !void {
        return parser.linkSetRel(self, rel);
    }

    pub fn get_href(self: *parser.Link) ![]const u8 {
        return parser.linkGetHref(self);
    }

    pub fn set_href(self: *parser.Link, href: []const u8, page: *const Page) !void {
        const full = try urlStitch(page.call_arena, href, page.url.raw, .{});
        return parser.linkSetHref(self, full);
    }
};

pub const HTMLMapElement = struct {
    pub const Self = parser.Map;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLMetaElement = struct {
    pub const Self = parser.Meta;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLMeterElement = struct {
    pub const Self = parser.Meter;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLModElement = struct {
    pub const Self = parser.Mod;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLOListElement = struct {
    pub const Self = parser.OList;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLObjectElement = struct {
    pub const Self = parser.Object;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLOptGroupElement = struct {
    pub const Self = parser.OptGroup;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLOutputElement = struct {
    pub const Self = parser.Output;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLParagraphElement = struct {
    pub const Self = parser.Paragraph;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLParamElement = struct {
    pub const Self = parser.Param;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLPictureElement = struct {
    pub const Self = parser.Picture;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLPreElement = struct {
    pub const Self = parser.Pre;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLProgressElement = struct {
    pub const Self = parser.Progress;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLQuoteElement = struct {
    pub const Self = parser.Quote;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

// https://html.spec.whatwg.org/#the-script-element
pub const HTMLScriptElement = struct {
    pub const Self = parser.Script;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_src(self: *parser.Script) !?[]const u8 {
        return try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "src",
        ) orelse "";
    }

    pub fn set_src(self: *parser.Script, v: []const u8, page: *Page) !void {
        try parser.elementSetAttribute(
            parser.scriptToElt(self),
            "src",
            v,
        );

        if (try Node.get_isConnected(@ptrCast(@alignCast(self)))) {
            // There are sites which do set the src AFTER appending the script
            // tag to the document:
            //    const s = document.createElement('script');
            //    document.getElementsByTagName('body')[0].appendChild(s);
            //    s.src = '...';
            // This should load the script.
            // addFromElement protects against double execution.
            try page.script_manager.addFromElement(@ptrCast(@alignCast(self)), "dynamic");
        }
    }

    pub fn get_type(self: *parser.Script) !?[]const u8 {
        return try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "type",
        ) orelse "";
    }

    pub fn set_type(self: *parser.Script, v: []const u8) !void {
        try parser.elementSetAttribute(
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
        try parser.elementSetAttribute(
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
        try parser.elementSetAttribute(
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

    pub fn get_nonce(self: *parser.Script) !?[]const u8 {
        return try parser.elementGetAttribute(
            parser.scriptToElt(self),
            "nonce",
        ) orelse "";
    }

    pub fn set_nonce(self: *parser.Script, v: []const u8) !void {
        try parser.elementSetAttribute(
            parser.scriptToElt(self),
            "nonce",
            v,
        );
    }

    pub fn get_onload(self: *parser.Script, page: *Page) !?js.Function {
        const state = page.getNodeState(@ptrCast(@alignCast(self))) orelse return null;
        return state.onload;
    }

    pub fn set_onload(self: *parser.Script, function: ?js.Function, page: *Page) !void {
        const state = try page.getOrCreateNodeState(@ptrCast(@alignCast(self)));
        state.onload = function;
    }

    pub fn get_onerror(self: *parser.Script, page: *Page) !?js.Function {
        const state = page.getNodeState(@ptrCast(@alignCast(self))) orelse return null;
        return state.onerror;
    }

    pub fn set_onerror(self: *parser.Script, function: ?js.Function, page: *Page) !void {
        const state = try page.getOrCreateNodeState(@ptrCast(@alignCast(self)));
        state.onerror = function;
    }
};

pub const HTMLSourceElement = struct {
    pub const Self = parser.Source;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLSpanElement = struct {
    pub const Self = parser.Span;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLSlotElement = struct {
    pub const Self = parser.Slot;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_name(self: *parser.Slot) !?[]const u8 {
        return (try parser.elementGetAttribute(@ptrCast(@alignCast(self)), "name")) orelse "";
    }

    pub fn set_name(self: *parser.Slot, value: []const u8) !void {
        return parser.elementSetAttribute(@ptrCast(@alignCast(self)), "name", value);
    }

    const AssignedNodesOpts = struct {
        flatten: bool = false,
    };
    pub fn _assignedNodes(self: *parser.Slot, opts_: ?AssignedNodesOpts, page: *Page) ![]NodeUnion {
        return findAssignedSlotNodes(self, opts_, false, page);
    }

    // This should return Union, instead of NodeUnion, but we want to re-use
    // findAssignedSlotNodes. Returning NodeUnion is fine, as long as every element
    // within is an Element. This could be more efficient
    pub fn _assignedElements(self: *parser.Slot, opts_: ?AssignedNodesOpts, page: *Page) ![]NodeUnion {
        return findAssignedSlotNodes(self, opts_, true, page);
    }

    fn findAssignedSlotNodes(self: *parser.Slot, opts_: ?AssignedNodesOpts, element_only: bool, page: *Page) ![]NodeUnion {
        const opts = opts_ orelse AssignedNodesOpts{ .flatten = false };

        if (opts.flatten) {
            log.debug(.web_api, "not implemented", .{ .feature = "HTMLSlotElement flatten assignedNodes" });
        }

        const node: *parser.Node = @ptrCast(@alignCast(self));

        // First we look for any explicitly assigned nodes (via the slot attribute)
        {
            const slot_name = try parser.elementGetAttribute(@ptrCast(@alignCast(self)), "name");
            var root = parser.nodeGetRootNode(node);
            if (page.getNodeState(root)) |state| {
                if (state.shadow_root) |sr| {
                    root = @ptrCast(@alignCast(sr.host));
                }
            }

            var arr: std.ArrayList(NodeUnion) = .empty;
            const w = @import("../dom/walker.zig").WalkerChildren{};
            var next: ?*parser.Node = null;
            while (true) {
                next = try w.get_next(root, next) orelse break;
                if (parser.nodeType(next.?) != .element) {
                    if (slot_name == null and !element_only) {
                        // default slot (with no name), takes everything
                        try arr.append(page.call_arena, try Node.toInterface(next.?));
                    }
                    continue;
                }
                const el: *parser.Element = @ptrCast(@alignCast(next.?));
                const element_slot = try parser.elementGetAttribute(el, "slot");

                if (nullableStringsAreEqual(slot_name, element_slot)) {
                    // either they're the same string or they are both null
                    try arr.append(page.call_arena, try Node.toInterface(next.?));
                    continue;
                }
            }
            if (arr.items.len > 0) {
                return arr.items;
            }

            if (!opts.flatten) {
                return &.{};
            }
        }

        // Since, we have no explicitly assigned nodes and flatten == false,
        // we'll collect the children of the slot - the defaults.
        {
            const nl = try parser.nodeGetChildNodes(node);
            const len = parser.nodeListLength(nl);
            if (len == 0) {
                return &.{};
            }

            var assigned = try page.call_arena.alloc(NodeUnion, len);
            var i: usize = 0;
            while (true) : (i += 1) {
                const child = parser.nodeListItem(nl, @intCast(i)) orelse break;
                if (!element_only or parser.nodeType(child) == .element) {
                    assigned[i] = try Node.toInterface(child);
                }
            }
            return assigned[0..i];
        }
    }

    fn nullableStringsAreEqual(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) {
            return true;
        }
        if (a) |aa| {
            const bb = b orelse return false;
            return std.mem.eql(u8, aa, bb);
        }

        // a is null, but b isn't (else the first guard clause would have hit)
        return false;
    }
};

pub const HTMLStyleElement = struct {
    pub const Self = parser.Style;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_sheet(self: *parser.Style, page: *Page) !*StyleSheet {
        const state = try page.getOrCreateNodeState(@ptrCast(@alignCast(self)));
        if (state.style_sheet) |ss| {
            return ss;
        }

        const ss = try page.arena.create(StyleSheet);
        ss.* = .{};
        state.style_sheet = ss;
        return ss;
    }
};

pub const HTMLTableElement = struct {
    pub const Self = parser.Table;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLTableCaptionElement = struct {
    pub const Self = parser.TableCaption;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLTableCellElement = struct {
    pub const Self = parser.TableCell;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLTableColElement = struct {
    pub const Self = parser.TableCol;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLTableRowElement = struct {
    pub const Self = parser.TableRow;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLTableSectionElement = struct {
    pub const Self = parser.TableSection;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLTemplateElement = struct {
    pub const Self = parser.Template;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;

    pub fn get_content(self: *parser.Template, page: *Page) !*parser.DocumentFragment {
        const state = try page.getOrCreateNodeState(@ptrCast(@alignCast(self)));
        if (state.template_content) |tc| {
            return tc;
        }
        const tc = try parser.documentCreateDocumentFragment(@ptrCast(page.window.document));
        state.template_content = tc;
        return tc;
    }
};

pub const HTMLTextAreaElement = struct {
    pub const Self = parser.TextArea;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLTimeElement = struct {
    pub const Self = parser.Time;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLTitleElement = struct {
    pub const Self = parser.Title;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLTrackElement = struct {
    pub const Self = parser.Track;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLUListElement = struct {
    pub const Self = parser.UList;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub const HTMLVideoElement = struct {
    pub const Self = parser.Video;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
};

pub fn toInterfaceFromTag(comptime T: type, e: *parser.Element, tag: parser.Tag) !T {
    return switch (tag) {
        .abbr, .acronym, .address, .article, .aside, .b, .basefont, .bdi, .bdo, .bgsound, .big, .center, .cite, .code, .dd, .details, .dfn, .dt, .em, .figcaption, .figure, .footer, .header, .hgroup, .i, .isindex, .keygen, .kbd, .main, .mark, .marquee, .menu, .menuitem, .nav, .nobr, .noframes, .noscript, .rp, .rt, .ruby, .s, .samp, .section, .small, .spacer, .strike, .strong, .sub, .summary, .sup, .tt, .u, .wbr, ._var => .{ .HTMLElement = @as(*parser.ElementHTML, @ptrCast(e)) },
        .a => .{ .HTMLAnchorElement = @as(*parser.Anchor, @ptrCast(e)) },
        .applet => .{ .HTMLAppletElement = @as(*parser.Applet, @ptrCast(e)) },
        .area => .{ .HTMLAreaElement = @as(*parser.Area, @ptrCast(e)) },
        .audio => .{ .HTMLAudioElement = @as(*parser.Audio, @ptrCast(e)) },
        .base => .{ .HTMLBaseElement = @as(*parser.Base, @ptrCast(e)) },
        .body => .{ .HTMLBodyElement = @as(*parser.Body, @ptrCast(e)) },
        .br => .{ .HTMLBRElement = @as(*parser.BR, @ptrCast(e)) },
        .button => .{ .HTMLButtonElement = @as(*parser.Button, @ptrCast(e)) },
        .canvas => .{ .HTMLCanvasElement = @as(*parser.Canvas, @ptrCast(e)) },
        .dl => .{ .HTMLDListElement = @as(*parser.DList, @ptrCast(e)) },
        .data => .{ .HTMLDataElement = @as(*parser.Data, @ptrCast(e)) },
        .datalist => .{ .HTMLDataListElement = @as(*parser.DataList, @ptrCast(e)) },
        .dialog => .{ .HTMLDialogElement = @as(*parser.Dialog, @ptrCast(e)) },
        .dir => .{ .HTMLDirectoryElement = @as(*parser.Directory, @ptrCast(e)) },
        .div => .{ .HTMLDivElement = @as(*parser.Div, @ptrCast(e)) },
        .embed => .{ .HTMLEmbedElement = @as(*parser.Embed, @ptrCast(e)) },
        .fieldset => .{ .HTMLFieldSetElement = @as(*parser.FieldSet, @ptrCast(e)) },
        .font => .{ .HTMLFontElement = @as(*parser.Font, @ptrCast(e)) },
        .form => .{ .HTMLFormElement = @as(*parser.Form, @ptrCast(e)) },
        .frame => .{ .HTMLFrameElement = @as(*parser.Frame, @ptrCast(e)) },
        .frameset => .{ .HTMLFrameSetElement = @as(*parser.FrameSet, @ptrCast(e)) },
        .hr => .{ .HTMLHRElement = @as(*parser.HR, @ptrCast(e)) },
        .head => .{ .HTMLHeadElement = @as(*parser.Head, @ptrCast(e)) },
        .h1, .h2, .h3, .h4, .h5, .h6 => .{ .HTMLHeadingElement = @as(*parser.Heading, @ptrCast(e)) },
        .html => .{ .HTMLHtmlElement = @as(*parser.Html, @ptrCast(e)) },
        .iframe => .{ .HTMLIFrameElement = @as(*parser.IFrame, @ptrCast(e)) },
        .img => .{ .HTMLImageElement = @as(*parser.Image, @ptrCast(e)) },
        .input => .{ .HTMLInputElement = @as(*parser.Input, @ptrCast(e)) },
        .li => .{ .HTMLLIElement = @as(*parser.LI, @ptrCast(e)) },
        .label => .{ .HTMLLabelElement = @as(*parser.Label, @ptrCast(e)) },
        .legend => .{ .HTMLLegendElement = @as(*parser.Legend, @ptrCast(e)) },
        .link => .{ .HTMLLinkElement = @as(*parser.Link, @ptrCast(e)) },
        .map => .{ .HTMLMapElement = @as(*parser.Map, @ptrCast(e)) },
        .meta => .{ .HTMLMetaElement = @as(*parser.Meta, @ptrCast(e)) },
        .meter => .{ .HTMLMeterElement = @as(*parser.Meter, @ptrCast(e)) },
        .ins, .del => .{ .HTMLModElement = @as(*parser.Mod, @ptrCast(e)) },
        .ol => .{ .HTMLOListElement = @as(*parser.OList, @ptrCast(e)) },
        .object => .{ .HTMLObjectElement = @as(*parser.Object, @ptrCast(e)) },
        .optgroup => .{ .HTMLOptGroupElement = @as(*parser.OptGroup, @ptrCast(e)) },
        .option => .{ .HTMLOptionElement = @as(*parser.Option, @ptrCast(e)) },
        .output => .{ .HTMLOutputElement = @as(*parser.Output, @ptrCast(e)) },
        .p => .{ .HTMLParagraphElement = @as(*parser.Paragraph, @ptrCast(e)) },
        .param => .{ .HTMLParamElement = @as(*parser.Param, @ptrCast(e)) },
        .picture => .{ .HTMLPictureElement = @as(*parser.Picture, @ptrCast(e)) },
        .pre => .{ .HTMLPreElement = @as(*parser.Pre, @ptrCast(e)) },
        .progress => .{ .HTMLProgressElement = @as(*parser.Progress, @ptrCast(e)) },
        .blockquote, .q => .{ .HTMLQuoteElement = @as(*parser.Quote, @ptrCast(e)) },
        .script => .{ .HTMLScriptElement = @as(*parser.Script, @ptrCast(e)) },
        .select => .{ .HTMLSelectElement = @as(*parser.Select, @ptrCast(e)) },
        .source => .{ .HTMLSourceElement = @as(*parser.Source, @ptrCast(e)) },
        .span => .{ .HTMLSpanElement = @as(*parser.Span, @ptrCast(e)) },
        .slot => .{ .HTMLSlotElement = @as(*parser.Slot, @ptrCast(e)) },
        .style => .{ .HTMLStyleElement = @as(*parser.Style, @ptrCast(e)) },
        .table => .{ .HTMLTableElement = @as(*parser.Table, @ptrCast(e)) },
        .caption => .{ .HTMLTableCaptionElement = @as(*parser.TableCaption, @ptrCast(e)) },
        .th, .td => .{ .HTMLTableCellElement = @as(*parser.TableCell, @ptrCast(e)) },
        .col, .colgroup => .{ .HTMLTableColElement = @as(*parser.TableCol, @ptrCast(e)) },
        .tr => .{ .HTMLTableRowElement = @as(*parser.TableRow, @ptrCast(e)) },
        .thead, .tbody, .tfoot => .{ .HTMLTableSectionElement = @as(*parser.TableSection, @ptrCast(e)) },
        .template => .{ .HTMLTemplateElement = @as(*parser.Template, @ptrCast(e)) },
        .textarea => .{ .HTMLTextAreaElement = @as(*parser.TextArea, @ptrCast(e)) },
        .time => .{ .HTMLTimeElement = @as(*parser.Time, @ptrCast(e)) },
        .title => .{ .HTMLTitleElement = @as(*parser.Title, @ptrCast(e)) },
        .track => .{ .HTMLTrackElement = @as(*parser.Track, @ptrCast(e)) },
        .ul => .{ .HTMLUListElement = @as(*parser.UList, @ptrCast(e)) },
        .video => .{ .HTMLVideoElement = @as(*parser.Video, @ptrCast(e)) },
        .undef => .{ .HTMLUnknownElement = @as(*parser.Unknown, @ptrCast(e)) },
    };
}

const testing = @import("../../testing.zig");
test "Browser: HTML.Element" {
    try testing.htmlRunner("html/element.html");
}

test "Browser: HTML.HtmlLinkElement" {
    try testing.htmlRunner("html/link.html");
}

test "Browser: HTML.HtmlImageElement" {
    try testing.htmlRunner("html/image.html");
}

test "Browser: HTML.HtmlInputElement" {
    try testing.htmlRunner("html/input.html");
}

test "Browser: HTML.HtmlTemplateElement" {
    try testing.htmlRunner("html/template.html");
}

test "Browser: HTML.HtmlStyleElement" {
    try testing.htmlRunner("html/style.html");
}

test "Browser: HTML.HtmlScriptElement" {
    try testing.htmlRunner("html/script/script.html");
    try testing.htmlRunner("html/script/inline_defer.html");
    try testing.htmlRunner("html/script/import.html");
    try testing.htmlRunner("html/script/dynamic_import.html");
}

test "Browser: HTML.HtmlSlotElement" {
    try testing.htmlRunner("html/slot.html");
}
