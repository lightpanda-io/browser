const parser = @import("../parser.zig");

const Element = @import("../dom/element.zig").Element;

// Abstract class
// --------------

pub const HTMLElement = struct {
    proto: Element,

    pub const prototype = *Element;

    pub fn init(elem_base: *parser.Element) HTMLElement {
        return .{ .proto = Element.init(elem_base) };
    }
};

const HTMLElementsTags = enum {
    unknown,
    anchor,
    area,
    audio,
    br,
    base,
    body,
    button,
    canvas,
    dlist,
    dialog,
    data,
    div,
    embed,
    fieldset,
    form,
    frameset,
    hr,
    head,
    heading,
    html,
    iframe,
    img,
    input,
    li,
    label,
    legend,
    link,
    map,
    meta,
    meter,
    mod,
    olist,
    object,
    optgroup,
    option,
    output,
    paragraph,
    picture,
    pre,
    progress,
    quote,
    script,
    select,
    source,
    span,
    style,
    table,
    tablecaption,
    tablecell,
    tablecol,
    tablerow,
    tablesection,
    template,
    textarea,
    time,
    title,
    track,
    ulist,
    video,
};

// TODO: generate comptime?
pub const HTMLElements = union(HTMLElementsTags) {
    unknown: HTMLUnknownElement,
    anchor: HTMLAnchorElement,
    area: HTMLAreaElement,
    audio: HTMLAudioElement,
    br: HTMLBRElement,
    base: HTMLBaseElement,
    body: HTMLBodyElement,
    button: HTMLButtonElement,
    canvas: HTMLCanvasElement,
    dlist: HTMLDListElement,
    dialog: HTMLDialogElement,
    data: HTMLDataElement,
    div: HTMLDivElement,
    embed: HTMLEmbedElement,
    fieldset: HTMLFieldSetElement,
    form: HTMLFormElement,
    frameset: HTMLFrameSetElement,
    hr: HTMLHRElement,
    head: HTMLHeadElement,
    heading: HTMLHeadingElement,
    html: HTMLHtmlElement,
    iframe: HTMLIFrameElement,
    img: HTMLImageElement,
    input: HTMLInputElement,
    li: HTMLLIElement,
    label: HTMLLabelElement,
    legend: HTMLLegendElement,
    link: HTMLLinkElement,
    map: HTMLMapElement,
    meta: HTMLMetaElement,
    meter: HTMLMeterElement,
    mod: HTMLModElement,
    olist: HTMLOListElement,
    object: HTMLObjectElement,
    optgroup: HTMLOptGroupElement,
    option: HTMLOptionElement,
    output: HTMLOutputElement,
    paragraph: HTMLParagraphElement,
    picture: HTMLPictureElement,
    pre: HTMLPreElement,
    progress: HTMLProgressElement,
    quote: HTMLQuoteElement,
    script: HTMLScriptElement,
    select: HTMLSelectElement,
    source: HTMLSourceElement,
    span: HTMLSpanElement,
    style: HTMLStyleElement,
    table: HTMLTableElement,
    tablecaption: HTMLTableCaptionElement,
    tablecell: HTMLTableCellElement,
    tablecol: HTMLTableColElement,
    tablerow: HTMLTableRowElement,
    tablesection: HTMLTableSectionElement,
    template: HTMLTemplateElement,
    textarea: HTMLTextAreaElement,
    time: HTMLTimeElement,
    title: HTMLTitleElement,
    track: HTMLTrackElement,
    ulist: HTMLUListElement,
    video: HTMLVideoElement,
};

// Deprecated HTMLElements in Chrome (2023/03/15)
// HTMLContentelement
// HTMLShadowElement

// Abstract sub-classes
// --------------------

pub const HTMLMediaElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLMediaElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

// HTML elements
// -------------

pub const HTMLUnknownElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLUnknownElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLAnchorElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLAnchorElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLAreaElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLAreaElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLAudioElement = struct {
    proto: HTMLMediaElement,

    pub const prototype = *HTMLMediaElement;

    pub fn init(elem_base: *parser.Element) HTMLAudioElement {
        return .{ .proto = HTMLMediaElement.init(elem_base) };
    }
};

pub const HTMLBRElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLBRElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLBaseElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLBaseElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLBodyElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLBodyElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLButtonElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLButtonElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLCanvasElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLCanvasElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLDListElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLDListElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLDialogElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLDialogElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLDataElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLDataElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLDivElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLDivElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLEmbedElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLEmbedElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLFieldSetElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLFieldSetElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLFormElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLFormElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLFrameSetElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLFrameSetElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLHRElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLHRElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLHeadElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLHeadElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLHeadingElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLHeadingElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLHtmlElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLHtmlElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLIFrameElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLIFrameElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLImageElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLImageElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLInputElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLInputElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLLIElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLLIElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLLabelElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLLabelElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLLegendElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLLegendElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLLinkElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLLinkElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLMapElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLMapElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLMetaElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLMetaElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLMeterElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLMeterElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLModElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLModElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLOListElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLOListElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLObjectElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLObjectElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLOptGroupElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLOptGroupElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLOptionElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLOptionElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLOutputElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLOutputElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLParagraphElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLParagraphElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLPictureElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLPictureElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLPreElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLPreElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLProgressElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLProgressElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLQuoteElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLQuoteElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLScriptElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLScriptElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLSelectElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLSelectElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLSourceElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLSourceElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLSpanElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLSpanElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLStyleElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLStyleElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTableElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTableElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTableCaptionElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTableCaptionElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTableCellElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTableCellElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTableColElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTableColElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTableRowElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTableRowElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTableSectionElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTableSectionElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTemplateElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTemplateElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTextAreaElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTextAreaElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTimeElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTimeElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTitleElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTitleElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLTrackElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLTrackElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLUListElement = struct {
    proto: HTMLElement,

    pub const prototype = *HTMLElement;

    pub fn init(elem_base: *parser.Element) HTMLUListElement {
        return .{ .proto = HTMLElement.init(elem_base) };
    }
};

