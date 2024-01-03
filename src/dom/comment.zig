const parser = @import("../netsurf.zig");

const CharacterData = @import("character_data.zig").CharacterData;

// https://dom.spec.whatwg.org/#interface-comment
pub const Comment = struct {
    pub const Self = parser.Comment;
    pub const prototype = *CharacterData;
    pub const mem_guarantied = true;

    // TODO add constructor, but I need to associate the new Comment
    // with the current document global object...
    // > The new Comment(data) constructor steps are to set this’s data to data
    // > and this’s node document to current global object’s associated
    // > Document.
    // https://dom.spec.whatwg.org/#dom-comment-comment
    pub fn constructor() !*parser.Comment {
        return error.NotImplemented;
    }
};
