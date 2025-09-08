// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const Allocator = std.mem.Allocator;

const parser = @import("../netsurf.zig");

const Element = @import("element.zig").Element;
const Union = @import("element.zig").Union;
const JsThis = @import("../env.zig").JsThis;
const Walker = @import("walker.zig").Walker;

const Matcher = union(enum) {
    matchByName: MatchByName,
    matchByTagName: MatchByTagName,
    matchByClassName: MatchByClassName,
    matchByLinks: MatchByLinks,
    matchByAnchors: MatchByAnchors,
    matchTrue: struct {},
    matchFalse: struct {},

    pub fn match(self: Matcher, node: *parser.Node) !bool {
        switch (self) {
            .matchTrue => return true,
            .matchFalse => return false,
            .matchByLinks => return MatchByLinks.match(node),
            .matchByAnchors => return MatchByAnchors.match(node),
            inline else => |m| return m.match(node),
        }
    }
};

pub const MatchByTagName = struct {
    // tag is used to select node against their name.
    // tag comparison is case insensitive.
    tag: []const u8,
    is_wildcard: bool,

    fn init(arena: Allocator, tag_name: []const u8) !MatchByTagName {
        if (std.mem.eql(u8, tag_name, "*")) {
            return .{ .tag = "*", .is_wildcard = true };
        }

        return .{
            .tag = try arena.dupe(u8, tag_name),
            .is_wildcard = false,
        };
    }

    pub fn match(self: MatchByTagName, node: *parser.Node) !bool {
        return self.is_wildcard or std.ascii.eqlIgnoreCase(self.tag, try parser.nodeName(node));
    }
};

pub fn HTMLCollectionByTagName(
    arena: Allocator,
    root: ?*parser.Node,
    tag_name: []const u8,
    opts: Opts,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = .{ .walkerDepthFirst = .{} },
        .matcher = .{ .matchByTagName = try MatchByTagName.init(arena, tag_name) },
        .mutable = opts.mutable,
        .include_root = opts.include_root,
    };
}

pub const MatchByClassName = struct {
    class_names: []const u8,

    fn init(arena: Allocator, class_names: []const u8) !MatchByClassName {
        return .{
            .class_names = try arena.dupe(u8, class_names),
        };
    }

    pub fn match(self: MatchByClassName, node: *parser.Node) !bool {
        const e = parser.nodeToElement(node);

        var it = std.mem.splitScalar(u8, self.class_names, ' ');
        while (it.next()) |c| {
            if (!try parser.elementHasClass(e, c)) {
                return false;
            }
        }

        return true;
    }
};

pub fn HTMLCollectionByClassName(
    arena: Allocator,
    root: ?*parser.Node,
    classNames: []const u8,
    opts: Opts,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = .{ .walkerDepthFirst = .{} },
        .matcher = .{ .matchByClassName = try MatchByClassName.init(arena, classNames) },
        .mutable = opts.mutable,
        .include_root = opts.include_root,
    };
}

pub const MatchByName = struct {
    name: []const u8,

    fn init(arena: Allocator, name: []const u8) !MatchByName {
        return .{
            .name = try arena.dupe(u8, name),
        };
    }

    pub fn match(self: MatchByName, node: *parser.Node) !bool {
        const e = parser.nodeToElement(node);
        const nname = try parser.elementGetAttribute(e, "name") orelse return false;
        return std.mem.eql(u8, self.name, nname);
    }
};

pub fn HTMLCollectionByName(
    arena: Allocator,
    root: ?*parser.Node,
    name: []const u8,
    opts: Opts,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = .{ .walkerDepthFirst = .{} },
        .matcher = .{ .matchByName = try MatchByName.init(arena, name) },
        .mutable = opts.mutable,
        .include_root = opts.include_root,
    };
}

// HTMLAllCollection is a special type: instances of it are falsy. It's the only
// object in the WebAPI that behaves like this - in fact, it's even a special
// case in the JavaScript spec.
// This is important, because a lot of browser detection rely on this behavior
// to determine what browser is running.

