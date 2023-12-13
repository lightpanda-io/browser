const std = @import("std");

const parser = @import("../netsurf.zig");

// https://dom.spec.whatwg.org/#processinginstruction
pub const ProcessingInstruction = struct {
    pub const Self = parser.ProcessingInstruction;

    // TODO for libdom processing instruction inherit from node.
    // But the spec says it must inherit from CDATA.
    // Moreover, inherit from Node causes also a crash with cloneNode.
    // https://github.com/lightpanda-io/browsercore/issues/123
    //
    // In consequence, for now, we don't implement all these func for
    // ProcessingInstruction.
    //
    //pub const prototype = *CharacterData;

    pub const mem_guarantied = true;

    pub fn get_target(self: *parser.ProcessingInstruction) ![]const u8 {
        // libdom stores the ProcessingInstruction target in the node's name.
        return try parser.nodeName(@as(*parser.Node, @ptrCast(self)));
    }
};
