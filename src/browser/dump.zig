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
const Page = @import("Page.zig");
const Node = @import("webapi/Node.zig");
const Slot = @import("webapi/element/html/Slot.zig");
const IFrame = @import("webapi/element/html/IFrame.zig");

const IS_DEBUG = @import("builtin").mode == .Debug;

pub const Opts = struct {
    with_base: bool = false,
    with_frames: bool = false,
    strip: Opts.Strip = .{},
    shadow: Opts.Shadow = .rendered,

    pub const Strip = struct {
        js: bool = false,
        ui: bool = false,
        css: bool = false,
    };

    pub const Shadow = enum {
        // Skip shadow DOM entirely (innerHTML/outerHTML)
        skip,

        // Dump everyhting (like "view source")
        complete,

        // Resolve slot elements (like what actually gets rendered)
        rendered,
    };
};

pub fn root(doc: *Node.Document, opts: Opts, writer: *std.Io.Writer, page: *Page) !void {
    if (doc.is(Node.Document.HTMLDocument)) |html_doc| {
        blk: {
            // Ideally we just render the doctype which is part of the document
            if (doc.asNode().firstChild()) |first| {
                if (first._type == .document_type) {
                    break :blk;
                }
            }
            // But if the doc has no child, or the first child isn't a doctype
            // well force it.
            try writer.writeAll("<!DOCTYPE html>");
        }

        if (opts.with_base) {
            const parent = if (html_doc.getHead()) |head| head.asNode() else doc.asNode();
            const base = try doc.createElement("base", null, page);
            try base.setAttributeSafe(comptime .wrap("base"), .wrap(page.base()), page);
            _ = try parent.insertBefore(base.asNode(), parent.firstChild(), page);
        }
    }

    return deep(doc.asNode(), opts, writer, page);
}

pub fn deep(node: *Node, opts: Opts, writer: *std.Io.Writer, page: *Page) error{WriteFailed}!void {
    return _deep(node, opts, false, writer, page);
}

fn _deep(node: *Node, opts: Opts, comptime force_slot: bool, writer: *std.Io.Writer, page: *Page) error{WriteFailed}!void {
    switch (node._type) {
        .cdata => |cd| {
            if (node.is(Node.CData.Comment)) |_| {
                try writer.writeAll("<!--");
                try writer.writeAll(cd.getData().str());
                try writer.writeAll("-->");
            } else if (node.is(Node.CData.ProcessingInstruction)) |pi| {
                try writer.writeAll("<?");
                try writer.writeAll(pi._target);
                try writer.writeAll(" ");
                try writer.writeAll(cd.getData().str());
                try writer.writeAll("?>");
            } else {
                if (shouldEscapeText(node._parent)) {
                    try writeEscapedText(cd.getData().str(), writer);
                } else {
                    try writer.writeAll(cd.getData().str());
                }
            }
        },
        .element => |el| {
            if (shouldStripElement(el, opts)) {
                return;
            }

            // When opts.shadow == .rendered, we normally skip any element with
            // a slot attribute. Only the "active" element will get rendered into
            // the <slot name="X">. However, the `deep` function is itself used
            // to render that "active" content, so when we're trying to render
            // it, we don't want to skip it.
            if ((comptime force_slot == false) and opts.shadow == .rendered) {
                if (el.getAttributeSafe(comptime .wrap("slot"))) |_| {
                    // Skip - will be rendered by the Slot if it's the active container
                    return;
                }
            }

            try el.format(writer);

            if (opts.shadow == .rendered) {
                if (el.is(Slot)) |slot| {
                    try dumpSlotContent(slot, opts, writer, page);
                    return writer.writeAll("</slot>");
                }
            }
            if (opts.shadow != .skip) {
                if (page._element_shadow_roots.get(el)) |shadow| {
                    try children(shadow.asNode(), opts, writer, page);
                    // In rendered mode, light DOM is only shown through slots, not directly
                    if (opts.shadow == .rendered) {
                        // Skip rendering light DOM children
                        if (!isVoidElement(el)) {
                            try writer.writeAll("</");
                            try writer.writeAll(el.getTagNameDump());
                            try writer.writeByte('>');
                        }
                        return;
                    }
                }
            }

            if (opts.with_frames and el.is(IFrame) != null) {
                const frame = el.as(IFrame);
                if (frame.getContentDocument()) |doc| {
                    // A frame's document should always ahave a page, but
                    // I'm not willing to crash a release build on that assertion.
                    if (comptime IS_DEBUG) {
                        std.debug.assert(doc._page != null);
                    }
                    if (doc._page) |frame_page| {
                        try writer.writeByte('\n');
                        root(doc, opts, writer, frame_page) catch return error.WriteFailed;
                        try writer.writeByte('\n');
                    }
                }
            } else {
                try children(node, opts, writer, page);
            }

            if (!isVoidElement(el)) {
                try writer.writeAll("</");
                try writer.writeAll(el.getTagNameDump());
                try writer.writeByte('>');
            }
        },
        .document => try children(node, opts, writer, page),
        .document_type => |dt| {
            try writer.writeAll("<!DOCTYPE ");
            try writer.writeAll(dt.getName());

            const public_id = dt.getPublicId();
            const system_id = dt.getSystemId();
            if (public_id.len != 0 and system_id.len != 0) {
                try writer.writeAll(" PUBLIC \"");
                try writeEscapedText(public_id, writer);
                try writer.writeAll("\" \"");
                try writeEscapedText(system_id, writer);
                try writer.writeByte('"');
            } else if (public_id.len != 0) {
                try writer.writeAll(" PUBLIC \"");
                try writeEscapedText(public_id, writer);
                try writer.writeByte('"');
            } else if (system_id.len != 0) {
                try writer.writeAll(" SYSTEM \"");
                try writeEscapedText(system_id, writer);
                try writer.writeByte('"');
            }
            try writer.writeAll(">\n");
        },
        .document_fragment => try children(node, opts, writer, page),
        .attribute => {
            // Not called normally, but can be called via XMLSerializer.serializeToString
            // in which case it should return an empty string
            try writer.writeAll("");
        },
    }
}

