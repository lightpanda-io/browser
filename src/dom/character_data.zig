const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const Comment = @import("comment.zig").Comment;
const Text = @import("text.zig").Text;
const HTMLElem = @import("../html/elements.zig");

pub const CharacterData = struct {
    pub const Self = parser.CharacterData;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    // JS funcs
    // --------

    // Read attributes

    pub fn get_length(self: *parser.CharacterData) u32 {
        return parser.characterDataLength(self);
    }

    pub fn get_nextElementSibling(self: *parser.CharacterData) ?HTMLElem.Union {
        const res = parser.nodeNextElementSibling(parser.characterDataToNode(self));
        if (res == null) {
            return null;
        }
        return HTMLElem.toInterface(HTMLElem.Union, res.?);
    }

    pub fn get_previousElementSibling(self: *parser.CharacterData) ?HTMLElem.Union {
        const res = parser.nodePreviousElementSibling(parser.characterDataToNode(self));
        if (res == null) {
            return null;
        }
        return HTMLElem.toInterface(HTMLElem.Union, res.?);
    }

    // Read/Write attributes

    pub fn get_data(self: *parser.CharacterData) []const u8 {
        return parser.characterDataData(self);
    }

    pub fn set_data(self: *parser.CharacterData, data: []const u8) void {
        return parser.characterDataSetData(self, data);
    }

    // JS methods
    // ----------

    pub fn _appendData(self: *parser.CharacterData, data: []const u8) void {
        return parser.characterDataAppendData(self, data);
    }

    pub fn _deleteData(self: *parser.CharacterData, offset: u32, count: u32) void {
        return parser.characterDataDeleteData(self, offset, count);
    }
};

pub const Types = generate.Tuple(.{
    Comment,
    Text,
});
const Generated = generate.Union.compile(Types);
pub const Union = Generated._union;
pub const Tags = Generated._enum;

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {
    var get_data = [_]Case{
        .{ .src = "let link = document.getElementById('link')", .ex = "undefined" },
        .{ .src = "let cdata = link.firstChild", .ex = "undefined" },
        .{ .src = "cdata.data", .ex = "OK" },
    };
    try checkCases(js_env, &get_data);

    var set_data = [_]Case{
        .{ .src = "cdata.data = 'OK modified'", .ex = "OK modified" },
        .{ .src = "cdata.data === 'OK modified'", .ex = "true" },
        .{ .src = "cdata.data = 'OK'", .ex = "OK" },
    };
    try checkCases(js_env, &set_data);

    var get_length = [_]Case{
        .{ .src = "cdata.length === 2", .ex = "true" },
    };
    try checkCases(js_env, &get_length);

    var get_next_elem_sibling = [_]Case{
        .{ .src = "cdata.nextElementSibling === null", .ex = "true" },
        // create a next element
        .{ .src = "let next = document.createElement('a')", .ex = "undefined" },
        .{ .src = "link.appendChild(next, cdata) !== undefined", .ex = "true" },
        .{ .src = "cdata.nextElementSibling.localName === 'a' ", .ex = "true" },
    };
    try checkCases(js_env, &get_next_elem_sibling);

    var get_prev_elem_sibling = [_]Case{
        .{ .src = "cdata.previousElementSibling === null", .ex = "true" },
        // create a prev element
        .{ .src = "let prev = document.createElement('div')", .ex = "undefined" },
        .{ .src = "link.insertBefore(prev, cdata) !== undefined", .ex = "true" },
        .{ .src = "cdata.previousElementSibling.localName === 'div' ", .ex = "true" },
    };
    try checkCases(js_env, &get_prev_elem_sibling);

    var append_data = [_]Case{
        .{ .src = "cdata.appendData(' modified')", .ex = "undefined" },
        .{ .src = "cdata.data === 'OK modified' ", .ex = "true" },
    };
    try checkCases(js_env, &append_data);

    var delete_data = [_]Case{
        .{ .src = "cdata.deleteData('OK'.length, ' modified'.length)", .ex = "undefined" },
        .{ .src = "cdata.data", .ex = "OK" },
    };
    try checkCases(js_env, &delete_data);
}
