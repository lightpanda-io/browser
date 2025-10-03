const std = @import("std");
const js = @import("js.zig");
const v8 = js.v8;

const Allocator = std.mem.Allocator;

// This only exists so that we know whether a function wants the opaque
// JS argument (js.Object), or if it wants the receiver as an opaque
// value.
// js.Object is normally used when a method wants an opaque JS object
// that it'll pass into a callback.
// This is used when the function wants to do advanced manipulation
// of the v8.Object bound to the instance. For example, postAttach is an
// example of using This.

const This = @This();
obj: js.Object,

pub fn setIndex(self: This, index: u32, value: anytype, opts: js.Object.SetOpts) !void {
    return self.obj.setIndex(index, value, opts);
}

pub fn set(self: This, key: []const u8, value: anytype, opts: js.Object.SetOpts) !void {
    return self.obj.set(key, value, opts);
}