pub fn children(parent: *Node, opts: Opts, writer: *std.Io.Writer, page: *Page) !void {
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        try deep(child, opts, writer, page);
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

fn dumpSlotContent(slot: *Slot, opts: Opts, writer: *std.Io.Writer, page: *Page) !void {
    const assigned = slot.assignedNodes(null, page) catch return;

    if (assigned.len > 0) {
        for (assigned) |assigned_node| {
            try _deep(assigned_node, opts, true, writer, page);
        }
    } else {
        try children(slot.asNode(), opts, writer, page);
    }
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

fn shouldStripElement(el: *const Node.Element, opts: Opts) bool {
    const tag_name = el.getTagNameDump();

    if (opts.strip.js) {
        if (std.mem.eql(u8, tag_name, "script")) return true;
        if (std.mem.eql(u8, tag_name, "noscript")) return true;

        if (std.mem.eql(u8, tag_name, "link")) {
            if (el.getAttributeSafe(comptime .wrap("as"))) |as| {
                if (std.mem.eql(u8, as, "script")) return true;
            }
            if (el.getAttributeSafe(comptime .wrap("rel"))) |rel| {
                if (std.mem.eql(u8, rel, "modulepreload") or std.mem.eql(u8, rel, "preload")) {
                    if (el.getAttributeSafe(comptime .wrap("as"))) |as| {
                        if (std.mem.eql(u8, as, "script")) return true;
                    }
                }
            }
        }
    }

    if (opts.strip.css or opts.strip.ui) {
        if (std.mem.eql(u8, tag_name, "style")) return true;

        if (std.mem.eql(u8, tag_name, "link")) {
            if (el.getAttributeSafe(comptime .wrap("rel"))) |rel| {
                if (std.mem.eql(u8, rel, "stylesheet")) return true;
            }
        }
    }

    if (opts.strip.ui) {
        if (std.mem.eql(u8, tag_name, "img")) return true;
        if (std.mem.eql(u8, tag_name, "picture")) return true;
        if (std.mem.eql(u8, tag_name, "video")) return true;
        if (std.mem.eql(u8, tag_name, "audio")) return true;
        if (std.mem.eql(u8, tag_name, "svg")) return true;
        if (std.mem.eql(u8, tag_name, "canvas")) return true;
        if (std.mem.eql(u8, tag_name, "iframe")) return true;
    }

    return false;
}

fn shouldEscapeText(node_: ?*Node) bool {
    const node = node_ orelse return true;
    if (node.is(Node.Element.Html.Script) != null) {
        return false;
    }
    // When scripting is enabled, <noscript> is a raw text element per the HTML spec
    // (https://html.spec.whatwg.org/multipage/parsing.html#serialising-html-fragments).
    // Its text content must not be HTML-escaped during serialization.
    if (node.is(Node.Element.Html.Generic)) |generic| {
        if (generic._tag == .noscript) return false;
    }
    return true;
}
fn writeEscapedText(text: []const u8, writer: *std.Io.Writer) !void {
    // Fast path: if no special characters, write directly
    const first_special = std.mem.indexOfAnyPos(u8, text, 0, &.{ '&', '<', '>', 194 }) orelse {
        return writer.writeAll(text);
    };

    try writer.writeAll(text[0..first_special]);
    var remaining = try writeEscapedByte(text, first_special, writer);

    while (std.mem.indexOfAnyPos(u8, remaining, 0, &.{ '&', '<', '>', 194 })) |offset| {
        try writer.writeAll(remaining[0..offset]);
        remaining = try writeEscapedByte(remaining, offset, writer);
    }

    if (remaining.len > 0) {
        try writer.writeAll(remaining);
    }
}

fn writeEscapedByte(input: []const u8, index: usize, writer: *std.Io.Writer) ![]const u8 {
    switch (input[index]) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        194 => {
            // non breaking space
            if (input.len > index + 1 and input[index + 1] == 160) {
                try writer.writeAll("&nbsp;");
                return input[index + 2 ..];
            }
            try writer.writeByte(194);
        },
        else => unreachable,
    }
    return input[index + 1 ..];
}
