const std = @import("std");
const Page = @import("../browser/Page.zig");
const URL = @import("../browser/URL.zig");
const Node = @import("../browser/webapi/Node.zig");
const Element = @import("../browser/webapi/Element.zig");
const HTMLDocument = @import("../browser/webapi/HTMLDocument.zig");
const DisplayList = @import("DisplayList.zig").DisplayList;
const Command = @import("DisplayList.zig").Command;
const Color = @import("DisplayList.zig").Color;
const LinkRegion = @import("DisplayList.zig").LinkRegion;
const ImageCommand = @import("DisplayList.zig").ImageCommand;

pub const PaintOpts = struct {
    viewport_width: i32,
    layout_scale: i32 = 100,
    page_margin: i32 = 20,
    block_min_width: i32 = 280,
    inline_min_width: i32 = 120,
    min_height: i32 = 24,
};

pub fn paintDocument(allocator: std.mem.Allocator, page: *Page, opts: PaintOpts) !DisplayList {
    var list = DisplayList{
        .layout_scale = opts.layout_scale,
        .page_margin = opts.page_margin,
    };
    errdefer list.deinit(allocator);

    const root = if (page.window._document.is(HTMLDocument)) |html_doc|
        if (html_doc.getBody()) |body| body.asNode() else page.window._document.asNode()
    else
        page.window._document.asNode();

    var painter = Painter{
        .allocator = allocator,
        .page = page,
        .opts = opts,
        .list = &list,
    };
    var cursor = FlowCursor.init(
        opts.page_margin,
        opts.page_margin,
        @max(@as(i32, 160), opts.viewport_width - (opts.page_margin * 2)),
    );
    try painter.paintNode(root, &cursor);
    return list;
}

const FlowCursor = struct {
    const Position = struct {
        x: i32,
        y: i32,
    };

    left: i32,
    width: i32,
    cursor_y: i32,
    cursor_x: i32,
    line_height: i32,

    fn init(left: i32, top: i32, width: i32) FlowCursor {
        return .{
            .left = left,
            .width = width,
            .cursor_y = top,
            .cursor_x = left,
            .line_height = 0,
        };
    }

    fn finishInlineRow(self: *FlowCursor, spacing: i32) void {
        if (self.line_height <= 0) {
            self.cursor_x = self.left;
            return;
        }
        self.cursor_y += self.line_height + spacing;
        self.cursor_x = self.left;
        self.line_height = 0;
    }

    fn beginBlock(self: *FlowCursor, margins: EdgeSizes) Position {
        self.finishInlineRow(0);
        return .{
            .x = self.left + margins.left,
            .y = self.cursor_y + margins.top,
        };
    }

    fn beginInlineLeaf(self: *FlowCursor, width: i32, margins: EdgeSizes) Position {
        const total_width = margins.left + width + margins.right;
        if (self.line_height > 0 and self.cursor_x + total_width > self.left + self.width) {
            self.finishInlineRow(2);
        }
        return .{
            .x = self.cursor_x + margins.left,
            .y = self.cursor_y + margins.top,
        };
    }

    fn advanceBlock(self: *FlowCursor, rect: anytype, margins: EdgeSizes, spacing: i32) void {
        self.cursor_y = rect.y + rect.height + margins.bottom + spacing;
        self.cursor_x = self.left;
        self.line_height = 0;
    }

    fn advanceInlineLeaf(self: *FlowCursor, rect: anytype, margins: EdgeSizes, spacing: i32) void {
        self.cursor_x = rect.x + rect.width + margins.right + spacing;
        self.line_height = @max(self.line_height, margins.top + rect.height + margins.bottom);
    }

    fn consumedHeightSince(self: *const FlowCursor, top: i32) i32 {
        return @max(@as(i32, 0), self.cursor_y - top) + @max(@as(i32, 0), self.line_height);
    }
};

const EdgeSizes = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,

    fn horizontal(self: EdgeSizes) i32 {
        return self.left + self.right;
    }

    fn vertical(self: EdgeSizes) i32 {
        return self.top + self.bottom;
    }
};

