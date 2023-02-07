const std = @import("std");

const runtime = @import("jsruntime");

const EventTarget = @import("dom/event_target.zig").EventTarget;
const Node = @import("dom/node.zig").Node;
const Document = @import("dom/document.zig").Document;

pub fn main() !void {

    // // generate APIs
    // _ = comptime runtime.compile(.{ EventTarget, Node, Document });

    // // create v8 vm
    // const vm = runtime.VM.init();
    // defer vm.deinit();

    // // document
    // var doc = Document.init();
    // defer doc.deinit();
    // var html: []const u8 = "<div><a href='foo'>OK</a><p>blah-blah-blah</p></div>";
    // try doc.parse(html);

    // try doc.proto.make_tree();

    std.debug.print("ok\n", .{});
}
