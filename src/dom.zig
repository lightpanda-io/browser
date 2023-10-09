const generate = @import("generate.zig");

const Console = @import("jsruntime").Console;

const DOM = @import("dom/dom.zig");
const HTML = @import("html/html.zig");

pub const HTMLDocument = @import("html/document.zig").HTMLDocument;

// Interfaces
pub const Interfaces = generate.Tuple(.{
    Console,
    DOM.Interfaces,
    HTML.Interfaces,
});