const Painter = struct {
    allocator: std.mem.Allocator,
    page: *Page,
    opts: PaintOpts,
    list: *DisplayList,

    fn paintNode(self: *Painter, node: *Node, cursor: *FlowCursor) anyerror!void {
        switch (node._type) {
            .document, .document_fragment => {
                var it = node.childrenIterator();
                while (it.next()) |child| {
                    try self.paintNode(child, cursor);
                }
            },
            .element => |element| try self.paintElement(element, cursor),
            .cdata => |cdata| switch (cdata._type) {
                .text => try self.paintInlineTextNode(cdata, cursor),
                else => {},
            },
            else => {},
        }
    }

    fn paintInlineTextNode(self: *Painter, cdata: *Node.CData, cursor: *FlowCursor) anyerror!void {
        const parent = cdata.asNode().parentElement() orelse return;
        const parent_style = try self.page.window.getComputedStyle(parent, null, self.page);
        const parent_decl = parent_style.asCSSStyleDeclaration();
        const parent_display = parent_decl.getPropertyValue("display", self.page);
        if (!isInlineDisplay(parent_display)) {
            return;
        }

        const raw = cdata.getData().str();
        const normalized = try normalizeInlineText(self.allocator, raw);
        defer self.allocator.free(normalized);
        if (normalized.len == 0) {
            return;
        }
        if (cursor.line_height <= 0 and std.mem.trim(u8, normalized, " ").len == 0) {
            return;
        }

        const parent_tag = parent.getTag();
        const font_size = parseFontSizePx(parent_decl.getPropertyValue("font-size", self.page)) orelse defaultFontSize(parent_tag);
        const width = std.math.clamp(
            estimateTextWidth(normalized, font_size) + 8,
            8,
            @max(@as(i32, 16), cursor.width),
        );
        const height = @max(font_size + 8, estimateTextHeight(normalized, width, font_size));
        const pos = cursor.beginInlineLeaf(width, .{});

        try self.list.addText(self.allocator, .{
            .x = pos.x,
            .y = pos.y,
            .width = width,
            .font_size = font_size,
            .color = resolveTextColor(parent_decl, self.page, parent, parent_tag),
            .underline = shouldUnderlineText(parent, parent_decl, self.page, parent_tag),
            .text = normalized,
        });

        cursor.advanceInlineLeaf(.{
            .x = pos.x,
            .y = pos.y,
            .width = width,
            .height = height,
        }, .{}, 2);
    }

    fn paintElement(self: *Painter, element: *Element, cursor: *FlowCursor) anyerror!void {
        const tag = element.getTag();
        if (switch (tag) {
            .script, .style, .template, .head, .meta, .link, .title => true,
            else => false,
        }) return;

        const style = try self.page.window.getComputedStyle(element, null, self.page);
        const decl = style.asCSSStyleDeclaration();
        if (std.mem.eql(u8, decl.getPropertyValue("display", self.page), "none")) {
            return;
        }

        const display = decl.getPropertyValue("display", self.page);
        const has_child_elements = hasRenderableChildElements(element);
        const block_like = isFlowBlockLike(tag, display, has_child_elements);
        const inline_leaf = !block_like and !has_child_elements;
        const margins = resolveEdgeSizes(decl, self.page, "margin");
        const padding = resolveEdgeSizes(decl, self.page, "padding");
        const font_size = parseFontSizePx(decl.getPropertyValue("font-size", self.page)) orelse defaultFontSize(tag);

        const label = try self.elementLabel(element);
        defer self.allocator.free(label);
        const inline_passthrough = try self.shouldPassThroughInlineContainer(
            element,
            decl,
            tag,
            display,
            has_child_elements,
            margins,
            padding,
            label,
        );

        if (inline_passthrough) {
            const command_start = self.list.commands.items.len;

            var child_it = element.asNode().childrenIterator();
            while (child_it.next()) |child| {
                try self.paintNode(child, cursor);
            }

            try self.appendInlineLinkRegionsForCommandRange(element, command_start);
            return;
        }

        const available_width = @max(@as(i32, 80), cursor.width - margins.horizontal());
        const width = resolveLayoutWidth(self, element, decl, self.page, tag, block_like, available_width, label, font_size);
        if (width <= 0) {
            return;
        }

        const pos = if (inline_leaf)
            cursor.beginInlineLeaf(width, margins)
        else
            cursor.beginBlock(margins);
        const x = pos.x;
        const y = pos.y;
        const own_content_height = resolveOwnContentHeight(
            self,
            element,
            decl,
            tag,
            width - padding.horizontal(),
            label,
            font_size,
        );

        const child_gap: i32 = if (has_child_elements and own_content_height > 0) 8 else 0;
        const child_indent = resolveChildIndent(tag, has_child_elements);
        const child_left = x + padding.left + child_indent;
        const child_top = y + padding.top + own_content_height + child_gap;
        const child_width = @max(@as(i32, 40), width - padding.left - padding.right - child_indent);
        var child_cursor = FlowCursor.init(child_left, child_top, child_width);

        var it = element.asNode().childrenIterator();
        while (it.next()) |child| {
            try self.paintNode(child, &child_cursor);
        }

        const child_height: i32 = if (has_child_elements)
            child_cursor.consumedHeightSince(child_top)
        else
            0;
        const explicit_height = resolveExplicitHeight(element, decl, self.page, tag);
        const min_height = resolveMinimumHeight(self, tag, block_like, own_content_height);
        const height = @max(min_height, @max(explicit_height, padding.top + own_content_height + child_gap + child_height + padding.bottom));

        const rect = .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        };

        const bg = parseCssColor(resolveCssPropertyValue(decl, self.page, element, "background-color"));
        const fg = resolveTextColor(decl, self.page, element, tag);

        if (shouldPaintBox(tag)) {
            if (bg) |background| {
                if (background.a > 0 and shouldPaintBackground(tag, has_child_elements)) {
                    try self.list.addFillRect(self.allocator, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                        .color = background,
                    });
                }
            } else if (tag == .input or tag == .textarea or tag == .button or tag == .select) {
                try self.list.addFillRect(self.allocator, .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = rect.height,
                    .color = .{ .r = 248, .g = 248, .b = 248 },
                });
            } else if (tag == .img) {
                try self.list.addFillRect(self.allocator, .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = rect.height,
                    .color = .{ .r = 236, .g = 236, .b = 236 },
                });
            }
        }

        if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
            try self.list.addStrokeRect(self.allocator, .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
                .color = stroke,
            });
        }

        const image_command = if (tag == .img)
            try resolvedImageCommand(element, self.page, rect.x, rect.y, rect.width, rect.height)
        else
            null;
        if (image_command) |command| {
            try self.list.addImage(self.allocator, command);
        }

        if (label.len > 0 and shouldPaintText(tag) and image_command == null) {
            try self.list.addText(self.allocator, .{
                .x = rect.x + padding.left + 6,
                .y = rect.y + padding.top + 4,
                .width = @max(@as(i32, 40), rect.width - padding.horizontal() - 12),
                .font_size = font_size,
                .color = fg,
                .underline = shouldUnderlineText(element, decl, self.page, tag),
                .text = label,
            });
        }

        if (try resolvedLinkRegion(element, self.page, rect.x, rect.y, rect.width, rect.height)) |region| {
            try self.list.addLinkRegion(self.allocator, region);
        }

        if (inline_leaf) {
            cursor.advanceInlineLeaf(rect, margins, flowSpacingAfter(tag, block_like));
        } else {
            cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
        }
    }

    fn elementLabel(self: *Painter, element: *Element) ![]u8 {
        switch (element.getTag()) {
            .img => {
                if (element.getAttributeSafe(comptime .wrap("alt"))) |alt| {
                    return self.allocator.dupe(u8, alt);
                }
                if (element.getAttributeSafe(comptime .wrap("src"))) |src| {
                    return std.fmt.allocPrint(self.allocator, "[image] {s}", .{src});
                }
                return self.allocator.dupe(u8, "[image]");
            },
            .input => {
                if (element.getAttributeSafe(comptime .wrap("value"))) |value| {
                    return self.allocator.dupe(u8, value);
                }
                if (element.getAttributeSafe(comptime .wrap("placeholder"))) |placeholder| {
                    return self.allocator.dupe(u8, placeholder);
                }
                return self.allocator.dupe(u8, "[input]");
            },
            .textarea => {
                const text = try element.asNode().getTextContentAlloc(self.allocator);
                defer self.allocator.free(text);
                if (element.getAttributeSafe(comptime .wrap("placeholder"))) |placeholder| {
                    return self.allocator.dupe(u8, placeholder);
                }
                if (std.mem.trim(u8, text, &std.ascii.whitespace).len > 0) {
                    return collapseWhitespace(self.allocator, text);
                }
                return self.allocator.dupe(u8, "[textarea]");
            },
            .button, .option, .select => {
                const text = try element.asNode().getTextContentAlloc(self.allocator);
                defer self.allocator.free(text);
                const collapsed = try collapseWhitespace(self.allocator, text);
                if (collapsed.len > 0) {
                    return collapsed;
                }
                self.allocator.free(collapsed);
                return self.allocator.dupe(u8, "[control]");
            },
            else => return collectDirectText(self.allocator, element),
        }
    }

    fn shouldPassThroughInlineContainer(
        self: *Painter,
        element: *Element,
        decl: anytype,
        tag: Element.Tag,
        display: []const u8,
        has_child_elements: bool,
        margins: EdgeSizes,
        padding: EdgeSizes,
        label: []const u8,
    ) !bool {
        _ = tag;
        _ = label;
        if (!has_child_elements) {
            return false;
        }
        if (!isInlineDisplay(display)) {
            return false;
        }
        if (margins.top != 0 or margins.right != 0 or margins.bottom != 0 or margins.left != 0) {
            return false;
        }
        if (padding.top != 0 or padding.right != 0 or padding.bottom != 0 or padding.left != 0) {
            return false;
        }
        if (parseCssColor(resolveCssPropertyValue(decl, self.page, element, "background-color"))) |background| {
            if (background.a > 0) {
                return false;
            }
        }
        if (hasVisibleBorder(decl, self.page)) {
            return false;
        }

        var it = element.asNode().childrenIterator();
        while (it.next()) |child| {
            if (child.is(Node.CData.Text)) |text| {
                _ = text;
                continue;
            }
            if (child.is(Element)) |child_el| {
                const child_style = try self.page.window.getComputedStyle(child_el, null, self.page);
                const child_decl = child_style.asCSSStyleDeclaration();
                const child_display = child_decl.getPropertyValue("display", self.page);
                if (!isInlineDisplay(child_display)) {
                    return false;
                }
                const child_has_children = hasRenderableChildElements(child_el);
                if (child_has_children) {
                    const child_margins = resolveEdgeSizes(child_decl, self.page, "margin");
                    const child_padding = resolveEdgeSizes(child_decl, self.page, "padding");
                    const child_label = try self.elementLabel(child_el);
                    defer self.allocator.free(child_label);
                    if (!(try self.shouldPassThroughInlineContainer(
                        child_el,
                        child_decl,
                        child_el.getTag(),
                        child_display,
                        child_has_children,
                        child_margins,
                        child_padding,
                        child_label,
                    ))) {
                        return false;
                    }
                }
                continue;
            }
            return false;
        }

        return true;
    }

    fn appendInlineLinkRegionsForCommandRange(
        self: *Painter,
        element: *Element,
        command_start: usize,
    ) !void {
        const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
        if (href.len == 0 or command_start >= self.list.commands.items.len) {
            return;
        }

        var fragments = try collectCommandRowFragments(self.allocator, self.list.commands.items[command_start..]);
        defer fragments.deinit(self.allocator);
        if (fragments.items.len == 0) {
            return;
        }

        sortCommandRowFragments(fragments.items);
        const resolved = try URL.resolve(self.page.call_arena, self.page.base(), href, .{ .encode = true });
        const download_filename = element.getAttributeSafe(comptime .wrap("download")) orelse "";
        const open_in_new_tab = linkOpensInNewTab(element);
        for (fragments.items) |fragment| {
            try self.list.addLinkRegion(self.allocator, .{
                .x = fragment.x,
                .y = fragment.y,
                .width = fragment.width,
                .height = fragment.height,
                .url = @constCast(resolved),
                .download_filename = @constCast(download_filename),
                .open_in_new_tab = open_in_new_tab,
            });
        }
    }
};

