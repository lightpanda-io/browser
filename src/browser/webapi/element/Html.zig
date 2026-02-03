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
const js = @import("../../js/js.zig");
const log = @import("../../../log.zig");
const reflect = @import("../../reflect.zig");

const Page = @import("../../Page.zig");
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
pub const Dialog = @import("html/Dialog.zig");
pub const Directory = @import("html/Directory.zig");
pub const Div = @import("html/Div.zig");
pub const Embed = @import("html/Embed.zig");
pub const FieldSet = @import("html/FieldSet.zig");
pub const Font = @import("html/Font.zig");
pub const Form = @import("html/Form.zig");
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

const HtmlElement = @This();

_type: Type,
_proto: *Element,

// Special constructor for custom elements
pub fn construct(page: *Page) !*Element {
    const node = page._upgrading_element orelse return error.IllegalConstructor;
    return node.is(Element) orelse return error.IllegalConstructor;
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
    dialog: *Dialog,
    directory: *Directory,
    div: *Div,
    embed: *Embed,
    fieldset: *FieldSet,
    font: *Font,
    form: *Form,
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

pub fn setInnerText(self: *HtmlElement, text: []const u8, page: *Page) !void {
    const parent = self.asElement().asNode();

    // Remove all existing children
    page.domChanged();
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        page.removeNode(parent, child, .{ .will_be_reconnected = false });
    }

    // Fast path: skip if text is empty
    if (text.len == 0) {
        return;
    }

    // Create and append text node
    const text_node = try page.createTextNode(text);
    try page.appendNode(parent, text_node, .{ .child_already_connected = false });
}

pub fn insertAdjacentHTML(
    self: *HtmlElement,
    position: []const u8,
    html: []const u8,
    page: *Page,
) !void {

    // Create a new HTMLDocument.
    const doc = try page._factory.document(@import("../HTMLDocument.zig"){
        ._proto = undefined,
    });
    const doc_node = doc.asNode();

    const arena = try page.getArena(.{ .debug = "HTML.insertAdjacentHTML" });
    defer page.releaseArena(arena);

    const Parser = @import("../../parser/Parser.zig");
    var parser = Parser.init(arena, doc_node, page);
    parser.parse(html);

    // Check if there's parsing error.
    if (parser.err) |_| {
        return error.Invalid;
    }

    // The parser wraps content in a document structure:
    // - Typical: <html><head>...</head><body>...</body></html>
    // - Head-only: <html><head><meta></head></html> (no body)
    // - Empty/comments: May have no <html> element at all
    const html_node = doc_node.firstChild() orelse return;

    const target_node, const prev_node = try self.asElement().asNode().findAdjacentNodes(position);

    // Iterate through all children of <html> (typically <head> and/or <body>)
    // and insert their children (not the containers themselves) into the target.
    // This handles both body content AND head-only elements like <meta>, <title>, etc.
    var html_children = html_node.childrenIterator();
    while (html_children.next()) |container| {
        var iter = container.childrenIterator();
        while (iter.next()) |child_node| {
            _ = try target_node.insertBefore(child_node, prev_node, page);
        }
    }
}

pub fn click(self: *HtmlElement, page: *Page) !void {
    switch (self._type) {
        inline .button, .input, .textarea, .select => |i| {
            if (i.getDisabled()) {
                return;
            }
        },
        else => {},
    }

    const event = try @import("../event/MouseEvent.zig").init("click", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = 0,
        .clientY = 0,
    }, page);
    try page._event_manager.dispatch(self.asEventTarget(), event.asEvent());
}

fn getAttributeFunction(
    self: *HtmlElement,
    comptime listener_type: Element.KnownListener,
    page: *Page,
) ?js.Function.Global {
    const element = self.asElement();
    if (page.getAttrListener(element, listener_type)) |cached| {
        return cached;
    }

    const attr = element.getAttributeSafe(.wrap(@tagName(listener_type))) orelse return null;
    const callback = page.js.stringToPersistedFunction(attr) catch |err| {
        // Not a valid expression; log this to find out if its something we should be supporting.
        log.warn(.unknown_prop, "Page.getAttrListener", .{
            .expression = attr,
            .err = err,
        });

        return null;
    };

    page.setAttrListener(element, listener_type, callback) catch {
        // This is fine :tm: We're out of memory for cache.
        // I don't want to make all getters "!?" just because of this honestly.
        log.warn(.app, "getAttributeFunction", .{
            .element = element,
            .listener_type = listener_type,
            .callback = callback,
        });
    };

    return callback;
}

