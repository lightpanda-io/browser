// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const URL = @import("URL.zig");
const TreeWalker = @import("webapi/TreeWalker.zig");
const Element = @import("webapi/Element.zig");
const Node = @import("webapi/Node.zig");
const EventTarget = @import("webapi/EventTarget.zig");

const Allocator = std.mem.Allocator;

pub const InteractivityType = enum {
    native,
    aria,
    contenteditable,
    listener,
    focusable,
};

pub const InteractiveElement = struct {
    backendNodeId: ?u32 = null,
    node: *Node,
    tag_name: []const u8,
    role: ?[]const u8,
    name: ?[]const u8,
    interactivity_type: InteractivityType,
    listener_types: []const []const u8,
    disabled: bool,
    tab_index: i32,
    id: ?[]const u8,
    class: ?[]const u8,
    href: ?[]const u8,
    input_type: ?[]const u8,
    value: ?[]const u8,
    element_name: ?[]const u8,
    placeholder: ?[]const u8,

    pub fn jsonStringify(self: *const InteractiveElement, jw: anytype) !void {
        try jw.beginObject();

        if (self.backendNodeId) |id| {
            try jw.objectField("backendNodeId");
            try jw.write(id);
        }

        try jw.objectField("tagName");
        try jw.write(self.tag_name);

        try jw.objectField("role");
        try jw.write(self.role);

        try jw.objectField("name");
        try jw.write(self.name);

        try jw.objectField("type");
        try jw.write(@tagName(self.interactivity_type));

        if (self.listener_types.len > 0) {
            try jw.objectField("listeners");
            try jw.beginArray();
            for (self.listener_types) |lt| {
                try jw.write(lt);
            }
            try jw.endArray();
        }

        if (self.disabled) {
            try jw.objectField("disabled");
            try jw.write(true);
        }

        try jw.objectField("tabIndex");
        try jw.write(self.tab_index);

        if (self.id) |v| {
            try jw.objectField("id");
            try jw.write(v);
        }

        if (self.class) |v| {
            try jw.objectField("class");
            try jw.write(v);
        }

        if (self.href) |v| {
            try jw.objectField("href");
            try jw.write(v);
        }

        if (self.input_type) |v| {
            try jw.objectField("inputType");
            try jw.write(v);
        }

        if (self.value) |v| {
            try jw.objectField("value");
            try jw.write(v);
        }

        if (self.element_name) |v| {
            try jw.objectField("elementName");
            try jw.write(v);
        }

        if (self.placeholder) |v| {
            try jw.objectField("placeholder");
            try jw.write(v);
        }

        try jw.endObject();
    }
};

/// Populate backendNodeId on each interactive element by registering
/// their nodes in the given registry. Works with both CDP and MCP registries.
pub fn registerNodes(elements: []InteractiveElement, registry: anytype) !void {
    for (elements) |*el| {
        const registered = try registry.register(el.node);
        el.backendNodeId = registered.id;
    }
}

/// Collect all interactive elements under `root`.
pub fn collectInteractiveElements(
    root: *Node,
    arena: Allocator,
    page: *Page,
) ![]InteractiveElement {
    // Pre-build a map of event_target pointer → event type names,
    // so classify and getListenerTypes are both O(1) per element.
    const listener_targets = try buildListenerTargetMap(page, arena);

    var css_cache: Element.PointerEventsCache = .empty;

    var results: std.ArrayList(InteractiveElement) = .empty;

    var tw = TreeWalker.Full.init(root, .{});
    while (tw.next()) |node| {
        const el = node.is(Element) orelse continue;
        const html_el = el.is(Element.Html) orelse continue;

        // Skip non-visual elements that are never user-interactive.
        switch (el.getTag()) {
            .script, .style, .link, .meta, .head, .noscript, .template => continue,
            else => {},
        }

        const itype = classifyInteractivity(page, el, html_el, listener_targets, &css_cache) orelse continue;

        const listener_types = getListenerTypes(
            el.asEventTarget(),
            listener_targets,
        );

        try results.append(arena, .{
            .node = node,
            .tag_name = el.getTagNameLower(),
            .role = getRole(el),
            .name = try getAccessibleName(el, arena),
            .interactivity_type = itype,
            .listener_types = listener_types,
            .disabled = el.isDisabled(),
            .tab_index = html_el.getTabIndex(),
            .id = el.getAttributeSafe(comptime .wrap("id")),
            .class = el.getAttributeSafe(comptime .wrap("class")),
            .href = if (el.getAttributeSafe(comptime .wrap("href"))) |href|
                URL.resolve(arena, page.base(), href, .{ .encode = true }) catch href
            else
                null,
            .input_type = getInputType(el),
            .value = getInputValue(el),
            .element_name = el.getAttributeSafe(comptime .wrap("name")),
            .placeholder = el.getAttributeSafe(comptime .wrap("placeholder")),
        });
    }

    return results.items;
}