pub const HTMLVideoElement = struct {
    proto: HTMLMediaElement,

    pub const prototype = *HTMLMediaElement;

    pub fn init(elem_base: *parser.Element) HTMLVideoElement {
        return .{ .proto = HTMLMediaElement.init(elem_base) };
    }
};

pub fn ElementToHTMLElementInterface(base: *parser.Element) HTMLElements {
    const tag = parser.nodeTag(parser.elementNode(base));
    return switch (tag) {
        .a => .{ .anchor = HTMLAnchorElement.init(base) },
        .area => .{ .area = HTMLAreaElement.init(base) },
        .audio => .{ .audio = HTMLAudioElement.init(base) },
        .br => .{ .br = HTMLBRElement.init(base) },
        .base => .{ .base = HTMLBaseElement.init(base) },
        .body => .{ .body = HTMLBodyElement.init(base) },
        .button => .{ .button = HTMLButtonElement.init(base) },
        .canvas => .{ .canvas = HTMLCanvasElement.init(base) },
        .dl => .{ .dlist = HTMLDListElement.init(base) },
        .dialog => .{ .dialog = HTMLDialogElement.init(base) },
        .data => .{ .data = HTMLDataElement.init(base) },
        .div => .{ .div = HTMLDivElement.init(base) },
        .embed => .{ .embed = HTMLEmbedElement.init(base) },
        .fieldset => .{ .fieldset = HTMLFieldSetElement.init(base) },
        .form => .{ .form = HTMLFormElement.init(base) },
        .frameset => .{ .frameset = HTMLFrameSetElement.init(base) },
        .hr => .{ .hr = HTMLHRElement.init(base) },
        .head => .{ .head = HTMLHeadElement.init(base) },
        .h1, .h2, .h3, .h4, .h5, .h6 => .{ .heading = HTMLHeadingElement.init(base) },
        .html => .{ .html = HTMLHtmlElement.init(base) },
        .iframe => .{ .iframe = HTMLIFrameElement.init(base) },
        .img => .{ .img = HTMLImageElement.init(base) },
        .input => .{ .input = HTMLInputElement.init(base) },
        .li => .{ .li = HTMLLIElement.init(base) },
        .label => .{ .label = HTMLLabelElement.init(base) },
        .legend => .{ .legend = HTMLLegendElement.init(base) },
        .link => .{ .link = HTMLLinkElement.init(base) },
        .map => .{ .map = HTMLMapElement.init(base) },
        .meta => .{ .meta = HTMLMetaElement.init(base) },
        .meter => .{ .meter = HTMLMeterElement.init(base) },
        .ins, .del => .{ .mod = HTMLModElement.init(base) },
        .ol => .{ .olist = HTMLOListElement.init(base) },
        .object => .{ .object = HTMLObjectElement.init(base) },
        .optgroup => .{ .optgroup = HTMLOptGroupElement.init(base) },
        .option => .{ .option = HTMLOptionElement.init(base) },
        .output => .{ .output = HTMLOutputElement.init(base) },
        .p => .{ .paragraph = HTMLParagraphElement.init(base) },
        .picture => .{ .picture = HTMLPictureElement.init(base) },
        .pre => .{ .pre = HTMLPreElement.init(base) },
        .progress => .{ .progress = HTMLProgressElement.init(base) },
        .blockquote, .q => .{ .quote = HTMLQuoteElement.init(base) },
        .script => .{ .script = HTMLScriptElement.init(base) },
        .select => .{ .select = HTMLSelectElement.init(base) },
        .source => .{ .source = HTMLSourceElement.init(base) },
        .span => .{ .span = HTMLSpanElement.init(base) },
        .style => .{ .style = HTMLStyleElement.init(base) },
        .table => .{ .table = HTMLTableElement.init(base) },
        .caption => .{ .tablecaption = HTMLTableCaptionElement.init(base) },
        .th, .td => .{ .tablecell = HTMLTableCellElement.init(base) },
        .col => .{ .tablecol = HTMLTableColElement.init(base) },
        .tr => .{ .tablerow = HTMLTableRowElement.init(base) },
        .thead, .tbody, .tfoot => .{ .tablesection = HTMLTableSectionElement.init(base) },
        .template => .{ .template = HTMLTemplateElement.init(base) },
        .textarea => .{ .textarea = HTMLTextAreaElement.init(base) },
        .time => .{ .time = HTMLTimeElement.init(base) },
        .title => .{ .title = HTMLTitleElement.init(base) },
        .track => .{ .track = HTMLTrackElement.init(base) },
        .ul => .{ .ulist = HTMLUListElement.init(base) },
        .video => .{ .video = HTMLVideoElement.init(base) },
        .undef => .{ .unknown = HTMLUnknownElement.init(base) },
    };
}
