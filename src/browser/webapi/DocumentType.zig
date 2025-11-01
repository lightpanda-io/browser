const std = @import("std");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Node = @import("Node.zig");

const DocumentType = @This();

_proto: *Node,
_name: []const u8,
_public_id: []const u8,
_system_id: []const u8,

pub fn asNode(self: *DocumentType) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *DocumentType) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn getName(self: *const DocumentType) []const u8 {
    return self._name;
}

pub fn getPublicId(self: *const DocumentType) []const u8 {
    return self._public_id;
}

pub fn getSystemId(self: *const DocumentType) []const u8 {
    return self._system_id;
}

pub fn className(_: *const DocumentType) []const u8 {
    return "[object DocumentType]";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DocumentType);

    pub const Meta = struct {
        pub const name = "DocumentType";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const name = bridge.accessor(DocumentType.getName, null, .{});
    pub const publicId = bridge.accessor(DocumentType.getPublicId, null, .{});
    pub const systemId = bridge.accessor(DocumentType.getSystemId, null, .{});

    pub const toString = bridge.function(_toString, .{});
    fn _toString(self: *const DocumentType) []const u8 {
        return self.className();
    }
};

const testing = @import("../../testing.zig");
test "WebApi: DOMImplementation" {
    try testing.htmlRunner("domimplementation.html", .{});
}
