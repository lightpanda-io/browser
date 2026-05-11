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
const reflect = @import("../../reflect.zig");

const global_event_handlers = @import("../global_event_handlers.zig");
const GlobalEventHandler = global_event_handlers.Handler;

const Frame = @import("../../Frame.zig");
const Node = @import("../Node.zig");
const Element = @import("../Element.zig");

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

const log = lp.log;
const IS_DEBUG = @import("builtin").mode == .Debug;

const HtmlElement = @This();

_type: Type,
_proto: *Element,

// Special constructor for custom elements.
// Two paths:
//  - Upgrade path: customElements.define / createElement / upgrade set
//    `_upgrading_element` before calling newInstance, and we just return it.
//  - Direct path: `new MyElement()` from user code. `new.target` tells us
//    which custom element class was invoked; look it up in the registry.
pub fn construct(new_target: js.Function, frame: *Frame) !*Element {
    if (frame._upgrading_element) |node| {
        return node.is(Element) orelse return error.IllegalConstructor;
    }
    return frame.constructCustomElement(new_target);
}

pub const Type = union(enum) {
    anchor: *Anchor,
    area: *Area,
    base: *Base,
    body: *Body,
    br: *BR,
    button: *Button,
    canvas: *Canvas,
    custom: *Custom,
    data: *Data,
    datalist: *DataList,
    details: *Details,
    dialog: *Dialog,
    directory: *Directory,
    div: *Div,
    dl: *DList,
    embed: *Embed,
    fieldset: *FieldSet,
    font: *Font,
    form: *Form,
    frameset: *FrameSet,
    generic: *Generic,
    heading: *Heading,
    head: *Head,
    html: *Html,
    hr: *HR,
    img: *Image,
    iframe: *IFrame,
    input: *Input,
    label: *Label,
    legend: *Legend,
    li: *LI,
    link: *Link,
    map: *Map,
    media: *Media,
    meta: *Meta,
    meter: *Meter,
    mod: *Mod,
    object: *Object,
    ol: *OL,
    optgroup: *OptGroup,
    option: *Option,
    output: *Output,
    p: *Paragraph,
    picture: *Picture,
    param: *Param,
    pre: *Pre,
    progress: *Progress,
    quote: *Quote,
    script: *Script,
    select: *Select,
    slot: *Slot,
    source: *Source,
    span: *Span,
    style: *Style,
    table: *Table,
    table_caption: *TableCaption,
    table_cell: *TableCell,
    table_col: *TableCol,
    table_row: *TableRow,
    table_section: *TableSection,
    template: *Template,
    textarea: *TextArea,
    time: *Time,
    title: *Title,
    track: *Track,
    ul: *UL,
    unknown: *Unknown,
};

pub fn is(self: *HtmlElement, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (@field(Type, f.name) == self._type) {
            if (f.type == T) {
                return &@field(self._type, f.name);
            }
            if (f.type == *T) {
                return @field(self._type, f.name);
            }
        }
    }
    return null;
}

pub fn asElement(self: *HtmlElement) *Element {
    return self._proto;
}

pub fn asNode(self: *HtmlElement) *Node {
    return self._proto._proto;
}

pub fn asEventTarget(self: *HtmlElement) *@import("../EventTarget.zig") {
    return self._proto._proto._proto;
}

// innerText represents the **rendered** text content of a node and its
// descendants.
pub fn getInnerText(self: *HtmlElement, writer: *std.Io.Writer) !void {
    var state = innerTextState{};
    return try self._getInnerText(writer, &state);
}

const innerTextState = struct {
    pre_w: bool = false,
    trim_left: bool = true,
};

fn _getInnerText(self: *HtmlElement, writer: *std.Io.Writer, state: *innerTextState) !void {
    var it = self.asElement().asNode().childrenIterator();
    while (it.next()) |child| {
        switch (child._type) {
            .element => |e| switch (e._type) {
                .html => |he| switch (he._type) {
                    .br => {
                        try writer.writeByte('\n');
                        state.pre_w = false; // prevent a next pre space.
                        state.trim_left = true;
                    },
                    .script, .style, .template => {
                        state.pre_w = false; // prevent a next pre space.
                        state.trim_left = true;
                    },
                    else => try he._getInnerText(writer, state), // TODO check if elt is hidden.
                },
                .svg => {},
            },
            .cdata => |c| switch (c._type) {
                .comment => {
                    state.pre_w = false; // prevent a next pre space.
                    state.trim_left = true;
                },
                .text => {
                    if (state.pre_w) try writer.writeByte(' ');
                    state.pre_w = try c.render(writer, .{ .trim_left = state.trim_left });
                    // if we had a pre space, trim left next one.
                    state.trim_left = state.pre_w;
                },
                // CDATA sections should not be used within HTML. They are
                // considered comments and are not displayed.
                .cdata_section => {},
                // Processing instructions are not displayed in innerText
                .processing_instruction => {},
            },
            .document => {},
            .document_type => {},
            .document_fragment => {},
            .attribute => |attr| try writer.writeAll(attr._value.str()),
        }
    }
}

