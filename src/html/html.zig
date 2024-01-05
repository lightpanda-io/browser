const generate = @import("../generate.zig");

const HTMLDocument = @import("document.zig").HTMLDocument;
const HTMLElem = @import("elements.zig");
const Window = @import("window.zig").Window;

pub const Interfaces = generate.Tuple(.{
    HTMLDocument,
    HTMLElem.HTMLElement,
    HTMLElem.HTMLMediaElement,
    HTMLElem.Interfaces,
    Window,
});
