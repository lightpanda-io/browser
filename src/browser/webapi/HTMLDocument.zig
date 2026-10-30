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
const Document = @import("Document.zig");
const Element = @import("Element.zig");
const Window = @import("Window.zig");
const TreeWalker = @import("TreeWalker.zig");
const collections = @import("collections.zig");

const NodeLive = collections.NodeLive;

const HTMLDocument = @This();

pub const Proto = Document;

_proto: *Document,

pub fn asDocument(self: *HTMLDocument) *Document {
    return self._proto;
}

pub fn asNode(self: *HTMLDocument) *Node {
    return self._proto.asNode();
}

pub fn asEventTarget(self: *HTMLDocument) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

const NamedItemResult = union(enum) {
    window: Window.Access,
    element: *Element,
    collection: NodeLive(.document_named),
};
fn namedItem(self: *HTMLDocument, name: []const u8, frame: *Frame) !?NamedItemResult {
    if (name.len == 0) {
        return null;
    }

    var tw = TreeWalker.FullExcludeSelf.Elements.init(self.asNode(), .{});
    const first = findNamed(&tw, name) orelse return null;
    if (findNamed(&tw, name) != null) {
        // we found more than one, we return an HTMLCollection
        return .{ .collection = NodeLive(.document_named).init(self.asNode(), try frame.dupeString(name), frame) };
    }

    if (first.is(Element.Html.IFrame)) |iframe| {
        const iframe_window = iframe._window orelse return null;
        return .{ .window = Window.Access.init(frame.window, iframe_window) };
    }
    return .{ .element = first };
}

// Not the only thing that applies this type of rule. The short of it is:
// 1 - document order
// 2 - id is prefered over name, but for X (img) only if there's no name
//     (which is different than am empty name)
// 3 - Drop duplicates
// https://html.spec.whatwg.org/multipage/dom.html#dom-document-nameditem
fn getNames(self: *HTMLDocument, frame: *Frame) !js.Array {
    const arena = frame.local_arena;
    var names: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    var tw = TreeWalker.FullExcludeSelf.Elements.init(self.asNode(), .{});
    while (tw.next()) |el| {
        const html = el.is(Element.Html) orelse continue;
        const name = el.getName() orelse "";
        const id: []const u8 = switch (html._type) {
            .embed, .form, .iframe => "",
            .img => if (name.len == 0) "" else el.getId() orelse "",
            .object => el.getId() orelse "",
            else => continue,
        };

        for ([_][]const u8{ id, name }) |n| {
            if (n.len == 0) {
                continue;
            }
            const gop = try seen.getOrPut(arena, n);
            if (gop.found_existing == false) {
                try names.append(arena, n);
            }
        }
    }

    var arr = frame.js.local.?.newArray(@intCast(names.items.len));
    for (names.items, 0..) |n, i| {
        _ = try arr.set(@intCast(i), n, .{});
    }
    return arr;
}

fn findNamed(tw: *TreeWalker.FullExcludeSelf.Elements, name: []const u8) ?*Element {
    while (tw.next()) |el| {
        if (isNamed(el, name)) {
            return el;
        }
    }
    return null;
}

pub fn isNamed(el: *Element, name: []const u8) bool {
    const html = el.is(Element.Html) orelse return false;
    switch (html._type) {
        .embed, .form, .iframe => {},
        .img => {
            const name_attr = el.getName() orelse return false;
            if (name_attr.len == 0) {
                return false;
            }

            if (std.mem.eql(u8, name_attr, name)) {
                return true;
            }

            // img is weird, it can only match by id when it has a non-empty name
            const id = el.getId() orelse return false;
            return std.mem.eql(u8, id, name);
        },
        .object => {
            if (el.getId()) |id| {
                if (std.mem.eql(u8, id, name)) {
                    return true;
                }
            }
        },
        else => return false,
    }
    const name_attr = el.getName() orelse return false;
    return std.mem.eql(u8, name_attr, name);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLDocument);

    pub const Meta = struct {
        pub const name = "HTMLDocument";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(frame: *Frame) !*HTMLDocument {
        return frame._factory.document(HTMLDocument{
            ._proto = undefined,
        });
    }

    pub const @"[str]" = bridge.namedIndexed(HTMLDocument.namedItem, null, null, HTMLDocument.getNames, struct {
        fn query(self: *HTMLDocument, name: []const u8) !u32 {
            if (name.len == 0) {
                return error.NotHandled;
            }

            var tw = TreeWalker.FullExcludeSelf.Elements.init(self.asNode(), .{});
            if (findNamed(&tw, name) == null) {
                return error.NotHandled;
            }
            return js.v8.None;
        }
    }.query, .{ .null_as_undefined = true });
};
