const Console = @import("jsruntime").Console;

pub const EventTarget = @import("dom/event_target.zig").EventTarget;
pub const Node = @import("dom/node.zig").Node;

pub const Element = @import("dom/element.zig").Element;
pub const HTMLElement = @import("dom/element.zig").HTMLElement;
pub const HTMLBodyElement = @import("dom/element.zig").HTMLBodyElement;

pub const Document = @import("dom/document.zig").Document;
pub const HTMLDocument = @import("dom/document.zig").HTMLDocument;

pub const Interfaces = .{
    Console,
    EventTarget,
    Node,

    Element,
    HTMLElement,
    HTMLBodyElement,

    Document,
    HTMLDocument,
};