pub fn setOnAbort(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .abort, callback);
}

pub fn getOnAbort(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .abort);
}

pub fn setOnAnimationCancel(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .animationcancel, callback);
}

pub fn getOnAnimationCancel(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .animationcancel);
}

pub fn setOnAnimationEnd(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .animationend, callback);
}

pub fn getOnAnimationEnd(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .animationend);
}

pub fn setOnAnimationIteration(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .animationiteration, callback);
}

pub fn getOnAnimationIteration(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .animationiteration);
}

pub fn setOnAnimationStart(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .animationstart, callback);
}

pub fn getOnAnimationStart(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .animationstart);
}

pub fn setOnAuxClick(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .auxclick, callback);
}

pub fn getOnAuxClick(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .auxclick);
}

pub fn setOnBeforeInput(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .beforeinput, callback);
}

pub fn getOnBeforeInput(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .beforeinput);
}

pub fn setOnBeforeMatch(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .beforematch, callback);
}

pub fn getOnBeforeMatch(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .beforematch);
}

pub fn setOnBeforeToggle(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .beforetoggle, callback);
}

pub fn getOnBeforeToggle(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .beforetoggle);
}

pub fn setOnBlur(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .blur, callback);
}

pub fn getOnBlur(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .blur);
}

pub fn setOnCancel(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .cancel, callback);
}

pub fn getOnCancel(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .cancel);
}

pub fn setOnCanPlay(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .canplay, callback);
}

pub fn getOnCanPlay(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .canplay);
}

pub fn setOnCanPlayThrough(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .canplaythrough, callback);
}

pub fn getOnCanPlayThrough(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .canplaythrough);
}

pub fn setOnChange(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .change, callback);
}

pub fn getOnChange(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .change);
}

pub fn setOnClick(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .click, callback);
}

pub fn getOnClick(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .click);
}

pub fn setOnClose(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .close, callback);
}

pub fn getOnClose(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .close);
}

pub fn setOnCommand(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .command, callback);
}

pub fn getOnCommand(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .command);
}

pub fn setOnContentVisibilityAutoStateChange(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .contentvisibilityautostatechange, callback);
}

pub fn getOnContentVisibilityAutoStateChange(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .contentvisibilityautostatechange);
}

pub fn setOnContextLost(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .contextlost, callback);
}

pub fn getOnContextLost(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .contextlost);
}

pub fn setOnContextMenu(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .contextmenu, callback);
}

pub fn getOnContextMenu(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .contextmenu);
}

pub fn setOnContextRestored(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .contextrestored, callback);
}

pub fn getOnContextRestored(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .contextrestored);
}

pub fn setOnCopy(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .copy, callback);
}

pub fn getOnCopy(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .copy);
}

pub fn setOnCueChange(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .cuechange, callback);
}

pub fn getOnCueChange(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .cuechange);
}

pub fn setOnCut(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .cut, callback);
}

pub fn getOnCut(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .cut);
}

pub fn setOnDblClick(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .dblclick, callback);
}

pub fn getOnDblClick(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .dblclick);
}

pub fn setOnDrag(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .drag, callback);
}

pub fn getOnDrag(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .drag);
}

pub fn setOnDragEnd(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .dragend, callback);
}

pub fn getOnDragEnd(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .dragend);
}

pub fn setOnDragEnter(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .dragenter, callback);
}

pub fn getOnDragEnter(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .dragenter);
}

pub fn setOnDragExit(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .dragexit, callback);
}

pub fn getOnDragExit(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .dragexit);
}

pub fn setOnDragLeave(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .dragleave, callback);
}

pub fn getOnDragLeave(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .dragleave);
}

pub fn setOnDragOver(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .dragover, callback);
}

pub fn getOnDragOver(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .dragover);
}

pub fn setOnDragStart(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .dragstart, callback);
}

pub fn getOnDragStart(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .dragstart);
}

