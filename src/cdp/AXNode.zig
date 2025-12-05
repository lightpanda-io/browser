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

const log = @import("../log.zig");
const parser = @import("../browser/netsurf.zig");

const AXNode = @This();
const Node = @import("Node.zig");

// Need a custom writer, because we can't just serialize the node as-is.
// Sometimes we want to serializ the node without chidren, sometimes with just
// its direct children, and sometimes the entire tree.
// (For now, we only support direct children)
pub const Writer = struct {
    root: *const Node,
    registry: *Node.Registry,

    const AXValuesType = enum(u8) { boolean, tristate, booleanOrUndefined, idref, idrefList, integer, node, nodeList, number, string, computedString, token, tokenList, domRelation, role, internalRole, valueUndefined };

    pub const Opts = struct {};

    pub fn jsonStringify(self: *const Writer, w: anytype) error{WriteFailed}!void {
        self.toJSON(self.root, w) catch |err| {
            // The only error our jsonStringify method can return is
            // @TypeOf(w).Error. In other words, our code can't return its own
            // error, we can only return a writer error. Kinda sucks.
            log.err(.cdp, "node toJSON stringify", .{ .err = err });
            return error.WriteFailed;
        };
    }

    fn toJSON(self: *const Writer, node: *const Node, w: anytype) !void {
        try w.beginArray();
        try self.writeNode(node, w);

        const walker = Walker{};
        var next: ?*parser.Node = null;
        var skip_children = false;
        while (true) {
            next = try walker.get_next(node._node, next, .{ .skip_children = skip_children }) orelse break;

            if (parser.nodeType(next.?) != .element) {
                skip_children = true;
                continue;
            }

            const n = try self.registry.register(next.?);
            try self.writeNode(n, w);

            const tag = try parser.elementTag(@ptrCast(next.?));
            skip_children = switch (tag) {
                .head => true,
                else => false,
            };
        }

        try w.endArray();
    }

    const AXValue = struct {
        type: enum(u8) { boolean, tristate, booleanOrUndefined, idref, idrefList, integer, node, nodeList, number, string, computedString, token, tokenList, domRelation, role, internalRole, valueUndefined },
        value: ?union(enum) {
            string: []const u8,
            uint: usize,
            boolean: bool,
        } = null,
        // TODO relatedNodes
        source: ?AXSource = null,
    };

    fn writeAXSource(_: *const Writer, source: AXSource, w: anytype) !void {
        try w.objectField("sources");
        try w.beginArray();
        try w.beginObject();
        // attribute, implicit, style, contents, placeholder, relatedElement
        const source_type = switch (source) {
            .aria_labelledby => blk: {
                try w.objectField("attribute");
                try w.write(@tagName(source));
                break :blk "relatedElement";
            },
            .aria_label, .alt, .title, .placeholder, .value => blk: {
                // No sure if it's correct for .value case.
                try w.objectField("attribute");
                try w.write(@tagName(source));
                break :blk "attribute";
            },
            // Chrome sends the content AXValue *again* in the source.
            // But It seems useless to me.
            //
            // w.objectField("value");
            // self.writeAXValue(.{ .type = .computedString, .value = value.value }, w);
            .contents => "contents",
            .label_element, .label_wrap => "TODO", // TODO
        };

        try w.objectField("type");
        try w.write(source_type);
        try w.endObject();
        try w.endArray();
    }

    fn writeAXValue(self: *const Writer, value: AXValue, w: anytype) !void {
        try w.beginObject();
        try w.objectField("type");
        try w.write(@tagName(value.type));

        if (value.value) |v| {
            try w.objectField("value");
            switch (v) {
                .uint => try w.write(v.uint),
                .string => try w.write(v.string),
                .boolean => try w.write(v.boolean),
            }
        }

        if (value.source) |source| {
            try self.writeAXSource(source, w);
        }
        try w.endObject();
    }

    const AXProperty = struct {
        name: enum(u8) { actions, busy, disabled, editable, focusable, focused, hidden, hiddenRoot, invalid, keyshortcuts, settable, roledescription, live, atomic, relevant, root, autocomplete, hasPopup, level, multiselectable, orientation, multiline, readonly, required, valuemin, valuemax, valuetext, checked, expanded, modal, pressed, selected, activedescendant, controls, describedby, details, errormessage, flowto, labelledby, owns, url, activeFullscreenElement, activeModalDialog, activeAriaModalDialog, ariaHiddenElement, ariaHiddenSubtree, emptyAlt, emptyText, inertElement, inertSubtree, labelContainer, labelFor, notRendered, notVisible, presentationalRole, probablyPresentational, inactiveCarouselTabContent, uninteresting },
        value: AXValue,
    };

    fn writeAXProperties(self: *const Writer, axnode: AXNode, w: anytype) !void {
        const node = axnode._node;
        switch (parser.nodeType(node)) {
            .document => {
                const uri = try parser.documentGetDocumentURI(@ptrCast(node));
                try self.writeAXProperty(.{ .name = .url, .value = .{ .type = .string, .value = .{ .string = uri } } }, w);
                try self.writeAXProperty(.{ .name = .focusable, .value = .{ .type = .booleanOrUndefined, .value = .{ .boolean = true } } }, w);
                return;
            },
            .element => {},
            else => {
                log.debug(.cdp, "invalid tag", .{ .node_type = parser.nodeType(node) });
                return error.InvalidTag;
            },
        }

        const elt: *parser.Element = @ptrCast(node);

        const tag = try parser.elementTag(elt);
        return switch (tag) {
            .h1 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 1 } } }, w),
            .h2 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 2 } } }, w),
            .h3 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 3 } } }, w),
            .h4 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 4 } } }, w),
            .h5 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 5 } } }, w),
            .h6 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 6 } } }, w),
            .img => {
                if (try parser.elementGetAttribute(elt, "href")) |uri| {
                    try self.writeAXProperty(.{ .name = .url, .value = .{ .type = .string, .value = .{ .string = uri } } }, w);
                }
            },
            .a => {
                if (try parser.elementGetAttribute(elt, "href")) |uri| {
                    try self.writeAXProperty(.{ .name = .url, .value = .{ .type = .string, .value = .{ .string = uri } } }, w);
                }
                try self.writeAXProperty(.{ .name = .focusable, .value = .{ .type = .booleanOrUndefined, .value = .{ .boolean = true } } }, w);
            },
            else => {},
        };
    }

    fn writeAXProperty(self: *const Writer, value: AXProperty, w: anytype) !void {
        try w.beginObject();
        try w.objectField("name");
        try w.write(@tagName(value.name));
        try w.objectField("value");
        try self.writeAXValue(value.value, w);
        try w.endObject();
    }

    // write a node. returns true if children must be skipped.
    fn writeNode(self: *const Writer, node: *const Node, w: anytype) !void {
        try w.beginObject();

        const axn = try AXNode.fromNode(node._node);
        try w.objectField("nodeId");
        try w.write(node.id);

        try w.objectField("role");
        try self.writeAXValue(.{ .type = .role, .value = .{ .string = try axn.getRole() } }, w);

        const ignore = try axn.isIgnore();
        try w.objectField("ignored");
        try w.write(ignore);

        if (ignore) {
            // Ignore reasons
            try w.objectField("ignored_reasons");
            try w.beginArray();
            try w.beginObject();
            try w.objectField("name");
            try w.write("uninteresting");
            try w.objectField("value");
            try self.writeAXValue(.{ .type = .boolean, .value = .{ .boolean = true } }, w);
            try w.endObject();
            try w.endArray();
        } else {
            // Name
            try w.objectField("name");
            try w.beginObject();
            try w.objectField("type");
            try w.write(@tagName(.computedString));
            try w.objectField("value");
            const source = try axn.writeName(w);
            if (source) |s| {
                try self.writeAXSource(s, w);
            }
            try w.endObject();

            // Properties
            try w.objectField("properties");
            try w.beginArray();
            try self.writeAXProperties(axn, w);
            try w.endArray();
        }

        const n = axn._node;

        // Parent
        if (parser.nodeParentNode(n)) |p| {
            const parent_node = try self.registry.register(p);
            try w.objectField("parentId");
            try w.write(parent_node.id);
        }

        // Children
        try w.objectField("childIds");
        var registry = self.registry;
        const child_nodes = try parser.nodeGetChildNodes(n);
        const child_count = parser.nodeListLength(child_nodes);

        var i: usize = 0;
        try w.beginArray();
        for (0..child_count) |_| {
            defer i += 1;
            const child = (parser.nodeListItem(child_nodes, @intCast(i))) orelse break;

            // ignore non-elements
            if (parser.nodeType(child) != .element) {
                continue;
            }

            const child_node = try registry.register(child);
            try w.write(child_node.id);
        }
        try w.endArray();

        try w.endObject();
    }
};

