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
const Page = @import("../browser/Page.zig");
const DOMNode = @import("../browser/webapi/Node.zig");
const URL = @import("../browser/URL.zig");

const AXNode = @This();
const Node = @import("Node.zig");

// Need a custom writer, because we can't just serialize the node as-is.
// Sometimes we want to serializ the node without chidren, sometimes with just
// its direct children, and sometimes the entire tree.
// (For now, we only support direct children)
pub const Writer = struct {
    root: *const Node,
    registry: *Node.Registry,
    page: *Page,

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
        const root = try AXNode.fromNode(node.dom);
        if (try self.writeNode(node.id, root, w)) {
            // skip children
            try w.endArray();
            return;
        }
        try self.writeNodeChildren(root, w);
        try w.endArray();
    }

    fn writeNodeChildren(self: *const Writer, parent: AXNode, w: anytype) !void {
        var it = parent.dom.childrenIterator();
        const ignore_text = ignoreText(parent.dom);
        while (it.next()) |dom_node| {
            switch (dom_node._type) {
                .cdata => {
                    if (dom_node.is(DOMNode.CData.Text) == null) {
                        continue;
                    }
                    if (ignore_text) {
                        continue;
                    }
                },
                .element => {},
                else => continue,
            }

            const node = try self.registry.register(dom_node);
            const axn = try AXNode.fromNode(node.dom);
            if (try self.writeNode(node.id, axn, w)) {
                // skip children
                continue;
            }
            try self.writeNodeChildren(axn, w);
        }
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
        const dom_node = axnode.dom;
        const page = self.page;
        switch (dom_node._type) {
            .document => |document| {
                const uri = document.getURL(page);
                try self.writeAXProperty(.{ .name = .url, .value = .{ .type = .string, .value = .{ .string = uri } } }, w);
                try self.writeAXProperty(.{ .name = .focusable, .value = .{ .type = .booleanOrUndefined, .value = .{ .boolean = true } } }, w);
                return;
            },
            .cdata => return,
            .element => |el| switch (el.getTag()) {
                .h1 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 1 } } }, w),
                .h2 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 2 } } }, w),
                .h3 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 3 } } }, w),
                .h4 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 4 } } }, w),
                .h5 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 5 } } }, w),
                .h6 => try self.writeAXProperty(.{ .name = .level, .value = .{ .type = .integer, .value = .{ .uint = 6 } } }, w),
                .img => {
                    const uri = el.getAttributeSafe("src") orelse return;
                    // TODO make uri absolute
                    try self.writeAXProperty(.{ .name = .url, .value = .{ .type = .string, .value = .{ .string = uri } } }, w);
                },
                .anchor => {
                    const uri = el.getAttributeSafe("href") orelse return;
                    // TODO make uri absolute
                    try self.writeAXProperty(.{ .name = .url, .value = .{ .type = .string, .value = .{ .string = uri } } }, w);
                    try self.writeAXProperty(.{ .name = .focusable, .value = .{ .type = .booleanOrUndefined, .value = .{ .boolean = true } } }, w);
                },
                else => {},
            },
            else => |tag| {
                log.debug(.cdp, "invalid tag", .{ .tag = tag });
                return error.InvalidTag;
            },
        }
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
    fn writeNode(self: *const Writer, id: u32, axn: AXNode, w: anytype) !bool {
        // ignore empty texts
        try w.beginObject();

        try w.objectField("nodeId");
        try w.write(id);

        try w.objectField("backendDOMNodeId");
        try w.write(id);

        try w.objectField("role");
        try self.writeAXValue(.{ .type = .role, .value = .{ .string = try axn.getRole() } }, w);

        const ignore = try axn.isIgnore(self.page);
        try w.objectField("ignored");
        try w.write(ignore);

        if (ignore) {
            // Ignore reasons
            try w.objectField("ignoredReasons");
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
            const source = try axn.writeName(w, self.page);
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

        const n = axn.dom;

        // Parent
        if (n._parent) |p| {
            const parent_node = try self.registry.register(p);
            try w.objectField("parentId");
            try w.write(parent_node.id);
        }

        // Children
        const skip_children = axn.ignoreChildren();

        try w.objectField("childIds");
        try w.beginArray();
        if (!skip_children) {
            var registry = self.registry;
            var it = n.childrenIterator();
            while (it.next()) |child| {
                // ignore non-elements or text.
                if (child.is(DOMNode.Element.Html) == null and child.is(DOMNode.CData.Text) == null) {
                    continue;
                }

                const child_node = try registry.register(child);
                try w.write(child_node.id);
            }
        }
        try w.endArray();

        try w.endObject();

        return skip_children;
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
    image,
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
    RootWebArea,
    LineBreak,
    StaticText,

    fn fromNode(node: *DOMNode) !AXRole {
        return switch (node._type) {
            .document => return .RootWebArea, // Chrome specific.
            .cdata => |cd| {
                if (cd.is(DOMNode.CData.Text) == null) {
                    log.debug(.cdp, "invalid tag", .{ .tag = cd });
                    return error.InvalidTag;
                }

                return .StaticText;
            },
            .element => |el| switch (el.getTag()) {
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
                    const input = el.as(DOMNode.Element.Html.Input);
                    return switch (input._input_type) {
                        .tel, .url, .email, .text => .textbox,
                        .image, .reset, .button, .submit => .button,
                        .radio => .radio,
                        .range => .slider,
                        .number => .spinbutton,
                        .search => .searchbox,
                        .checkbox => .checkbox,
                        .password, .datetime_local, .hidden, .month, .color, .week, .time, .file, .date => .none,
                    };
                },
                .textarea => .textbox,
                .select => {
                    if (el.getAttributeSafe("multiple") != null) {
                        return .listbox;
                    }
                    if (el.getAttributeSafe("size")) |size| {
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
                .anchor, .area => {
                    if (el.getAttributeSafe("href") == null) {
                        return .none;
                    }

                    return .link;
                },
                .details => .group,
                .summary => .button,
                .dialog => .dialog,

                // Media
                .img => .image,
                .figure => .figure,

                // Tables
                .table => .table,
                .caption => .caption,
                .thead, .tbody, .tfoot => .rowgroup,
                .tr => .row,
                .th => {
                    if (el.getAttributeSafe("scope")) |scope| {
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

                .br => .LineBreak,

                else => .none,
            },
            else => |tag| {
                log.debug(.cdp, "invalid tag", .{ .tag = tag });
                return error.InvalidTag;
            },
        };
    }
};

dom: *DOMNode,
role_attr: ?[]const u8,

pub fn fromNode(dom: *DOMNode) !AXNode {
    return .{
        .dom = dom,
        .role_attr = blk: {
            if (dom.is(DOMNode.Element.Html) == null) {
                break :blk null;
            }
            const elt = dom.as(DOMNode.Element);
            break :blk elt.getAttributeSafe("role");
        },
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

fn writeName(axnode: AXNode, w: anytype, page: *Page) !?AXSource {
    const node = axnode.dom;

    return switch (node._type) {
        .document => |doc| switch (doc._type) {
            .html => |doc_html| {
                try w.write(try doc_html.getTitle(page));
                return .title;
            },
            else => null,
        },
        .cdata => |cd| switch (cd._type) {
            .text => |*text| {
                try writeString(text.getWholeText(), w);
                return .contents;
            },
            else => null,
        },
        .element => |el| {
            // TODO handle aria-labelledby attribute

            if (el.getAttributeSafe("aria-label")) |aria_label| {
                try w.write(aria_label);
                return .aria_label;
            }

            if (el.getAttributeSafe("alt")) |alt| {
                try w.write(alt);
                return .alt;
            }

            switch (el.getTag()) {
                .br => {
                    try writeString("\n", w);
                    return .contents;
                },
                .input => {
                    const input = el.as(DOMNode.Element.Html.Input);
                    switch (input._input_type) {
                        .reset, .button, .submit => {
                            try w.write(input.getValue());
                            return .value;
                        },
                        else => {},
                    }
                    // TODO Check for <label> with matching "for" attribute
                    // TODO Check if input is wrapped in a <label>
                },
                .textarea, .select, .img, .audio, .video, .iframe, .embed, .object, .progress, .meter, .p => {},
                else => {
                    // write text content if exists.
                    var buf = std.Io.Writer.Allocating.init(page.call_arena);
                    try el.getInnerText(&buf.writer);
                    const written = buf.written();
                    try w.write(written);
                    return .contents;
                },
            }

            if (el.getAttributeSafe("title")) |title| {
                try w.write(title);
                return .title;
            }

            if (el.getAttributeSafe("placeholder")) |placeholder| {
                try w.write(placeholder);
                return .placeholder;
            }

            try w.write("");
            return null;
        },
        else => {
            try w.write("");
            return null;
        },
    };
}

fn isHidden(elt: *DOMNode.Element) bool {
    if (elt.getAttributeSafe("aria-hidden")) |value| {
        if (std.mem.eql(u8, value, "true")) {
            return true;
        }
    }

    if (elt.hasAttributeSafe("hidden")) {
        return true;
    }

    if (elt.hasAttributeSafe("inert")) {
        return true;
    }

    // TODO Check if aria-hidden ancestor exists
    // TODO Check CSS visibility (if you have access to computed styles)

    return false;
}

fn ignoreText(node: *DOMNode) bool {
    if (node.is(DOMNode.Element.Html) == null) {
        return false;
    }

    const elt = node.as(DOMNode.Element);
    return switch (elt.getTag()) {
        .p => false,
        else => true,
    };
}

fn ignoreChildren(self: AXNode) bool {
    const node = self.dom;
    if (node.is(DOMNode.Element.Html) == null) {
        return false;
    }

    const elt = node.as(DOMNode.Element);
    return switch (elt.getTag()) {
        .head => true,
        else => false,
    };
}

fn isIgnore(self: AXNode, page: *Page) !bool {
    const node = self.dom;
    const role_attr = self.role_attr;

    if (node.is(DOMNode.Element.Html) == null) {
        return false;
    }
    const elt = node.as(DOMNode.Element);
    const tag = elt.getTag();
    switch (tag) {
        .script, .style, .meta, .link, .title, .base, .head, .noscript, .template, .param, .source, .track, .datalist, .col, .colgroup, .html, .body => return true,
        .img => {
            // Check for empty decorative images
            const alt_ = elt.getAttributeSafe("alt");
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

    if (isHidden(elt)) {
        return true;
    }

    // Generic containers with no semantic value
    if (tag == .div or tag == .span) {
        const has_role = elt.hasAttributeSafe("role");
        const has_aria_label = elt.hasAttributeSafe("aria-label");
        const has_aria_labelledby = elt.hasAttributeSafe("aria-labelledby");

        if (!has_role and !has_aria_label and !has_aria_labelledby) {
            // Check if it has any non-ignored children
            var it = node.childrenIterator();
            while (it.next()) |child| {
                const axn = try AXNode.fromNode(child);
                if (!try axn.isIgnore(page)) {
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

    const role_implicit = try AXRole.fromNode(self.dom);

    return @tagName(role_implicit);
}

// Replace successives whitespaces with one withespace.
// Trims left and right according to the options.
// Returns true if the string ends with a trimmed whitespace.
fn writeString(s: []const u8, w: anytype) !void {
    try w.beginWriteRaw();
    try w.writer.writeByte('\"');
    try stripWhitespaces(s, w.writer);
    try w.writer.writeByte('\"');
    w.endWriteRaw();
}

fn stripWhitespaces(s: []const u8, writer: anytype) !void {
    var start: usize = 0;
    var prev_w: ?bool = null;
    var is_w: bool = undefined;

    for (s, 0..) |c, i| {
        is_w = std.ascii.isWhitespace(c);

        // Detect the first char type.
        if (prev_w == null) {
            prev_w = is_w;
        }
        // The current char is the same kind of char, the chunk continues.
        if (prev_w.? == is_w) {
            continue;
        }

        // Starting here, the chunk changed.
        if (is_w) {
            // We have a chunk of non-whitespaces, we write it as it.
            try writer.writeAll(s[start..i]);
        } else {
            // We have a chunk of whitespaces, replace with one space,
            // depending the position.
            if (start > 0) {
                try writer.writeByte(' ');
            }
        }
        // Start the new chunk.
        prev_w = is_w;
        start = i;
    }
    // Write the reminder chunk.
    if (!is_w) {
        // last chunk is non whitespaces.
        try writer.writeAll(s[start..]);
    }
}

test "AXnode: stripWhitespaces" {
    const allocator = std.testing.allocator;

    const TestCase = struct {
        value: []const u8,
        expected: []const u8,
    };

    const test_cases = [_]TestCase{
        .{ .value = "   ", .expected = "" },
        .{ .value = "   ", .expected = "" },
        .{ .value = "foo bar", .expected = "foo bar" },
        .{ .value = "foo  bar", .expected = "foo bar" },
        .{ .value = "  foo bar", .expected = "foo bar" },
        .{ .value = "foo bar  ", .expected = "foo bar" },
        .{ .value = "  foo bar  ", .expected = "foo bar" },
        .{ .value = "foo\n\tbar", .expected = "foo bar" },
        .{ .value = "\tfoo bar   baz   \t\n yeah\r\n", .expected = "foo bar baz yeah" },
    };

    var buffer = std.io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    for (test_cases) |test_case| {
        buffer.clearRetainingCapacity();
        try stripWhitespaces(test_case.value, &buffer.writer);
        try std.testing.expectEqualStrings(test_case.expected, buffer.written());
    }
}

const testing = @import("testing.zig");
test "AXNode: writer" {
    var registry = Node.Registry.init(testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("cdp/dom1.html");
    defer page._session.removePage();
    var doc = page.window._document;

    const node = try registry.register(doc.asNode());
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Writer{
        .root = node,
        .registry = &registry,
        .page = page,
    }, .{});
    defer testing.allocator.free(json);
}