pub const ListenerTargetMap = std.AutoHashMapUnmanaged(usize, std.ArrayList([]const u8));

/// Pre-build a map from event_target pointer → list of event type names.
/// This lets both classifyInteractivity (O(1) "has any?") and
/// getListenerTypes (O(1) "which ones?") avoid re-iterating per element.
pub fn buildListenerTargetMap(page: *Page, arena: Allocator) !ListenerTargetMap {
    var map = ListenerTargetMap{};

    // addEventListener registrations
    var it = page._event_manager.lookup.iterator();
    while (it.next()) |entry| {
        const list = entry.value_ptr.*;
        if (list.first != null) {
            const gop = try map.getOrPut(arena, entry.key_ptr.event_target);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, entry.key_ptr.type_string.str());
        }
    }

    // Inline handlers (onclick, onmousedown, etc.)
    var attr_it = page._event_target_attr_listeners.iterator();
    while (attr_it.next()) |entry| {
        const gop = try map.getOrPut(arena, @intFromPtr(entry.key_ptr.target));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        // Strip "on" prefix to get the event type name.
        try gop.value_ptr.append(arena, @tagName(entry.key_ptr.handler)[2..]);
    }

    return map;
}

pub fn classifyInteractivity(
    page: *Page,
    el: *Element,
    html_el: *Element.Html,
    listener_targets: ListenerTargetMap,
    cache: ?*Element.PointerEventsCache,
) ?InteractivityType {
    if (el.hasPointerEventsNone(cache, page)) return null;

    // 1. Native interactive by tag
    switch (el.getTag()) {
        .button, .summary, .details, .select, .textarea => return .native,
        .anchor, .area => {
            if (el.getAttributeSafe(comptime .wrap("href")) != null) return .native;
        },
        .input => {
            if (el.is(Element.Html.Input)) |input| {
                if (input._input_type != .hidden) return .native;
            }
        },
        else => {},
    }

    // 2. ARIA interactive role
    if (el.getAttributeSafe(comptime .wrap("role"))) |role| {
        if (isInteractiveRole(role)) return .aria;
    }

    // 3. contenteditable (15 bytes, exceeds SSO limit for comptime)
    if (el.getAttributeSafe(.wrap("contenteditable"))) |ce| {
        if (ce.len == 0 or std.ascii.eqlIgnoreCase(ce, "true")) return .contenteditable;
    }

    // 4. Event listeners (addEventListener or inline handlers)
    const et_ptr = @intFromPtr(html_el.asEventTarget());
    if (listener_targets.get(et_ptr) != null) return .listener;

    // 5. Explicitly focusable via tabindex.
    // Only count elements with an EXPLICIT tabindex attribute,
    // since getTabIndex() returns 0 for all interactive tags by default
    // (including anchors without href and hidden inputs).
    if (el.getAttributeSafe(comptime .wrap("tabindex"))) |_| {
        if (html_el.getTabIndex() >= 0) return .focusable;
    }

    return null;
}

pub fn isInteractiveRole(role: []const u8) bool {
    const MAX_LEN = "menuitemcheckbox".len;
    if (role.len > MAX_LEN) return false;
    var buf: [MAX_LEN]u8 = undefined;
    const lowered = std.ascii.lowerString(&buf, role);
    const interactive_roles = std.StaticStringMap(void).initComptime(.{
        .{ "button", {} },
        .{ "checkbox", {} },
        .{ "combobox", {} },
        .{ "iframe", {} },
        .{ "link", {} },
        .{ "listbox", {} },
        .{ "menuitem", {} },
        .{ "menuitemcheckbox", {} },
        .{ "menuitemradio", {} },
        .{ "option", {} },
        .{ "radio", {} },
        .{ "searchbox", {} },
        .{ "slider", {} },
        .{ "spinbutton", {} },
        .{ "switch", {} },
        .{ "tab", {} },
        .{ "textbox", {} },
        .{ "treeitem", {} },
    });
    return interactive_roles.has(lowered);
}

