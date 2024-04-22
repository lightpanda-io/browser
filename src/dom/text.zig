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

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const parser = @import("../netsurf.zig");

const CharacterData = @import("character_data.zig").CharacterData;
const CDATASection = @import("cdata_section.zig").CDATASection;

const UserContext = @import("../user_context.zig").UserContext;

// Text interfaces
pub const Interfaces = generate.Tuple(.{
    CDATASection,
});

pub const Text = struct {
    pub const Self = parser.Text;
    pub const prototype = *CharacterData;
    pub const mem_guarantied = true;

    pub fn constructor(userctx: UserContext, data: ?[]const u8) !*parser.Text {
        if (userctx.document == null) return parser.DOMError.NotSupported;

        return parser.documentCreateTextNode(
            parser.documentHTMLToDocument(userctx.document.?),
            data orelse "",
        );
    }

    // JS funcs
    // --------

    // Read attributes

    pub fn get_wholeText(self: *parser.Text) ![]const u8 {
        return try parser.textWholdeText(self);
    }

    // JS methods
    // ----------

    pub fn _splitText(self: *parser.Text, offset: u32) !*parser.Text {
        return try parser.textSplitText(self, offset);
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var constructor = [_]Case{
        .{ .src = "let t = new Text('foo')", .ex = "undefined" },
        .{ .src = "t.data", .ex = "foo" },

        .{ .src = "let emptyt = new Text()", .ex = "undefined" },
        .{ .src = "emptyt.data", .ex = "" },
    };
    try checkCases(js_env, &constructor);

    var get_whole_text = [_]Case{
        .{ .src = "let text = document.getElementById('link').firstChild", .ex = "undefined" },
        .{ .src = "text.wholeText === 'OK'", .ex = "true" },
    };
    try checkCases(js_env, &get_whole_text);

    var split_text = [_]Case{
        .{ .src = "text.data = 'OK modified'", .ex = "OK modified" },
        .{ .src = "let split = text.splitText('OK'.length)", .ex = "undefined" },
        .{ .src = "split.data === ' modified'", .ex = "true" },
        .{ .src = "text.data === 'OK'", .ex = "true" },
    };
    try checkCases(js_env, &split_text);
}
