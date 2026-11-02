// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");
const StyleManager = @import("../../StyleManager.zig");

const Node = @import("../Node.zig");
const Window = @import("../Window.zig");
const Element = @import("../Element.zig");
const DOMStringMap = @import("DOMStringMap.zig");
const EventTarget = @import("../EventTarget.zig");
const ElementInternals = @import("../ElementInternals.zig");
const global_event_handlers = @import("../global_event_handlers.zig");

const reflection = @import("reflection.zig");
const popover = @import("popover.zig");
pub const Anchor = @import("html/Anchor.zig");
pub const Area = @import("html/Area.zig");
pub const Base = @import("html/Base.zig");
pub const Body = @import("html/Body.zig");
pub const BR = @import("html/BR.zig");
pub const Button = @import("html/Button.zig");
pub const Canvas = @import("html/Canvas.zig");
pub const Custom = @import("html/Custom.zig");
pub const Data = @import("html/Data.zig");
pub const DataList = @import("html/DataList.zig");
pub const Details = @import("html/Details.zig");
pub const Dialog = @import("html/Dialog.zig");
pub const Directory = @import("html/Directory.zig");
pub const Div = @import("html/Div.zig");
pub const DList = @import("html/DList.zig");
pub const Embed = @import("html/Embed.zig");
pub const FieldSet = @import("html/FieldSet.zig");
pub const Font = @import("html/Font.zig");
pub const Form = @import("html/Form.zig");
pub const FrameSet = @import("html/FrameSet.zig");
pub const Generic = @import("html/Generic.zig");
pub const Head = @import("html/Head.zig");
pub const Heading = @import("html/Heading.zig");
pub const HR = @import("html/HR.zig");
pub const Html = @import("html/Html.zig");
pub const IFrame = @import("html/IFrame.zig");
pub const Image = @import("html/Image.zig");
pub const Input = @import("html/Input.zig");
pub const Label = @import("html/Label.zig");
pub const Legend = @import("html/Legend.zig");
pub const LI = @import("html/LI.zig");
pub const Link = @import("html/Link.zig");
pub const Map = @import("html/Map.zig");
pub const Marquee = @import("html/Marquee.zig");
pub const Media = @import("html/Media.zig");
pub const Meta = @import("html/Meta.zig");
pub const Meter = @import("html/Meter.zig");
pub const Mod = @import("html/Mod.zig");
pub const Object = @import("html/Object.zig");
pub const OL = @import("html/OL.zig");
pub const OptGroup = @import("html/OptGroup.zig");
pub const Option = @import("html/Option.zig");
pub const Output = @import("html/Output.zig");
pub const Paragraph = @import("html/Paragraph.zig");
pub const Picture = @import("html/Picture.zig");
pub const Param = @import("html/Param.zig");
pub const Pre = @import("html/Pre.zig");
pub const Progress = @import("html/Progress.zig");
pub const Quote = @import("html/Quote.zig");
pub const Script = @import("html/Script.zig");
pub const Select = @import("html/Select.zig");
pub const Slot = @import("html/Slot.zig");
pub const Source = @import("html/Source.zig");
pub const Span = @import("html/Span.zig");
pub const Style = @import("html/Style.zig");
pub const Table = @import("html/Table.zig");
pub const TableCaption = @import("html/TableCaption.zig");
pub const TableCell = @import("html/TableCell.zig");
pub const TableCol = @import("html/TableCol.zig");
pub const TableRow = @import("html/TableRow.zig");
pub const TableSection = @import("html/TableSection.zig");
pub const Template = @import("html/Template.zig");
pub const TextArea = @import("html/TextArea.zig");
pub const Time = @import("html/Time.zig");
pub const Title = @import("html/Title.zig");
pub const Track = @import("html/Track.zig");
pub const UL = @import("html/UL.zig");
pub const Unknown = @import("html/Unknown.zig");

const TextTransform = StyleManager.TextTransform;

const HtmlElement = @This();

pub const Proto = Element;

_type: Type,
_proto_canary: if (lp.IS_DEBUG) *Element else void = undefined,

// Special constructor for custom elements (autonomous, `extends HTMLElement`).
// Two paths:
//  - Upgrade path: customElements.define / createElement / upgrade set
//    `_upgrading_element` before calling newInstance, and we just return it.
//  - Direct path: `new MyElement()` from user code. `new.target` tells us
//    which custom element class was invoked; look it up in the registry.
pub fn construct(new_target: js.Function, frame: *Frame) !*Element {
    if (frame._upgrading_element) |node| {
        if (frame._upgrading_consumed) {
            return error.TypeError;
        }
        frame._upgrading_consumed = true;
        return node.is(Element) orelse return error.IllegalConstructor;
    }
    return Frame.node_factory.constructCustomElement(frame, new_target);
}

// Shared constructor callback for builtin html element interfaces. These types
// cannot be instantinated (e.g. new HTMLDivElement), but a custom element can
// be extended, so super() has to create them. All of these types have their
// constructors routed here.
pub fn upgradeConstruct(frame: *Frame) !*Element {
    const node = frame._upgrading_element orelse return error.TypeError;
    if (frame._upgrading_consumed) {
        return error.TypeError;
    }
    frame._upgrading_consumed = true;
    return node.is(Element) orelse return error.TypeError;
}

fn attachInternals(self: *HtmlElement, frame: *Frame) !*ElementInternals {
    const custom = self.is(Custom) orelse return error.NotSupported;
    const definition = custom._definition orelse return error.NotSupported;
    if (definition.disable_internals or custom._internals != null) {
        return error.NotSupported;
    }
    const internals = try ElementInternals.init(custom, frame);
    custom._internals = internals;
    return internals;
}