const CommandBounds = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    fn right(self: CommandBounds) i32 {
        return self.x + self.width;
    }

    fn bottom(self: CommandBounds) i32 {
        return self.y + self.height;
    }
};

fn shouldPaintBox(tag: Element.Tag) bool {
    return switch (tag) {
        .html, .body, .head, .meta, .link, .script, .style, .title => false,
        else => true,
    };
}

fn shouldStrokeBox(tag: Element.Tag) bool {
    return switch (tag) {
        .img, .input, .textarea, .button, .select, .iframe, .canvas => true,
        else => false,
    };
}

fn resolveTextColor(decl: anytype, page: *Page, element: *Element, tag: Element.Tag) Color {
    if (parseCssColor(resolveCssPropertyValue(decl, page, element, "color"))) |color| {
        return color;
    }

    if (tag == .anchor and element.getAttributeSafe(comptime .wrap("href")) != null) {
        return .{ .r = 0, .g = 102, .b = 204 };
    }

    return .{ .r = 0, .g = 0, .b = 0 };
}

fn shouldUnderlineText(element: *Element, decl: anytype, page: *Page, tag: Element.Tag) bool {
    if (containsAsciiToken(resolveCssPropertyValue(decl, page, element, "text-decoration-line"), "underline")) {
        return true;
    }
    if (containsAsciiToken(resolveCssPropertyValue(decl, page, element, "text-decoration"), "underline")) {
        return true;
    }
    return tag == .anchor and element.getAttributeSafe(comptime .wrap("href")) != null;
}

