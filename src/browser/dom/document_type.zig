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

const Node = @import("node.zig").Node;

// WEB IDL https://dom.spec.whatwg.org/#documenttype
pub const DocumentType = struct {
    pub const Self = parser.DocumentType;
    pub const prototype = *Node;

    pub fn get_name(self: *parser.DocumentType) ![]const u8 {
        return try parser.documentTypeGetName(self);
    }

    pub fn get_publicId(self: *parser.DocumentType) ![]const u8 {
        return try parser.documentTypeGetPublicId(self);
    }

    pub fn get_systemId(self: *parser.DocumentType) ![]const u8 {
        return try parser.documentTypeGetSystemId(self);
    }
};