pub const Type = enum(u8) {
    anchor,
    area,
    base,
    body,
    br,
    button,
    canvas,
    custom,
    data,
    datalist,
    details,
    dialog,
    directory,
    div,
    dl,
    embed,
    fieldset,
    font,
    form,
    frameset,
    generic,
    heading,
    head,
    html,
    hr,
    img,
    iframe,
    input,
    label,
    legend,
    li,
    link,
    map,
    marquee,
    media,
    meta,
    meter,
    mod,
    object,
    ol,
    optgroup,
    option,
    output,
    p,
    picture,
    param,
    pre,
    progress,
    quote,
    script,
    select,
    slot,
    source,
    span,
    style,
    table,
    table_caption,
    table_cell,
    table_col,
    table_row,
    table_section,
    template,
    textarea,
    time,
    title,
    track,
    ul,
    unknown,
};

pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .anchor => Anchor,
        .area => Area,
        .base => Base,
        .body => Body,
        .br => BR,
        .button => Button,
        .canvas => Canvas,
        .custom => Custom,
        .data => Data,
        .datalist => DataList,
        .details => Details,
        .dialog => Dialog,
        .directory => Directory,
        .div => Div,
        .dl => DList,
        .embed => Embed,
        .fieldset => FieldSet,
        .font => Font,
        .form => Form,
        .frameset => FrameSet,
        .generic => Generic,
        .heading => Heading,
        .head => Head,
        .html => Html,
        .hr => HR,
        .img => Image,
        .iframe => IFrame,
        .input => Input,
        .label => Label,
        .legend => Legend,
        .li => LI,
        .link => Link,
        .map => Map,
        .marquee => Marquee,
        .media => Media,
        .meta => Meta,
        .meter => Meter,
        .mod => Mod,
        .object => Object,
        .ol => OL,
        .optgroup => OptGroup,
        .option => Option,
        .output => Output,
        .p => Paragraph,
        .picture => Picture,
        .param => Param,
        .pre => Pre,
        .progress => Progress,
        .quote => Quote,
        .script => Script,
        .select => Select,
        .slot => Slot,
        .source => Source,
        .span => Span,
        .style => Style,
        .table => Table,
        .table_caption => TableCaption,
        .table_cell => TableCell,
        .table_col => TableCol,
        .table_row => TableRow,
        .table_section => TableSection,
        .template => Template,
        .textarea => TextArea,
        .time => Time,
        .title => Title,
        .track => Track,
        .ul => UL,
        .unknown => Unknown,
    };
}

pub fn subtype(self: *const HtmlElement, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, HtmlElement);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

pub fn is(self: *HtmlElement, comptime T: type) ?*T {
    switch (self._type) {
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    return null;
}

pub fn asElement(self: *HtmlElement) *Element {
    return Factory.protoOf(self);
}

pub fn asNode(self: *HtmlElement) *Node {
    return self.asElement().asNode();
}

pub fn asEventTarget(self: *HtmlElement) *@import("../EventTarget.zig") {
    return self.asNode().asEventTarget();
}

pub fn getInnerText(self: *HtmlElement, writer: *std.Io.Writer, frame: *Frame) !void {
    const el = self.asElement();
    // An element that isn't being rendered returns its text content
    const owner = el.ownerFrame(frame) orelse return self.asNode().getTextContent(writer);
    const style_manager = &owner._style_manager;
    if (self.asNode().isConnected() == false or style_manager.isHidden(el, .{})) {
        return self.asNode().getTextContent(writer);
    }

    const tag = el.getTag();
    switch (innerTextDisplay(self, tag)) {
        .skip, .replaced => return,
        else => {},
    }

    var state = InnerTextState{
        .writer = writer,
        .scratch = .init(frame.local_arena),
        .style_manager = style_manager,
        .preserve = tag == .pre,
        .transform = style_manager.textTransform(el),
    };
    defer state.scratch.deinit();
    try self.collectInnerText(&state);
}

pub fn setInnerText(self: *HtmlElement, text: []const u8, frame: *Frame) !void {
    const items = try renderedTextFragment(self.asNode().getDocument(frame), text, frame);
    try self.asElement().replaceChildren(.init(items), frame);
}

pub fn setOuterText(self: *HtmlElement, text: []const u8, frame: *Frame) !void {
    const el = self.asElement();
    // outerText is an HTMLElement property. MathML elements currently share
    // the HTML wrapper types, so keep the assignment inert for them.
    if (el._namespace != .html) {
        return;
    }
    const node = el.asNode();
    const parent = node.parentNode() orelse return error.NoModificationAllowed;

    const prev = node.previousSibling();
    const next = node.nextSibling();

    var items: []const Node.NodeOrText = try renderedTextFragment(node.getDocument(frame), text, frame);
    if (items.len == 0) {
        // A fragment with no node still replaces the element with an empty Text
        // node so surrounding text can merge with it.
        items = &.{.{ .text = "" }};
    }
    try el.replaceWith(.init(items), frame);

    // Merge with the immediately neighbouring Text nodes (only those two; the
    // tree is not fully normalised, per spec).
    const first = if (prev) |p| p.nextSibling() else parent.firstChild();
    var last = if (next) |n| n.previousSibling() else parent.lastChild();

    if (prev) |p| {
        if (first) |f| {
            if (mergeTextNodes(p, f, frame) catch false) {
                if (f == last) last = p;
            }
        }
    }

    if (next) |n| {
        if (last) |l| {
            _ = mergeTextNodes(l, n, frame) catch false;
        }
    }
}

pub fn click(self: *HtmlElement, frame: *Frame) !void {
    switch (self._type) {
        .button, .input, .textarea, .select, .option, .optgroup => if (self.asElement().isDisabled()) return,
        else => {},
    }

    const flags = &self.asElement()._flags;
    if (flags.click_in_progress) {
        return;
    }
    flags.click_in_progress = true;
    defer flags.click_in_progress = false;

    const event = (try @import("../event/PointerEvent.zig").init("click", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .pointerId = -1,
    }, frame)).asEvent();

    if (!try frame._event_manager.dispatchCancelable(self.asEventTarget(), event)) {
        // toggle the popover_target
        const explicit: ?*Element = switch (self._type) {
            .button => self.subtype(Button)._popover_target,
            .input => self.subtype(Input)._popover_target,
            else => null,
        };
        try popover.runInvokerActivation(self, explicit, frame);
    }
}