fn containsAsciiToken(haystack: []const u8, needle: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, haystack, " \t\r\n,/");
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, needle)) {
            return true;
        }
    }
    return false;
}

fn resolvedLinkRegion(
    element: *Element,
    page: *Page,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) !?LinkRegion {
    const href = element.getAttributeSafe(comptime .wrap("href")) orelse return null;
    if (href.len == 0) {
        return null;
    }
    const resolved = try URL.resolve(page.call_arena, page.base(), href, .{ .encode = true });

    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .url = @constCast(resolved),
        .download_filename = @constCast(element.getAttributeSafe(comptime .wrap("download")) orelse ""),
        .open_in_new_tab = linkOpensInNewTab(element),
    };
}

fn linkOpensInNewTab(element: *Element) bool {
    const target = element.getAttributeSafe(comptime .wrap("target")) orelse return false;
    if (target.len == 0) {
        return false;
    }
    if (std.mem.eql(u8, target, "_self") or
        std.mem.eql(u8, target, "_parent") or
        std.mem.eql(u8, target, "_top"))
    {
        return false;
    }
    return true;
}

fn collectCommandRowFragments(
    allocator: std.mem.Allocator,
    commands: []const Command,
) !std.ArrayListUnmanaged(CommandBounds) {
    var fragments: std.ArrayListUnmanaged(CommandBounds) = .{};
    errdefer fragments.deinit(allocator);

    for (commands) |command| {
        const bounds = commandBounds(command) orelse continue;
        try mergeCommandBoundsIntoFragments(allocator, &fragments, bounds);
    }
    return fragments;
}

fn mergeCommandBoundsIntoFragments(
    allocator: std.mem.Allocator,
    fragments: *std.ArrayListUnmanaged(CommandBounds),
    bounds: CommandBounds,
) !void {
    if (bounds.width <= 0 or bounds.height <= 0) {
        return;
    }

    var merged = bounds;
    var index: usize = 0;
    while (index < fragments.items.len) {
        if (!commandBoundsShareInlineRow(fragments.items[index], merged)) {
            index += 1;
            continue;
        }
        merged = unionCommandBounds(fragments.items[index], merged);
        _ = fragments.orderedRemove(index);
    }
    try fragments.append(allocator, merged);
}

fn commandBounds(command: Command) ?CommandBounds {
    return switch (command) {
        .fill_rect => |rect| if (rect.width > 0 and rect.height > 0) .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        } else null,
        .stroke_rect => |rect| if (rect.width > 0 and rect.height > 0) .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        } else null,
        .image => |image| if (image.width > 0 and image.height > 0) .{
            .x = image.x,
            .y = image.y,
            .width = image.width,
            .height = image.height,
        } else null,
        .text => |text| if (text.width > 0) .{
            .x = text.x,
            .y = text.y,
            .width = text.width,
            .height = estimateTextHeight(text.text, @max(@as(i32, 40), text.width), text.font_size),
        } else null,
    };
}

fn commandBoundsShareInlineRow(a: CommandBounds, b: CommandBounds) bool {
    return b.y < a.bottom() and b.bottom() > a.y;
}

fn unionCommandBounds(a: CommandBounds, b: CommandBounds) CommandBounds {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(a.right(), b.right());
    const bottom = @max(a.bottom(), b.bottom());
    return .{
        .x = left,
        .y = top,
        .width = right - left,
        .height = bottom - top,
    };
}

fn sortCommandRowFragments(fragments: []CommandBounds) void {
    var i: usize = 1;
    while (i < fragments.len) : (i += 1) {
        var j = i;
        while (j > 0 and commandBoundsLessThan(fragments[j], fragments[j - 1])) : (j -= 1) {
            std.mem.swap(CommandBounds, &fragments[j], &fragments[j - 1]);
        }
    }
}

fn commandBoundsLessThan(a: CommandBounds, b: CommandBounds) bool {
    if (a.y != b.y) {
        return a.y < b.y;
    }
    if (a.x != b.x) {
        return a.x < b.x;
    }
    if (a.height != b.height) {
        return a.height < b.height;
    }
    return a.width < b.width;
}

fn resolvedImageCommand(
    element: *Element,
    page: *Page,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) !?ImageCommand {
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return null;
    if (src.len == 0) {
        return null;
    }

    const resolved = try URL.resolve(page.call_arena, page.base(), src, .{ .encode = true });
    const alt = element.getAttributeSafe(comptime .wrap("alt")) orelse "";
    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .url = @constCast(resolved),
        .alt = @constCast(alt),
    };
}

fn resolveStrokeColor(decl: anytype, page: *Page, tag: Element.Tag) ?Color {
    if (hasVisibleBorder(decl, page)) {
        return parseCssColor(firstNonEmpty(&.{
            decl.getPropertyValue("border-color", page),
            decl.getPropertyValue("border-top-color", page),
            decl.getPropertyValue("border-right-color", page),
            decl.getPropertyValue("border-bottom-color", page),
            decl.getPropertyValue("border-left-color", page),
        })) orelse Color{ .r = 180, .g = 180, .b = 180 };
    }

    if (shouldStrokeBox(tag)) {
        return .{ .r = 180, .g = 180, .b = 180 };
    }
    return null;
}