pub fn setOnDrop(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .drop, callback);
}

pub fn getOnDrop(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .drop);
}

pub fn setOnDurationChange(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .durationchange, callback);
}

pub fn getOnDurationChange(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .durationchange);
}

pub fn setOnEmptied(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .emptied, callback);
}

pub fn getOnEmptied(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .emptied);
}

pub fn setOnEnded(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .ended, callback);
}

pub fn getOnEnded(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .ended);
}

pub fn setOnError(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .@"error", callback);
}

pub fn getOnError(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .@"error");
}

pub fn setOnFocus(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .focus, callback);
}

pub fn getOnFocus(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .focus);
}

pub fn setOnFormData(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .formdata, callback);
}

pub fn getOnFormData(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .formdata);
}

pub fn setOnFullscreenChange(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .fullscreenchange, callback);
}

pub fn getOnFullscreenChange(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .fullscreenchange);
}

pub fn setOnFullscreenError(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .fullscreenerror, callback);
}

pub fn getOnFullscreenError(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .fullscreenerror);
}

pub fn setOnGotPointerCapture(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .gotpointercapture, callback);
}

pub fn getOnGotPointerCapture(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .gotpointercapture);
}

pub fn setOnInput(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .input, callback);
}

pub fn getOnInput(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .input);
}

pub fn setOnInvalid(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .invalid, callback);
}

pub fn getOnInvalid(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .invalid);
}

pub fn setOnKeyDown(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .keydown, callback);
}

pub fn getOnKeyDown(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .keydown);
}

pub fn setOnKeyPress(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .keypress, callback);
}

pub fn getOnKeyPress(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .keypress);
}

pub fn setOnKeyUp(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .keyup, callback);
}

pub fn getOnKeyUp(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .keyup);
}

pub fn setOnLoad(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .load, callback);
}

pub fn getOnLoad(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .load);
}

pub fn setOnLoadedData(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .loadeddata, callback);
}

pub fn getOnLoadedData(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .loadeddata);
}

pub fn setOnLoadedMetadata(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .loadedmetadata, callback);
}

pub fn getOnLoadedMetadata(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .loadedmetadata);
}

pub fn setOnLoadStart(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .loadstart, callback);
}

pub fn getOnLoadStart(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .loadstart);
}

pub fn setOnLostPointerCapture(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .lostpointercapture, callback);
}

pub fn getOnLostPointerCapture(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .lostpointercapture);
}

pub fn setOnMouseDown(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .mousedown, callback);
}

pub fn getOnMouseDown(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .mousedown);
}

pub fn setOnMouseMove(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .mousemove, callback);
}

pub fn getOnMouseMove(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .mousemove);
}

pub fn setOnMouseOut(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .mouseout, callback);
}

pub fn getOnMouseOut(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .mouseout);
}

pub fn setOnMouseOver(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .mouseover, callback);
}

pub fn getOnMouseOver(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .mouseover);
}

pub fn setOnMouseUp(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .mouseup, callback);
}

pub fn getOnMouseUp(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .mouseup);
}

pub fn setOnPaste(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .paste, callback);
}

pub fn getOnPaste(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .paste);
}

pub fn setOnPause(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pause, callback);
}

pub fn getOnPause(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pause);
}

pub fn setOnPlay(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .play, callback);
}

pub fn getOnPlay(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .play);
}

pub fn setOnPlaying(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .playing, callback);
}

pub fn getOnPlaying(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .playing);
}

pub fn setOnPointerCancel(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pointercancel, callback);
}

pub fn getOnPointerCancel(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pointercancel);
}

pub fn setOnPointerDown(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pointerdown, callback);
}

pub fn getOnPointerDown(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pointerdown);
}

pub fn setOnPointerEnter(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pointerenter, callback);
}

pub fn getOnPointerEnter(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pointerenter);
}

pub fn setOnPointerLeave(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pointerleave, callback);
}

pub fn getOnPointerLeave(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pointerleave);
}

pub fn setOnPointerMove(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pointermove, callback);
}

pub fn getOnPointerMove(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pointermove);
}

pub fn setOnPointerOut(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pointerout, callback);
}

pub fn getOnPointerOut(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pointerout);
}

