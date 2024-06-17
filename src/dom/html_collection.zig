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

const parser = @import("netsurf");

const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const generate = @import("../generate.zig");

const utils = @import("utils.z");
const Element = @import("element.zig").Element;
const Union = @import("element.zig").Union;

const Walker = @import("walker.zig").Walker;
const WalkerDepthFirst = @import("walker.zig").WalkerDepthFirst;
const WalkerChildren = @import("walker.zig").WalkerChildren;
const WalkerNone = @import("walker.zig").WalkerNone;

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
            inline .matchTrue => return true,
            inline .matchFalse => return false,
            inline .matchByTagName => |case| return case.match(node),
            inline .matchByClassName => |case| return case.match(node),
            inline .matchByName => |case| return case.match(node),
            inline .matchByLinks => return MatchByLinks.match(node),
            inline .matchByAnchors => return MatchByAnchors.match(node),
        }
    }

    pub fn deinit(self: Matcher, alloc: std.mem.Allocator) void {
        switch (self) {
            inline .matchTrue => return,
            inline .matchFalse => return,
            inline .matchByTagName => |case| return case.deinit(alloc),
            inline .matchByClassName => |case| return case.deinit(alloc),
            inline .matchByName => |case| return case.deinit(alloc),
            inline .matchByLinks => return,
            inline .matchByAnchors => return,
        }
    }
};

pub const MatchByTagName = struct {
    // tag is used to select node against their name.
    // tag comparison is case insensitive.
    tag: []const u8,
    is_wildcard: bool,

    fn init(alloc: std.mem.Allocator, tag_name: []const u8) !MatchByTagName {
        const tag_name_alloc = try alloc.alloc(u8, tag_name.len);
        @memcpy(tag_name_alloc, tag_name);
        return MatchByTagName{
            .tag = tag_name_alloc,
            .is_wildcard = std.mem.eql(u8, tag_name, "*"),
        };
    }

    pub fn match(self: MatchByTagName, node: *parser.Node) !bool {
        return self.is_wildcard or std.ascii.eqlIgnoreCase(self.tag, try parser.nodeName(node));
    }

    fn deinit(self: MatchByTagName, alloc: std.mem.Allocator) void {
        alloc.free(self.tag);
    }
};

pub fn HTMLCollectionByTagName(
    alloc: std.mem.Allocator,
    root: ?*parser.Node,
    tag_name: []const u8,
    include_root: bool,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = Walker{ .walkerDepthFirst = .{} },
        .matcher = Matcher{
            .matchByTagName = try MatchByTagName.init(alloc, tag_name),
        },
        .include_root = include_root,
    };
}

pub const MatchByClassName = struct {
    classNames: []const u8,

    fn init(alloc: std.mem.Allocator, classNames: []const u8) !MatchByClassName {
        const class_names_alloc = try alloc.alloc(u8, classNames.len);
        @memcpy(class_names_alloc, classNames);
        return MatchByClassName{
            .classNames = class_names_alloc,
        };
    }

    pub fn match(self: MatchByClassName, node: *parser.Node) !bool {
        var it = std.mem.splitAny(u8, self.classNames, " ");
        const e = parser.nodeToElement(node);
        while (it.next()) |c| {
            if (!try parser.elementHasClass(e, c)) {
                return false;
            }
        }

        return true;
    }

    fn deinit(self: MatchByClassName, alloc: std.mem.Allocator) void {
        alloc.free(self.classNames);
    }
};

pub fn HTMLCollectionByClassName(
    alloc: std.mem.Allocator,
    root: ?*parser.Node,
    classNames: []const u8,
    include_root: bool,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = Walker{ .walkerDepthFirst = .{} },
        .matcher = Matcher{
            .matchByClassName = try MatchByClassName.init(alloc, classNames),
        },
        .include_root = include_root,
    };
}

pub const MatchByName = struct {
    name: []const u8,

    fn init(alloc: std.mem.Allocator, name: []const u8) !MatchByName {
        const names_alloc = try alloc.alloc(u8, name.len);
        @memcpy(names_alloc, name);
        return MatchByName{
            .name = names_alloc,
        };
    }

    pub fn match(self: MatchByName, node: *parser.Node) !bool {
        const e = parser.nodeToElement(node);
        const nname = try parser.elementGetAttribute(e, "name") orelse return false;
        return std.mem.eql(u8, self.name, nname);
    }

    fn deinit(self: MatchByName, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub fn HTMLCollectionByName(
    alloc: std.mem.Allocator,
    root: ?*parser.Node,
    name: []const u8,
    include_root: bool,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = Walker{ .walkerDepthFirst = .{} },
        .matcher = Matcher{
            .matchByName = try MatchByName.init(alloc, name),
        },
        .include_root = include_root,
    };
}

pub fn HTMLCollectionAll(
    root: ?*parser.Node,
    include_root: bool,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = Walker{ .walkerDepthFirst = .{} },
        .matcher = Matcher{ .matchTrue = .{} },
        .include_root = include_root,
    };
}

pub fn HTMLCollectionChildren(
    root: ?*parser.Node,
    include_root: bool,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = Walker{ .walkerChildren = .{} },
        .matcher = Matcher{ .matchTrue = .{} },
        .include_root = include_root,
    };
}

