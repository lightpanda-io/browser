const generate = @import("../generate.zig");
const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const Comment = @import("comment.zig").Comment;
const Text = @import("text.zig").Text;

pub const CharacterData = struct {
    pub const Self = parser.CharacterData;
    pub const prototype = *Node;
    pub const mem_guarantied = true;
};

pub const Types = generate.Tuple(.{
    Comment,
    Text,
});
const Generated = generate.Union.compile(Types);
pub const Union = Generated._union;
pub const Tags = Generated._enum;
