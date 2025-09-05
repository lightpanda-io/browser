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

// https://developer.mozilla.org/en-US/docs/Web/API/DOMParser
pub const DOMParser = struct {
    pub fn constructor() !DOMParser {
        return .{};
    }

    pub fn _parseFromString(_: *DOMParser, string: []const u8, mime_type: []const u8) !*parser.DocumentHTML {
        if (!std.mem.eql(u8, mime_type, "text/html")) {
            // TODO: Support XML
            return error.TypeError;
        }

        return try parser.documentHTMLParseFromStr(string);
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.Parser" {
    try testing.htmlRunner("dom/dom_parser.html");
}