pub fn HTMLCollectionEmpty() !HTMLCollection {
    return HTMLCollection{
        .root = null,
        .walker = Walker{ .walkerNone = .{} },
        .matcher = Matcher{ .matchFalse = .{} },
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
    include_root: bool,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = Walker{ .walkerDepthFirst = .{} },
        .matcher = Matcher{
            .matchByLinks = MatchByLinks{},
        },
        .include_root = include_root,
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
    include_root: bool,
) !HTMLCollection {
    return HTMLCollection{
        .root = root,
        .walker = Walker{ .walkerDepthFirst = .{} },
        .matcher = Matcher{
            .matchByAnchors = MatchByAnchors{},
        },
        .include_root = include_root,
    };
}

pub const HTMLCollectionIterator = struct {
    pub const mem_guarantied = true;

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

// WEB IDL https://dom.spec.whatwg.org/#htmlcollection
// HTMLCollection is re implemented in zig here because libdom
// dom_html_collection expects a comparison function callback as arguement.
// But we wanted a dynamically comparison here, according to the match tagname.
pub const HTMLCollection = struct {
    pub const mem_guarantied = true;

    matcher: Matcher,
    walker: Walker,

    root: ?*parser.Node,

    // By default the HTMLCollection walk on the root's descendant only.
    // But on somes cases, like for dom document, we want to walk over the root
    // itself.
    include_root: bool = false,

    // save a state for the collection to improve the _item speed.
    cur_idx: ?u32 = undefined,
    cur_node: ?*parser.Node = undefined,

    // array_like_keys is used to keep reference to array like interface implementation.
    // the collection generates keys string which must be free on deinit.
    array_like_keys: std.ArrayListUnmanaged([]u8) = .{},

    // start returns the first node to walk on.
    fn start(self: HTMLCollection) !?*parser.Node {
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
        if (self.cur_idx != null and index >= self.cur_idx.?) {
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

    pub fn _namedItem(self: *HTMLCollection, name: []const u8) !?Union {
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

    pub fn postAttach(self: *HTMLCollection, alloc: std.mem.Allocator, js_obj: jsruntime.JSObject) !void {
        const ln = try self.get_length();
        var i: u32 = 0;
        while (i < ln) {
            defer i += 1;
            const k = try std.fmt.allocPrint(alloc, "{d}", .{i});
            try self.array_like_keys.append(alloc, k);

            const node = try self.item(i) orelse unreachable;
            const e = @as(*parser.Element, @ptrCast(node));
            try js_obj.set(k, e);

            if (try item_name(e)) |name| {
                try js_obj.set(name, e);
            }
        }
    }

    pub fn deinit(self: *HTMLCollection, alloc: std.mem.Allocator) void {
        for (self.array_like_keys_) |k| alloc.free(k);
        self.array_like_keys.deinit(alloc);
        self.matcher.deinit(alloc);
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var getElementsByTagName = [_]Case{
        .{ .src = "let getElementsByTagName = document.getElementsByTagName('p')", .ex = "undefined" },
        .{ .src = "getElementsByTagName.length", .ex = "2" },
        .{ .src = "let getElementsByTagNameCI = document.getElementsByTagName('P')", .ex = "undefined" },
        .{ .src = "getElementsByTagNameCI.length", .ex = "2" },
        .{ .src = "getElementsByTagName.item(0).localName", .ex = "p" },
        .{ .src = "getElementsByTagName.item(1).localName", .ex = "p" },
        .{ .src = "let getElementsByTagNameAll = document.getElementsByTagName('*')", .ex = "undefined" },
        .{ .src = "getElementsByTagNameAll.length", .ex = "8" },
        .{ .src = "getElementsByTagNameAll.item(0).localName", .ex = "html" },
        .{ .src = "getElementsByTagNameAll.item(0).localName", .ex = "html" },
        .{ .src = "getElementsByTagNameAll.item(1).localName", .ex = "head" },
        .{ .src = "getElementsByTagNameAll.item(0).localName", .ex = "html" },
        .{ .src = "getElementsByTagNameAll.item(2).localName", .ex = "body" },
        .{ .src = "getElementsByTagNameAll.item(3).localName", .ex = "div" },
        .{ .src = "getElementsByTagNameAll.item(7).localName", .ex = "p" },
        .{ .src = "getElementsByTagNameAll.namedItem('para-empty-child').localName", .ex = "span" },

        // array like
        .{ .src = "getElementsByTagNameAll[0].localName", .ex = "html" },
        .{ .src = "getElementsByTagNameAll[7].localName", .ex = "p" },
        .{ .src = "getElementsByTagNameAll[8]", .ex = "undefined" },
        .{ .src = "getElementsByTagNameAll['para-empty-child'].localName", .ex = "span" },
        .{ .src = "getElementsByTagNameAll['foo']", .ex = "undefined" },

        .{ .src = "document.getElementById('content').getElementsByTagName('*').length", .ex = "4" },
        .{ .src = "document.getElementById('content').getElementsByTagName('p').length", .ex = "2" },
        .{ .src = "document.getElementById('content').getElementsByTagName('div').length", .ex = "0" },

        .{ .src = "document.children.length", .ex = "1" },
        .{ .src = "document.getElementById('content').children.length", .ex = "3" },

        // check liveness
        .{ .src = "let content = document.getElementById('content')", .ex = "undefined" },
        .{ .src = "let pe = document.getElementById('para-empty')", .ex = "undefined" },
        .{ .src = "let p = document.createElement('p')", .ex = "undefined" },
        .{ .src = "p.textContent = 'OK live'", .ex = "OK live" },
        .{ .src = "getElementsByTagName.item(1).textContent", .ex = " And" },
        .{ .src = "content.appendChild(p) != undefined", .ex = "true" },
        .{ .src = "getElementsByTagName.length", .ex = "3" },
        .{ .src = "getElementsByTagName.item(2).textContent", .ex = "OK live" },
        .{ .src = "content.insertBefore(p, pe) != undefined", .ex = "true" },
        .{ .src = "getElementsByTagName.item(0).textContent", .ex = "OK live" },
    };
    try checkCases(js_env, &getElementsByTagName);
}
