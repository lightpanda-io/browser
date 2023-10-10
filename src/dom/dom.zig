const generate = @import("../generate.zig");

const EventTarget = @import("event_target.zig").EventTarget;
const Nod = @import("node.zig");

pub const Interfaces = generate.Tuple(.{
    EventTarget,
    Nod.Node,
    Nod.Interfaces,
});