pub fn isContentRole(role: []const u8) bool {
    const MAX_LEN = "columnheader".len;
    if (role.len > MAX_LEN) return false;
    var buf: [MAX_LEN]u8 = undefined;
    const lowered = std.ascii.lowerString(&buf, role);
    const content_roles = std.StaticStringMap(void).initComptime(.{
        .{ "article", {} },
        .{ "cell", {} },
        .{ "columnheader", {} },
        .{ "gridcell", {} },
        .{ "heading", {} },
        .{ "listitem", {} },
        .{ "main", {} },
        .{ "navigation", {} },
        .{ "region", {} },
        .{ "rowheader", {} },
    });
    return content_roles.has(lowered);
}

fn getRole(el: *Element) ?[]const u8 {
    // Explicit role attribute takes precedence
    if (el.getAttributeSafe(comptime .wrap("role"))) |role| return role;

    // Implicit role from tag
    return switch (el.getTag()) {
        .button, .summary => "button",
        .anchor, .area => if (el.getAttributeSafe(comptime .wrap("href")) != null) "link" else null,
        .input => blk: {
            if (el.is(Element.Html.Input)) |input| {
                break :blk switch (input._input_type) {
                    .text, .tel, .url, .email => "textbox",
                    .checkbox => "checkbox",
                    .radio => "radio",
                    .button, .submit, .reset, .image => "button",
                    .range => "slider",
                    .number => "spinbutton",
                    .search => "searchbox",
                    else => null,
                };
            }
            break :blk null;
        },
        .select => "combobox",
        .textarea => "textbox",
        .details => "group",
        else => null,
    };
}

fn getAccessibleName(el: *Element, arena: Allocator) !?[]const u8 {
    // aria-label
    if (el.getAttributeSafe(comptime .wrap("aria-label"))) |v| {
        if (v.len > 0) return v;
    }

    // alt (for img, input[type=image])
    if (el.getAttributeSafe(comptime .wrap("alt"))) |v| {
        if (v.len > 0) return v;
    }

    // title
    if (el.getAttributeSafe(comptime .wrap("title"))) |v| {
        if (v.len > 0) return v;
    }

    // placeholder
    if (el.getAttributeSafe(comptime .wrap("placeholder"))) |v| {
        if (v.len > 0) return v;
    }

    // value (for buttons)
    if (el.getTag() == .input) {
        if (el.getAttributeSafe(comptime .wrap("value"))) |v| {
            if (v.len > 0) return v;
        }
    }

    // Text content (first non-empty text node, trimmed)
    return try getTextContent(el.asNode(), arena);
}

fn getTextContent(node: *Node, arena: Allocator) !?[]const u8 {
    var tw: TreeWalker.FullExcludeSelf = .init(node, .{});

    var arr: std.ArrayList(u8) = .empty;
    var single_chunk: ?[]const u8 = null;

    while (tw.next()) |child| {
        // Skip text inside script/style elements.
        if (child.is(Element)) |el| {
            switch (el.getTag()) {
                .script, .style => {
                    tw.skipChildren();
                    continue;
                },
                else => {},
            }
        }
        if (child.is(Node.CData)) |cdata| {
            if (cdata.is(Node.CData.Text)) |text| {
                const content = std.mem.trim(u8, text.getWholeText(), &std.ascii.whitespace);
                if (content.len > 0) {
                    if (single_chunk == null and arr.items.len == 0) {
                        single_chunk = content;
                    } else {
                        if (single_chunk) |sc| {
                            try arr.appendSlice(arena, sc);
                            try arr.append(arena, ' ');
                            single_chunk = null;
                        }
                        try arr.appendSlice(arena, content);
                        try arr.append(arena, ' ');
                    }
                }
            }
        }
    }

    if (single_chunk) |sc| return sc;
    if (arr.items.len == 0) return null;

    // strip out trailing space
    return arr.items[0 .. arr.items.len - 1];
}

fn getInputType(el: *Element) ?[]const u8 {
    if (el.is(Element.Html.Input)) |input| {
        return input._input_type.toString();
    }
    return null;
}

fn getInputValue(el: *Element) ?[]const u8 {
    if (el.is(Element.Html.Input)) |input| {
        return input.getValue();
    }
    return null;
}

/// Get all event listener types registered on this target.
fn getListenerTypes(target: *EventTarget, listener_targets: ListenerTargetMap) []const []const u8 {
    if (listener_targets.get(@intFromPtr(target))) |types| return types.items;
    return &.{};
}

const testing = @import("../testing.zig");

fn testInteractive(html: []const u8) ![]InteractiveElement {
    const page = try testing.test_session.createPage();
    defer testing.test_session.removePage();

    const doc = page.window._document;
    const div = try doc.createElement("div", null, page);
    try page.parseHtmlAsChildren(div.asNode(), html);

    return collectInteractiveElements(div.asNode(), page.call_arena, page);
}

