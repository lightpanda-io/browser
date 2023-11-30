const parser = @import("../netsurf.zig");
const generate = @import("../generate.zig");

const Element = @import("../dom/element.zig").Element;

// HTMLElement interfaces
pub const Interfaces = .{
    HTMLElement,
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
};
const Generated = generate.Union.compile(Interfaces);
pub const Union = Generated._union;
pub const Tags = Generated._enum;

// Abstract class
// --------------

pub const HTMLElement = struct {
    pub const Self = parser.ElementHTML;
    pub const prototype = *Element;
    pub const mem_guarantied = true;
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

pub fn toInterface(comptime T: type, e: *parser.Element) !T {
    const elem: *align(@alignOf(*parser.Element)) parser.Element = @alignCast(e);
    const tag = try parser.elementHTMLGetTagType(@as(*parser.ElementHTML, @ptrCast(elem)));
    return switch (tag) {
        .abbr, .acronym, .address, .article, .aside, .b, .bdi, .bdo, .bgsound, .big, .center, .cite, .code, .dd, .details, .dfn, .dt, .figcaption, .figure, .footer, .header, .hgroup, .i, .isindex, .kbd, .main, .mark, .marquee, .nav, .nobr, .noframes, .noscript, .rp, .rt, .ruby, .s, .samp, .section, .small, .spacer, .strike, .sub, .summary, .sup, .tt, .u, .wbr, ._var => .{ .HTMLElement = @as(*parser.ElementHTML, @ptrCast(elem)) },
        .a => .{ .HTMLAnchorElement = @as(*parser.Anchor, @ptrCast(elem)) },
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