pub const AXRole = enum(u8) {
    none,
    article,
    banner,
    blockquote,
    button,
    caption,
    cell,
    checkbox,
    code,
    columnheader,
    combobox,
    complementary,
    contentinfo,
    definition,
    deletion,
    dialog,
    document,
    emphasis,
    figure,
    form,
    group,
    heading,
    img,
    insertion,
    link,
    list,
    listbox,
    listitem,
    main,
    marquee,
    meter,
    navigation,
    option,
    paragraph,
    presentation,
    progressbar,
    radio,
    region,
    row,
    rowgroup,
    rowheader,
    searchbox,
    separator,
    slider,
    spinbutton,
    status,
    strong,
    subscript,
    superscript,
    table,
    term,
    textbox,
    time,
    WebRootArea,

    fn fromNode(node: *parser.Node) !AXRole {
        switch (parser.nodeType(node)) {
            .document => return .WebRootArea, // Chrome specific.
            .element => {},
            else => {
                log.debug(.cdp, "invalid tag", .{ .node_type = parser.nodeType(node) });
                return error.InvalidTag;
            },
        }

        const elt: *parser.Element = @ptrCast(node);

        const tag = try parser.elementTag(elt);
        return switch (tag) {
            // Navigation & Structure
            .nav => .navigation,
            .main => .main,
            .aside => .complementary,
            // TODO conditions:
            // .banner Not descendant of article, aside, main, nav, section
            // (none) When descendant of article, aside, main, nav, section
            .header => .banner,
            // TODO conditions:
            // contentinfo Not descendant of article, aside, main, nav, section
            // (none)  When descendant of article, aside, main, nav, section
            .footer => .contentinfo,
            // TODO conditions:
            // region Has accessible name (aria-label, aria-labelledby, or title) |
            // (none) No accessible name                                          |
            .section => .region,
            .article, .hgroup => .article,
            .address => .group,

            // Headings
            .h1, .h2, .h3, .h4, .h5, .h6 => .heading,
            .ul, .ol, .menu => .list,
            .li => .listitem,
            .dt => .term,
            .dd => .definition,

            // Forms & Inputs
            // TODO conditions:
            //  form  Has accessible name
            //  (none) No accessible name
            .form => .form,
            .input => {
                const input_type = try parser.inputGetType(@ptrCast(elt));
                switch (input_type.len) {
                    3 => {
                        // tel defaults to textbox
                        // url defaults to textbox
                    },
                    4 => {
                        if (std.ascii.eqlIgnoreCase(input_type, "date")) {
                            return .none;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "file")) {
                            return .none;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "time")) {
                            return .none;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "week")) {
                            return .none;
                        }
                        // text defaults to textbox
                    },
                    5 => {
                        if (std.ascii.eqlIgnoreCase(input_type, "color")) {
                            return .none;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "image")) {
                            return .button;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "month")) {
                            return .none;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "radio")) {
                            return .radio;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "range")) {
                            return .slider;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "reset")) {
                            return .button;
                        }
                        // email defaults to textbox.
                    },
                    6 => {
                        if (std.ascii.eqlIgnoreCase(input_type, "button")) {
                            return .button;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "hidden")) {
                            return .none;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "number")) {
                            return .spinbutton;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "search")) {
                            return .searchbox;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "submit")) {
                            return .button;
                        }
                    },
                    8 => {
                        if (std.ascii.eqlIgnoreCase(input_type, "checkbox")) {
                            return .checkbox;
                        }
                        if (std.ascii.eqlIgnoreCase(input_type, "password")) {
                            return .none;
                        }
                    },
                    14 => {
                        if (std.ascii.eqlIgnoreCase(input_type, "datetime-local")) {
                            return .none;
                        }
                    },
                    else => {},
                }
                return .textbox;
            },
            .textarea => .textbox,
            .select => {
                if (try getAttribute(node, "multiple") != null) {
                    return .listbox;
                }
                if (try getAttribute(node, "size")) |size| {
                    if (!std.ascii.eqlIgnoreCase(size, "1")) {
                        return .listbox;
                    }
                }
                return .combobox;
            },
            .option => .option,
            .optgroup, .fieldset => .group,
            .button => .button,
            .output => .status,
            .progress => .progressbar,
            .meter => .meter,
            .datalist => .listbox,

            // Interactive Elements
            .a, .area => {
                if (try getAttribute(node, "href") == null) {
                    return .none;
                }

                return .link;
            },
            .details => .group,
            .summary => .button,
            .dialog => .dialog,

            // Media
            .img => .img,
            .figure => .figure,

            // Tables
            .table => .table,
            .caption => .caption,
            .thead, .tbody, .tfoot => .rowgroup,
            .tr => .row,
            .th => {
                if (try getAttribute(node, "scope")) |scope| {
                    if (std.ascii.eqlIgnoreCase(scope, "row")) {
                        return .rowheader;
                    }
                }
                return .columnheader;
            },
            .td => .cell,

            // Text & Semantics
            .p => .paragraph,
            .hr => .separator,
            .blockquote => .blockquote,
            .code => .code,
            .em => .emphasis,
            .strong => .strong,
            .s, .del => .deletion,
            .ins => .insertion,
            .sub => .subscript,
            .sup => .superscript,
            .time => .time,
            .dfn => .term,

            // Document Structure
            .html => .none,
            .body => .none,

            // Deprecated/Obsolete Elements
            .marquee => .marquee,

            else => .none,
        };
    }
};