pub fn setInnerText(self: *HtmlElement, text: []const u8, frame: *Frame) !void {
    const parent = self.asElement().asNode();

    // Remove all existing children
    frame.domChanged();
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        frame.removeNode(parent, child, .{ .will_be_reconnected = false });
    }

    // Fast path: skip if text is empty
    if (text.len == 0) {
        return;
    }

    // Create and append text node
    const text_node = try frame.createTextNode(text);
    try frame.appendNode(parent, text_node, .{ .child_already_connected = false });
}

pub fn insertAdjacentHTML(
    self: *HtmlElement,
    position: []const u8,
    html: []const u8,
    frame: *Frame,
) !void {
    const DocumentFragment = @import("../DocumentFragment.zig");
    const fragment = (try DocumentFragment.init(frame)).asNode();
    try frame.parseHtmlAsChildren(fragment, html);

    const target_node, const prev_node = try self.asElement().asNode().findAdjacentNodes(position);

    var iter = fragment.childrenIterator();
    while (iter.next()) |child_node| {
        _ = try target_node.insertBefore(child_node, prev_node, frame);
    }
}

pub fn click(self: *HtmlElement, frame: *Frame) !void {
    switch (self._type) {
        inline .button, .input, .textarea, .select => |i| {
            if (i.getDisabled()) {
                return;
            }
        },
        else => {},
    }

    const event = (try @import("../event/MouseEvent.zig").init("click", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = 0,
        .clientY = 0,
    }, frame)).asEvent();
    try frame._event_manager.dispatch(self.asEventTarget(), event);
}

// TODO: Per spec, hidden is a tristate: true | false | "until-found".
// We only support boolean for now; "until-found" would need bridge union support.
pub fn getHidden(self: *HtmlElement) bool {
    return self.asElement().getAttributeSafe(comptime .wrap("hidden")) != null;
}

pub fn setHidden(self: *HtmlElement, hidden: bool, frame: *Frame) !void {
    if (hidden) {
        try self.asElement().setAttributeSafe(comptime .wrap("hidden"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("hidden"), frame);
    }
}

pub fn getTabIndex(self: *HtmlElement) i32 {
    const attr = self.asElement().getAttributeSafe(comptime .wrap("tabindex")) orelse {
        // Per spec, interactive/focusable elements default to 0 when tabindex is absent
        return switch (self._type) {
            .anchor, .area, .button, .input, .select, .textarea, .iframe => 0,
            else => -1,
        };
    };
    return std.fmt.parseInt(i32, attr, 10) catch -1;
}

pub fn setTabIndex(self: *HtmlElement, value: i32, frame: *Frame) !void {
    var buf: [12]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try self.asElement().setAttributeSafe(comptime .wrap("tabindex"), .wrap(str), frame);
}

pub fn getDir(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("dir")) orelse "";
}

pub fn setDir(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("dir"), .wrap(value), frame);
}

pub fn getLang(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("lang")) orelse "";
}

pub fn setLang(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("lang"), .wrap(value), frame);
}

pub fn getTitle(self: *HtmlElement) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("title")) orelse "";
}

pub fn setTitle(self: *HtmlElement, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("title"), .wrap(value), frame);
}

// HTML §7.7.5.2 specifies the IDL attribute as true iff the element's effective
// content editable state is "true" or "plaintext-only". Lightpanda has no
// caret/keyboard editing pipeline, so a true answer cannot be honored
// end-to-end — downstream CDP tools (notably Puppeteer's dispatchKeyEvent
// path) would route into an input pipeline that silently no-ops. Always
// return false, and log .not_implemented when the spec would have said true
// so usage surfaces in telemetry rather than silently depending on an
// unsupported value. Spec walk per HTML §7.7.5.2 still applies — the nearest
// ancestor with `contenteditable` wins; "false" disables. See PR #2310 for
// the routing-vs-fail-loud discussion.
//
// "contenteditable" is 15 bytes — past the comptime SSO limit — so the
// String wrap runs at runtime, mirroring the pattern in interactive.zig.
pub fn getIsContentEditable(self: *HtmlElement) bool {
    var current: ?*Element = self.asElement();
    while (current) |el| : (current = el.parentElement()) {
        const raw = el.getAttributeSafe(.wrap("contenteditable")) orelse continue;
        if (!std.ascii.eqlIgnoreCase(raw, "false")) {
            log.info(.not_implemented, "IsContentEditable", .{});
        }
        break;
    }
    return false;
}

