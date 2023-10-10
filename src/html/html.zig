const generate = @import("../generate.zig");

const HTMLDocument = @import("document.zig").HTMLDocument;
const HTMLElem = @import("elements.zig");

pub const Interfaces = generate.Tuple(.{
    HTMLDocument,
    HTMLElem.HTMLElement,
    HTMLElem.HTMLMediaElement,
    HTMLElem.Interfaces,
});
