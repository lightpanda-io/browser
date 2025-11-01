const std = @import("std");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Node = @import("Node.zig");
const DocumentType = @import("DocumentType.zig");

const DOMImplementation = @This();

pub fn createDocumentType(_: *const DOMImplementation, qualified_name: []const u8, public_id: ?[]const u8, system_id: ?[]const u8, page: *Page) !*DocumentType {
    const name = try page.dupeString(qualified_name);
    const pub_id = try page.dupeString(public_id orelse "");
    const sys_id = try page.dupeString(system_id orelse "");

    const doctype = try page._factory.node(DocumentType{
        ._proto = undefined,
        ._name = name,
        ._public_id = pub_id,
        ._system_id = sys_id,
    });

    return doctype;
}

pub fn hasFeature(_: *const DOMImplementation, _: []const u8, _: ?[]const u8) bool {
    // Modern DOM spec says this should always return true
    // This method is deprecated and kept for compatibility only
    return true;
}

pub fn className(_: *const DOMImplementation) []const u8 {
    return "[object DOMImplementation]";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMImplementation);

    pub const Meta = struct {
        pub const name = "DOMImplementation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const createDocumentType = bridge.function(DOMImplementation.createDocumentType, .{ .dom_exception = true });
    pub const hasFeature = bridge.function(DOMImplementation.hasFeature, .{});

    pub const toString = bridge.function(_toString, .{});
    fn _toString(_: *const DOMImplementation) []const u8 {
        return "[object DOMImplementation]";
    }
};

const testing = @import("../../testing.zig");
test "WebApi: DOMImplementation" {
    try testing.htmlRunner("domimplementation.html", .{});
}