_node: *parser.Node,
role_attr: ?[]const u8,

pub fn fromNode(node: *parser.Node) !AXNode {
    return .{
        ._node = node,
        .role_attr = try getAttribute(node, "role"),
    };
}

const AXSource = enum(u8) {
    aria_labelledby,
    aria_label,
    label_element, // <label for="...">
    label_wrap, // <label><input></label>
    alt, // img alt attribute
    title, // title attribute
    placeholder, // input placeholder
    contents, // text content
    value, // input value
};

fn writeName(axnode: AXNode, w: anytype) !?AXSource {
    const node = axnode._node;
    if (parser.nodeType(node) == .document) {
        try w.write(try parser.documentHTMLGetTitle(@ptrCast(node)));
        return .title;
    }

    std.debug.assert(parser.nodeType(node) == .element);
    const elt: *parser.Element = @ptrCast(node);

    // TODO handle aria-labelledby attribute

    if (try parser.elementGetAttribute(elt, "aria-label")) |aria_label| {
        try w.write(aria_label);
        return .aria_label;
    }

    if (try parser.elementGetAttribute(elt, "alt")) |alt| {
        try w.write(alt);
        return .alt;
    }

    const tag = try parser.elementTag(elt);
    switch (tag) {
        .input => {
            const input_type = try parser.elementGetAttribute(elt, "type") orelse "text";
            switch (input_type.len) {
                5 => {
                    if (std.ascii.eqlIgnoreCase(input_type, "reset")) {
                        if (try parser.elementGetAttribute(elt, "value")) |value| {
                            try w.write(value);
                            return .value;
                        }
                    }
                },
                6 => {
                    if (std.ascii.eqlIgnoreCase(input_type, "button")) {
                        if (try parser.elementGetAttribute(elt, "value")) |value| {
                            try w.write(value);
                            return .value;
                        }
                    }
                    if (std.ascii.eqlIgnoreCase(input_type, "submit")) {
                        if (try parser.elementGetAttribute(elt, "value")) |value| {
                            try w.write(value);
                            return .value;
                        }
                    }
                },
                else => {},
            }

            // TODO Check for <label> with matching "for" attribute
            // TODO Check if input is wrapped in a <label>
        },
        .textarea,
        .select,
        .img,
        .audio,
        .video,
        .iframe,
        .embed,
        .object,
        .progress,
        .meter,
        => {},
        else => {
            if (parser.nodeTextContent(node)) |content| {
                try writeString(content, w);
                return .contents;
            }
        },
    }

    if (try parser.elementGetAttribute(elt, "title")) |title| {
        try w.write(title);
        return .title;
    }

    if (try parser.elementGetAttribute(elt, "placeholder")) |placeholder| {
        try w.write(placeholder);
        return .placeholder;
    }

    try w.write("");
    return null;
}

