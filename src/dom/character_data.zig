const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const parser = @import("../netsurf.zig");

const Node = @import("node.zig").Node;
const Comment = @import("comment.zig").Comment;
const Text = @import("text.zig").Text;

pub const CharacterData = struct {
    pub const Self = parser.CharacterData;
    pub const prototype = *Node;
    pub const mem_guarantied = true;

    // JS funcs
    // --------

    // Read/Write attributes

    pub fn get_data(self: *parser.CharacterData) []const u8 {
        return parser.characterDataData(self);
    }

    pub fn set_data(self: *parser.CharacterData, data: []const u8) void {
        return parser.characterDataSetData(self, data);
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
        .{ .src = "let cdata_t = document.getElementById('link').firstChild", .ex = "undefined" },
        .{ .src = "cdata_t.data", .ex = "OK" },
    };
    try checkCases(js_env, &get_data);

    var set_data = [_]Case{
        .{ .src = "cdata_t.data = 'OK modified'", .ex = "OK modified" },
        .{ .src = "cdata_t.data === 'OK modified'", .ex = "true" },
        .{ .src = "cdata_t.data = 'OK'", .ex = "OK" },
    };
    try checkCases(js_env, &set_data);
}