pub fn getAttributeFunction(
    self: *HtmlElement,
    listener_type: GlobalEventHandler,
    frame: *Frame,
) !?js.Function.Global {
    const element = self.asElement();
    if (frame._event_target_attr_listeners.get(.{ .target = element.asEventTarget(), .handler = listener_type })) |cached| {
        return cached;
    }

    const attr = element.getAttributeSafe(.wrap(@tagName(listener_type))) orelse return null;
    const function = frame.js.stringToPersistedFunction(attr, &.{"event"}, &.{}) catch |err| {
        // Not a valid expression; log this to find out if its something we should be supporting.
        log.warn(.js, "Html.getAttributeFunction", .{
            .expression = attr,
            .err = err,
        });
        return null;
    };

    try self.setAttributeListener(listener_type, function, frame);
    return function;
}

pub fn hasAttributeFunction(self: *HtmlElement, listener_type: GlobalEventHandler, frame: *const Frame) bool {
    return frame._event_target_attr_listeners.contains(.{ .target = self.asEventTarget(), .handler = listener_type });
}

fn setAttributeListener(
    self: *Element.Html,
    listener_type: GlobalEventHandler,
    listener_callback: ?js.Function.Global,
    frame: *Frame,
) !void {
    if (comptime IS_DEBUG) {
        log.debug(.event, "Html.setAttributeListener", .{
            .type = std.meta.activeTag(self._type),
            .listener_type = listener_type,
        });
    }

    if (listener_callback) |cb| {
        try frame._event_target_attr_listeners.put(frame.arena, .{
            .target = self.asEventTarget(),
            .handler = listener_type,
        }, cb);
        return;
    }

    // The listener is null, remove existing listener.
    _ = frame._event_target_attr_listeners.remove(.{
        .target = self.asEventTarget(),
        .handler = listener_type,
    });
}

pub fn setOnAbort(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onabort, callback, frame);
}

pub fn getOnAbort(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onabort, frame);
}

pub fn setOnAnimationCancel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onanimationcancel, callback, frame);
}

pub fn getOnAnimationCancel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onanimationcancel, frame);
}

pub fn setOnAnimationEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onanimationend, callback, frame);
}

pub fn getOnAnimationEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onanimationend, frame);
}

pub fn setOnAnimationIteration(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onanimationiteration, callback, frame);
}

pub fn getOnAnimationIteration(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onanimationiteration, frame);
}

pub fn setOnAnimationStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onanimationstart, callback, frame);
}

pub fn getOnAnimationStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onanimationstart, frame);
}

pub fn setOnAuxClick(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onauxclick, callback, frame);
}

pub fn getOnAuxClick(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onauxclick, frame);
}

pub fn setOnBeforeInput(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onbeforeinput, callback, frame);
}

pub fn getOnBeforeInput(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onbeforeinput, frame);
}

pub fn setOnBeforeMatch(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onbeforematch, callback, frame);
}

pub fn getOnBeforeMatch(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onbeforematch, frame);
}

pub fn setOnBeforeToggle(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onbeforetoggle, callback, frame);
}

pub fn getOnBeforeToggle(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onbeforetoggle, frame);
}

pub fn setOnBlur(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onblur, callback, frame);
}

pub fn getOnBlur(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onblur, frame);
}

pub fn setOnCancel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncancel, callback, frame);
}

pub fn getOnCancel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncancel, frame);
}

pub fn setOnCanPlay(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncanplay, callback, frame);
}

pub fn getOnCanPlay(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncanplay, frame);
}

pub fn setOnCanPlayThrough(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncanplaythrough, callback, frame);
}

pub fn getOnCanPlayThrough(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncanplaythrough, frame);
}

pub fn setOnChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onchange, callback, frame);
}

pub fn getOnChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onchange, frame);
}

pub fn setOnClick(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onclick, callback, frame);
}

pub fn getOnClick(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onclick, frame);
}

pub fn setOnClose(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onclose, callback, frame);
}

pub fn getOnClose(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onclose, frame);
}

pub fn setOnCommand(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncommand, callback, frame);
}

pub fn getOnCommand(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncommand, frame);
}

pub fn setOnContentVisibilityAutoStateChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncontentvisibilityautostatechange, callback, frame);
}

pub fn getOnContentVisibilityAutoStateChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncontentvisibilityautostatechange, frame);
}

pub fn setOnContextLost(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncontextlost, callback, frame);
}

pub fn getOnContextLost(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncontextlost, frame);
}

pub fn setOnContextMenu(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncontextmenu, callback, frame);
}

pub fn getOnContextMenu(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncontextmenu, frame);
}

pub fn setOnContextRestored(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncontextrestored, callback, frame);
}

pub fn getOnContextRestored(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncontextrestored, frame);
}

pub fn setOnCopy(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncopy, callback, frame);
}

pub fn getOnCopy(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncopy, frame);
}

pub fn setOnCueChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncuechange, callback, frame);
}

pub fn getOnCueChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncuechange, frame);
}

pub fn setOnCut(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oncut, callback, frame);
}

pub fn getOnCut(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oncut, frame);
}