// TODO: Per spec, hidden is a tristate: true | false | "until-found".
// We only support boolean for now; "until-found" would need bridge union support.
pub fn getHidden(self: *HtmlElement) bool {
    return self.asElement().getAttributeInterned("hidden") != null;
}

pub fn setHidden(self: *HtmlElement, hidden: bool, frame: *Frame) !void {
    if (hidden) {
        try self.asElement().setAttributeSafe(comptime .wrap("hidden"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("hidden"), frame);
    }
}

pub fn getInert(self: *HtmlElement) bool {
    return self.asElement().hasAttributeSafe(comptime .wrap("inert"));
}

pub fn setInert(self: *HtmlElement, inert: bool, frame: *Frame) !void {
    if (inert) {
        try self.asElement().setAttributeSafe(comptime .wrap("inert"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("inert"), frame);
    }
}

// The translate IDL attribute reflects the element's translation mode:
// translate="yes"/"" enables it, "no" disables it, anything else (or no
// attribute) inherits from the parent, defaulting to enabled.
pub fn getTranslate(self: *HtmlElement) bool {
    var node: ?*Node = self.asElement().asNode();
    while (node) |n| : (node = n.parentNode()) {
        const el = n.is(Element) orelse continue;
        const value = el.getAttributeSafe(comptime .wrap("translate")) orelse continue;
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "yes")) {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(value, "no")) {
            return false;
        }
    }
    return true;
}

pub fn setTranslate(self: *HtmlElement, translate: bool, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("translate"), .wrap(if (translate) "yes" else "no"), frame);
}

// spellcheck="true"/"" enables checking, "false" disables it, anything else
// (or no attribute) inherits from the parent. The default is UA-defined:
// Chrome checks everything.
pub fn getSpellcheck(self: *HtmlElement) bool {
    var node: ?*Node = self.asElement().asNode();
    while (node) |n| : (node = n.parentNode()) {
        const el = n.is(Element) orelse continue;
        const value = el.getAttributeSafe(comptime .wrap("spellcheck")) orelse continue;
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "true")) {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(value, "false")) {
            return false;
        }
    }
    return true;
}

pub fn setSpellcheck(self: *HtmlElement, spellcheck: bool, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("spellcheck"), .wrap(if (spellcheck) "true" else "false"), frame);
}

// The draggable IDL attribute reflects the enumerated content attribute:
// "true" => true, "false" => false, anything else (or no attribute) is the
// auto state, which defaults to true only for <img> and <a> with an href.
// https://html.spec.whatwg.org/multipage/dnd.html#the-draggable-attribute
pub fn getDraggable(self: *HtmlElement) bool {
    if (self.asElement().getAttributeInterned("draggable")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "true")) {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(value, "false")) {
            return false;
        }
    }
    return switch (self._type) {
        .img => true,
        .anchor => self.asElement().getAttributeInterned("href") != null,
        else => false,
    };
}

pub fn setDraggable(self: *HtmlElement, draggable: bool, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("draggable"), .wrap(if (draggable) "true" else "false"), frame);
}

// accessKeyLabel: the UA-assigned shortcut for a valid (single character)
// accesskey, or the empty string. We report an Alt+ chord like Chromium.
pub fn getAccessKeyLabel(self: *HtmlElement, frame: *Frame) ![]const u8 {
    const value = self.asElement().getAttributeSafe(comptime .wrap("accesskey")) orelse return "";
    const codepoints = std.unicode.utf8CountCodepoints(value) catch return "";
    if (codepoints != 1) {
        return "";
    }
    return frame.local_arena.print("Alt+{s}", .{value});
}

pub fn getPopover(self: *HtmlElement) ?[]const u8 {
    const s = popover.getState(self.asElement()) orelse return null;
    return @tagName(s);
}

pub fn setPopover(self: *HtmlElement, value_: ?[]const u8, frame: *Frame) !void {
    if (value_) |value| {
        // does not validate the value, stores it as-is
        try self.asElement().setAttribute(comptime .wrap("popover"), .wrap(value), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("popover"), frame);
    }
}

pub fn showPopover(self: *HtmlElement, frame: *Frame) !void {
    return popover.show(self.asElement(), frame);
}

pub fn hidePopover(self: *HtmlElement, frame: *Frame) !void {
    return popover.hide(self.asElement(), frame);
}

pub fn togglePopover(self: *HtmlElement, force: ?bool, frame: *Frame) !bool {
    return popover.toggle(self.asElement(), force, frame);
}

pub fn getTabIndex(self: *HtmlElement) i32 {
    if (self.asElement().getAttributeInterned("tabindex")) |attr| {
        if (parseInteger(attr)) |tab_index| {
            return tab_index;
        }
    }

    return switch (self._type) {
        .anchor, .area, .button, .input, .select, .textarea, .iframe => 0,
        else => -1,
    };
}

pub fn setTabIndex(self: *HtmlElement, value: i32, frame: *Frame) !void {
    var buf: [12]u8 = undefined;
    const str = std.mem.print(&buf, "{d}", .{value}) catch unreachable;
    try self.asElement().setAttributeSafe(comptime .wrap("tabindex"), .wrap(str), frame);
}

pub fn getDir(self: *HtmlElement) []const u8 {
    return reflection.enumeratedValue(self.asElement().getDir(), &.{ "ltr", "rtl", "auto" }, "", "").?;
}

pub fn getAccessKey(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("accesskey")) orelse "";
}

pub fn setAccessKey(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("accesskey"), .wrap(value), frame);
}

pub fn getAutofocus(self: *HtmlElement) bool {
    return self.asElement().getAttributeInterned("autofocus") != null;
}

pub fn setAutofocus(self: *HtmlElement, autofocus: bool, frame: *Frame) !void {
    if (autofocus) {
        try self.asElement().setAttributeSafe(comptime .wrap("autofocus"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("autofocus"), frame);
    }
}

pub fn getNonce(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("nonce")) orelse "";
}

pub fn setNonce(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("nonce"), .wrap(value), frame);
}

pub fn getLang(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeInterned("lang") orelse "";
}

pub fn setLang(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("lang"), .wrap(value), frame);
}