fn hasVisibleBorder(decl: anytype, page: *Page) bool {
    if (borderSideVisible(
        decl.getPropertyValue("border-top-style", page),
        decl.getPropertyValue("border-top-width", page),
    )) return true;
    if (borderSideVisible(
        decl.getPropertyValue("border-right-style", page),
        decl.getPropertyValue("border-right-width", page),
    )) return true;
    if (borderSideVisible(
        decl.getPropertyValue("border-bottom-style", page),
        decl.getPropertyValue("border-bottom-width", page),
    )) return true;
    if (borderSideVisible(
        decl.getPropertyValue("border-left-style", page),
        decl.getPropertyValue("border-left-width", page),
    )) return true;

    return borderSideVisible(
        decl.getPropertyValue("border-style", page),
        decl.getPropertyValue("border-width", page),
    );
}

fn borderSideVisible(style_value: []const u8, width_value: []const u8) bool {
    const style = std.mem.trim(u8, style_value, &std.ascii.whitespace);
    if (style.len == 0 or
        std.ascii.eqlIgnoreCase(style, "none") or
        std.ascii.eqlIgnoreCase(style, "hidden"))
    {
        return false;
    }

    const width = parseBorderWidthPx(width_value) orelse return true;
    return width > 0;
}

fn firstNonEmpty(values: []const []const u8) []const u8 {
    for (values) |value| {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            return trimmed;
        }
    }
    return "";
}

fn resolveCssPropertyValue(
    decl: anytype,
    page: *Page,
    element: *Element,
    comptime property: []const u8,
) []const u8 {
    if (inlineStylePropertyValue(element, property)) |inline_value| {
        return inline_value;
    }
    const computed = decl.getPropertyValue(property, page);
    if (std.mem.trim(u8, computed, &std.ascii.whitespace).len > 0) {
        return computed;
    }
    return inlineStylePropertyValue(element, property) orelse "";
}

fn inlineStylePropertyValue(element: *Element, comptime property: []const u8) ?[]const u8 {
    const style_attr = element.getAttributeSafe(comptime .wrap("style")) orelse return null;
    return inlineStyleDeclarationValue(style_attr, property);
}

fn inlineStyleDeclarationValue(style_attr: []const u8, comptime property: []const u8) ?[]const u8 {
    var declarations = std.mem.splitScalar(u8, style_attr, ';');
    while (declarations.next()) |decl| {
        const separator = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
        const name = std.mem.trim(u8, decl[0..separator], &std.ascii.whitespace);
        if (!std.ascii.eqlIgnoreCase(name, property)) {
            continue;
        }
        const value = std.mem.trim(u8, decl[separator + 1 ..], &std.ascii.whitespace);
        if (value.len > 0) {
            return value;
        }
    }
    return null;
}

fn isInlineDisplay(display: []const u8) bool {
    const trimmed = std.mem.trim(u8, display, &std.ascii.whitespace);
    return std.mem.eql(u8, trimmed, "inline") or std.mem.startsWith(u8, trimmed, "inline-");
}

fn hasRenderableChildElements(element: *Element) bool {
    var it = element.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |child_el| {
            if (switch (child_el.getTag()) {
                .script, .style, .template, .head, .meta, .link, .title => true,
                else => false,
            }) continue;
            return true;
        }
    }
    return false;
}

fn isFlowBlockLike(tag: Element.Tag, display: []const u8, has_child_elements: bool) bool {
    const trimmed = std.mem.trim(u8, display, &std.ascii.whitespace);
    if (std.mem.eql(u8, trimmed, "inline")) {
        return has_child_elements;
    }
    if (std.mem.startsWith(u8, trimmed, "inline-")) {
        return has_child_elements;
    }
    if (trimmed.len > 0) {
        return true;
    }

    return switch (tag) {
        .span, .anchor, .strong, .em, .code, .label, .option => false,
        else => true,
    };
}

fn resolveEdgeSizes(decl: anytype, page: *Page, comptime prefix: []const u8) EdgeSizes {
    const shorthand = decl.getPropertyValue(prefix, page);
    const shorthand_edges = parseCssEdgeShorthand(shorthand);
    return .{
        .top = parseCssLengthPx(firstNonEmpty(&.{
            decl.getPropertyValue(prefix ++ "-top", page),
        })) orelse shorthand_edges.top,
        .right = parseCssLengthPx(firstNonEmpty(&.{
            decl.getPropertyValue(prefix ++ "-right", page),
        })) orelse shorthand_edges.right,
        .bottom = parseCssLengthPx(firstNonEmpty(&.{
            decl.getPropertyValue(prefix ++ "-bottom", page),
        })) orelse shorthand_edges.bottom,
        .left = parseCssLengthPx(firstNonEmpty(&.{
            decl.getPropertyValue(prefix ++ "-left", page),
        })) orelse shorthand_edges.left,
    };
}

fn defaultFontSize(tag: Element.Tag) i32 {
    return switch (tag) {
        .h1 => 32,
        .h2 => 28,
        .h3 => 24,
        .h4 => 20,
        .h5 => 18,
        .h6 => 16,
        else => 16,
    };
}

fn resolveLayoutWidth(
    self: *const Painter,
    element: *Element,
    decl: anytype,
    page: *Page,
    tag: Element.Tag,
    block_like: bool,
    available_width: i32,
    label: []const u8,
    font_size: i32,
) i32 {
    const explicit_width = resolveExplicitWidth(element, decl, page, tag);
    if (block_like) {
        return std.math.clamp(
            if (explicit_width > 0) explicit_width else available_width,
            80,
            available_width,
        );
    }

    var preferred = explicit_width;
    if (preferred <= 0) {
        preferred = switch (tag) {
            .img => 180,
            .textarea => 240,
            .input, .button, .select => 180,
            else => @max(self.opts.inline_min_width, estimateTextWidth(label, font_size) + 16),
        };
    }
    return std.math.clamp(preferred, 60, available_width);
}

