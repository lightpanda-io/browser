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

const c = @cImport({
    @cInclude("lexbor/html/html.h");
});

pub fn ElementToHTMLElementInterface(base: *parser.Element) HTMLElements {
    return switch (base.*.node.local_name) {
        c.LXB_TAG_A => .{ .anchor = HTMLAnchorElement.init(base) },
        c.LXB_TAG_AREA => .{ .area = HTMLAreaElement.init(base) },
        c.LXB_TAG_AUDIO => .{ .audio = HTMLAudioElement.init(base) },
        c.LXB_TAG_BR => .{ .br = HTMLBRElement.init(base) },
        c.LXB_TAG_BASE => .{ .base = HTMLBaseElement.init(base) },
        c.LXB_TAG_BODY => .{ .body = HTMLBodyElement.init(base) },
        c.LXB_TAG_BUTTON => .{ .button = HTMLButtonElement.init(base) },
        c.LXB_TAG_CANVAS => .{ .canvas = HTMLCanvasElement.init(base) },
        c.LXB_TAG_DL => .{ .dlist = HTMLDListElement.init(base) },
        c.LXB_TAG_DIALOG => .{ .dialog = HTMLDialogElement.init(base) },
        c.LXB_TAG_DATA => .{ .data = HTMLDataElement.init(base) },
        c.LXB_TAG_DIV => .{ .div = HTMLDivElement.init(base) },
        c.LXB_TAG_EMBED => .{ .embed = HTMLEmbedElement.init(base) },
        c.LXB_TAG_FIELDSET => .{ .fieldset = HTMLFieldSetElement.init(base) },
        c.LXB_TAG_FORM => .{ .form = HTMLFormElement.init(base) },
        c.LXB_TAG_FRAMESET => .{ .frameset = HTMLFrameSetElement.init(base) },
        c.LXB_TAG_HR => .{ .hr = HTMLHRElement.init(base) },
        c.LXB_TAG_HEAD => .{ .head = HTMLHeadElement.init(base) },
        c.LXB_TAG_H1 => .{ .heading = HTMLHeadingElement.init(base) },
        c.LXB_TAG_H2 => .{ .heading = HTMLHeadingElement.init(base) },
        c.LXB_TAG_H3 => .{ .heading = HTMLHeadingElement.init(base) },
        c.LXB_TAG_H4 => .{ .heading = HTMLHeadingElement.init(base) },
        c.LXB_TAG_H5 => .{ .heading = HTMLHeadingElement.init(base) },
        c.LXB_TAG_H6 => .{ .heading = HTMLHeadingElement.init(base) },
        c.LXB_TAG_HTML => .{ .html = HTMLHtmlElement.init(base) },
        c.LXB_TAG_IFRAME => .{ .iframe = HTMLIFrameElement.init(base) },
        c.LXB_TAG_IMG => .{ .img = HTMLImageElement.init(base) },
        c.LXB_TAG_INPUT => .{ .input = HTMLInputElement.init(base) },
        c.LXB_TAG_LI => .{ .li = HTMLLIElement.init(base) },
        c.LXB_TAG_LABEL => .{ .label = HTMLLabelElement.init(base) },
        c.LXB_TAG_LEGEND => .{ .legend = HTMLLegendElement.init(base) },
        c.LXB_TAG_LINK => .{ .link = HTMLLinkElement.init(base) },
        c.LXB_TAG_MAP => .{ .map = HTMLMapElement.init(base) },
        c.LXB_TAG_META => .{ .meta = HTMLMetaElement.init(base) },
        c.LXB_TAG_METER => .{ .meter = HTMLMeterElement.init(base) },
        c.LXB_TAG_INS => .{ .mod = HTMLModElement.init(base) },
        c.LXB_TAG_DEL => .{ .mod = HTMLModElement.init(base) },
        c.LXB_TAG_OL => .{ .olist = HTMLOListElement.init(base) },
        c.LXB_TAG_OBJECT => .{ .object = HTMLObjectElement.init(base) },
        c.LXB_TAG_OPTGROUP => .{ .optgroup = HTMLOptGroupElement.init(base) },
        c.LXB_TAG_OPTION => .{ .option = HTMLOptionElement.init(base) },
        c.LXB_TAG_OUTPUT => .{ .output = HTMLOutputElement.init(base) },
        c.LXB_TAG_P => .{ .paragraph = HTMLParagraphElement.init(base) },
        c.LXB_TAG_PICTURE => .{ .picture = HTMLPictureElement.init(base) },
        c.LXB_TAG_PRE => .{ .pre = HTMLPreElement.init(base) },
        c.LXB_TAG_PROGRESS => .{ .progress = HTMLProgressElement.init(base) },
        c.LXB_TAG_BLOCKQUOTE => .{ .quote = HTMLQuoteElement.init(base) },
        c.LXB_TAG_Q => .{ .quote = HTMLQuoteElement.init(base) },
        c.LXB_TAG_SCRIPT => .{ .script = HTMLScriptElement.init(base) },
        c.LXB_TAG_SELECT => .{ .select = HTMLSelectElement.init(base) },
        c.LXB_TAG_SOURCE => .{ .source = HTMLSourceElement.init(base) },
        c.LXB_TAG_SPAN => .{ .span = HTMLSpanElement.init(base) },
        c.LXB_TAG_STYLE => .{ .style = HTMLStyleElement.init(base) },
        c.LXB_TAG_TABLE => .{ .table = HTMLTableElement.init(base) },
        c.LXB_TAG_CAPTION => .{ .tablecaption = HTMLTableCaptionElement.init(base) },
        c.LXB_TAG_TH => .{ .tablecell = HTMLTableCellElement.init(base) },
        c.LXB_TAG_TD => .{ .tablecell = HTMLTableCellElement.init(base) },
        c.LXB_TAG_COL => .{ .tablecol = HTMLTableColElement.init(base) },
        c.LXB_TAG_TR => .{ .tablerow = HTMLTableRowElement.init(base) },
        c.LXB_TAG_THEAD => .{ .tablesection = HTMLTableSectionElement.init(base) },
        c.LXB_TAG_TBODY => .{ .tablesection = HTMLTableSectionElement.init(base) },
        c.LXB_TAG_TFOOT => .{ .tablesection = HTMLTableSectionElement.init(base) },
        c.LXB_TAG_TEMPLATE => .{ .template = HTMLTemplateElement.init(base) },
        c.LXB_TAG_TEXTAREA => .{ .textarea = HTMLTextAreaElement.init(base) },
        c.LXB_TAG_TIME => .{ .time = HTMLTimeElement.init(base) },
        c.LXB_TAG_TITLE => .{ .title = HTMLTitleElement.init(base) },
        c.LXB_TAG_TRACK => .{ .track = HTMLTrackElement.init(base) },
        c.LXB_TAG_UL => .{ .ulist = HTMLUListElement.init(base) },
        c.LXB_TAG_VIDEO => .{ .video = HTMLVideoElement.init(base) },
        c.LXB_TAG__UNDEF => .{ .unknown = HTMLUnknownElement.init(base) },
        else => .{ .unknown = HTMLUnknownElement.init(base) },
    };
}