pub fn getTitle(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeInterned("title") orelse "";
}

pub fn setTitle(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("title"), .wrap(value), frame);
}

/// Reflects the attribute only; `isContentEditable` gives the state the
/// element ends up with (see Element.isEditable).
pub fn getContentEditable(self: *HtmlElement) []const u8 {
    const raw = self.asElement().getAttributeInterned("contenteditable") orelse return "inherit";
    if (raw.len == 0 or std.ascii.eqlIgnoreCase(raw, "true")) return "true";
    if (std.ascii.eqlIgnoreCase(raw, "false")) return "false";
    if (std.ascii.eqlIgnoreCase(raw, "plaintext-only")) return "plaintext-only";
    return "inherit";
}

pub fn setContentEditable(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    const el = self.asElement();
    if (std.ascii.eqlIgnoreCase(value, "inherit")) {
        return el.removeAttribute(.wrap("contenteditable"), frame);
    }
    inline for (.{ "true", "false", "plaintext-only" }) |keyword| {
        if (std.ascii.eqlIgnoreCase(value, keyword)) {
            return el.setAttributeSafe(.wrap("contenteditable"), .wrap(keyword), frame);
        }
    }
    return error.SyntaxError;
}

pub fn getIsContentEditable(self: *HtmlElement) bool {
    return self.asElement().isEditable();
}

// An event handler content attribute (onclick="...") sets the handler to its
// uncompiled source; removing the attribute (a null value) removes the
// handler. `value` must be the element's stored attribute value: the handler
// keeps it, uncopied.
pub fn eventHandlerAttributeChanged(self: *HtmlElement, name: []const u8, value: ?[]const u8, frame: *Frame) !void {
    if (name.len < 3 or name[0] != 'o' or name[1] != 'n') {
        return;
    }
    const element = self.asElement();
    switch (element.getTag()) {
        // These belong to the Window (see Window.reflectingHandlerAccessor)
        .body, .frameset => if (Window.isWindowReflectingHandler(name)) {
            const owner = element.ownerFrame(frame) orelse return;
            return owner._event_manager.setHandlerSource(owner.window.asEventTarget(), name[2..], value);
        },
        else => {},
    }
    if (global_event_handlers.isEventHandler(name) == false) {
        return;
    }
    return frame._event_manager.setHandlerSource(element.asEventTarget(), name[2..], value);
}

// HTML "rules for parsing integers", for callers that want an i32 (tabindex);
// out-of-range values parse as failure.
pub fn parseInteger(input: []const u8) ?i32 {
    const value = reflection.parseInteger(input) orelse return null;
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) {
        return null;
    }
    return @intCast(value);
}

const InnerTextState = struct {
    writer: *std.Io.Writer,

    scratch: std.Io.Writer.Allocating,

    // The walk never leaves the root's document, so we can capture the
    // style_manager upfront
    style_manager: *StyleManager,

    // number of line breaks we've accumulated for the block. Emitted lazily that
    // leading/trailing breaks aren't written and so that we can emit the max
    // requested, which can change as we render children.
    pending_breaks: u8 = 0,

    // suppresses leading line breaks if nothing has been written yet
    wrote_any: bool = false,

    // A collapsible space is pending from a previous text run, it should only
    // be written if there's more to write
    pre_w: bool = false,

    // Trim leading whitespace of the next text run.
    trim_left: bool = true,

    // preserve whitespace (pre tag, in the future white-space: pre)
    preserve: bool = false,

    // text-transform of the element whose text is being written
    transform: TextTransform = .none,

    fn requireBreaks(self: *InnerTextState, n: u8) void {
        if (n > self.pending_breaks) {
            self.pending_breaks = n;
        }
    }

    fn flushBreaks(self: *InnerTextState) !void {
        if (self.pending_breaks == 0) {
            return;
        }
        if (self.wrote_any) {
            for (0..self.pending_breaks) |_| {
                try self.writer.writeByte('\n');
            }
        }
        self.pending_breaks = 0;
        // A block boundary trims the whitespace on either side of it.
        self.pre_w = false;
        self.trim_left = true;
    }

    // Emit a literal separator (table cell tab / row newline).
    fn writeSeparator(self: *InnerTextState, ch: u8) !void {
        try self.flushBreaks();
        try self.writer.writeByte(ch);
        self.wrote_any = true;
        self.pre_w = false;
        self.trim_left = true;
    }
};

const ChildFilter = enum { none, select, optgroup };

fn collectInnerText(self: *HtmlElement, state: *InnerTextState) std.Io.Writer.Error!void {
    const el = self.asElement();
    const self_tag = el.getTag();

    // special filtering type applied to children based on the tag
    const child_filter: ChildFilter = switch (self_tag) {
        .select => .select,
        .optgroup => .optgroup,
        else => .none,
    };

    // Inside table containers, inter-cell/row whitespace text is not rendered.
    const table_ctx = switch (self_tag) {
        .table, .tbody, .thead, .tfoot, .tr => true,
        else => false,
    };

    // Track whether we've already emitted a cell/row in this parent so we can
    // insert tab/newline separators *between* them.
    var saw_row = false;
    var saw_cell = false;

    // The text of an invisible element isn't included, but we still walk all
    // its children, since they can make themeselves visible again.
    const text_hidden = state.style_manager.hasVisibilityHiddenInherited(el);
    // A closed <details> renders only its summary; its other elements are
    // display:none, and its loose text isn't rendered either.
    const closed_details = if (el.is(Details)) |d| d.isClosed() else false;

    var it = el.asNode().childrenIterator();
    while (it.next()) |child| {
        switch (child._type) {
            .element => {
                const e = child.subtype(Node.Element);
                switch (e._type) {
                    .svg => {},
                    .html => {
                        const tag = e.getTag();
                        switch (child_filter) {
                            .none => {},
                            .select => if (tag != .option and tag != .optgroup) continue,
                            .optgroup => if (tag != .option) continue,
                        }
                        try handleChildElement(e.subtype(HtmlElement), tag, state, &saw_cell, &saw_row);
                    },
                }
            },
            .cdata => {
                const c = child.subtype(Node.CData);
                switch (c._type) {
                    .text => {
                        if (child_filter != .none or text_hidden or closed_details) {
                            // Text directly inside <select>/<optgroup> or a closed
                            // <details> is skipped, as is visibility:hidden text
                            continue;
                        }
                        if (table_ctx and isAllAsciiWhitespace(c.getData().str())) {
                            continue;
                        }
                        try writeText(c, state);
                    },
                    .comment, .cdata_section, .processing_instruction => {},
                }
            },
            else => {},
        }
    }
}

