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
const lp = @import("lightpanda");
const js = @import("../../js/js.zig");
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
