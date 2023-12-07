const std = @import("std");

const parser = @import("../netsurf.zig");

const CharacterData = @import("character_data.zig").CharacterData;

// https://dom.spec.whatwg.org/#processinginstruction
pub const ProcessingInstruction = struct {
    pub const Self = parser.ProcessingInstruction;
    pub const prototype = *CharacterData;
    pub const mem_guarantied = true;

    // TODO implement get_target
};
