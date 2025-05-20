// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const parser = @import("../netsurf.zig");

const CharacterData = @import("character_data.zig").CharacterData;

const SessionState = @import("../env.zig").SessionState;

// https://dom.spec.whatwg.org/#interface-comment
pub const Comment = struct {
    pub const Self = parser.Comment;
    pub const prototype = *CharacterData;
    pub const subtype = .node;

    pub fn constructor(data: ?[]const u8, state: *const SessionState) !*parser.Comment {
        return parser.documentCreateComment(
            parser.documentHTMLToDocument(state.window.document),
            data orelse "",
        );
    }
};

// Tests
// -----

const testing = @import("../../testing.zig");
test "Browser.DOM.Comment" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let comment = new Comment('foo')", "undefined" },
        .{ "comment.data", "foo" },

        .{ "let emptycomment = new Comment()", "undefined" },
        .{ "emptycomment.data", "" },
    }, .{});
}