// It's also possible to use an instance like a function:
//   document.all(3)
//   document.all('some_id')
pub const HTMLAllCollection = struct {
    pub const prototype = *HTMLCollection;

    proto: HTMLCollection,

    pub const mark_as_undetectable = true;

    pub fn init(root: ?*parser.Node) HTMLAllCollection {
        return .{ .proto = .{
            .root = root,
            .walker = .{ .walkerDepthFirst = .{} },
            .matcher = .{ .matchTrue = .{} },
            .include_root = true,
        } };
    }

    const CAllAsFunctionArg = union(enum) {
        index: u32,
        id: []const u8,
    };

    pub fn jsCallAsFunction(self: *HTMLAllCollection, arg: CAllAsFunctionArg) !?Union {
        return switch (arg) {
            .index => |i| self.proto._item(i),
            .id => |id| self.proto._namedItem(id),
        };
    }
};

pub fn HTMLCollectionChildren(
    root: ?*parser.Node,
    opts: Opts,
) HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = .{ .walkerChildren = .{} },
        .matcher = .{ .matchTrue = .{} },
        .mutable = opts.mutable,
        .include_root = opts.include_root,
    };
}

pub fn HTMLCollectionEmpty() !HTMLCollection {
    return HTMLCollection{
        .root = null,
        .walker = .{ .walkerNone = .{} },
        .matcher = .{ .matchFalse = .{} },
        .include_root = false,
    };
}

// MatchByLinks matches the a and area elements in the Document that have href
// attributes.
// https://html.spec.whatwg.org/#dom-document-links
pub const MatchByLinks = struct {
    pub fn match(node: *parser.Node) !bool {
        const tag = try parser.nodeName(node);
        if (!std.ascii.eqlIgnoreCase(tag, "a") and !std.ascii.eqlIgnoreCase(tag, "area")) {
            return false;
        }
        const elem = @as(*parser.Element, @ptrCast(node));
        return parser.elementHasAttribute(elem, "href");
    }
};

pub fn HTMLCollectionByLinks(
    root: ?*parser.Node,
    opts: Opts,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = .{ .walkerDepthFirst = .{} },
        .matcher = .{ .matchByLinks = MatchByLinks{} },
        .mutable = opts.mutable,
        .include_root = opts.include_root,
    };
}

// MatchByAnchors matches the a elements in the Document that have name
// attributes.
// https://html.spec.whatwg.org/#dom-document-anchors
pub const MatchByAnchors = struct {
    pub fn match(node: *parser.Node) !bool {
        const tag = try parser.nodeName(node);
        if (!std.ascii.eqlIgnoreCase(tag, "a")) return false;

        const elem = @as(*parser.Element, @ptrCast(node));
        return parser.elementHasAttribute(elem, "name");
    }
};

pub fn HTMLCollectionByAnchors(
    root: ?*parser.Node,
    opts: Opts,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = .{ .walkerDepthFirst = .{} },
        .matcher = .{ .matchByAnchors = MatchByAnchors{} },
        .mutable = opts.mutable,
        .include_root = opts.include_root,
    };
}

pub const HTMLCollectionIterator = struct {
    coll: *HTMLCollection,
    index: u32 = 0,

    pub const Return = struct {
        value: ?Union,
        done: bool,
    };

    pub fn _next(self: *HTMLCollectionIterator) !Return {
        const e = try self.coll._item(self.index);
        if (e == null) {
            return Return{
                .value = null,
                .done = true,
            };
        }

        self.index += 1;
        return Return{
            .value = e,
            .done = false,
        };
    }
};

const Opts = struct {
    include_root: bool,
    mutable: bool = false,
};

