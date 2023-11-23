const generate = @import("../generate.zig");

const DOMException = @import("exceptions.zig").DOMException;
const EventTarget = @import("event_target.zig").EventTarget;
const Nod = @import("node.zig");

pub const Interfaces = generate.Tuple(.{
    DOMException,
    EventTarget,
    Nod.Node,
    Nod.Interfaces,
});