fn resolveOwnContentHeight(
    self: *const Painter,
    element: *Element,
    decl: anytype,
    tag: Element.Tag,
    content_width: i32,
    label: []const u8,
    font_size: i32,
) i32 {
    const explicit_height = resolveExplicitHeight(element, decl, self.page, tag);
    var height = explicit_height;

    if (tag == .img) {
        height = @max(height, 120);
    } else if (tag == .textarea) {
        height = @max(height, 100);
    } else if (tag == .input or tag == .button or tag == .select) {
        height = @max(height, 30);
    } else if (label.len > 0 and shouldPaintText(tag)) {
        height = @max(height, estimateTextHeight(label, @max(40, content_width - 12), font_size));
    }

    return height;
}

fn resolveExplicitWidth(element: *Element, decl: anytype, page: *Page, tag: Element.Tag) i32 {
    if (parseCssLengthPx(decl.getPropertyValue("width", page))) |width| {
        return width;
    }
    if (tag == .img or tag == .iframe or tag == .canvas or tag == .input) {
        if (element.getAttributeSafe(comptime .wrap("width"))) |raw| {
            return parseCssLengthPx(raw) orelse 0;
        }
    }
    return 0;
}

fn resolveExplicitHeight(element: *Element, decl: anytype, page: *Page, tag: Element.Tag) i32 {
    if (parseCssLengthPx(decl.getPropertyValue("height", page))) |height| {
        return height;
    }
    if (tag == .img or tag == .iframe or tag == .canvas or tag == .textarea) {
        if (element.getAttributeSafe(comptime .wrap("height"))) |raw| {
            return parseCssLengthPx(raw) orelse 0;
        }
    }
    return 0;
}

fn resolveMinimumHeight(self: *const Painter, tag: Element.Tag, block_like: bool, own_content_height: i32) i32 {
    if (tag == .html or tag == .body) {
        return own_content_height;
    }
    if (own_content_height > 0) {
        return own_content_height;
    }
    if (tag == .textarea) return 100;
    if (tag == .img) return 120;
    if (tag == .input or tag == .button or tag == .select) return 30;
    return if (block_like) self.opts.min_height else 20;
}

fn shouldPaintBackground(tag: Element.Tag, has_child_elements: bool) bool {
    if (!has_child_elements) {
        return true;
    }
    return switch (tag) {
        .img, .input, .textarea, .button, .select, .canvas, .iframe => true,
        else => false,
    };
}

fn resolveChildIndent(tag: Element.Tag, has_child_elements: bool) i32 {
    if (!has_child_elements) {
        return 0;
    }
    return switch (tag) {
        .html, .body => 0,
        .ul, .ol => 18,
        else => 12,
    };
}

fn flowSpacingAfter(tag: Element.Tag, block_like: bool) i32 {
    return switch (tag) {
        .html, .body => 0,
        .h1, .h2, .h3, .h4, .h5, .h6 => 10,
        .p, .div, .section, .article, .header, .footer, .nav, .main, .aside, .ul, .ol, .li, .form => 8,
        else => if (block_like) 4 else 2,
    };
}

fn shouldPaintText(tag: Element.Tag) bool {
    return switch (tag) {
        .html, .body, .head, .meta, .link, .script, .style, .template, .img => false,
        else => true,
    };
}

fn estimateTextHeight(text: []const u8, width: i32, font_size: i32) i32 {
    if (text.len == 0) {
        return font_size + 8;
    }

    const usable_width = @max(40, width);
    const char_width = @max(@as(i32, 7), @divTrunc(font_size, 2));
    const chars_per_line = @max(@as(usize, 1), @as(usize, @intCast(usable_width / char_width)));
    const lines = @max(@as(usize, 1), (text.len + chars_per_line - 1) / chars_per_line);
    return @as(i32, @intCast(lines)) * (font_size + 4) + 8;
}

fn estimateTextWidth(text: []const u8, font_size: i32) i32 {
    if (text.len == 0) {
        return 0;
    }
    const char_width = @max(@as(i32, 7), @divTrunc(font_size, 2));
    return @as(i32, @intCast(text.len)) * char_width;
}

fn collectDirectText(allocator: std.mem.Allocator, element: *Element) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();

    var it = element.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Node.CData.Text)) |text| {
            try buf.writer.writeAll(text.getWholeText());
            try buf.writer.writeByte(' ');
            continue;
        }
        if (child.is(Element)) |child_el| {
            if (child_el.getTag() == .br) {
                try buf.writer.writeByte('\n');
            }
        }
    }

    return collapseWhitespace(allocator, buf.written());
}

fn normalizeInlineText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) {
        return allocator.dupe(u8, "");
    }

    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return allocator.dupe(u8, " ");
    }

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    if (std.ascii.isWhitespace(text[0])) {
        try out.append(allocator, ' ');
    }

    var in_space = false;
    for (trimmed) |c| {
        if (std.ascii.isWhitespace(c)) {
            in_space = true;
            continue;
        }
        if (in_space and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
            try out.append(allocator, ' ');
        }
        in_space = false;
        try out.append(allocator, c);
    }

    if (std.ascii.isWhitespace(text[text.len - 1]) and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
        try out.append(allocator, ' ');
    }

    return out.toOwnedSlice(allocator);
}

fn collapseWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return allocator.dupe(u8, "");
    }

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var in_space = false;
    for (trimmed) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!in_space) {
                try out.append(allocator, ' ');
                in_space = true;
            }
            continue;
        }
        in_space = false;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn parseFontSizePx(value: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return null;
    }
    if (std.mem.endsWith(u8, trimmed, "px")) {
        const raw = trimmed[0 .. trimmed.len - 2];
        return @intFromFloat(std.fmt.parseFloat(f64, raw) catch return null);
    }
    return null;
}