const Display = enum { skip, replaced, @"inline", block, block_p, transparent, table_cell, table_row };

fn handleChildElement(
    he: *HtmlElement,
    tag: Element.Tag,
    state: *InnerTextState,
    saw_cell: *bool,
    saw_row: *bool,
) !void {
    // doesn't use StyleManger's isHidden, because we don't care if the element
    // is hidden through its parent. If you can el.innerText on an element, the
    // visibility of el.parent doesn't matter. So we only care about visibility
    // on the element itself and then on each child. This is much simpler too.
    const el = he.asElement();
    if (state.style_manager.hasDisplayNone(el)) {
        return;
    }

    if (he._type == .br) {
        try state.flushBreaks();
        try state.writer.writeByte('\n');
        state.wrote_any = true;
        state.pre_w = false;
        state.trim_left = true;
        return;
    }

    const display = innerTextDisplay(he, tag);
    switch (display) {
        .skip, .replaced => return,
        else => {},
    }

    // text-transform inherits, so a child's own value covers its subtree only.
    const parent_transform = state.transform;
    defer state.transform = parent_transform;
    const own_transform = state.style_manager.ownTextTransform(el);
    if (own_transform != .inherit) {
        state.transform = own_transform;
    }

    switch (display) {
        .skip, .replaced => unreachable,
        .@"inline", .transparent => try he.collectInnerText(state),
        .block => {
            state.requireBreaks(1);
            try enterBlock(he, tag, state);
            state.requireBreaks(1);
        },
        .block_p => {
            state.requireBreaks(2);
            try he.collectInnerText(state);
            state.requireBreaks(2);
        },
        .table_cell => {
            if (saw_cell.*) {
                try state.writeSeparator('\t');
            }
            saw_cell.* = true;
            try he.collectInnerText(state);
        },
        .table_row => {
            if (saw_row.*) {
                try state.writeSeparator('\n');
            }
            saw_row.* = true;
            try he.collectInnerText(state);
        },
    }
}

// Recurse into a block, enabling whitespace preservation for <pre> subtrees.
fn enterBlock(he: *HtmlElement, tag: Element.Tag, state: *InnerTextState) std.Io.Writer.Error!void {
    if (tag == .pre and !state.preserve) {
        state.preserve = true;
        defer state.preserve = false;
        return he.collectInnerText(state);
    }
    return he.collectInnerText(state);
}

fn innerTextDisplay(he: *HtmlElement, tag: Element.Tag) Display {
    return switch (he._type) {
        .br => .@"inline", // handled before this point
        .p => .block_p,
        .table_cell => .table_cell,
        .table_row => .table_row,
        .table_caption => .block,
        // Row groups / column groups are transparent: no break of their own.
        .table_section => .transparent,
        .table_col => .skip,
        .option, .optgroup => .block,
        // Replaced / embedded content whose subtree is not part of innerText.
        .img, .canvas, .iframe, .embed, .object, .media, .input, .textarea => .replaced,
        // Never-rendered elements (UA display:none / not parsed as content).
        .script, .style, .template, .head, .base, .link, .meta, .title, .source, .track, .param, .area, .datalist => .skip,
        else => if (tag.isHiddenByUaStylesheet())
            .skip
        else if (isInnerTextBlockTag(tag))
            .block
        else
            .@"inline",
    };
}

fn isInnerTextBlockTag(tag: Element.Tag) bool {
    if (tag.isBlock()) {
        return true;
    }
    return switch (tag) {
        .summary, .details, .dialog, .menu, .dd, .dt, .form, .li => true,
        else => false,
    };
}

fn isAllAsciiWhitespace(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isWhitespace(c)) {
            return false;
        }
    }
    return true;
}

fn writeText(c: *Node.CData, state: *InnerTextState) !void {
    // `capitalize` is recognized (getComputedStyle reports it) but not
    // applied: it needs word-boundary tracking across text runs.
    if (state.transform != .uppercase and state.transform != .lowercase) {
        return writeRenderedText(c, state);
    }

    // Every case mapping we apply keeps the UTF-8 length, so the text is
    // rendered to a scratch buffer and mapped in place.
    const scratch = &state.scratch;
    scratch.clearRetainingCapacity();
    const out = state.writer;
    state.writer = &scratch.writer;
    const rendered = writeRenderedText(c, state);
    state.writer = out;
    try rendered;

    const text = scratch.written();
    applyTextTransform(text, state.transform);
    try out.writeAll(text);
}

fn writeRenderedText(c: *Node.CData, state: *InnerTextState) !void {
    const writer = state.writer;

    const s = c.getData().str();
    if (state.preserve) {
        if (s.len == 0) {
            return;
        }
        try state.flushBreaks();
        // Preserve whitespace verbatim, normalising CR / CRLF to LF.
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const ch = s[i];
            if (ch == '\r') {
                try writer.writeByte('\n');
                if (i + 1 < s.len and s[i + 1] == '\n') {
                    i += 1;
                }
            } else {
                try writer.writeByte(ch);
            }
        }
        state.wrote_any = true;
        state.pre_w = false;
        state.trim_left = false;
        return;
    }

    if (isAllAsciiWhitespace(s)) {
        state.pre_w = state.wrote_any and state.trim_left == false;
        return;
    }

    try state.flushBreaks();
    if (state.pre_w) {
        try writer.writeByte(' ');
    }
    state.pre_w = try c.render(writer, .{ .trim_left = state.trim_left });
    state.wrote_any = true;
    state.trim_left = state.pre_w;
}

