const std = @import("std");

const parser = @import("../netsurf.zig");

const CharacterData = @import("character_data.zig").CharacterData;

// https://dom.spec.whatwg.org/#processinginstruction
pub const ProcessingInstruction = struct {
    pub const Self = parser.ProcessingInstruction;
    pub const prototype = *CharacterData;
    pub const mem_guarantied = true;

    pub fn get_target(self: *parser.ProcessingInstruction) ![]const u8 {
        // libdom stores the ProcessingInstruction target in the node's name.
        return try parser.nodeName(@as(*parser.Node, @ptrCast(self)));
    }
};
