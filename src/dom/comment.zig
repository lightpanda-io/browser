const parser = @import("../netsurf.zig");

const CharacterData = @import("character_data.zig").CharacterData;

pub const Comment = struct {
    pub const Self = parser.Comment;
    pub const prototype = *CharacterData;
    pub const mem_guarantied = true;
};
