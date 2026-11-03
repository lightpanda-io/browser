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

const std = @import("std");
const js = @import("../js/js.zig");

const Frame = @import("../Frame.zig");
const Node = @import("Node.zig");
const Element = Node.Element;
const Template = @import("element/html/Template.zig");
const dump = @import("../dump.zig");

const XMLSerializer = @This();

// Padding to avoid zero-size struct, which causes identity_map pointer collisions.
_pad: bool = false,

pub fn init() XMLSerializer {
    return .{};
}

fn serializeToString(self: *const XMLSerializer, node: *Node, frame: *Frame) ![]const u8 {
    _ = self;
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    var walk: Walk = .{ .writer = &buf.writer, .frame = frame };
    try walk.visit(node, null);
    try walk.run();
    return buf.written();
}

// Very large trees can stackoverflow, hence the iterative walk.
const Walk = struct {
    writer: *std.Io.Writer,
    frame: *Frame,
    stack: std.ArrayList(Open) = .empty,

    const Open = struct {
        // null for a document or fragment, which have no tags
        el: ?*Element,
        next: ?*Node,
        // The default namespace its children inherit
        ns: ?[]const u8,
    };

    fn run(self: *Walk) !void {
        while (self.stack.items.len > 0) {
            // The cursor advances before visit(), which can grow (move) the stack.
            const top = &self.stack.items[self.stack.items.len - 1];
            if (top.next) |n| {
                top.next = n.nextSibling();
                try self.visit(n, top.ns);
                continue;
            }
            const done = self.stack.pop().?;
            if (done.el) |el| {
                try self.writer.print("</{s}>", .{el.getTagNameDump()});
            }
        }
    }

    fn open(self: *Walk, el: ?*Element, first: ?*Node, ns: ?[]const u8) !void {
        return self.stack.append(self.frame.local_arena, .{ .el = el, .next = first, .ns = ns });
    }

    fn visit(self: *Walk, node: *Node, inherited_ns: ?[]const u8) !void {
        const writer = self.writer;
        switch (node._type) {
            .cdata => {
                const cd = node.subtype(Node.CData);
                const data = cd.getData().str();
                if (node.is(Node.CData.ProcessingInstruction)) |pi| {
                    try writer.print("<?{s} {s}?>", .{ pi._target, data });
                } else switch (cd._type) {
                    .comment => try writer.print("<!--{s}-->", .{data}),
                    .cdata_section => try writer.print("<![CDATA[{s}]]>", .{data}),
                    else => try writeEscaped(data, false, writer),
                }
            },
            .element => try self.visitElement(node.subtype(Element), inherited_ns),
            .document, .document_fragment => try self.open(null, node.firstChild(), inherited_ns),
            .document_type => {
                const dt = node.subtype(Node.DocumentType);
                try writer.print("<!DOCTYPE {s}", .{dt.getName()});
                const public_id = dt.getPublicId();
                const system_id = dt.getSystemId();
                if (public_id.len != 0) {
                    try writer.print(" PUBLIC \"{s}\"", .{public_id});
                }
                if (system_id.len != 0) {
                    if (public_id.len == 0) try writer.writeAll(" SYSTEM");
                    try writer.print(" \"{s}\"", .{system_id});
                }
                try writer.writeByte('>');
            },
            // Serializes to an empty string
            .attribute => {},
        }
    }

    fn visitElement(self: *Walk, el: *Element, inherited_ns: ?[]const u8) !void {
        const writer = self.writer;
        const name = el.getTagNameDump();
        const ns = el.getNamespaceUri(self.frame);
        try writer.print("<{s}", .{name});

        var default_ns = inherited_ns;
        if (prefixOf(el)) |prefix| {
            if (ns != null and !self.prefixDeclared(prefix, ns) and !hasAttribute(el, "xmlns:", prefix)) {
                try writer.print(" xmlns:{s}=\"", .{prefix});
                try writeEscaped(ns.?, true, writer);
                try writer.writeByte('"');
            }
        } else {
            if (!eqlNamespace(ns, inherited_ns) and !hasAttribute(el, "xmlns", "")) {
                try writer.writeAll(" xmlns=\"");
                try writeEscaped(ns orelse "", true, writer);
                try writer.writeByte('"');
            }
            default_ns = ns;
        }

        for (el.attributeEntries()) |*attr| {
            try writer.print(" {s}=\"", .{attr.name()});
            try writeEscaped(attr.value(), true, writer);
            try writer.writeByte('"');
        }

        // A template serializes its contents, not its own children.
        const content_root = if (el.is(Template)) |template| template.getContent().asNode() else el.asNode();
        if (content_root.firstChild()) |first| {
            try writer.writeByte('>');
            return self.open(el, first, default_ns);
        }

        if (dump.isVoidElement(el)) {
            try writer.writeAll(" />");
        } else if (el._namespace == .html) {
            try writer.print("></{s}>", .{name});
        } else {
            try writer.writeAll("/>");
        }
    }

    // Whether an element being written already declares this prefix.
    fn prefixDeclared(self: *const Walk, prefix: []const u8, ns: ?[]const u8) bool {
        for (self.stack.items) |item| {
            const el = item.el orelse continue;
            const other = prefixOf(el) orelse continue;
            if (std.mem.eql(u8, other, prefix) and eqlNamespace(el.getNamespaceUri(self.frame), ns)) {
                return true;
            }
        }
        return false;
    }
};

fn prefixOf(el: *const Element) ?[]const u8 {
    const name = el.getTagNameDump();
    const colon = std.mem.findScalar(u8, name, ':') orelse return null;
    return name[0..colon];
}

// Whether the element has an attribute named `start` followed by `rest`.
fn hasAttribute(el: *const Element, start: []const u8, rest: []const u8) bool {
    for (el.attributeEntries()) |*attr| {
        const name = attr.name();
        if (name.len == start.len + rest.len and std.mem.startsWith(u8, name, start) and std.mem.endsWith(u8, name, rest)) {
            return true;
        }
    }
    return false;
}

fn eqlNamespace(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.mem.eql(u8, a.?, b.?);
}

fn writeEscaped(text: []const u8, in_attribute: bool, writer: *std.Io.Writer) !void {
    for (text) |c| {
        const escaped: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => if (in_attribute) "&quot;" else null,
            '\t' => if (in_attribute) "&#9;" else null,
            '\n' => if (in_attribute) "&#10;" else null,
            '\r' => if (in_attribute) "&#13;" else null,
            else => null,
        };
        if (escaped) |e| {
            try writer.writeAll(e);
        } else {
            try writer.writeByte(c);
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLSerializer);

    pub const Meta = struct {
        pub const name = "XMLSerializer";
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(XMLSerializer.init, .{});
    pub const serializeToString = bridge.function(XMLSerializer.serializeToString, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: XMLSerializer" {
    try testing.htmlRunner("xmlserializer.html", .{});
}
