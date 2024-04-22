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
const std = @import("std");

const parser = @import("../netsurf.zig");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const CharacterData = @import("character_data.zig").CharacterData;

const UserContext = @import("../user_context.zig").UserContext;

// https://dom.spec.whatwg.org/#interface-comment
pub const Comment = struct {
    pub const Self = parser.Comment;
    pub const prototype = *CharacterData;
    pub const mem_guarantied = true;

    pub fn constructor(userctx: UserContext, data: ?[]const u8) !*parser.Comment {
        if (userctx.document == null) return parser.DOMError.NotSupported;

        return parser.documentCreateComment(
            parser.documentHTMLToDocument(userctx.document.?),
            data orelse "",
        );
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var constructor = [_]Case{
        .{ .src = "let comment = new Comment('foo')", .ex = "undefined" },
        .{ .src = "comment.data", .ex = "foo" },

        .{ .src = "let emptycomment = new Comment()", .ex = "undefined" },
        .{ .src = "emptycomment.data", .ex = "" },
    };
    try checkCases(js_env, &constructor);
}
