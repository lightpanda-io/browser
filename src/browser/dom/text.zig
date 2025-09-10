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
const Page = @import("../page.zig").Page;

const CharacterData = @import("character_data.zig").CharacterData;
const CDATASection = @import("cdata_section.zig").CDATASection;

// Text interfaces
pub const Interfaces = .{
    CDATASection,
};

pub const Text = struct {
    pub const Self = parser.Text;
    pub const prototype = *CharacterData;
    pub const subtype = .node;

    pub fn constructor(data: ?[]const u8, page: *const Page) !*parser.Text {
        return parser.documentCreateTextNode(
            parser.documentHTMLToDocument(page.window.document),
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

const testing = @import("../../testing.zig");
test "Browser: DOM.Text" {
    try testing.htmlRunner("dom/text.html");
}