fn parseCssLengthPx(value: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return null;
    }
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |_| {
        return null;
    }
    if (std.mem.endsWith(u8, trimmed, "px")) {
        const raw = trimmed[0 .. trimmed.len - 2];
        return @intFromFloat(std.fmt.parseFloat(f64, raw) catch return null);
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "thin")) return 1;
    if (std.ascii.eqlIgnoreCase(trimmed, "medium")) return 2;
    if (std.ascii.eqlIgnoreCase(trimmed, "thick")) return 4;
    if (std.mem.eql(u8, trimmed, "0")) return 0;
    return @intFromFloat(std.fmt.parseFloat(f64, trimmed) catch return null);
}

fn parseCssEdgeShorthand(value: []const u8) EdgeSizes {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return .{};
    }

    var values: [4]i32 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |part| {
        if (count == values.len) break;
        values[count] = parseCssLengthPx(part) orelse 0;
        count += 1;
    }

    return switch (count) {
        0 => .{},
        1 => .{ .top = values[0], .right = values[0], .bottom = values[0], .left = values[0] },
        2 => .{ .top = values[0], .right = values[1], .bottom = values[0], .left = values[1] },
        3 => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[1] },
        else => .{ .top = values[0], .right = values[1], .bottom = values[2], .left = values[3] },
    };
}

fn parseBorderWidthPx(value: []const u8) ?i32 {
    return parseCssLengthPx(value);
}

fn parseCssColor(value: []const u8) ?Color {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return null;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "transparent")) {
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
    if (std.mem.startsWith(u8, trimmed, "rgb(") and trimmed.len > 5 and trimmed[trimmed.len - 1] == ')') {
        return parseRgbColor(trimmed[4 .. trimmed.len - 1], false);
    }
    if (std.mem.startsWith(u8, trimmed, "rgba(") and trimmed.len > 6 and trimmed[trimmed.len - 1] == ')') {
        return parseRgbColor(trimmed[5 .. trimmed.len - 1], true);
    }
    if (trimmed[0] == '#') {
        return parseHexColor(trimmed[1..]);
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "black")) return .{ .r = 0, .g = 0, .b = 0 };
    if (std.ascii.eqlIgnoreCase(trimmed, "white")) return .{ .r = 255, .g = 255, .b = 255 };
    if (std.ascii.eqlIgnoreCase(trimmed, "red")) return .{ .r = 255, .g = 0, .b = 0 };
    if (std.ascii.eqlIgnoreCase(trimmed, "green")) return .{ .r = 0, .g = 128, .b = 0 };
    if (std.ascii.eqlIgnoreCase(trimmed, "blue")) return .{ .r = 0, .g = 0, .b = 255 };
    if (std.ascii.eqlIgnoreCase(trimmed, "gray") or std.ascii.eqlIgnoreCase(trimmed, "grey")) return .{ .r = 128, .g = 128, .b = 128 };
    if (std.ascii.eqlIgnoreCase(trimmed, "lightgray") or std.ascii.eqlIgnoreCase(trimmed, "lightgrey")) return .{ .r = 211, .g = 211, .b = 211 };
    if (std.ascii.eqlIgnoreCase(trimmed, "yellow")) return .{ .r = 255, .g = 255, .b = 0 };
    return null;
}

