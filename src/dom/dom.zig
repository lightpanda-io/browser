const generate = @import("../generate.zig");

const DOMException = @import("exceptions.zig").DOMException;
const EventTarget = @import("event_target.zig").EventTarget;
const DOMImplementation = @import("implementation.zig").DOMImplementation;
const NamedNodeMap = @import("namednodemap.zig").NamedNodeMap;
const DOMTokenList = @import("token_list.zig").DOMTokenList;
const Nod = @import("node.zig");

pub const Interfaces = generate.Tuple(.{
    DOMException,
    EventTarget,
    DOMImplementation,
    NamedNodeMap,
    DOMTokenList,
    Nod.Node,
    Nod.Interfaces,
});