fn isHidden(elt: *parser.Element) !bool {
    if (try parser.elementGetAttribute(elt, "aria-hidden")) |value| {
        if (std.mem.eql(u8, value, "true")) {
            return true;
        }
    }

    if (try parser.elementHasAttribute(elt, "hidden")) {
        return true;
    }

    if (try parser.elementHasAttribute(elt, "inert")) {
        return true;
    }

    // TODO Check if aria-hidden ancestor exists
    // TODO Check CSS visibility (if you have access to computed styles)

    return false;
}

fn isIgnore(self: AXNode) !bool {
    const node = self._node;
    const role_attr = self.role_attr;

    if (parser.nodeType(node) == .document) {
        return false;
    }

    std.debug.assert(parser.nodeType(node) == .element);

    const elt: *parser.Element = @ptrCast(node);
    const tag = try parser.elementTag(elt);
    switch (tag) {
        .script,
        .style,
        .meta,
        .link,
        .title,
        .base,
        .head,
        .noscript,
        .template,
        .param,
        .source,
        .track,
        .datalist,
        .col,
        .colgroup,
        .html,
        .body,
        => return true,
        .img => {
            // Check for empty decorative images
            const alt_ = try parser.elementGetAttribute(elt, "alt");
            if (alt_ == null or alt_.?.len == 0) {
                return true;
            }
        },
        else => {},
    }

    if (role_attr) |role| {
        if (std.ascii.eqlIgnoreCase(role, "none") or std.ascii.eqlIgnoreCase(role, "presentation")) {
            return true;
        }
    }

    if (try isHidden(elt)) {
        return true;
    }

    // Generic containers with no semantic value
    if (tag == .div or tag == .span) {
        const has_role = try parser.elementGetAttribute(elt, "role") != null;
        const has_aria_label = try parser.elementGetAttribute(elt, "aria-label") != null;
        const has_aria_labelledby = try parser.elementGetAttribute(elt, "aria-labelledby") != null;

        if (!has_role and !has_aria_label and !has_aria_labelledby) {
            // Check if it has any non-ignored children
            const child_nodes = try parser.nodeGetChildNodes(node);
            const child_count = parser.nodeListLength(child_nodes);

            for (0..child_count) |i| {
                const child = parser.nodeListItem(child_nodes, @intCast(i)) orelse unreachable;
                const axn = try AXNode.fromNode(child);
                if (!try axn.isIgnore()) {
                    return false;
                }
            }

            return true;
        }
    }

    return false;
}