fn parseRgbColor(value: []const u8, has_alpha: bool) ?Color {
    var parts = std.mem.splitScalar(u8, value, ',');
    const r = parseComponent(parts.next() orelse return null) orelse return null;
    const g = parseComponent(parts.next() orelse return null) orelse return null;
    const b = parseComponent(parts.next() orelse return null) orelse return null;
    var a: u8 = 255;
    if (has_alpha) {
        const alpha_raw = std.mem.trim(u8, parts.next() orelse return null, &std.ascii.whitespace);
        if (std.mem.indexOfScalar(u8, alpha_raw, '.')) |_| {
            const alpha = std.fmt.parseFloat(f64, alpha_raw) catch return null;
            a = @intFromFloat(std.math.clamp(alpha, 0.0, 1.0) * 255.0);
        } else {
            a = parseComponent(alpha_raw) orelse return null;
        }
    }
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn parseComponent(value: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    const parsed = std.fmt.parseInt(u16, trimmed, 10) catch return null;
    return @intCast(@min(parsed, 255));
}

fn parseHexColor(value: []const u8) ?Color {
    if (value.len == 3) {
        return .{
            .r = parseHexByte(value[0], value[0]) orelse return null,
            .g = parseHexByte(value[1], value[1]) orelse return null,
            .b = parseHexByte(value[2], value[2]) orelse return null,
        };
    }
    if (value.len == 6) {
        return .{
            .r = parseHexByte(value[0], value[1]) orelse return null,
            .g = parseHexByte(value[2], value[3]) orelse return null,
            .b = parseHexByte(value[4], value[5]) orelse return null,
        };
    }
    return null;
}

fn parseHexByte(high: u8, low: u8) ?u8 {
    const digits = [_]u8{ high, low };
    return std.fmt.parseInt(u8, &digits, 16) catch null;
}

test "parseCssColor handles rgb and hex" {
    try std.testing.expectEqualDeep(Color{ .r = 12, .g = 34, .b = 56 }, parseCssColor("rgb(12, 34, 56)").?);
    try std.testing.expectEqualDeep(Color{ .r = 255, .g = 0, .b = 170 }, parseCssColor("#f0a").?);
}

test "parseBorderWidthPx handles px and keywords" {
    try std.testing.expectEqual(@as(?i32, 1), parseBorderWidthPx("thin"));
    try std.testing.expectEqual(@as(?i32, 2), parseBorderWidthPx("2px"));
    try std.testing.expectEqual(@as(?i32, 0), parseBorderWidthPx("0"));
    try std.testing.expect(parseBorderWidthPx("") == null);
}

test "parseCssEdgeShorthand handles 1 to 4 values" {
    const single = parseCssEdgeShorthand("24px");
    try std.testing.expectEqual(@as(i32, 24), single.top);
    try std.testing.expectEqual(@as(i32, 24), single.right);
    try std.testing.expectEqual(@as(i32, 24), single.bottom);
    try std.testing.expectEqual(@as(i32, 24), single.left);

    const double = parseCssEdgeShorthand("24px 8px");
    try std.testing.expectEqual(@as(i32, 24), double.top);
    try std.testing.expectEqual(@as(i32, 8), double.right);
    try std.testing.expectEqual(@as(i32, 24), double.bottom);
    try std.testing.expectEqual(@as(i32, 8), double.left);

    const triple = parseCssEdgeShorthand("24px 8px 4px");
    try std.testing.expectEqual(@as(i32, 24), triple.top);
    try std.testing.expectEqual(@as(i32, 8), triple.right);
    try std.testing.expectEqual(@as(i32, 4), triple.bottom);
    try std.testing.expectEqual(@as(i32, 8), triple.left);

    const quadruple = parseCssEdgeShorthand("24px 8px 4px 2px");
    try std.testing.expectEqual(@as(i32, 24), quadruple.top);
    try std.testing.expectEqual(@as(i32, 8), quadruple.right);
    try std.testing.expectEqual(@as(i32, 4), quadruple.bottom);
    try std.testing.expectEqual(@as(i32, 2), quadruple.left);
}

test "inlineStyleDeclarationValue parses inline style properties" {
    const style =
        "color: white; background-color: #dd3333; text-decoration-line: underline;";
    try std.testing.expectEqualStrings("white", inlineStyleDeclarationValue(style, "color").?);
    try std.testing.expectEqualStrings("#dd3333", inlineStyleDeclarationValue(style, "background-color").?);
    try std.testing.expectEqualStrings("underline", inlineStyleDeclarationValue(style, "text-decoration-line").?);
    try std.testing.expect(inlineStyleDeclarationValue(style, "font-size") == null);
}

test "normalizeInlineText preserves edge spaces and collapses runs" {
    const normalized = try normalizeInlineText(std.testing.allocator, "  hello \r\n   world \t ");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(" hello world ", normalized);
}

test "normalizeInlineText reduces whitespace-only text to a single space" {
    const normalized = try normalizeInlineText(std.testing.allocator, "\r\n \t ");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(" ", normalized);
}

test "FlowCursor consumedHeightSince includes active inline row" {
    var cursor = FlowCursor.init(20, 40, 400);
    const pos = cursor.beginInlineLeaf(80, .{});
    cursor.advanceInlineLeaf(.{
        .x = pos.x,
        .y = pos.y,
        .width = 80,
        .height = 24,
    }, .{}, 2);
    try std.testing.expectEqual(@as(i32, 24), cursor.consumedHeightSince(40));

    cursor.finishInlineRow(2);
    try std.testing.expectEqual(@as(i32, 26), cursor.consumedHeightSince(40));
}

test "collectCommandRowFragments splits wrapped inline rows" {
    const commands = [_]Command{
        .{ .text = .{
            .x = 20,
            .y = 10,
            .width = 28,
            .font_size = 16,
            .color = .{ .r = 0, .g = 0, .b = 0 },
            .text = @constCast("go"),
        } },
        .{ .fill_rect = .{
            .x = 56,
            .y = 8,
            .width = 64,
            .height = 28,
            .color = .{ .r = 26, .g = 85, .b = 214 },
        } },
        .{ .text = .{
            .x = 124,
            .y = 10,
            .width = 34,
            .font_size = 16,
            .color = .{ .r = 0, .g = 0, .b = 0 },
            .text = @constCast("now"),
        } },
        .{ .text = .{
            .x = 20,
            .y = 42,
            .width = 80,
            .font_size = 16,
            .color = .{ .r = 0, .g = 0, .b = 0 },
            .text = @constCast("wrapped"),
        } },
    };

    var fragments = try collectCommandRowFragments(std.testing.allocator, &commands);
    defer fragments.deinit(std.testing.allocator);
    sortCommandRowFragments(fragments.items);

    try std.testing.expectEqual(@as(usize, 2), fragments.items.len);
    try std.testing.expectEqual(@as(i32, 20), fragments.items[0].x);
    try std.testing.expectEqual(@as(i32, 8), fragments.items[0].y);
    try std.testing.expectEqual(@as(i32, 138), fragments.items[0].width);
    try std.testing.expectEqual(@as(i32, 30), fragments.items[0].height);
    try std.testing.expectEqual(@as(i32, 20), fragments.items[1].x);
    try std.testing.expectEqual(@as(i32, 42), fragments.items[1].y);
    try std.testing.expectEqual(@as(i32, 80), fragments.items[1].width);
    try std.testing.expectEqual(@as(i32, 28), fragments.items[1].height);
}

test "inlineStyleDeclarationValue is case-insensitive and trims values" {
    const style =
        " COLOR : rgb(12, 34, 56) ; Background-Color :  #1a55d6 ; ";
    try std.testing.expectEqualStrings("rgb(12, 34, 56)", inlineStyleDeclarationValue(style, "color").?);
    try std.testing.expectEqualStrings("#1a55d6", inlineStyleDeclarationValue(style, "background-color").?);
}

test "isInlineDisplay matches inline variants" {
    try std.testing.expect(isInlineDisplay("inline"));
    try std.testing.expect(isInlineDisplay("inline-block"));
    try std.testing.expect(isInlineDisplay(" inline-flex "));
    try std.testing.expect(!isInlineDisplay("block"));
}
