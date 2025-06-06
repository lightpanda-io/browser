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

const parser = @import("../netsurf.zig");
const generate = @import("../../runtime/generate.zig");
const Env = @import("../env.zig").Env;
const Page = @import("../page.zig").Page;

const urlStitch = @import("../../url.zig").URL.stitch;
const URL = @import("../url/url.zig").URL;
const Node = @import("../dom/node.zig").Node;
const Element = @import("../dom/element.zig").Element;

const CSSStyleDeclaration = @import("../cssom/css_style_declaration.zig").CSSStyleDeclaration;

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
    HTMLFrameElement,
    HTMLFrameSetElement,
    HTMLHRElement,
    HTMLHeadElement,
    HTMLHeadingElement,
    HTMLHtmlElement,
    HTMLIFrameElement,
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
    HTMLOptionElement,
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
    @import("select.zig").HTMLSelectElement,
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
        _ = try parser.nodeAppendChild(n, @as(*parser.Node, @alignCast(@ptrCast(t))));
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
        if (!try page.isNodeAttached(@ptrCast(e))) {
            return;
        }

        const Document = @import("../dom/document.zig").Document;
        const root_node = try parser.nodeGetRootNode(@ptrCast(e));
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
        return try parser.nodeTextContent(parser.anchorToNode(self));
    }

    pub fn set_text(self: *parser.Anchor, v: []const u8) !void {
        return try parser.nodeSetTextContent(parser.anchorToNode(self), v);
    }

    inline fn url(self: *parser.Anchor, page: *Page) !URL {
        return URL.constructor(.{ .element = @alignCast(@ptrCast(self)) }, null, page); // TODO inject base url
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

pub const HTMLIFrameElement = struct {
    pub const Self = parser.IFrame;
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

pub const HTMLOptionElement = struct {
    pub const Self = parser.Option;
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

    pub fn get_onload(self: *parser.Script, page: *Page) !?Env.Function {
        const state = page.getNodeState(@alignCast(@ptrCast(self))) orelse return null;
        return state.onload;
    }

    pub fn set_onload(self: *parser.Script, function: ?Env.Function, page: *Page) !void {
        const state = try page.getOrCreateNodeState(@alignCast(@ptrCast(self)));
        state.onload = function;
    }

    pub fn get_onerror(self: *parser.Script, page: *Page) !?Env.Function {
        const state = page.getNodeState(@alignCast(@ptrCast(self))) orelse return null;
        return state.onerror;
    }

    pub fn set_onerror(self: *parser.Script, function: ?Env.Function, page: *Page) !void {
        const state = try page.getOrCreateNodeState(@alignCast(@ptrCast(self)));
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

pub const HTMLStyleElement = struct {
    pub const Self = parser.Style;
    pub const prototype = *HTMLElement;
    pub const subtype = .node;
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

const testing = @import("../../testing.zig");
test "Browser.HTML.Element" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let link = document.getElementById('link')", "undefined" },
        .{ "link.target", "" },
        .{ "link.target = '_blank'", "_blank" },
        .{ "link.target", "_blank" },
        .{ "link.target = ''", "" },

        .{ "link.href", "foo" },
        .{ "link.href = 'https://lightpanda.io/'", "https://lightpanda.io/" },
        .{ "link.href", "https://lightpanda.io/" },

        .{ "link.origin", "https://lightpanda.io" },

        .{ "link.host = 'lightpanda.io:443'", "lightpanda.io:443" },
        .{ "link.host", "lightpanda.io:443" },
        .{ "link.port", "443" },
        .{ "link.hostname", "lightpanda.io" },

        .{ "link.host = 'lightpanda.io'", "lightpanda.io" },
        .{ "link.host", "lightpanda.io" },
        .{ "link.port", "" },
        .{ "link.hostname", "lightpanda.io" },

        .{ "link.host", "lightpanda.io" },
        .{ "link.hostname", "lightpanda.io" },
        .{ "link.hostname = 'foo.bar'", "foo.bar" },
        .{ "link.href", "https://foo.bar/" },

        .{ "link.search", "" },
        .{ "link.search = 'q=bar'", "q=bar" },
        .{ "link.search", "?q=bar" },
        .{ "link.href", "https://foo.bar/?q=bar" },

        .{ "link.hash", "" },
        .{ "link.hash = 'frag'", "frag" },
        .{ "link.hash", "#frag" },
        .{ "link.href", "https://foo.bar/?q=bar#frag" },

        .{ "link.port", "" },
        .{ "link.port = '443'", "443" },
        .{ "link.host", "foo.bar:443" },
        .{ "link.hostname", "foo.bar" },
        .{ "link.href", "https://foo.bar:443/?q=bar#frag" },
        .{ "link.port = null", "null" },
        .{ "link.href", "https://foo.bar/?q=bar#frag" },

        .{ "link.href = 'foo'", "foo" },

        .{ "link.type", "" },
        .{ "link.type = 'text/html'", "text/html" },
        .{ "link.type", "text/html" },
        .{ "link.type = ''", "" },

        .{ "link.text", "OK" },
        .{ "link.text = 'foo'", "foo" },
        .{ "link.text", "foo" },
        .{ "link.text = 'OK'", "OK" },
    }, .{});

    try runner.testCases(&.{
        .{ "let script = document.createElement('script')", "undefined" },
        .{ "script.src = 'foo.bar'", "foo.bar" },

        .{ "script.async = true", "true" },
        .{ "script.async", "true" },
        .{ "script.async = false", "false" },
        .{ "script.async", "false" },
    }, .{});

    try runner.testCases(&.{
        .{ "const backup = document.getElementById('content')", "undefined" },
        .{ "document.getElementById('content').innerText = 'foo';", "foo" },
        .{ "document.getElementById('content').innerText", "foo" },
        .{ "document.getElementById('content').innerHTML = backup; true;", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "let click_count = 0;", "undefined" },
        .{ "let clickCbk = function() { click_count++ }", "undefined" },
        .{ "document.getElementById('content').addEventListener('click', clickCbk);", "undefined" },
        .{ "document.getElementById('content').click()", "undefined" },
        .{ "click_count", "1" },
    }, .{});

    try runner.testCases(&.{
        .{ "let style = document.getElementById('content').style", "undefined" },
        .{ "style.cssText = 'color: red; font-size: 12px; margin: 5px !important;'", "color: red; font-size: 12px; margin: 5px !important;" },
        .{ "style.length", "3" },
        .{ "style.setProperty('background-color', 'blue')", "undefined" },
        .{ "style.getPropertyValue('background-color')", "blue" },
        .{ "style.length", "4" },
    }, .{});

    // Image
    try runner.testCases(&.{
        // Testing constructors
        .{ "(new Image).width", "0" },
        .{ "(new Image).height", "0" },
        .{ "(new Image(4)).width", "4" },
        .{ "(new Image(4, 6)).height", "6" },

        // Testing ulong property
        .{ "let fruit = new Image", null },
        .{ "fruit.width", "0" },
        .{ "fruit.width = 5", "5" },
        .{ "fruit.width", "5" },
        .{ "fruit.width = '15'", "15" },
        .{ "fruit.width", "15" },
        .{ "fruit.width = 'apple'", "apple" },
        .{ "fruit.width;", "0" },

        // Testing string property
        .{ "let lyric = new Image", null },
        .{ "lyric.src", "" },
        .{ "lyric.src = 'okay'", "okay" },
        .{ "lyric.src", "okay" },
        .{ "lyric.src = 15", "15" },
        .{ "lyric.src", "15" },
    }, .{});

    try runner.testCases(&.{
        .{ "let a = document.createElement('a');", null },
        .{ "a.href = 'about'", null },
        .{ "a.href", "https://lightpanda.io/opensource-browser/about" },
    }, .{});

    // detached node cannot be focused
    try runner.testCases(&.{
        .{ "const focused = document.activeElement", null },
        .{ "document.createElement('a').focus()", null },
        .{ "document.activeElement === focused", "true" },
    }, .{});
}
test "Browser.HTML.HtmlInputElement.propeties" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .url = "https://lightpanda.io/noslashattheend" });
    defer runner.deinit();
    var alloc = std.heap.ArenaAllocator.init(runner.app.allocator);
    defer alloc.deinit();
    const arena = alloc.allocator();

    try runner.testCases(&.{.{ "let elem_input = document.createElement('input')", null }}, .{});

    try runner.testCases(&.{.{ "elem_input.form", "null" }}, .{}); // Initial value
    // Valid input.form is tested separately :Browser.HTML.HtmlInputElement.propeties.form
    try testProperty(arena, &runner, "elem_input.form", "null", &.{.{ .input = "'foo'" }}); // Invalid

    try runner.testCases(&.{.{ "elem_input.accept", "" }}, .{}); // Initial value
    try testProperty(arena, &runner, "elem_input.accept", null, &str_valids); // Valid

    try runner.testCases(&.{.{ "elem_input.alt", "" }}, .{}); // Initial value
    try testProperty(arena, &runner, "elem_input.alt", null, &str_valids); // Valid

    try runner.testCases(&.{.{ "elem_input.disabled", "false" }}, .{}); // Initial value
    try testProperty(arena, &runner, "elem_input.disabled", null, &bool_valids); // Valid

    try runner.testCases(&.{.{ "elem_input.maxLength", "-1" }}, .{}); // Initial value
    try testProperty(arena, &runner, "elem_input.maxLength", null, &.{.{ .input = "5" }}); // Valid
    try testProperty(arena, &runner, "elem_input.maxLength", "0", &.{.{ .input = "'banana'" }}); // Invalid
    try runner.testCases(&.{.{ "try { elem_input.maxLength = -45 } catch(e) {e}", "Error: NegativeValueNotAllowed" }}, .{}); // Error

    try runner.testCases(&.{.{ "elem_input.name", "" }}, .{}); // Initial value
    try testProperty(arena, &runner, "elem_input.name", null, &str_valids); // Valid

    try runner.testCases(&.{.{ "elem_input.readOnly", "false" }}, .{}); // Initial value
    try testProperty(arena, &runner, "elem_input.readOnly", null, &bool_valids); // Valid

    try runner.testCases(&.{.{ "elem_input.size", "20" }}, .{}); // Initial value
    try testProperty(arena, &runner, "elem_input.size", null, &.{.{ .input = "5" }}); // Valid
    try testProperty(arena, &runner, "elem_input.size", "20", &.{.{ .input = "-26" }}); // Invalid
    try runner.testCases(&.{.{ "try { elem_input.size = 0 } catch(e) {e}", "Error: ZeroNotAllowed" }}, .{}); // Error
    try runner.testCases(&.{.{ "try { elem_input.size = 'banana' } catch(e) {e}", "Error: ZeroNotAllowed" }}, .{}); // Error

    try runner.testCases(&.{.{ "elem_input.src", "" }}, .{}); // Initial value
    try testProperty(arena, &runner, "elem_input.src", null, &.{
        .{ .input = "'foo'", .expected = "https://lightpanda.io/foo" }, // TODO stitch should work with spaces -> %20
        .{ .input = "-3", .expected = "https://lightpanda.io/-3" },
        .{ .input = "''", .expected = "https://lightpanda.io/noslashattheend" },
    });

    try runner.testCases(&.{.{ "elem_input.type", "text" }}, .{}); // Initial value
    try testProperty(arena, &runner, "elem_input.type", null, &.{.{ .input = "'checkbox'", .expected = "checkbox" }}); // Valid
    try testProperty(arena, &runner, "elem_input.type", "text", &.{.{ .input = "'5'" }}); // Invalid

    // Properties that are related
    try runner.testCases(&.{
        .{ "let input_checked = document.createElement('input')", null },
        .{ "input_checked.defaultChecked", "false" },
        .{ "input_checked.checked", "false" },

        .{ "input_checked.defaultChecked = true", "true" },
        .{ "input_checked.defaultChecked", "true" },
        .{ "input_checked.checked", "true" }, // Also perceived as true

        .{ "input_checked.checked = false", "false" },
        .{ "input_checked.defaultChecked", "true" },
        .{ "input_checked.checked", "false" },

        .{ "input_checked.defaultChecked = true", "true" },
        .{ "input_checked.checked", "false" }, // Still false
    }, .{});
    try runner.testCases(&.{
        .{ "let input_value = document.createElement('input')", null },
        .{ "input_value.defaultValue", "" },
        .{ "input_value.value", "" },

        .{ "input_value.defaultValue = 3.1", "3.1" },
        .{ "input_value.defaultValue", "3.1" },
        .{ "input_value.value", "3.1" }, // Also perceived as 3.1

        .{ "input_value.value = 'mango'", "mango" },
        .{ "input_value.defaultValue", "3.1" },
        .{ "input_value.value", "mango" },

        .{ "input_value.defaultValue = true", "true" },
        .{ "input_value.value", "mango" }, // Still mango
    }, .{});
}
test "Browser.HTML.HtmlInputElement.propeties.form" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .html = 
        \\ <form action="test.php" target="_blank">
        \\   <p>
        \\     <label>First name: <input type="text" name="first-name" /></label>
        \\   </p>
        \\ </form>
    });
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let elem_input = document.querySelector('input')", null },
    }, .{});
    try runner.testCases(&.{.{ "elem_input.form", "[object HTMLFormElement]" }}, .{}); // Initial value
    try runner.testCases(&.{
        .{ "elem_input.form = 'foo'", null },
        .{ "elem_input.form", "[object HTMLFormElement]" }, // Invalid
    }, .{});
}

const Check = struct {
    input: []const u8,
    expected: ?[]const u8 = null, // Needed when input != expected
};
const bool_valids = [_]Check{
    .{ .input = "true" },
    .{ .input = "''", .expected = "false" },
    .{ .input = "13.5", .expected = "true" },
};
const str_valids = [_]Check{
    .{ .input = "'foo'", .expected = "foo" },
    .{ .input = "5", .expected = "5" },
    .{ .input = "''", .expected = "" },
    .{ .input = "document", .expected = "[object HTMLDocument]" },
};

// .{ "elem.type = '5'", "5" },
// .{ "elem.type", "text" },
fn testProperty(
    arena: std.mem.Allocator,
    runner: *testing.JsRunner,
    elem_dot_prop: []const u8,
    always: ?[]const u8, // Ignores checks' expected if set
    checks: []const Check,
) !void {
    for (checks) |check| {
        try runner.testCases(&.{
            .{ try std.mem.concat(arena, u8, &.{ elem_dot_prop, " = ", check.input }), null },
            .{ elem_dot_prop, always orelse check.expected orelse check.input },
        }, .{});
    }
}