pub fn setOnDblClick(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondblclick, callback, frame);
}

pub fn getOnDblClick(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondblclick, frame);
}

pub fn setOnDrag(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondrag, callback, frame);
}

pub fn getOnDrag(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondrag, frame);
}

pub fn setOnDragEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragend, callback, frame);
}

pub fn getOnDragEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragend, frame);
}

pub fn setOnDragEnter(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragenter, callback, frame);
}

pub fn getOnDragEnter(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragenter, frame);
}

pub fn setOnDragExit(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragexit, callback, frame);
}

pub fn getOnDragExit(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragexit, frame);
}

pub fn setOnDragLeave(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragleave, callback, frame);
}

pub fn getOnDragLeave(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragleave, frame);
}

pub fn setOnDragOver(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragover, callback, frame);
}

pub fn getOnDragOver(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragover, frame);
}

pub fn setOnDragStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondragstart, callback, frame);
}

pub fn getOnDragStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondragstart, frame);
}

pub fn setOnDrop(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondrop, callback, frame);
}

pub fn getOnDrop(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondrop, frame);
}

pub fn setOnDurationChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ondurationchange, callback, frame);
}

pub fn getOnDurationChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ondurationchange, frame);
}

pub fn setOnEmptied(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onemptied, callback, frame);
}

pub fn getOnEmptied(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onemptied, frame);
}

pub fn setOnEnded(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onended, callback, frame);
}

pub fn getOnEnded(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onended, frame);
}

pub fn setOnError(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onerror, callback, frame);
}

pub fn getOnError(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onerror, frame);
}

pub fn setOnFocus(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onfocus, callback, frame);
}

pub fn getOnFocus(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onfocus, frame);
}

pub fn setOnFormData(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onformdata, callback, frame);
}

pub fn getOnFormData(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onformdata, frame);
}

pub fn setOnFullscreenChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onfullscreenchange, callback, frame);
}

pub fn getOnFullscreenChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onfullscreenchange, frame);
}

pub fn setOnFullscreenError(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onfullscreenerror, callback, frame);
}

pub fn getOnFullscreenError(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onfullscreenerror, frame);
}

pub fn setOnGotPointerCapture(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ongotpointercapture, callback, frame);
}

pub fn getOnGotPointerCapture(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ongotpointercapture, frame);
}

pub fn setOnInput(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oninput, callback, frame);
}

pub fn getOnInput(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oninput, frame);
}

pub fn setOnInvalid(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.oninvalid, callback, frame);
}

pub fn getOnInvalid(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.oninvalid, frame);
}

pub fn setOnKeyDown(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onkeydown, callback, frame);
}

pub fn getOnKeyDown(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onkeydown, frame);
}

pub fn setOnKeyPress(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onkeypress, callback, frame);
}

pub fn getOnKeyPress(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onkeypress, frame);
}

pub fn setOnKeyUp(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onkeyup, callback, frame);
}

pub fn getOnKeyUp(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onkeyup, frame);
}

pub fn setOnLoad(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onload, callback, frame);
}

pub fn getOnLoad(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onload, frame);
}

pub fn setOnLoadedData(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onloadeddata, callback, frame);
}

pub fn getOnLoadedData(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onloadeddata, frame);
}

pub fn setOnLoadedMetadata(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onloadedmetadata, callback, frame);
}

pub fn getOnLoadedMetadata(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onloadedmetadata, frame);
}

pub fn setOnLoadStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onloadstart, callback, frame);
}

pub fn getOnLoadStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onloadstart, frame);
}

pub fn setOnLostPointerCapture(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onlostpointercapture, callback, frame);
}

pub fn getOnLostPointerCapture(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onlostpointercapture, frame);
}

pub fn setOnMouseDown(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmousedown, callback, frame);
}

pub fn getOnMouseDown(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmousedown, frame);
}

pub fn setOnMouseMove(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmousemove, callback, frame);
}

pub fn getOnMouseMove(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmousemove, frame);
}

pub fn setOnMouseOut(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmouseout, callback, frame);
}

pub fn getOnMouseOut(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmouseout, frame);
}

pub fn setOnMouseOver(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmouseover, callback, frame);
}

pub fn getOnMouseOver(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmouseover, frame);
}

pub fn setOnMouseUp(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onmouseup, callback, frame);
}

pub fn getOnMouseUp(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onmouseup, frame);
}

pub fn setOnPaste(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpaste, callback, frame);
}

pub fn getOnPaste(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpaste, frame);
}

pub fn setOnPause(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpause, callback, frame);
}

pub fn getOnPause(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpause, frame);
}

pub fn setOnPlay(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onplay, callback, frame);
}

pub fn getOnPlay(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onplay, frame);
}

pub fn setOnPlaying(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onplaying, callback, frame);
}

pub fn getOnPlaying(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onplaying, frame);
}

