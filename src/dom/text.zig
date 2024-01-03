const std = @import("std");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const parser = @import("../netsurf.zig");

const CharacterData = @import("character_data.zig").CharacterData;
const CDATASection = @import("cdata_section.zig").CDATASection;

// Text interfaces
pub const Interfaces = generate.Tuple(.{
    CDATASection,
});

pub const Text = struct {
    pub const Self = parser.Text;
    pub const prototype = *CharacterData;
    pub const mem_guarantied = true;

    // TODO add constructor, but I need to associate the new Text
    // with the current document global object...
    // > The new Text(data) constructor steps are to set this’s data to data
    // > and this’s node document to current global object’s associated
    // > Document.
    // https://dom.spec.whatwg.org/#dom-text-text
    pub fn constructor() !*parser.Comment {
        return error.NotImplemented;
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
    comptime _: []jsruntime.API,
) !void {
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
