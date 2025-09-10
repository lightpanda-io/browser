// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

// https://w3c.github.io/FileAPI/#file-section
const File = @This();

// Very incomplete. The prototype for this is Blob, which we don't have.
// This minimum "implementation" is added because some JavaScript code just
// checks: if (x instanceof File) throw Error(...)
pub fn constructor() File {
    return .{};
}

const testing = @import("../../testing.zig");
test "Browser: File" {
    try testing.htmlRunner("xhr/file.html");
}
