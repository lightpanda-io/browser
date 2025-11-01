const std = @import("std");
const Node = @import("webapi/Node.zig");

pub const Opts = struct {
    // @ZIGDOM (none of these do anything)
    with_base: bool = false,
    strip_mode: StripMode = .{},

    pub const StripMode = struct {
        js: bool = false,
        ui: bool = false,
        css: bool = false,
    };
};

pub fn deep(node: *Node, opts: Opts, writer: *std.Io.Writer) error{WriteFailed}!void {
    switch (node._type) {
        .cdata => |cd| try writer.writeAll(cd.getData()),
        .element => |el| {
            try el.format(writer);
            try children(node, opts, writer);
            if (!isVoidElement(el)) {
                try writer.writeAll("</");
                try writer.writeAll(el.getTagNameDump());
                try writer.writeByte('>');
            }
        },
        .document => try children(node, opts, writer),
        .document_type => {},
        .document_fragment => try children(node, opts, writer),
        .attribute => unreachable,
    }
}

pub fn children(parent: *Node, opts: Opts, writer: *std.Io.Writer) !void {
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        try deep(child, opts, writer);
    }
}

pub fn toJSON(node: *Node, writer: *std.json.Stringify) !void {
    try writer.beginObject();

    try writer.objectField("type");
    switch (node.type) {
        .cdata => {
            try writer.write("cdata");
        },
        .document => {
            try writer.write("document");
        },
        .document_type => {
            try writer.write("document_type");
        },
        .element => |*el| {
            try writer.write("element");
            try writer.objectField("tag");
            try writer.write(el.tagName());

            try writer.objectField("attributes");
            try writer.beginObject();
            var it = el.attributeIterator();
            while (it.next()) |attr| {
                try writer.objectField(attr.name);
                try writer.write(attr.value);
            }
            try writer.endObject();
        },
    }

    try writer.objectField("children");
    try writer.beginArray();
    var it = node.childrenIterator();
    while (it.next()) |child| {
        try toJSON(child, writer);
    }
    try writer.endArray();
    try writer.endObject();
}

fn isVoidElement(el: *const Node.Element) bool {
    return switch (el._type) {
        .html => |html| switch (html._type) {
            .br, .hr, .img, .input, .link, .meta => true,
            else => false,
        },
        .svg => false,
    };
}