// WEB IDL https://dom.spec.whatwg.org/#htmlcollection
// HTMLCollection is re implemented in zig here because libdom
// dom_html_collection expects a comparison function callback as arguement.
// But we wanted a dynamically comparison here, according to the match tagname.
pub const HTMLCollection = struct {
    matcher: Matcher,
    walker: Walker,

    root: ?*parser.Node,

    // By default the HTMLCollection walk on the root's descendant only.
    // But on somes cases, like for dom document, we want to walk over the root
    // itself.
    include_root: bool = false,

    mutable: bool = false,

    // save a state for the collection to improve the _item speed.
    cur_idx: ?u32 = null,
    cur_node: ?*parser.Node = null,

    // start returns the first node to walk on.
    fn start(self: *const HTMLCollection) !?*parser.Node {
        if (self.root == null) return null;

        if (self.include_root) {
            return self.root.?;
        }

        return try self.walker.get_next(self.root.?, null);
    }

    pub fn _symbol_iterator(self: *HTMLCollection) HTMLCollectionIterator {
        return HTMLCollectionIterator{
            .coll = self,
        };
    }

    /// get_length computes the collection's length dynamically according to
    /// the current root structure.
    // TODO: nodes retrieved must be de-referenced.
    pub fn get_length(self: *HTMLCollection) !u32 {
        if (self.root == null) return 0;

        var len: u32 = 0;
        var node = try self.start() orelse return 0;

        while (true) {
            if (try parser.nodeType(node) == .element) {
                if (try self.matcher.match(node)) {
                    len += 1;
                }
            }

            node = try self.walker.get_next(self.root.?, node) orelse break;
        }

        return len;
    }

    pub fn item(self: *HTMLCollection, index: u32) !?*parser.Node {
        if (self.root == null) return null;

        var i: u32 = 0;
        var node: *parser.Node = undefined;

        // Use the current state to improve speed if possible.
        if (self.mutable == false and self.cur_idx != null and index >= self.cur_idx.?) {
            i = self.cur_idx.?;
            node = self.cur_node.?;
        } else {
            node = try self.start() orelse return null;
        }

        while (true) {
            if (try parser.nodeType(node) == .element) {
                if (try self.matcher.match(node)) {
                    // check if we found the searched element.
                    if (i == index) {
                        // save the current state
                        self.cur_node = node;
                        self.cur_idx = i;

                        return node;
                    }

                    i += 1;
                }
            }

            node = try self.walker.get_next(self.root.?, node) orelse break;
        }

        return null;
    }

    pub fn _item(self: *HTMLCollection, index: u32) !?Union {
        const node = try self.item(index) orelse return null;
        const e = @as(*parser.Element, @ptrCast(node));
        return try Element.toInterface(e);
    }

    pub fn _namedItem(self: *const HTMLCollection, name: []const u8) !?Union {
        if (self.root == null) return null;
        if (name.len == 0) return null;

        var node = try self.start() orelse return null;

        while (true) {
            if (try parser.nodeType(node) == .element) {
                if (try self.matcher.match(node)) {
                    const elem = @as(*parser.Element, @ptrCast(node));

                    var attr = try parser.elementGetAttribute(elem, "id");
                    // check if the node id corresponds to the name argument.
                    if (attr != null and std.mem.eql(u8, name, attr.?)) {
                        return try Element.toInterface(elem);
                    }

                    attr = try parser.elementGetAttribute(elem, "name");
                    // check if the node id corresponds to the name argument.
                    if (attr != null and std.mem.eql(u8, name, attr.?)) {
                        return try Element.toInterface(elem);
                    }
                }
            }

            node = try self.walker.get_next(self.root.?, node) orelse break;
        }

        return null;
    }

    fn item_name(elt: *parser.Element) !?[]const u8 {
        if (try parser.elementGetAttribute(elt, "id")) |v| {
            return v;
        }
        if (try parser.elementGetAttribute(elt, "name")) |v| {
            return v;
        }

        return null;
    }

    pub fn postAttach(self: *HTMLCollection, js_this: JsThis) !void {
        const len = try self.get_length();
        for (0..len) |i| {
            const node = try self.item(@intCast(i)) orelse unreachable;
            const e = @as(*parser.Element, @ptrCast(node));
            const as_interface = try Element.toInterface(e);
            try js_this.setIndex(@intCast(i), as_interface, .{});

            if (try item_name(e)) |name| {
                // Even though an entry might have an empty id, the spec says
                // that namedItem("") should always return null
                if (name.len > 0) {
                    // Named fields should not be enumerable (it is defined with
                    // the LegacyUnenumerableNamedProperties flag.)
                    try js_this.set(name, as_interface, .{ .DONT_ENUM = true });
                }
            }
        }
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.HTMLCollection" {
    try testing.htmlRunner("dom/html_collection.html");
}
