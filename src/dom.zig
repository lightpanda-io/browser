const generate = @import("generate.zig");

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
const interfaces = .{
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
    E.HTMLElementsTypes,
};
pub const Interfaces = generate.TupleInst(generate.TupleT(interfaces), interfaces);
