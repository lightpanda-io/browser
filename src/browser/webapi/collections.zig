pub const NodeLive = @import("collections/node_live.zig").NodeLive;
pub const ChildNodes = @import("collections/ChildNodes.zig");
pub const DOMTokenList = @import("collections/DOMTokenList.zig");
pub const HTMLAllCollection = @import("collections/HTMLAllCollection.zig");

pub fn registerTypes() []const type {
    return &.{
        @import("collections/HTMLCollection.zig"),
        @import("collections/HTMLCollection.zig").Iterator,
        @import("collections/NodeList.zig"),
        @import("collections/NodeList.zig").KeyIterator,
        @import("collections/NodeList.zig").ValueIterator,
        @import("collections/NodeList.zig").EntryIterator,
        @import("collections/HTMLAllCollection.zig"),
        @import("collections/HTMLAllCollection.zig").Iterator,
        DOMTokenList,
        DOMTokenList.Iterator,
    };
}