fn getRole(self: AXNode) ![]const u8 {
    if (self.role_attr) |role_value| {
        // TODO the role can have multiple comma separated values.
        return role_value;
    }

    const role_implicit = try AXRole.fromNode(self._node);

    return @tagName(role_implicit);
}

fn getAttribute(node: *parser.Node, name: []const u8) !?[]const u8 {
    if (parser.nodeType(node) != .element) {
        return null;
    }

    return try parser.elementGetAttribute(@ptrCast(node), name);
}

// Walker iterates over the DOM tree to return the next following
// node or null at the end.
// Accepts options.
pub const Walker = struct {
    const Opts = struct {
        skip_children: bool = false,
    };
    pub fn get_next(_: Walker, root: *parser.Node, cur: ?*parser.Node, opts: Opts) !?*parser.Node {
        var n = cur orelse root;

        if (!opts.skip_children) {
            if (parser.nodeFirstChild(n)) |next| {
                return next;
            }
        }

        if (parser.nodeNextSibling(n)) |next| {
            return next;
        }

        // Back to the parent of cur.
        // If cur has no parent, then the iteration is over.
        var parent = parser.nodeParentNode(n) orelse return null;

        var lastchild = parser.nodeLastChild(parent);
        while (n != root and n == lastchild) {
            n = parent;

            // Back to the prev's parent.
            // If prev has no parent, then the loop must stop.
            parent = parser.nodeParentNode(n) orelse break;

            lastchild = parser.nodeLastChild(parent);
        }

        if (n == root) {
            return null;
        }

        return parser.nodeNextSibling(n);
    }
};

// write a JSON string.
// replaces all whitspaces with a single space.
fn writeString(s: []const u8, w: anytype) !void {
    if (!std.unicode.utf8ValidateSlice(s)) {
        return error.InvalidUTF8String;
    }

    // replace white spaces with single space.
    try w.beginWriteRaw();
    try w.writer.writeByte('\"');
    var cursor: usize = 0;
    for (s, 0..) |c, i| {
        if (std.ascii.isWhitespace(c)) {
            // write string until space
            if (cursor < i) {
                try w.writer.writeAll(s[cursor..i]);
                try w.writer.writeByte(' ');
            }
            cursor = i + 1;
        }
    }
    // write the reminder string
    if (cursor < s.len) {
        try w.writer.writeAll(s[cursor..]);
    }
    try w.writer.writeByte('\"');
    w.endWriteRaw();
}
