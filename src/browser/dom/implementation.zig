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
const DOMException = @import("exceptions.zig").DOMException;

// WEB IDL https://dom.spec.whatwg.org/#domimplementation
pub const DOMImplementation = struct {
    pub const Exception = DOMException;

    pub fn _createDocumentType(
        _: *DOMImplementation,
        qname: [:0]const u8,
        publicId: [:0]const u8,
        systemId: [:0]const u8,
    ) !*parser.DocumentType {
        return try parser.domImplementationCreateDocumentType(qname, publicId, systemId);
    }

    pub fn _createDocument(
        _: *DOMImplementation,
        namespace: ?[:0]const u8,
        qname: ?[:0]const u8,
        doctype: ?*parser.DocumentType,
    ) !*parser.Document {
        return try parser.domImplementationCreateDocument(namespace, qname, doctype);
    }

    pub fn _createHTMLDocument(_: *DOMImplementation, title: ?[]const u8) !*parser.DocumentHTML {
        return try parser.domImplementationCreateHTMLDocument(title);
    }

    pub fn _hasFeature(_: *DOMImplementation) bool {
        return true;
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.Implementation" {
    try testing.htmlRunner("dom/implementation.html");
}