// Maps `text` in place for `uppercase` / `lowercase`.
fn applyTextTransform(text: []u8, transform: TextTransform) void {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + len > text.len) {
            break;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            continue;
        };
        const mapped = switch (transform) {
            .uppercase => upperCodepoint(cp),
            .lowercase => lowerCodepoint(cp),
            else => cp,
        };
        if (mapped != cp) {
            _ = std.unicode.utf8Encode(mapped, text[i..][0..len]) catch unreachable;
        }
        i += len;
    }
}

// Simple case mappings that keep the UTF-8 length: Latin-1, Latin
// Extended-A, basic Greek and Cyrillic. Other scripts pass through, as do
// mappings that change the length (ß -> SS, ı -> I, İ -> i̇).
fn upperCodepoint(cp: u21) u21 {
    return switch (cp) {
        'a'...'z' => cp - 0x20,
        0xE0...0xF6, 0xF8...0xFE => cp - 0x20,
        0xFF => 0x178,
        0x101...0x12F, 0x133...0x137, 0x14B...0x177 => if (cp % 2 == 1) cp - 1 else cp,
        0x13A...0x148, 0x17A...0x17E => if (cp % 2 == 0) cp - 1 else cp,
        0x3B1...0x3C1, 0x3C3...0x3C9 => cp - 0x20,
        0x3C2 => 0x3A3, // final sigma
        0x430...0x44F => cp - 0x20,
        0x450...0x45F => cp - 0x50,
        else => cp,
    };
}

fn lowerCodepoint(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 0x20,
        0xC0...0xD6, 0xD8...0xDE => cp + 0x20,
        0x178 => 0xFF,
        0x100...0x12E, 0x132...0x136, 0x14A...0x176 => if (cp % 2 == 0) cp + 1 else cp,
        0x139...0x147, 0x179...0x17D => if (cp % 2 == 1) cp + 1 else cp,
        0x391...0x3A1, 0x3A3...0x3A9 => cp + 0x20,
        0x410...0x42F => cp + 0x20,
        0x400...0x40F => cp + 0x50,
        else => cp,
    };
}

fn mergeTextNodes(left_node: *Node, right_node: *Node, frame: *Frame) !bool {
    const left = left_node.is(Node.CData) orelse return false;
    const right = right_node.is(Node.CData) orelse return false;
    if (left._type != .text or right._type != .text) return false;

    // both nodes are Text nodes

    const merged = try std.mem.concat(frame.local_arena, u8, &.{ left.getData().str(), right.getData().str() });
    // set the left node to the merged value
    try left.setData(merged, frame);

    if (right_node.parentNode()) |p| {
        // remove right node
        frame.removeNode(p, right_node, .{ .reconnect_to = null });
    }
    return true;
}

