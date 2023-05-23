const parser = @import("../parser.zig");
const generate = @import("../generate.zig");

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
    HTMLDialogElement,
    HTMLDataElement,
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
        .a => .{ .HTMLAnchorElement = HTMLAnchorElement.init(base) },
        .area => .{ .HTMLAreaElement = HTMLAreaElement.init(base) },
        .audio => .{ .HTMLAudioElement = HTMLAudioElement.init(base) },
        .br => .{ .HTMLBRElement = HTMLBRElement.init(base) },
        .base => .{ .HTMLBaseElement = HTMLBaseElement.init(base) },
        .body => .{ .HTMLBodyElement = HTMLBodyElement.init(base) },
        .button => .{ .HTMLButtonElement = HTMLButtonElement.init(base) },
        .canvas => .{ .HTMLCanvasElement = HTMLCanvasElement.init(base) },
        .dl => .{ .HTMLDListElement = HTMLDListElement.init(base) },
        .dialog => .{ .HTMLDialogElement = HTMLDialogElement.init(base) },
        .data => .{ .HTMLDataElement = HTMLDataElement.init(base) },
        .div => .{ .HTMLDivElement = HTMLDivElement.init(base) },
        .embed => .{ .HTMLEmbedElement = HTMLEmbedElement.init(base) },
        .fieldset => .{ .HTMLFieldSetElement = HTMLFieldSetElement.init(base) },
        .form => .{ .HTMLFormElement = HTMLFormElement.init(base) },
        .frameset => .{ .HTMLFrameSetElement = HTMLFrameSetElement.init(base) },
        .hr => .{ .HTMLHRElement = HTMLHRElement.init(base) },
        .head => .{ .HTMLHeadElement = HTMLHeadElement.init(base) },
        .h1, .h2, .h3, .h4, .h5, .h6 => .{ .HTMLHeadingElement = HTMLHeadingElement.init(base) },
        .html => .{ .HTMLHtmlElement = HTMLHtmlElement.init(base) },
        .iframe => .{ .HTMLIFrameElement = HTMLIFrameElement.init(base) },
        .img => .{ .HTMLImageElement = HTMLImageElement.init(base) },
        .input => .{ .HTMLInputElement = HTMLInputElement.init(base) },
        .li => .{ .HTMLLIElement = HTMLLIElement.init(base) },
        .label => .{ .HTMLLabelElement = HTMLLabelElement.init(base) },
        .legend => .{ .HTMLLegendElement = HTMLLegendElement.init(base) },
        .link => .{ .HTMLLinkElement = HTMLLinkElement.init(base) },
        .map => .{ .HTMLMapElement = HTMLMapElement.init(base) },
        .meta => .{ .HTMLMetaElement = HTMLMetaElement.init(base) },
        .meter => .{ .HTMLMeterElement = HTMLMeterElement.init(base) },
        .ins, .del => .{ .HTMLModElement = HTMLModElement.init(base) },
        .ol => .{ .HTMLOListElement = HTMLOListElement.init(base) },
        .object => .{ .HTMLObjectElement = HTMLObjectElement.init(base) },
        .optgroup => .{ .HTMLOptGroupElement = HTMLOptGroupElement.init(base) },
        .option => .{ .HTMLOptionElement = HTMLOptionElement.init(base) },
        .output => .{ .HTMLOutputElement = HTMLOutputElement.init(base) },
        .p => .{ .HTMLParagraphElement = HTMLParagraphElement.init(base) },
        .picture => .{ .HTMLPictureElement = HTMLPictureElement.init(base) },
        .pre => .{ .HTMLPreElement = HTMLPreElement.init(base) },
        .progress => .{ .HTMLProgressElement = HTMLProgressElement.init(base) },
        .blockquote, .q => .{ .HTMLQuoteElement = HTMLQuoteElement.init(base) },
        .script => .{ .HTMLScriptElement = HTMLScriptElement.init(base) },
        .select => .{ .HTMLSelectElement = HTMLSelectElement.init(base) },
        .source => .{ .HTMLSourceElement = HTMLSourceElement.init(base) },
        .span => .{ .HTMLSpanElement = HTMLSpanElement.init(base) },
        .style => .{ .HTMLStyleElement = HTMLStyleElement.init(base) },
        .table => .{ .HTMLTableElement = HTMLTableElement.init(base) },
        .caption => .{ .HTMLTableCaptionElement = HTMLTableCaptionElement.init(base) },
        .th, .td => .{ .HTMLTableCellElement = HTMLTableCellElement.init(base) },
        .col => .{ .HTMLTableColElement = HTMLTableColElement.init(base) },
        .tr => .{ .HTMLTableRowElement = HTMLTableRowElement.init(base) },
        .thead, .tbody, .tfoot => .{ .HTMLTableSectionElement = HTMLTableSectionElement.init(base) },
        .template => .{ .HTMLTemplateElement = HTMLTemplateElement.init(base) },
        .textarea => .{ .HTMLTextAreaElement = HTMLTextAreaElement.init(base) },
        .time => .{ .HTMLTimeElement = HTMLTimeElement.init(base) },
        .title => .{ .HTMLTitleElement = HTMLTitleElement.init(base) },
        .track => .{ .HTMLTrackElement = HTMLTrackElement.init(base) },
        .ul => .{ .HTMLUListElement = HTMLUListElement.init(base) },
        .video => .{ .HTMLVideoElement = HTMLVideoElement.init(base) },
        .undef => .{ .HTMLUnknownElement = HTMLUnknownElement.init(base) },
    };
}
