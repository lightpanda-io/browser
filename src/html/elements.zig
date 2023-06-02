const parser = @import("../parser.zig");
const generate = @import("../generate.zig");

const Element = @import("../dom/element.zig").Element;

// Abstract class
// --------------

pub const HTMLElement = struct {
    pub const Self = parser.HTMLElement;
    pub const prototype = *Element;
    pub const mem_guarantied = true;
};

pub const HTMLElementsTypes = .{
    HTMLUnknownElement,
    HTMLAnchorElement,
    HTMLAreaElement,
    HTMLAudioElement,
    HTMLBRElement,
    HTMLBaseElement,
    HTMLBodyElement,
    HTMLButtonElement,
    HTMLCanvasElement,
    HTMLDListElement,
    HTMLDataElement,
    HTMLDialogElement,
    HTMLDivElement,
    HTMLEmbedElement,
    HTMLFieldSetElement,
    HTMLFormElement,
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
};
const HTMLElementsGenerated = generate.Union.compile(HTMLElementsTypes);
pub const HTMLElements = HTMLElementsGenerated._union;
pub const HTMLElementsTags = HTMLElementsGenerated._enum;

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

pub const HTMLAnchorElement = struct {
    pub const Self = parser.Anchor;
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

pub const HTMLDialogElement = struct {
    pub const Self = parser.Dialog;
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

pub const HTMLFormElement = struct {
    pub const Self = parser.Form;
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

pub const HTMLScriptElement = struct {
    pub const Self = parser.Script;
    pub const prototype = *HTMLElement;
    pub const mem_guarantied = true;
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

pub fn ElementToHTMLElementInterface(elem: *parser.Element) HTMLElements {
    const tag = parser.nodeTag(parser.elementNode(elem));
    return switch (tag) {
        .a => .{ .HTMLAnchorElement = @ptrCast(*parser.Anchor, elem) },
        .area => .{ .HTMLAreaElement = @ptrCast(*parser.Area, elem) },
        .audio => .{ .HTMLAudioElement = @ptrCast(*parser.Audio, elem) },
        .br => .{ .HTMLBRElement = @ptrCast(*parser.BR, elem) },
        .base => .{ .HTMLBaseElement = @ptrCast(*parser.Base, elem) },
        .body => .{ .HTMLBodyElement = @ptrCast(*parser.Body, elem) },
        .button => .{ .HTMLButtonElement = @ptrCast(*parser.Button, elem) },
        .canvas => .{ .HTMLCanvasElement = @ptrCast(*parser.Canvas, elem) },
        .dl => .{ .HTMLDListElement = @ptrCast(*parser.DList, elem) },
        .data => .{ .HTMLDataElement = @ptrCast(*parser.Data, elem) },
        .dialog => .{ .HTMLDialogElement = @ptrCast(*parser.Dialog, elem) },
        .div => .{ .HTMLDivElement = @ptrCast(*parser.Div, elem) },
        .embed => .{ .HTMLEmbedElement = @ptrCast(*parser.Embed, elem) },
        .fieldset => .{ .HTMLFieldSetElement = @ptrCast(*parser.FieldSet, elem) },
        .form => .{ .HTMLFormElement = @ptrCast(*parser.Form, elem) },
        .frameset => .{ .HTMLFrameSetElement = @ptrCast(*parser.FrameSet, elem) },
        .hr => .{ .HTMLHRElement = @ptrCast(*parser.HR, elem) },
        .head => .{ .HTMLHeadElement = @ptrCast(*parser.Head, elem) },
        .h1, .h2, .h3, .h4, .h5, .h6 => .{ .HTMLHeadingElement = @ptrCast(*parser.Heading, elem) },
        .html => .{ .HTMLHtmlElement = @ptrCast(*parser.Html, elem) },
        .iframe => .{ .HTMLIFrameElement = @ptrCast(*parser.IFrame, elem) },
        .img => .{ .HTMLImageElement = @ptrCast(*parser.Image, elem) },
        .input => .{ .HTMLInputElement = @ptrCast(*parser.Input, elem) },
        .li => .{ .HTMLLIElement = @ptrCast(*parser.LI, elem) },
        .label => .{ .HTMLLabelElement = @ptrCast(*parser.Label, elem) },
        .legend => .{ .HTMLLegendElement = @ptrCast(*parser.Legend, elem) },
        .link => .{ .HTMLLinkElement = @ptrCast(*parser.Link, elem) },
        .map => .{ .HTMLMapElement = @ptrCast(*parser.Map, elem) },
        .meta => .{ .HTMLMetaElement = @ptrCast(*parser.Meta, elem) },
        .meter => .{ .HTMLMeterElement = @ptrCast(*parser.Meter, elem) },
        .ins, .del => .{ .HTMLModElement = @ptrCast(*parser.Mod, elem) },
        .ol => .{ .HTMLOListElement = @ptrCast(*parser.OList, elem) },
        .object => .{ .HTMLObjectElement = @ptrCast(*parser.Object, elem) },
        .optgroup => .{ .HTMLOptGroupElement = @ptrCast(*parser.OptGroup, elem) },
        .option => .{ .HTMLOptionElement = @ptrCast(*parser.Option, elem) },
        .output => .{ .HTMLOutputElement = @ptrCast(*parser.Output, elem) },
        .p => .{ .HTMLParagraphElement = @ptrCast(*parser.Paragraph, elem) },
        .picture => .{ .HTMLPictureElement = @ptrCast(*parser.Picture, elem) },
        .pre => .{ .HTMLPreElement = @ptrCast(*parser.Pre, elem) },
        .progress => .{ .HTMLProgressElement = @ptrCast(*parser.Progress, elem) },
        .blockquote, .q => .{ .HTMLQuoteElement = @ptrCast(*parser.Quote, elem) },
        .script => .{ .HTMLScriptElement = @ptrCast(*parser.Script, elem) },
        .select => .{ .HTMLSelectElement = @ptrCast(*parser.Select, elem) },
        .source => .{ .HTMLSourceElement = @ptrCast(*parser.Source, elem) },
        .span => .{ .HTMLSpanElement = @ptrCast(*parser.Span, elem) },
        .style => .{ .HTMLStyleElement = @ptrCast(*parser.Style, elem) },
        .table => .{ .HTMLTableElement = @ptrCast(*parser.Table, elem) },
        .caption => .{ .HTMLTableCaptionElement = @ptrCast(*parser.TableCaption, elem) },
        .th, .td => .{ .HTMLTableCellElement = @ptrCast(*parser.TableCell, elem) },
        .col => .{ .HTMLTableColElement = @ptrCast(*parser.TableCol, elem) },
        .tr => .{ .HTMLTableRowElement = @ptrCast(*parser.TableRow, elem) },
        .thead, .tbody, .tfoot => .{ .HTMLTableSectionElement = @ptrCast(*parser.TableSection, elem) },
        .template => .{ .HTMLTemplateElement = @ptrCast(*parser.Template, elem) },
        .textarea => .{ .HTMLTextAreaElement = @ptrCast(*parser.TextArea, elem) },
        .time => .{ .HTMLTimeElement = @ptrCast(*parser.Time, elem) },
        .title => .{ .HTMLTitleElement = @ptrCast(*parser.Title, elem) },
        .track => .{ .HTMLTrackElement = @ptrCast(*parser.Track, elem) },
        .ul => .{ .HTMLUListElement = @ptrCast(*parser.UList, elem) },
        .video => .{ .HTMLVideoElement = @ptrCast(*parser.Video, elem) },
        .undef => .{ .HTMLUnknownElement = @ptrCast(*parser.Unknown, elem) },
    };
}