pub fn setOnPointerCancel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointercancel, callback, frame);
}

pub fn getOnPointerCancel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointercancel, frame);
}

pub fn setOnPointerDown(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerdown, callback, frame);
}

pub fn getOnPointerDown(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerdown, frame);
}

pub fn setOnPointerEnter(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerenter, callback, frame);
}

pub fn getOnPointerEnter(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerenter, frame);
}

pub fn setOnPointerLeave(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerleave, callback, frame);
}

pub fn getOnPointerLeave(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerleave, frame);
}

pub fn setOnPointerMove(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointermove, callback, frame);
}

pub fn getOnPointerMove(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointermove, frame);
}

pub fn setOnPointerOut(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerout, callback, frame);
}

pub fn getOnPointerOut(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerout, frame);
}

pub fn setOnPointerOver(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerover, callback, frame);
}

pub fn getOnPointerOver(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerover, frame);
}

pub fn setOnPointerRawUpdate(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerrawupdate, callback, frame);
}

pub fn getOnPointerRawUpdate(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerrawupdate, frame);
}

pub fn setOnPointerUp(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onpointerup, callback, frame);
}

pub fn getOnPointerUp(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onpointerup, frame);
}

pub fn setOnProgress(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onprogress, callback, frame);
}

pub fn getOnProgress(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onprogress, frame);
}

pub fn setOnRateChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onratechange, callback, frame);
}

pub fn getOnRateChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onratechange, frame);
}

pub fn setOnReset(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onreset, callback, frame);
}

pub fn getOnReset(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onreset, frame);
}

pub fn setOnResize(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onresize, callback, frame);
}

pub fn getOnResize(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onresize, frame);
}

pub fn setOnScroll(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onscroll, callback, frame);
}

pub fn getOnScroll(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onscroll, frame);
}

pub fn setOnScrollEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onscrollend, callback, frame);
}

pub fn getOnScrollEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onscrollend, frame);
}

pub fn setOnSecurityPolicyViolation(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onsecuritypolicyviolation, callback, frame);
}

pub fn getOnSecurityPolicyViolation(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onsecuritypolicyviolation, frame);
}

pub fn setOnSeeked(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onseeked, callback, frame);
}

pub fn getOnSeeked(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onseeked, frame);
}

pub fn setOnSeeking(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onseeking, callback, frame);
}

pub fn getOnSeeking(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onseeking, frame);
}

pub fn setOnSelect(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onselect, callback, frame);
}

pub fn getOnSelect(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onselect, frame);
}

pub fn setOnSelectionChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onselectionchange, callback, frame);
}

pub fn getOnSelectionChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onselectionchange, frame);
}

pub fn setOnSelectStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onselectstart, callback, frame);
}

pub fn getOnSelectStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onselectstart, frame);
}

pub fn setOnSlotChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onslotchange, callback, frame);
}

pub fn getOnSlotChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onslotchange, frame);
}

pub fn setOnStalled(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onstalled, callback, frame);
}

pub fn getOnStalled(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onstalled, frame);
}

pub fn setOnSubmit(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onsubmit, callback, frame);
}

pub fn getOnSubmit(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onsubmit, frame);
}

pub fn setOnSuspend(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onsuspend, callback, frame);
}

pub fn getOnSuspend(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onsuspend, frame);
}

pub fn setOnTimeUpdate(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontimeupdate, callback, frame);
}

pub fn getOnTimeUpdate(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontimeupdate, frame);
}

pub fn setOnToggle(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontoggle, callback, frame);
}

pub fn getOnToggle(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontoggle, frame);
}

pub fn setOnTransitionCancel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontransitioncancel, callback, frame);
}

pub fn getOnTransitionCancel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontransitioncancel, frame);
}

pub fn setOnTransitionEnd(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontransitionend, callback, frame);
}

pub fn getOnTransitionEnd(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontransitionend, frame);
}

pub fn setOnTransitionRun(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontransitionrun, callback, frame);
}

pub fn getOnTransitionRun(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontransitionrun, frame);
}

pub fn setOnTransitionStart(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.ontransitionstart, callback, frame);
}

pub fn getOnTransitionStart(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.ontransitionstart, frame);
}

pub fn setOnVolumeChange(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onvolumechange, callback, frame);
}

pub fn getOnVolumeChange(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onvolumechange, frame);
}

pub fn setOnWaiting(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onwaiting, callback, frame);
}

pub fn getOnWaiting(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onwaiting, frame);
}

pub fn setOnWheel(self: *HtmlElement, callback: ?js.Function.Global, frame: *Frame) !void {
    return self.setAttributeListener(.onwheel, callback, frame);
}

