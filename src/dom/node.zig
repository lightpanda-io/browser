const std = @import("std");

const generate = @import("../generate.zig");

const parser = @import("../netsurf.zig");

const EventTarget = @import("event_target.zig").EventTarget;
const HTMLDocument = @import("../html/document.zig").HTMLDocument;
const HTMLElem = @import("../html/elements.zig");

pub const Node = struct {
    pub const Self = parser.Node;
    pub const prototype = *EventTarget;
    pub const mem_guarantied = true;
};

pub const Types = generate.Tuple(.{
    HTMLElem.Types,
    HTMLDocument,
});
const Generated = generate.Union.compile(Types);
pub const Union = Generated._union;
pub const Tags = Generated._enum;
