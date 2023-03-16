const Console = @import("jsruntime").Console;

// DOM
const EventTarget = @import("dom/event_target.zig").EventTarget;
const Node = @import("dom/node.zig").Node;
const Element = @import("dom/element.zig").Element;
const Document = @import("dom/document.zig").Document;

// HTML
pub const HTMLDocument = @import("html/document.zig").HTMLDocument;

const E = @import("html/elements.zig");

// Interfaces
pub const Interfaces = .{
    Console,

    // DOM
    EventTarget,
    Node,
    Element,
    Document,

    // HTML
    HTMLDocument,

    E.HTMLElement,
    E.HTMLMediaElement,

    // TODO: generate HTMLElements comptime
    E.HTMLUnknownElement,
    E.HTMLAnchorElement,
    E.HTMLAreaElement,
    E.HTMLAudioElement,
    E.HTMLBRElement,
    E.HTMLBaseElement,
    E.HTMLBodyElement,
    E.HTMLButtonElement,
    E.HTMLCanvasElement,
    E.HTMLDListElement,
    E.HTMLDialogElement,
    E.HTMLDataElement,
    E.HTMLDivElement,
    E.HTMLEmbedElement,
    E.HTMLFieldSetElement,
    E.HTMLFormElement,
    E.HTMLFrameSetElement,
    E.HTMLHRElement,
    E.HTMLHeadElement,
    E.HTMLHeadingElement,
    E.HTMLHtmlElement,
    E.HTMLIFrameElement,
    E.HTMLImageElement,
    E.HTMLInputElement,
    E.HTMLLIElement,
    E.HTMLLabelElement,
    E.HTMLLegendElement,
    E.HTMLLinkElement,
    E.HTMLMapElement,
    E.HTMLMetaElement,
    E.HTMLMeterElement,
    E.HTMLModElement,
    E.HTMLOListElement,
    E.HTMLObjectElement,
    E.HTMLOptGroupElement,
    E.HTMLOptionElement,
    E.HTMLOutputElement,
    E.HTMLParagraphElement,
    E.HTMLPictureElement,
    E.HTMLPreElement,
    E.HTMLProgressElement,
    E.HTMLQuoteElement,
    E.HTMLScriptElement,
    E.HTMLSelectElement,
    E.HTMLSourceElement,
    E.HTMLSpanElement,
    E.HTMLStyleElement,
    E.HTMLTableElement,
    E.HTMLTableCaptionElement,
    E.HTMLTableCellElement,
    E.HTMLTableColElement,
    E.HTMLTableRowElement,
    E.HTMLTableSectionElement,
    E.HTMLTemplateElement,
    E.HTMLTextAreaElement,
    E.HTMLTimeElement,
    E.HTMLTitleElement,
    E.HTMLTrackElement,
    E.HTMLUListElement,
    E.HTMLVideoElement,
};
