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
//
const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const DOMError = @import("netsurf").DOMError;

const parser = @import("netsurf");
const dump = @import("../browser/dump.zig");

pub const Interfaces = generate.Tuple(.{
    XMLSerializer,
});

// https://w3c.github.io/DOM-Parsing/#dom-xmlserializer-constructor
pub const XMLSerializer = struct {
    pub const mem_guarantied = true;

    pub fn constructor() !XMLSerializer {
        return .{};
    }

    pub fn deinit(_: *XMLSerializer, _: std.mem.Allocator) void {}

    pub fn _serializeToString(_: XMLSerializer, alloc: std.mem.Allocator, root: *parser.Node) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        if (try parser.nodeType(root) == .document) {
            try dump.writeHTML(@as(*parser.Document, @ptrCast(root)), buf.writer());
        } else {
            try dump.writeNode(root, buf.writer());
        }
        // TODO express the caller owned the slice.
        // https://github.com/lightpanda-io/jsruntime-lib/issues/195
        return try buf.toOwnedSlice();
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var serializer = [_]Case{
        .{ .src = "const s = new XMLSerializer()", .ex = "undefined" },
        .{ .src = "s.serializeToString(document.getElementById('para'))", .ex = "<p id=\"para\"> And</p>" },
    };
    try checkCases(js_env, &serializer);
}
