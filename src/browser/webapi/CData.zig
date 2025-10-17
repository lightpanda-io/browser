const std = @import("std");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
pub const Text = @import("cdata/Text.zig");
pub const Comment = @import("cdata/Comment.zig");

const CData = @This();

_type: Type,
_proto: *Node,
_data: []const u8 = "",

pub const Type = union(enum) {
    text: Text,
    comment: Comment,
};

pub fn asNode(self: *CData) *Node {
    return self._proto;
}

pub fn is(self: *CData, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (f.type == T and @field(Type, f.name) == self._type) {
            return &@field(self._type, f.name);
        }
    }
    return null;
}

pub fn className(self: *const CData) []const u8 {
    return switch (self._type) {
        .text => "[object Text]",
        .comment => "[object Comment]",
    };
}

pub fn getData(self: *const CData) []const u8 {
    return self._data;
}

pub fn setData(self: *CData, value: ?[]const u8, page: *Page) !void {
    if (value) |v| {
        self._data = try page.dupeString(v);
    } else {
        self._data = "";
    }
}

pub fn format(self: *const CData, writer: *std.io.Writer) !void {
    return switch (self._type) {
        .text => writer.print("<text>{s}</text>", .{self._data}),
        .comment => writer.print("<comment>{s}</comment>", .{self._data}),
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CData);

    pub const Meta = struct {
        pub const name = "CData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const data = bridge.accessor(CData.getData, CData.setData, .{});
};