pub fn setOnPointerOver(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pointerover, callback);
}

pub fn getOnPointerOver(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pointerover);
}

pub fn setOnPointerRawUpdate(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pointerrawupdate, callback);
}

pub fn getOnPointerRawUpdate(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pointerrawupdate);
}

pub fn setOnPointerUp(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .pointerup, callback);
}

pub fn getOnPointerUp(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .pointerup);
}

pub fn setOnProgress(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .progress, callback);
}

pub fn getOnProgress(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .progress);
}

pub fn setOnRateChange(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .ratechange, callback);
}

pub fn getOnRateChange(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .ratechange);
}

pub fn setOnReset(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .reset, callback);
}

pub fn getOnReset(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .reset);
}

pub fn setOnResize(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .resize, callback);
}

pub fn getOnResize(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .resize);
}

pub fn setOnScroll(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .scroll, callback);
}

pub fn getOnScroll(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .scroll);
}

pub fn setOnScrollEnd(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .scrollend, callback);
}

pub fn getOnScrollEnd(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .scrollend);
}

pub fn setOnSecurityPolicyViolation(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .securitypolicyviolation, callback);
}

pub fn getOnSecurityPolicyViolation(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .securitypolicyviolation);
}

pub fn setOnSeeked(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .seeked, callback);
}

pub fn getOnSeeked(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .seeked);
}

pub fn setOnSeeking(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .seeking, callback);
}

pub fn getOnSeeking(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .seeking);
}

pub fn setOnSelect(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .select, callback);
}

pub fn getOnSelect(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .select);
}

pub fn setOnSelectionChange(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .selectionchange, callback);
}

pub fn getOnSelectionChange(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .selectionchange);
}

pub fn setOnSelectStart(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .selectstart, callback);
}

pub fn getOnSelectStart(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .selectstart);
}

pub fn setOnSlotChange(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .slotchange, callback);
}

pub fn getOnSlotChange(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .slotchange);
}

pub fn setOnStalled(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .stalled, callback);
}

pub fn getOnStalled(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .stalled);
}

pub fn setOnSubmit(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .submit, callback);
}

pub fn getOnSubmit(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .submit);
}

pub fn setOnSuspend(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .@"suspend", callback);
}

pub fn getOnSuspend(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .@"suspend");
}

pub fn setOnTimeUpdate(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .timeupdate, callback);
}

pub fn getOnTimeUpdate(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .timeupdate);
}

pub fn setOnToggle(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .toggle, callback);
}

pub fn getOnToggle(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .toggle);
}

pub fn setOnTransitionCancel(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .transitioncancel, callback);
}

pub fn getOnTransitionCancel(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .transitioncancel);
}

pub fn setOnTransitionEnd(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .transitionend, callback);
}

pub fn getOnTransitionEnd(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .transitionend);
}

pub fn setOnTransitionRun(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .transitionrun, callback);
}

pub fn getOnTransitionRun(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .transitionrun);
}

pub fn setOnTransitionStart(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .transitionstart, callback);
}

pub fn getOnTransitionStart(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .transitionstart);
}

pub fn setOnVolumeChange(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .volumechange, callback);
}

pub fn getOnVolumeChange(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .volumechange);
}

pub fn setOnWaiting(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .waiting, callback);
}

pub fn getOnWaiting(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .waiting);
}

pub fn setOnWheel(self: *HtmlElement, callback: js.Function.Global, page: *Page) !void {
    return page.setAttrListener(self.asElement(), .wheel, callback);
}

pub fn getOnWheel(self: *HtmlElement, page: *Page) ?js.Function.Global {
    return page.getAttrListener(self.asElement(), .wheel);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HtmlElement);

    pub const Meta = struct {
        pub const name = "HTMLElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(HtmlElement.construct, .{});

    pub const innerText = bridge.accessor(_innerText, HtmlElement.setInnerText, .{});
    fn _innerText(self: *HtmlElement, page: *const Page) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(page.call_arena);
        try self.getInnerText(&buf.writer);
        return buf.written();
    }
    pub const insertAdjacentHTML = bridge.function(HtmlElement.insertAdjacentHTML, .{ .dom_exception = true });
    pub const click = bridge.function(HtmlElement.click, .{});

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