fn renderedTextFragment(document: *const Node.Document, value: []const u8, frame: *Frame) ![]Node.NodeOrText {
    const arena = frame.local_arena;
    var nodes: std.ArrayList(Node.NodeOrText) = .empty;

    var rest = value;
    while (true) {
        const text_end = std.mem.findAny(u8, rest, "\r\n") orelse rest.len;
        if (text_end > 0) {
            try nodes.append(arena, .{ .text = rest[0..text_end] });
        }
        rest = rest[text_end..];
        if (rest.len == 0) {
            return nodes.items;
        }

        // Each line break becomes one <br>; a CR/LF pair counts as a single
        // break (so "\r\n" is one <br> but "\n\n" is two).
        const break_len: usize = if (rest[0] == '\r' and rest.len > 1 and rest[1] == '\n') 2 else 1;

        try nodes.append(arena, .{ .node = try Frame.node_factory.createElementNS(document, .html, "br", null) });
        rest = rest[break_len..];
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HtmlElement);

    pub const Meta = struct {
        pub const name = "HTMLElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(HtmlElement);
    pub const inputMode = reflect.enumerated("inputmode", &.{ "none", "text", "tel", "url", "email", "numeric", "decimal", "search" }, .{});
    pub const enterKeyHint = reflect.enumerated("enterkeyhint", &.{ "enter", "done", "go", "next", "previous", "search", "send" }, .{});

    pub const constructor = bridge.constructor(HtmlElement.construct, .{ .new_target = true });
    pub const upgrade_constructor = bridge.constructor(HtmlElement.upgradeConstruct, .{});

    pub const dataset = bridge.accessor(_dataset, null, .{});
    fn _dataset(self: *HtmlElement, frame: *Frame) !*DOMStringMap {
        return self.asElement().getDataset(frame);
    }

    pub const innerText = bridge.accessor(_innerText, _setInnerText, .{ .ce_reactions = true });
    fn _innerText(self: *HtmlElement, frame: *Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getInnerText(&buf.writer, frame);
        return buf.written();
    }
    fn _setInnerText(self: *HtmlElement, value: js.Value, frame: *Frame) !void {
        // `[LegacyNullToEmptyString]`: a JS null becomes "", not "null".
        return self.setInnerText(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }
    pub const outerText = bridge.accessor(_innerText, _setOuterText, .{ .ce_reactions = true });
    fn _setOuterText(self: *HtmlElement, value: js.Value, frame: *Frame) !void {
        return self.setOuterText(if (value.isNull()) "" else try value.toZig([]const u8), frame);
    }
    pub const click = bridge.function(HtmlElement.click, .{});
    pub const attachInternals = bridge.function(HtmlElement.attachInternals, .{});

    pub const accessKey = bridge.accessor(HtmlElement.getAccessKey, HtmlElement.setAccessKey, .{ .ce_reactions = true });
    pub const autofocus = bridge.accessor(HtmlElement.getAutofocus, HtmlElement.setAutofocus, .{ .ce_reactions = true });
    pub const dir = reflect.enumerated("dir", &.{ "ltr", "rtl", "auto" }, .{});
    pub const draggable = bridge.accessor(HtmlElement.getDraggable, HtmlElement.setDraggable, .{ .ce_reactions = true });
    pub const hidden = bridge.accessor(HtmlElement.getHidden, HtmlElement.setHidden, .{ .ce_reactions = true });
    pub const inert = bridge.accessor(HtmlElement.getInert, HtmlElement.setInert, .{ .ce_reactions = true });
    pub const translate = bridge.accessor(HtmlElement.getTranslate, HtmlElement.setTranslate, .{ .ce_reactions = true });
    pub const spellcheck = bridge.accessor(HtmlElement.getSpellcheck, HtmlElement.setSpellcheck, .{ .ce_reactions = true });
    pub const accessKeyLabel = bridge.accessor(HtmlElement.getAccessKeyLabel, null, .{});
    pub const popover = bridge.accessor(HtmlElement.getPopover, HtmlElement.setPopover, .{ .ce_reactions = true });
    pub const showPopover = bridge.function(HtmlElement.showPopover, .{});
    pub const hidePopover = bridge.function(HtmlElement.hidePopover, .{});
    pub const togglePopover = bridge.function(HtmlElement.togglePopover, .{});
    pub const contentEditable = bridge.accessor(HtmlElement.getContentEditable, HtmlElement.setContentEditable, .{ .ce_reactions = true });
    pub const isContentEditable = bridge.accessor(HtmlElement.getIsContentEditable, null, .{});
    pub const lang = bridge.accessor(HtmlElement.getLang, HtmlElement.setLang, .{ .ce_reactions = true });
    pub const nonce = bridge.accessor(HtmlElement.getNonce, HtmlElement.setNonce, .{ .ce_reactions = true });
    pub const tabIndex = bridge.accessor(HtmlElement.getTabIndex, HtmlElement.setTabIndex, .{ .ce_reactions = true });
    pub const title = bridge.accessor(HtmlElement.getTitle, HtmlElement.setTitle, .{ .ce_reactions = true });

    pub const onabort = EventTarget.handlerAccessor(HtmlElement, "abort");
    pub const onanimationcancel = EventTarget.handlerAccessor(HtmlElement, "animationcancel");
    pub const onanimationend = EventTarget.handlerAccessor(HtmlElement, "animationend");
    pub const onanimationiteration = EventTarget.handlerAccessor(HtmlElement, "animationiteration");
    pub const onanimationstart = EventTarget.handlerAccessor(HtmlElement, "animationstart");
    pub const onauxclick = EventTarget.handlerAccessor(HtmlElement, "auxclick");
    pub const onbeforeinput = EventTarget.handlerAccessor(HtmlElement, "beforeinput");
    pub const onbeforematch = EventTarget.handlerAccessor(HtmlElement, "beforematch");
    pub const onbeforetoggle = EventTarget.handlerAccessor(HtmlElement, "beforetoggle");
    pub const onblur = EventTarget.handlerAccessor(HtmlElement, "blur");
    pub const oncancel = EventTarget.handlerAccessor(HtmlElement, "cancel");
    pub const oncanplay = EventTarget.handlerAccessor(HtmlElement, "canplay");
    pub const oncanplaythrough = EventTarget.handlerAccessor(HtmlElement, "canplaythrough");
    pub const onchange = EventTarget.handlerAccessor(HtmlElement, "change");
    pub const onclick = EventTarget.handlerAccessor(HtmlElement, "click");
    pub const onclose = EventTarget.handlerAccessor(HtmlElement, "close");
    pub const oncommand = EventTarget.handlerAccessor(HtmlElement, "command");
    pub const oncontentvisibilityautostatechange = EventTarget.handlerAccessor(HtmlElement, "contentvisibilityautostatechange");
    pub const oncontextlost = EventTarget.handlerAccessor(HtmlElement, "contextlost");
    pub const oncontextmenu = EventTarget.handlerAccessor(HtmlElement, "contextmenu");
    pub const oncontextrestored = EventTarget.handlerAccessor(HtmlElement, "contextrestored");
    pub const oncopy = EventTarget.handlerAccessor(HtmlElement, "copy");
    pub const oncuechange = EventTarget.handlerAccessor(HtmlElement, "cuechange");
    pub const oncut = EventTarget.handlerAccessor(HtmlElement, "cut");
    pub const ondblclick = EventTarget.handlerAccessor(HtmlElement, "dblclick");
    pub const ondrag = EventTarget.handlerAccessor(HtmlElement, "drag");
    pub const ondragend = EventTarget.handlerAccessor(HtmlElement, "dragend");
    pub const ondragenter = EventTarget.handlerAccessor(HtmlElement, "dragenter");
    pub const ondragleave = EventTarget.handlerAccessor(HtmlElement, "dragleave");
    pub const ondragover = EventTarget.handlerAccessor(HtmlElement, "dragover");
    pub const ondragstart = EventTarget.handlerAccessor(HtmlElement, "dragstart");
    pub const ondrop = EventTarget.handlerAccessor(HtmlElement, "drop");
    pub const ondurationchange = EventTarget.handlerAccessor(HtmlElement, "durationchange");
    pub const onemptied = EventTarget.handlerAccessor(HtmlElement, "emptied");
    pub const onended = EventTarget.handlerAccessor(HtmlElement, "ended");
    pub const onerror = EventTarget.handlerAccessor(HtmlElement, "error");
    pub const onfocus = EventTarget.handlerAccessor(HtmlElement, "focus");
    pub const onformdata = EventTarget.handlerAccessor(HtmlElement, "formdata");
    pub const onfullscreenchange = EventTarget.handlerAccessor(HtmlElement, "fullscreenchange");
    pub const onfullscreenerror = EventTarget.handlerAccessor(HtmlElement, "fullscreenerror");
    pub const ongotpointercapture = EventTarget.handlerAccessor(HtmlElement, "gotpointercapture");
    pub const oninput = EventTarget.handlerAccessor(HtmlElement, "input");
    pub const oninvalid = EventTarget.handlerAccessor(HtmlElement, "invalid");
    pub const onkeydown = EventTarget.handlerAccessor(HtmlElement, "keydown");
    pub const onkeypress = EventTarget.handlerAccessor(HtmlElement, "keypress");
    pub const onkeyup = EventTarget.handlerAccessor(HtmlElement, "keyup");
    pub const onload = EventTarget.handlerAccessor(HtmlElement, "load");
    pub const onloadeddata = EventTarget.handlerAccessor(HtmlElement, "loadeddata");
    pub const onloadedmetadata = EventTarget.handlerAccessor(HtmlElement, "loadedmetadata");
    pub const onloadstart = EventTarget.handlerAccessor(HtmlElement, "loadstart");
    pub const onlostpointercapture = EventTarget.handlerAccessor(HtmlElement, "lostpointercapture");
    pub const onmousedown = EventTarget.handlerAccessor(HtmlElement, "mousedown");
    pub const onmouseenter = EventTarget.handlerAccessor(HtmlElement, "mouseenter");
    pub const onmouseleave = EventTarget.handlerAccessor(HtmlElement, "mouseleave");
    pub const onmousemove = EventTarget.handlerAccessor(HtmlElement, "mousemove");
    pub const onmouseout = EventTarget.handlerAccessor(HtmlElement, "mouseout");
    pub const onmouseover = EventTarget.handlerAccessor(HtmlElement, "mouseover");
    pub const onmouseup = EventTarget.handlerAccessor(HtmlElement, "mouseup");
    pub const onpaste = EventTarget.handlerAccessor(HtmlElement, "paste");
    pub const onpause = EventTarget.handlerAccessor(HtmlElement, "pause");
    pub const onplay = EventTarget.handlerAccessor(HtmlElement, "play");
    pub const onplaying = EventTarget.handlerAccessor(HtmlElement, "playing");
    pub const onpointercancel = EventTarget.handlerAccessor(HtmlElement, "pointercancel");
    pub const onpointerdown = EventTarget.handlerAccessor(HtmlElement, "pointerdown");
    pub const onpointerenter = EventTarget.handlerAccessor(HtmlElement, "pointerenter");
    pub const onpointerleave = EventTarget.handlerAccessor(HtmlElement, "pointerleave");
    pub const onpointermove = EventTarget.handlerAccessor(HtmlElement, "pointermove");
    pub const onpointerout = EventTarget.handlerAccessor(HtmlElement, "pointerout");
    pub const onpointerover = EventTarget.handlerAccessor(HtmlElement, "pointerover");
    pub const onpointerrawupdate = EventTarget.handlerAccessor(HtmlElement, "pointerrawupdate");
    pub const onpointerup = EventTarget.handlerAccessor(HtmlElement, "pointerup");
    pub const onprogress = EventTarget.handlerAccessor(HtmlElement, "progress");
    pub const onratechange = EventTarget.handlerAccessor(HtmlElement, "ratechange");
    pub const onreset = EventTarget.handlerAccessor(HtmlElement, "reset");
    pub const onresize = EventTarget.handlerAccessor(HtmlElement, "resize");
    pub const onscroll = EventTarget.handlerAccessor(HtmlElement, "scroll");
    pub const onscrollend = EventTarget.handlerAccessor(HtmlElement, "scrollend");
    pub const onsecuritypolicyviolation = EventTarget.handlerAccessor(HtmlElement, "securitypolicyviolation");
    pub const onseeked = EventTarget.handlerAccessor(HtmlElement, "seeked");
    pub const onseeking = EventTarget.handlerAccessor(HtmlElement, "seeking");
    pub const onselect = EventTarget.handlerAccessor(HtmlElement, "select");
    pub const onselectionchange = EventTarget.handlerAccessor(HtmlElement, "selectionchange");
    pub const onselectstart = EventTarget.handlerAccessor(HtmlElement, "selectstart");
    pub const onslotchange = EventTarget.handlerAccessor(HtmlElement, "slotchange");
    pub const onstalled = EventTarget.handlerAccessor(HtmlElement, "stalled");
    pub const onsubmit = EventTarget.handlerAccessor(HtmlElement, "submit");
    pub const onsuspend = EventTarget.handlerAccessor(HtmlElement, "suspend");
    pub const ontimeupdate = EventTarget.handlerAccessor(HtmlElement, "timeupdate");
    pub const ontoggle = EventTarget.handlerAccessor(HtmlElement, "toggle");
    pub const ontransitioncancel = EventTarget.handlerAccessor(HtmlElement, "transitioncancel");
    pub const ontransitionend = EventTarget.handlerAccessor(HtmlElement, "transitionend");
    pub const ontransitionrun = EventTarget.handlerAccessor(HtmlElement, "transitionrun");
    pub const ontransitionstart = EventTarget.handlerAccessor(HtmlElement, "transitionstart");
    pub const onvolumechange = EventTarget.handlerAccessor(HtmlElement, "volumechange");
    pub const onwaiting = EventTarget.handlerAccessor(HtmlElement, "waiting");
    pub const onwheel = EventTarget.handlerAccessor(HtmlElement, "wheel");
};

pub const Build = struct {
    // Calls `func_name` with `args` on the most specific type where it is
    // implement. This could be on the HtmlElement itself.
    pub fn call(self: *const HtmlElement, comptime func_name: []const u8, args: anytype) !bool {
        switch (self._type) {
            inline else => |tag| {
                const S = Subtype(tag);
                // The inner type implements this function. Call it and we're done.
                if (@hasDecl(S, "Build")) {
                    if (@hasDecl(S.Build, func_name)) {
                        try @call(.auto, @field(S.Build, func_name), args);
                        return true;
                    }
                }
            },
        }

        if (@hasDecl(HtmlElement.Build, func_name)) {
            // Our last resort - the node implements this function.
            try @call(.auto, @field(HtmlElement.Build, func_name), args);
            return true;
        }

        // inform our caller (the Element) that we didn't find anything that implemented
        // func_name and it should keep searching for a match.
        return false;
    }
};

const testing = @import("../../../testing.zig");
test "WebApi: HTML.event_listeners" {
    try testing.htmlRunner("element/html/event_listeners.html", .{});
}
test "WebApi: HTMLElement.props" {
    try testing.htmlRunner("element/html/htmlelement-props.html", .{});
}
test "WebApi: HTMLElement.contenteditable" {
    try testing.htmlRunner("element/html/contenteditable.html", .{});
}