pub fn getOnWheel(self: *HtmlElement, frame: *Frame) !?js.Function.Global {
    return self.getAttributeFunction(.onwheel, frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HtmlElement);

    pub const Meta = struct {
        pub const name = "HTMLElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(HtmlElement.construct, .{ .new_target = true });

    pub const innerText = bridge.accessor(_innerText, HtmlElement.setInnerText, .{});
    fn _innerText(self: *HtmlElement, frame: *const Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.call_arena);
        try self.getInnerText(&buf.writer);
        return buf.written();
    }
    pub const insertAdjacentHTML = bridge.function(HtmlElement.insertAdjacentHTML, .{ .dom_exception = true });
    pub const click = bridge.function(HtmlElement.click, .{});

    pub const dir = bridge.accessor(HtmlElement.getDir, HtmlElement.setDir, .{});
    pub const hidden = bridge.accessor(HtmlElement.getHidden, HtmlElement.setHidden, .{});
    pub const isContentEditable = bridge.accessor(HtmlElement.getIsContentEditable, null, .{});
    pub const lang = bridge.accessor(HtmlElement.getLang, HtmlElement.setLang, .{});
    pub const tabIndex = bridge.accessor(HtmlElement.getTabIndex, HtmlElement.setTabIndex, .{});
    pub const title = bridge.accessor(HtmlElement.getTitle, HtmlElement.setTitle, .{});

    pub const onabort = bridge.accessor(HtmlElement.getOnAbort, HtmlElement.setOnAbort, .{});
    pub const onanimationcancel = bridge.accessor(HtmlElement.getOnAnimationCancel, HtmlElement.setOnAnimationCancel, .{});
    pub const onanimationend = bridge.accessor(HtmlElement.getOnAnimationEnd, HtmlElement.setOnAnimationEnd, .{});
    pub const onanimationiteration = bridge.accessor(HtmlElement.getOnAnimationIteration, HtmlElement.setOnAnimationIteration, .{});
    pub const onanimationstart = bridge.accessor(HtmlElement.getOnAnimationStart, HtmlElement.setOnAnimationStart, .{});
    pub const onauxclick = bridge.accessor(HtmlElement.getOnAuxClick, HtmlElement.setOnAuxClick, .{});
    pub const onbeforeinput = bridge.accessor(HtmlElement.getOnBeforeInput, HtmlElement.setOnBeforeInput, .{});
    pub const onbeforematch = bridge.accessor(HtmlElement.getOnBeforeMatch, HtmlElement.setOnBeforeMatch, .{});
    pub const onbeforetoggle = bridge.accessor(HtmlElement.getOnBeforeToggle, HtmlElement.setOnBeforeToggle, .{});
    pub const onblur = bridge.accessor(HtmlElement.getOnBlur, HtmlElement.setOnBlur, .{});
    pub const oncancel = bridge.accessor(HtmlElement.getOnCancel, HtmlElement.setOnCancel, .{});
    pub const oncanplay = bridge.accessor(HtmlElement.getOnCanPlay, HtmlElement.setOnCanPlay, .{});
    pub const oncanplaythrough = bridge.accessor(HtmlElement.getOnCanPlayThrough, HtmlElement.setOnCanPlayThrough, .{});
    pub const onchange = bridge.accessor(HtmlElement.getOnChange, HtmlElement.setOnChange, .{});
    pub const onclick = bridge.accessor(HtmlElement.getOnClick, HtmlElement.setOnClick, .{});
    pub const onclose = bridge.accessor(HtmlElement.getOnClose, HtmlElement.setOnClose, .{});
    pub const oncommand = bridge.accessor(HtmlElement.getOnCommand, HtmlElement.setOnCommand, .{});
    pub const oncontentvisibilityautostatechange = bridge.accessor(HtmlElement.getOnContentVisibilityAutoStateChange, HtmlElement.setOnContentVisibilityAutoStateChange, .{});
    pub const oncontextlost = bridge.accessor(HtmlElement.getOnContextLost, HtmlElement.setOnContextLost, .{});
    pub const oncontextmenu = bridge.accessor(HtmlElement.getOnContextMenu, HtmlElement.setOnContextMenu, .{});
    pub const oncontextrestored = bridge.accessor(HtmlElement.getOnContextRestored, HtmlElement.setOnContextRestored, .{});
    pub const oncopy = bridge.accessor(HtmlElement.getOnCopy, HtmlElement.setOnCopy, .{});
    pub const oncuechange = bridge.accessor(HtmlElement.getOnCueChange, HtmlElement.setOnCueChange, .{});
    pub const oncut = bridge.accessor(HtmlElement.getOnCut, HtmlElement.setOnCut, .{});
    pub const ondblclick = bridge.accessor(HtmlElement.getOnDblClick, HtmlElement.setOnDblClick, .{});
    pub const ondrag = bridge.accessor(HtmlElement.getOnDrag, HtmlElement.setOnDrag, .{});
    pub const ondragend = bridge.accessor(HtmlElement.getOnDragEnd, HtmlElement.setOnDragEnd, .{});
    pub const ondragenter = bridge.accessor(HtmlElement.getOnDragEnter, HtmlElement.setOnDragEnter, .{});
    pub const ondragexit = bridge.accessor(HtmlElement.getOnDragExit, HtmlElement.setOnDragExit, .{});
    pub const ondragleave = bridge.accessor(HtmlElement.getOnDragLeave, HtmlElement.setOnDragLeave, .{});
    pub const ondragover = bridge.accessor(HtmlElement.getOnDragOver, HtmlElement.setOnDragOver, .{});
    pub const ondragstart = bridge.accessor(HtmlElement.getOnDragStart, HtmlElement.setOnDragStart, .{});
    pub const ondrop = bridge.accessor(HtmlElement.getOnDrop, HtmlElement.setOnDrop, .{});
    pub const ondurationchange = bridge.accessor(HtmlElement.getOnDurationChange, HtmlElement.setOnDurationChange, .{});
    pub const onemptied = bridge.accessor(HtmlElement.getOnEmptied, HtmlElement.setOnEmptied, .{});
    pub const onended = bridge.accessor(HtmlElement.getOnEnded, HtmlElement.setOnEnded, .{});
    pub const onerror = bridge.accessor(HtmlElement.getOnError, HtmlElement.setOnError, .{});
    pub const onfocus = bridge.accessor(HtmlElement.getOnFocus, HtmlElement.setOnFocus, .{});
    pub const onformdata = bridge.accessor(HtmlElement.getOnFormData, HtmlElement.setOnFormData, .{});
    pub const onfullscreenchange = bridge.accessor(HtmlElement.getOnFullscreenChange, HtmlElement.setOnFullscreenChange, .{});
    pub const onfullscreenerror = bridge.accessor(HtmlElement.getOnFullscreenError, HtmlElement.setOnFullscreenError, .{});
    pub const ongotpointercapture = bridge.accessor(HtmlElement.getOnGotPointerCapture, HtmlElement.setOnGotPointerCapture, .{});
    pub const oninput = bridge.accessor(HtmlElement.getOnInput, HtmlElement.setOnInput, .{});
    pub const oninvalid = bridge.accessor(HtmlElement.getOnInvalid, HtmlElement.setOnInvalid, .{});
    pub const onkeydown = bridge.accessor(HtmlElement.getOnKeyDown, HtmlElement.setOnKeyDown, .{});
    pub const onkeypress = bridge.accessor(HtmlElement.getOnKeyPress, HtmlElement.setOnKeyPress, .{});
    pub const onkeyup = bridge.accessor(HtmlElement.getOnKeyUp, HtmlElement.setOnKeyUp, .{});
    pub const onload = bridge.accessor(HtmlElement.getOnLoad, HtmlElement.setOnLoad, .{});
    pub const onloadeddata = bridge.accessor(HtmlElement.getOnLoadedData, HtmlElement.setOnLoadedData, .{});
    pub const onloadedmetadata = bridge.accessor(HtmlElement.getOnLoadedMetadata, HtmlElement.setOnLoadedMetadata, .{});
    pub const onloadstart = bridge.accessor(HtmlElement.getOnLoadStart, HtmlElement.setOnLoadStart, .{});
    pub const onlostpointercapture = bridge.accessor(HtmlElement.getOnLostPointerCapture, HtmlElement.setOnLostPointerCapture, .{});
    pub const onmousedown = bridge.accessor(HtmlElement.getOnMouseDown, HtmlElement.setOnMouseDown, .{});
    pub const onmousemove = bridge.accessor(HtmlElement.getOnMouseMove, HtmlElement.setOnMouseMove, .{});
    pub const onmouseout = bridge.accessor(HtmlElement.getOnMouseOut, HtmlElement.setOnMouseOut, .{});
    pub const onmouseover = bridge.accessor(HtmlElement.getOnMouseOver, HtmlElement.setOnMouseOver, .{});
    pub const onmouseup = bridge.accessor(HtmlElement.getOnMouseUp, HtmlElement.setOnMouseUp, .{});
    pub const onpaste = bridge.accessor(HtmlElement.getOnPaste, HtmlElement.setOnPaste, .{});
    pub const onpause = bridge.accessor(HtmlElement.getOnPause, HtmlElement.setOnPause, .{});
    pub const onplay = bridge.accessor(HtmlElement.getOnPlay, HtmlElement.setOnPlay, .{});
    pub const onplaying = bridge.accessor(HtmlElement.getOnPlaying, HtmlElement.setOnPlaying, .{});
    pub const onpointercancel = bridge.accessor(HtmlElement.getOnPointerCancel, HtmlElement.setOnPointerCancel, .{});
    pub const onpointerdown = bridge.accessor(HtmlElement.getOnPointerDown, HtmlElement.setOnPointerDown, .{});
    pub const onpointerenter = bridge.accessor(HtmlElement.getOnPointerEnter, HtmlElement.setOnPointerEnter, .{});
    pub const onpointerleave = bridge.accessor(HtmlElement.getOnPointerLeave, HtmlElement.setOnPointerLeave, .{});
    pub const onpointermove = bridge.accessor(HtmlElement.getOnPointerMove, HtmlElement.setOnPointerMove, .{});
    pub const onpointerout = bridge.accessor(HtmlElement.getOnPointerOut, HtmlElement.setOnPointerOut, .{});
    pub const onpointerover = bridge.accessor(HtmlElement.getOnPointerOver, HtmlElement.setOnPointerOver, .{});
    pub const onpointerrawupdate = bridge.accessor(HtmlElement.getOnPointerRawUpdate, HtmlElement.setOnPointerRawUpdate, .{});
    pub const onpointerup = bridge.accessor(HtmlElement.getOnPointerUp, HtmlElement.setOnPointerUp, .{});
    pub const onprogress = bridge.accessor(HtmlElement.getOnProgress, HtmlElement.setOnProgress, .{});
    pub const onratechange = bridge.accessor(HtmlElement.getOnRateChange, HtmlElement.setOnRateChange, .{});
    pub const onreset = bridge.accessor(HtmlElement.getOnReset, HtmlElement.setOnReset, .{});
    pub const onresize = bridge.accessor(HtmlElement.getOnResize, HtmlElement.setOnResize, .{});
    pub const onscroll = bridge.accessor(HtmlElement.getOnScroll, HtmlElement.setOnScroll, .{});
    pub const onscrollend = bridge.accessor(HtmlElement.getOnScrollEnd, HtmlElement.setOnScrollEnd, .{});
    pub const onsecuritypolicyviolation = bridge.accessor(HtmlElement.getOnSecurityPolicyViolation, HtmlElement.setOnSecurityPolicyViolation, .{});
    pub const onseeked = bridge.accessor(HtmlElement.getOnSeeked, HtmlElement.setOnSeeked, .{});
    pub const onseeking = bridge.accessor(HtmlElement.getOnSeeking, HtmlElement.setOnSeeking, .{});
    pub const onselect = bridge.accessor(HtmlElement.getOnSelect, HtmlElement.setOnSelect, .{});
    pub const onselectionchange = bridge.accessor(HtmlElement.getOnSelectionChange, HtmlElement.setOnSelectionChange, .{});
    pub const onselectstart = bridge.accessor(HtmlElement.getOnSelectStart, HtmlElement.setOnSelectStart, .{});
    pub const onslotchange = bridge.accessor(HtmlElement.getOnSlotChange, HtmlElement.setOnSlotChange, .{});
    pub const onstalled = bridge.accessor(HtmlElement.getOnStalled, HtmlElement.setOnStalled, .{});
    pub const onsubmit = bridge.accessor(HtmlElement.getOnSubmit, HtmlElement.setOnSubmit, .{});
    pub const onsuspend = bridge.accessor(HtmlElement.getOnSuspend, HtmlElement.setOnSuspend, .{});
    pub const ontimeupdate = bridge.accessor(HtmlElement.getOnTimeUpdate, HtmlElement.setOnTimeUpdate, .{});
    pub const ontoggle = bridge.accessor(HtmlElement.getOnToggle, HtmlElement.setOnToggle, .{});
    pub const ontransitioncancel = bridge.accessor(HtmlElement.getOnTransitionCancel, HtmlElement.setOnTransitionCancel, .{});
    pub const ontransitionend = bridge.accessor(HtmlElement.getOnTransitionEnd, HtmlElement.setOnTransitionEnd, .{});
    pub const ontransitionrun = bridge.accessor(HtmlElement.getOnTransitionRun, HtmlElement.setOnTransitionRun, .{});
    pub const ontransitionstart = bridge.accessor(HtmlElement.getOnTransitionStart, HtmlElement.setOnTransitionStart, .{});
    pub const onvolumechange = bridge.accessor(HtmlElement.getOnVolumeChange, HtmlElement.setOnVolumeChange, .{});
    pub const onwaiting = bridge.accessor(HtmlElement.getOnWaiting, HtmlElement.setOnWaiting, .{});
    pub const onwheel = bridge.accessor(HtmlElement.getOnWheel, HtmlElement.setOnWheel, .{});
};

pub const Build = struct {
    // Calls `func_name` with `args` on the most specific type where it is
    // implement. This could be on the HtmlElement itself.
    pub fn call(self: *const HtmlElement, comptime func_name: []const u8, args: anytype) !bool {
        inline for (@typeInfo(HtmlElement.Type).@"union".fields) |f| {
            if (@field(HtmlElement.Type, f.name) == self._type) {
                // The inner type implements this function. Call it and we're done.
                const S = reflect.Struct(f.type);
                if (@hasDecl(S, "Build")) {
                    if (@hasDecl(S.Build, func_name)) {
                        try @call(.auto, @field(S.Build, func_name), args);
                        return true;
                    }
                }
            }
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