test "browser.interactive: button" {
    const elements = try testInteractive("<button>Click me</button>");
    try testing.expectEqual(1, elements.len);
    try testing.expectEqual("button", elements[0].tag_name);
    try testing.expectEqual("button", elements[0].role.?);
    try testing.expectEqual("Click me", elements[0].name.?);
    try testing.expectEqual(InteractivityType.native, elements[0].interactivity_type);
}

test "browser.interactive: anchor with href" {
    const elements = try testInteractive("<a href=\"/page\">Link</a>");
    try testing.expectEqual(1, elements.len);
    try testing.expectEqual("a", elements[0].tag_name);
    try testing.expectEqual("link", elements[0].role.?);
    try testing.expectEqual("Link", elements[0].name.?);
}

test "browser.interactive: anchor without href" {
    const elements = try testInteractive("<a>Not a link</a>");
    try testing.expectEqual(0, elements.len);
}

test "browser.interactive: input types" {
    const elements = try testInteractive(
        \\<input type="text" placeholder="Search">
        \\<input type="hidden" name="csrf">
    );
    try testing.expectEqual(1, elements.len);
    try testing.expectEqual("input", elements[0].tag_name);
    try testing.expectEqual("text", elements[0].input_type.?);
    try testing.expectEqual("Search", elements[0].placeholder.?);
}

test "browser.interactive: select and textarea" {
    const elements = try testInteractive(
        \\<select name="color"><option>Red</option></select>
        \\<textarea name="msg"></textarea>
    );
    try testing.expectEqual(2, elements.len);
    try testing.expectEqual("select", elements[0].tag_name);
    try testing.expectEqual("textarea", elements[1].tag_name);
}

test "browser.interactive: aria role" {
    const elements = try testInteractive("<div role=\"button\">Custom</div>");
    try testing.expectEqual(1, elements.len);
    try testing.expectEqual("div", elements[0].tag_name);
    try testing.expectEqual("button", elements[0].role.?);
    try testing.expectEqual(InteractivityType.aria, elements[0].interactivity_type);
}

test "browser.interactive: contenteditable" {
    const elements = try testInteractive("<div contenteditable=\"true\">Edit me</div>");
    try testing.expectEqual(1, elements.len);
    try testing.expectEqual(InteractivityType.contenteditable, elements[0].interactivity_type);
}

test "browser.interactive: tabindex" {
    const elements = try testInteractive("<div tabindex=\"0\">Focusable</div>");
    try testing.expectEqual(1, elements.len);
    try testing.expectEqual(InteractivityType.focusable, elements[0].interactivity_type);
    try testing.expectEqual(@as(i32, 0), elements[0].tab_index);
}

test "browser.interactive: disabled" {
    const elements = try testInteractive("<button disabled>Off</button>");
    try testing.expectEqual(1, elements.len);
    try testing.expect(elements[0].disabled);
}

test "browser.interactive: disabled by fieldset" {
    const elements = try testInteractive(
        \\<fieldset disabled>
        \\  <button>Disabled</button>
        \\  <legend><button>In legend</button></legend>
        \\</fieldset>
    );
    try testing.expectEqual(2, elements.len);
    // Button outside legend is disabled by fieldset
    try testing.expect(elements[0].disabled);
    // Button inside first legend is NOT disabled
    try testing.expect(!elements[1].disabled);
}

test "browser.interactive: pointer-events none" {
    const elements = try testInteractive("<button style=\"pointer-events: none;\">Click me</button>");
    try testing.expectEqual(0, elements.len);
}

test "browser.interactive: non-interactive div" {
    const elements = try testInteractive("<div>Just text</div>");
    try testing.expectEqual(0, elements.len);
}

test "browser.interactive: details and summary" {
    const elements = try testInteractive("<details><summary>More</summary><p>Content</p></details>");
    try testing.expectEqual(2, elements.len);
    try testing.expectEqual("details", elements[0].tag_name);
    try testing.expectEqual("summary", elements[1].tag_name);
}

test "browser.interactive: mixed elements" {
    const elements = try testInteractive(
        \\<div>
        \\  <a href="/home">Home</a>
        \\  <p>Some text</p>
        \\  <button id="btn1">Submit</button>
        \\  <input type="email" placeholder="Email">
        \\  <div>Not interactive</div>
        \\  <div role="tab">Tab</div>
        \\</div>
    );
    try testing.expectEqual(4, elements.len);
}
