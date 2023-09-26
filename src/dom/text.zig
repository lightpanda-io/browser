const parser = @import("../netsurf.zig");

const CharacterData = @import("character_data.zig").CharacterData;

pub const Text = struct {
    pub const Self = parser.Text;
    pub const prototype = *CharacterData;
    pub const mem_guarantied = true;
};
