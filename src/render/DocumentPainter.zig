const std = @import("std");
const builtin = @import("builtin");
const Page = @import("../browser/Page.zig");
const URL = @import("../browser/URL.zig");
const Node = @import("../browser/webapi/Node.zig");
const Element = @import("../browser/webapi/Element.zig");
const HTMLDocument = @import("../browser/webapi/HTMLDocument.zig");
const testing = @import("../testing.zig");
const DisplayList = @import("DisplayList.zig").DisplayList;
const Command = @import("DisplayList.zig").Command;
const Color = @import("DisplayList.zig").Color;
const LinkRegion = @import("DisplayList.zig").LinkRegion;
const ControlRegion = @import("DisplayList.zig").ControlRegion;
const ImageCommand = @import("DisplayList.zig").ImageCommand;
const FontFaceResource = @import("DisplayList.zig").FontFaceResource;
const FontFaceFormat = @import("DisplayList.zig").FontFaceFormat;
const CSSStyleSheet = @import("../browser/webapi/css/CSSStyleSheet.zig");
const win = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("wingdi.h");
    @cInclude("winuser.h");
}) else struct {};

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
    try appendLoadedFontFacesToDisplayList(allocator, page, &list);
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

    fn forceLineBreak(self: *FlowCursor, min_height: i32, spacing: i32) void {
        const line_height = @max(self.line_height, min_height);
        self.cursor_y += line_height + spacing;
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
        const inline_text_parent = isInlineDisplay(parent_display) or
            try usesInlineContentFlowContainer(parent, parent_decl, self.page, parent_display);
        if (!inline_text_parent) {
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
        const font_family = resolveCssPropertyValue(parent_decl, self.page, parent, "font-family");
        const font_weight = parseCssFontWeight(resolveCssPropertyValue(parent_decl, self.page, parent, "font-weight"));
        const italic = parseCssFontItalic(resolveCssPropertyValue(parent_decl, self.page, parent, "font-style"));
        var segment_start: usize = 0;
        while (segment_start < normalized.len) {
            while (segment_start < normalized.len and normalized[segment_start] == ' ') : (segment_start += 1) {}
            if (segment_start >= normalized.len) break;

            var segment_end = segment_start;
            while (segment_end < normalized.len and normalized[segment_end] != ' ') : (segment_end += 1) {}
            while (segment_end < normalized.len and normalized[segment_end] == ' ') : (segment_end += 1) {}

            try self.paintInlineTextSegment(
                normalized[segment_start..segment_end],
                parent,
                parent_decl,
                parent_tag,
                font_size,
                font_family,
                font_weight,
                italic,
                cursor,
            );
            segment_start = segment_end;
        }
    }

    fn paintInlineTextSegment(
        self: *Painter,
        segment: []const u8,
        parent: *Element,
        parent_decl: anytype,
        parent_tag: Element.Tag,
        font_size: i32,
        font_family: []const u8,
        font_weight: i32,
        italic: bool,
        cursor: *FlowCursor,
    ) !void {
        if (segment.len == 0) return;

        const width = std.math.clamp(
            estimateTextWidth(segment, font_size, font_family, font_weight, italic) + 8,
            8,
            @max(@as(i32, 16), cursor.width),
        );
        const height = @max(font_size + 8, estimateTextHeight(segment, width, font_size, font_family, font_weight, italic) + 8);
        const pos = cursor.beginInlineLeaf(width, .{});

        try self.list.addText(self.allocator, .{
            .x = pos.x,
            .y = pos.y,
            .width = width,
            .height = height,
            .font_size = font_size,
            .font_family = @constCast(font_family),
            .font_weight = font_weight,
            .italic = italic,
            .color = resolveTextColor(parent_decl, self.page, parent, parent_tag),
            .underline = shouldUnderlineText(parent, parent_decl, self.page, parent_tag),
            .text = @constCast(segment),
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
        if (isHiddenFormControl(element)) return;

        const style = try self.page.window.getComputedStyle(element, null, self.page);
        const decl = style.asCSSStyleDeclaration();
        if (std.mem.eql(u8, decl.getPropertyValue("display", self.page), "none")) {
            return;
        }

        const font_size = parseFontSizePx(decl.getPropertyValue("font-size", self.page)) orelse defaultFontSize(tag);
        if (tag == .br) {
            cursor.forceLineBreak(@max(font_size + 8, 20), 2);
            return;
        }

        const display = decl.getPropertyValue("display", self.page);
        const has_child_elements = hasRenderableChildElements(element);
        const block_like = isFlowBlockLike(tag, display, has_child_elements);
        const inline_leaf = !block_like and !has_child_elements;
        const margins = resolveEdgeSizes(decl, self.page, "margin");
        const padding = resolveEdgeSizes(decl, self.page, "padding");
        const font_family = resolveCssPropertyValue(decl, self.page, element, "font-family");
        const font_weight = parseCssFontWeight(resolveCssPropertyValue(decl, self.page, element, "font-weight"));
        const italic = parseCssFontItalic(resolveCssPropertyValue(decl, self.page, element, "font-style"));
        const inline_content_flow = block_like and try usesInlineContentFlowContainer(element, decl, self.page, display);

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
        const width = resolveLayoutWidth(self, element, decl, self.page, tag, block_like, available_width, label, font_size, font_family, font_weight, italic);
        if (width <= 0) {
            return;
        }

        const pos = if (inline_leaf)
            cursor.beginInlineLeaf(width, margins)
        else
            cursor.beginBlock(margins);
        const x = pos.x;
        const y = pos.y;
        if (inline_content_flow) {
            var child_cursor = FlowCursor.init(x + padding.left, y + padding.top, @max(@as(i32, 40), width - padding.left - padding.right));
            var child_it = element.asNode().childrenIterator();
            while (child_it.next()) |child| {
                try self.paintNode(child, &child_cursor);
            }

            const child_height = child_cursor.consumedHeightSince(y + padding.top);
            const explicit_height = resolveExplicitHeight(element, decl, self.page, tag);
            const height = @max(
                resolveMinimumHeight(self, tag, block_like, 0),
                @max(explicit_height, padding.top + child_height + padding.bottom),
            );
            const rect = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            };

            if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
                try self.list.addStrokeRect(self.allocator, .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = rect.height,
                    .color = stroke,
                });
            }
            cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
            return;
        }
        const own_content_height = resolveOwnContentHeight(
            self,
            element,
            decl,
            tag,
            width - padding.horizontal(),
            label,
            font_size,
            font_family,
            font_weight,
            italic,
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
                .height = @max(
                    font_size + 8,
                    estimateTextHeight(
                        label,
                        @max(@as(i32, 40), rect.width - padding.horizontal() - 12),
                        font_size,
                        font_family,
                        font_weight,
                        italic,
                    ) + 8,
                ),
                .font_size = font_size,
                .font_family = @constCast(font_family),
                .font_weight = font_weight,
                .italic = italic,
                .color = fg,
                .underline = shouldUnderlineText(element, decl, self.page, tag),
                .text = label,
            });
        }

        if (try resolvedLinkRegion(element, self.page, rect.x, rect.y, rect.width, rect.height)) |region| {
            try self.list.addLinkRegion(self.allocator, region);
        }
        if (try resolvedControlRegion(element, self.page, rect.x, rect.y, rect.width, rect.height)) |region| {
            try self.list.addControlRegion(self.allocator, region);
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
                const input = element.as(Element.Html.Input);
                if (input._input_type == .file) {
                    const selected_files = input.getSelectedFiles();
                    if (selected_files.len > 1) {
                        return std.fmt.allocPrint(self.allocator, "{d} files selected", .{selected_files.len});
                    }
                    const selected_name = input.getSelectedFileName();
                    if (selected_name.len > 0) {
                        return self.allocator.dupe(u8, selected_name);
                    }
                    if (element.getAttributeSafe(comptime .wrap("placeholder"))) |placeholder| {
                        return self.allocator.dupe(u8, placeholder);
                    }
                    return self.allocator.dupe(u8, "[choose file]");
                }
                const current_value = input.getValue();
                if (current_value.len > 0) {
                    return self.allocator.dupe(u8, current_value);
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
        const dom_path = try encodeNodePath(self.page.call_arena, element.asNode());
        const download_filename = element.getAttributeSafe(comptime .wrap("download")) orelse "";
        const open_in_new_tab = linkOpensFreshTab(element);
        const target_name = linkTargetName(element);
        for (fragments.items) |fragment| {
            try self.list.addLinkRegion(self.allocator, .{
                .x = fragment.x,
                .y = fragment.y,
                .width = fragment.width,
                .height = fragment.height,
                .url = @constCast(resolved),
                .dom_path = dom_path,
                .download_filename = @constCast(download_filename),
                .open_in_new_tab = open_in_new_tab,
                .target_name = @constCast(target_name),
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
    const dom_path = try encodeNodePath(page.call_arena, element.asNode());

    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .url = @constCast(resolved),
        .dom_path = dom_path,
        .download_filename = @constCast(element.getAttributeSafe(comptime .wrap("download")) orelse ""),
        .open_in_new_tab = linkOpensFreshTab(element),
        .target_name = @constCast(linkTargetName(element)),
    };
}

fn resolvedControlRegion(
    element: *Element,
    page: *Page,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) !?ControlRegion {
    const html = element.is(Element.Html) orelse return null;
    switch (html._type) {
        .input => |input| if (input._input_type == .hidden) return null,
        .button, .select, .textarea => {},
        else => return null,
    }

    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .dom_path = try encodeNodePath(page.call_arena, element.asNode()),
    };
}

fn isHiddenFormControl(element: *Element) bool {
    const html = element.is(Element.Html) orelse return false;
    return switch (html._type) {
        .input => |input| input._input_type == .hidden,
        else => false,
    };
}

const LinkTargetKind = union(enum) {
    same_context,
    new_tab,
    named: []const u8,
};

fn classifyLinkTargetValue(target_value: []const u8) LinkTargetKind {
    const target = std.mem.trim(u8, target_value, &std.ascii.whitespace);
    if (target.len == 0) {
        return .same_context;
    }
    if (std.ascii.eqlIgnoreCase(target, "_self") or
        std.ascii.eqlIgnoreCase(target, "_parent") or
        std.ascii.eqlIgnoreCase(target, "_top"))
    {
        return .same_context;
    }
    if (std.ascii.eqlIgnoreCase(target, "_blank")) {
        return .new_tab;
    }
    return .{ .named = target };
}

fn linkOpensFreshTab(element: *Element) bool {
    return switch (classifyLinkTargetValue(element.getAttributeSafe(comptime .wrap("target")) orelse "")) {
        .new_tab => true,
        else => false,
    };
}

fn linkTargetName(element: *Element) []const u8 {
    return switch (classifyLinkTargetValue(element.getAttributeSafe(comptime .wrap("target")) orelse "")) {
        .named => |target_name| target_name,
        else => "",
    };
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

fn encodeNodePath(
    allocator: std.mem.Allocator,
    node: *Node,
) ![]u16 {
    var reverse: std.ArrayListUnmanaged(u16) = .{};
    errdefer reverse.deinit(allocator);

    var current: ?*Node = node;
    while (current) |value| {
        const parent = value.parentNode() orelse break;
        var child = parent.firstChild();
        var index: usize = 0;
        while (child) |candidate| : (child = candidate.nextSibling()) {
            if (candidate == value) {
                break;
            }
            index += 1;
        }
        try reverse.append(allocator, std.math.cast(u16, index) orelse return error.Overflow);
        current = parent;
    }

    const path = try allocator.alloc(u16, reverse.items.len);
    for (reverse.items, 0..) |segment, idx| {
        path[(reverse.items.len - 1) - idx] = segment;
    }
    reverse.deinit(allocator);
    return path;
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
            .height = @max(@as(i32, 1), text.height),
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
    const resolved_z = try page.call_arena.dupeZ(u8, resolved);
    const request_context = try resolveImageRequestContext(page, resolved_z);
    const alt = element.getAttributeSafe(comptime .wrap("alt")) orelse "";
    const include_credentials = imageRequestIncludesCredentials(element);
    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .url = @constCast(resolved),
        .alt = @constCast(alt),
        .request_include_credentials = include_credentials,
        .request_cookie_value = if (include_credentials) request_context.cookie_value else &.{},
        .request_referer_value = request_context.referer_value,
        .request_authorization_value = if (include_credentials) request_context.authorization_value else &.{},
    };
}

const ImageRequestContext = struct {
    cookie_value: []u8 = &.{},
    referer_value: []u8 = &.{},
    authorization_value: []u8 = &.{},
};

fn resolveImageRequestContext(page: *Page, resolved_url: [:0]const u8) !ImageRequestContext {
    var headers = try page._session.browser.http_client.newHeaders();
    defer headers.deinit();

    try page.headersForRequest(page.call_arena, resolved_url, &headers);

    var context = ImageRequestContext{};
    var it = headers.iterator();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Cookie")) {
            context.cookie_value = try page.call_arena.dupe(u8, header.value);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Referer")) {
            context.referer_value = try page.call_arena.dupe(u8, header.value);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
            context.authorization_value = try page.call_arena.dupe(u8, header.value);
        }
    }
    return context;
}

fn imageRequestIncludesCredentials(element: *Element) bool {
    const cross_origin = element.getAttributeSafe(comptime .wrap("crossorigin")) orelse return true;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, cross_origin, " \t\r\n"), "use-credentials");
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

fn usesInlineContentFlowContainer(
    element: *Element,
    decl: anytype,
    page: *Page,
    display: []const u8,
) !bool {
    if (isInlineDisplay(display)) return false;
    if (hasVisibleBorder(decl, page)) return false;
    if (parseCssColor(resolveCssPropertyValue(decl, page, element, "background-color"))) |background| {
        if (background.a > 0) return false;
    }

    return try hasOnlyInlineFlowChildren(element, page);
}

fn hasOnlyInlineFlowChildren(element: *Element, page: *Page) !bool {
    var saw_flow_child = false;
    var it = element.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Node.CData.Text)) |text| {
            if (std.mem.trim(u8, text.getWholeText(), &std.ascii.whitespace).len > 0) {
                saw_flow_child = true;
            }
            continue;
        }
        if (child.is(Element)) |child_el| {
            if (switch (child_el.getTag()) {
                .script, .style, .template, .head, .meta, .link, .title => true,
                else => false,
            }) continue;
            if (child_el.getTag() == .br) {
                saw_flow_child = true;
                continue;
            }

            const child_style = try page.window.getComputedStyle(child_el, null, page);
            const child_display = child_style.asCSSStyleDeclaration().getPropertyValue("display", page);
            if (!isInlineDisplay(child_display)) {
                return false;
            }
            saw_flow_child = true;
        }
    }
    return saw_flow_child;
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
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
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
            .input, .select => 180,
            else => @max(self.opts.inline_min_width, estimateTextWidth(label, font_size, font_family, font_weight, italic) + 16),
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
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
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
        height = @max(height, estimateTextHeight(label, @max(40, content_width - 12), font_size, font_family, font_weight, italic) + 8);
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

fn estimateTextHeight(
    text: []const u8,
    width: i32,
    font_size: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
) i32 {
    if (builtin.os.tag == .windows) {
        return measureTextHeightWin32(text, width, font_size, font_family, font_weight, italic) catch
            estimateTextHeightFallback(text, width, font_size);
    }
    return estimateTextHeightFallback(text, width, font_size);
}

fn estimateTextHeightFallback(text: []const u8, width: i32, font_size: i32) i32 {
    if (text.len == 0) {
        return font_size + 8;
    }

    const usable_width = @max(40, width);
    const char_width = @max(@as(i32, 7), @divTrunc(font_size, 2));
    const chars_per_line = @max(@as(usize, 1), @as(usize, @intCast(usable_width / char_width)));
    const lines = @max(@as(usize, 1), (text.len + chars_per_line - 1) / chars_per_line);
    return @as(i32, @intCast(lines)) * (font_size + 4) + 8;
}

fn estimateTextWidth(
    text: []const u8,
    font_size: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
) i32 {
    if (builtin.os.tag == .windows) {
        return measureTextWidthWin32(text, font_size, font_family, font_weight, italic) catch
            estimateTextWidthFallback(text, font_size);
    }
    return estimateTextWidthFallback(text, font_size);
}

fn estimateTextWidthFallback(text: []const u8, font_size: i32) i32 {
    if (text.len == 0) {
        return 0;
    }
    const char_width = @max(@as(i32, 7), @divTrunc(font_size, 2));
    return @as(i32, @intCast(text.len)) * char_width;
}

fn measureTextWidthWin32(
    text: []const u8,
    font_size: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
) !i32 {
    if (text.len == 0) return 0;

    const metrics = try measureTextMetricsWin32(text, null, font_size, font_family, font_weight, italic);
    return metrics.width;
}

fn measureTextHeightWin32(
    text: []const u8,
    width: i32,
    font_size: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
) !i32 {
    const metrics = try measureTextMetricsWin32(text, width, font_size, font_family, font_weight, italic);
    return metrics.height;
}

const MeasuredTextMetrics = struct {
    width: i32,
    height: i32,
};

fn measureTextMetricsWin32(
    text: []const u8,
    wrap_width: ?i32,
    font_size: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
) !MeasuredTextMetrics {
    if (text.len == 0) {
        return .{ .width = 0, .height = font_size + 8 };
    }

    const hdc = win.CreateCompatibleDC(null) orelse return error.TextMeasureDcFailed;
    defer _ = win.DeleteDC(hdc);

    const font_spec = resolveMeasuredFontSpec(font_family);
    const wide_face = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, font_spec.face_name);
    defer std.heap.c_allocator.free(wide_face);
    const font = win.CreateFontW(
        -@as(i32, @intCast(@max(@as(i32, 1), font_size))),
        0,
        0,
        0,
        measuredFontWeight(font_weight),
        @intFromBool(italic),
        0,
        0,
        win.DEFAULT_CHARSET,
        win.OUT_DEFAULT_PRECIS,
        win.CLIP_DEFAULT_PRECIS,
        win.CLEARTYPE_QUALITY,
        @as(win.DWORD, @intCast(font_spec.pitch_family)),
        wide_face.ptr,
    );
    if (font == null) return error.TextMeasureFontFailed;
    const previous_font = win.SelectObject(hdc, font);
    defer {
        _ = win.SelectObject(hdc, previous_font);
        _ = win.DeleteObject(font);
    }

    const wide_text = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, text);
    defer std.heap.c_allocator.free(wide_text);

    var rect = win.RECT{
        .left = 0,
        .top = 0,
        .right = if (wrap_width) |w| @max(@as(i32, 1), w) else 0,
        .bottom = 0,
    };
    const flags: win.UINT = if (wrap_width != null)
        win.DT_LEFT | win.DT_TOP | win.DT_NOPREFIX | win.DT_CALCRECT | win.DT_WORDBREAK
    else
        win.DT_LEFT | win.DT_TOP | win.DT_NOPREFIX | win.DT_CALCRECT | win.DT_SINGLELINE;
    _ = win.DrawTextW(hdc, wide_text.ptr, @intCast(wide_text.len), &rect, flags);

    return .{
        .width = @max(@as(i32, 0), rect.right - rect.left),
        .height = @max(@as(i32, 0), rect.bottom - rect.top),
    };
}

const MeasuredFontSpec = struct {
    face_name: []const u8,
    pitch_family: u32,
};

fn resolveMeasuredFontSpec(font_family_value: []const u8) MeasuredFontSpec {
    var preferred_specific: []const u8 = "";
    var generic_spec: ?MeasuredFontSpec = null;

    var families = std.mem.splitScalar(u8, font_family_value, ',');
    while (families.next()) |raw_family| {
        const family = trimMeasuredFontFamily(raw_family);
        if (family.len == 0) continue;
        if (measuredGenericFontSpec(family)) |spec| {
            if (generic_spec == null) generic_spec = spec;
            continue;
        }
        if (preferred_specific.len == 0) preferred_specific = family;
    }

    if (preferred_specific.len > 0) {
        return .{
            .face_name = preferred_specific,
            .pitch_family = if (generic_spec) |spec| spec.pitch_family else @as(u32, win.DEFAULT_PITCH | win.FF_DONTCARE),
        };
    }
    if (generic_spec) |spec| return spec;
    return .{
        .face_name = "Segoe UI",
        .pitch_family = @as(u32, win.DEFAULT_PITCH | win.FF_SWISS),
    };
}

fn trimMeasuredFontFamily(raw_family: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_family, &std.ascii.whitespace);
    if (trimmed.len >= 2) {
        const quote = trimmed[0];
        if ((quote == '"' or quote == '\'') and trimmed[trimmed.len - 1] == quote) {
            return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], &std.ascii.whitespace);
        }
    }
    return trimmed;
}

fn measuredGenericFontSpec(family: []const u8) ?MeasuredFontSpec {
    if (std.ascii.eqlIgnoreCase(family, "sans-serif") or
        std.ascii.eqlIgnoreCase(family, "system-ui") or
        std.ascii.eqlIgnoreCase(family, "ui-sans-serif") or
        std.ascii.eqlIgnoreCase(family, "ui-rounded"))
    {
        return .{ .face_name = "Segoe UI", .pitch_family = @as(u32, win.DEFAULT_PITCH | win.FF_SWISS) };
    }
    if (std.ascii.eqlIgnoreCase(family, "serif") or std.ascii.eqlIgnoreCase(family, "ui-serif")) {
        return .{ .face_name = "Times New Roman", .pitch_family = @as(u32, win.VARIABLE_PITCH | win.FF_ROMAN) };
    }
    if (std.ascii.eqlIgnoreCase(family, "monospace") or std.ascii.eqlIgnoreCase(family, "ui-monospace")) {
        return .{ .face_name = "Consolas", .pitch_family = @as(u32, win.FIXED_PITCH | win.FF_MODERN) };
    }
    if (std.ascii.eqlIgnoreCase(family, "cursive")) {
        return .{ .face_name = "Segoe Script", .pitch_family = @as(u32, win.VARIABLE_PITCH | win.FF_SCRIPT) };
    }
    if (std.ascii.eqlIgnoreCase(family, "fantasy")) {
        return .{ .face_name = "Impact", .pitch_family = @as(u32, win.VARIABLE_PITCH | win.FF_DECORATIVE) };
    }
    if (std.ascii.eqlIgnoreCase(family, "emoji")) {
        return .{ .face_name = "Segoe UI Emoji", .pitch_family = @as(u32, win.DEFAULT_PITCH | win.FF_DONTCARE) };
    }
    if (std.ascii.eqlIgnoreCase(family, "math")) {
        return .{ .face_name = "Cambria Math", .pitch_family = @as(u32, win.DEFAULT_PITCH | win.FF_ROMAN) };
    }
    return null;
}

fn measuredFontWeight(css_weight: i32) i32 {
    return @as(i32, @intCast(std.math.clamp(css_weight, 100, 900)));
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

fn parseCssFontWeight(value: []const u8) i32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return 400;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "normal")) return 400;
    if (std.ascii.eqlIgnoreCase(trimmed, "bold")) return 700;
    if (std.ascii.eqlIgnoreCase(trimmed, "bolder")) return 700;
    if (std.ascii.eqlIgnoreCase(trimmed, "lighter")) return 300;

    const parsed = std.fmt.parseInt(i32, trimmed, 10) catch return 400;
    return std.math.clamp(parsed, 100, 900);
}

fn parseCssFontItalic(value: []const u8) bool {
    return containsAsciiToken(value, "italic") or containsAsciiToken(value, "oblique");
}

fn appendLoadedFontFacesToDisplayList(
    allocator: std.mem.Allocator,
    page: *Page,
    list: *DisplayList,
) !void {
    const sheets = try page.window._document.getStyleSheets(page);
    for (sheets.items()) |sheet| {
        for (sheet.getFontFaces()) |entry| {
            if (!entry.loaded or entry.font_bytes.len == 0) {
                continue;
            }
            const format = mapFontFaceFormat(entry.format);
            if (!format.supportsWin32PrivateRegistration()) {
                continue;
            }
            if (displayListHasFontFace(list, entry.family, format, entry.font_bytes)) {
                continue;
            }
            try list.addFontFace(allocator, .{
                .family = @constCast(entry.family),
                .format = format,
                .bytes = @constCast(entry.font_bytes),
            });
        }
    }
}

fn mapFontFaceFormat(format: CSSStyleSheet.FontFaceEntry.Format) FontFaceFormat {
    return switch (format) {
        .truetype => .truetype,
        .opentype => .opentype,
        .woff => .woff,
        .woff2 => .woff2,
        else => .unknown,
    };
}

fn displayListHasFontFace(
    list: *const DisplayList,
    family: []const u8,
    format: FontFaceFormat,
    bytes: []const u8,
) bool {
    for (list.font_faces.items) |entry| {
        if (entry.format != format) continue;
        if (!std.ascii.eqlIgnoreCase(entry.family, family)) continue;
        if (std.mem.eql(u8, entry.bytes, bytes)) {
            return true;
        }
    }
    return false;
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

test "parseCssFontWeight handles keywords and numeric values" {
    try std.testing.expectEqual(@as(i32, 400), parseCssFontWeight(""));
    try std.testing.expectEqual(@as(i32, 400), parseCssFontWeight("normal"));
    try std.testing.expectEqual(@as(i32, 700), parseCssFontWeight("bold"));
    try std.testing.expectEqual(@as(i32, 700), parseCssFontWeight("bolder"));
    try std.testing.expectEqual(@as(i32, 300), parseCssFontWeight("lighter"));
    try std.testing.expectEqual(@as(i32, 500), parseCssFontWeight("500"));
    try std.testing.expectEqual(@as(i32, 900), parseCssFontWeight("1200"));
}

test "parseCssFontItalic handles italic and oblique values" {
    try std.testing.expect(!parseCssFontItalic(""));
    try std.testing.expect(!parseCssFontItalic("normal"));
    try std.testing.expect(parseCssFontItalic("italic"));
    try std.testing.expect(parseCssFontItalic("oblique"));
    try std.testing.expect(parseCssFontItalic("oblique 10deg"));
}

test "isInlineDisplay matches inline variants" {
    try std.testing.expect(isInlineDisplay("inline"));
    try std.testing.expect(isInlineDisplay("inline-block"));
    try std.testing.expect(isInlineDisplay(" inline-flex "));
    try std.testing.expect(!isInlineDisplay("block"));
}

test "classifyLinkTargetValue distinguishes blank named and same-context targets" {
    try std.testing.expectEqual(LinkTargetKind.same_context, classifyLinkTargetValue(""));
    try std.testing.expectEqual(LinkTargetKind.same_context, classifyLinkTargetValue("_self"));
    try std.testing.expectEqual(LinkTargetKind.same_context, classifyLinkTargetValue("_TOP"));
    try std.testing.expectEqual(LinkTargetKind.new_tab, classifyLinkTargetValue("_blank"));
    const named = classifyLinkTargetValue(" report ");
    try std.testing.expectEqualStrings(
        "report",
        switch (named) {
            .named => |value| value,
            else => return error.TestUnexpectedTargetKind,
        },
    );
}

test "paintDocument emits named target link region" {
    var page = try testing.pageTest("page/popup_target.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.link_regions.items) |region| {
        if (!std.mem.eql(u8, region.target_name, "report")) {
            continue;
        }
        try std.testing.expectEqualStrings(
            "http://127.0.0.1:9582/src/browser/tests/page/popup-target-result.html?from=anchor",
            region.url,
        );
        try std.testing.expect(region.width > 0);
        try std.testing.expect(region.height > 0);
        found = true;
        break;
    }

    try std.testing.expect(found);
}

test "paintDocument emits same-context link region with dom path" {
    var page = try testing.pageTest("page/rendered_link_activation.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.link_regions.items) |region| {
        if (!std.mem.eql(u8, region.url, "http://127.0.0.1:9582/src/browser/tests/page/original-target.html")) {
            continue;
        }
        try std.testing.expect(region.width > 0);
        try std.testing.expect(region.height > 0);
        try std.testing.expect(region.dom_path.len > 0);
        found = true;
        break;
    }

    try std.testing.expect(found);
}

test "paintDocument emits control region for file input" {
    var page = try testing.pageTest("page/upload_form.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.control_regions.items) |region| {
        if (region.dom_path.len == 0) {
            continue;
        }
        found = true;
        break;
    }

    try std.testing.expect(found);
}

test "paintDocument emits image request authorization from url userinfo" {
    var page = try testing.pageTest("page/auth_image.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| {
                if (!std.mem.eql(u8, image.url, "http://img%20user:p%40ss@127.0.0.1:9582/private.png")) {
                    continue;
                }
                try std.testing.expectEqualStrings("Basic aW1nIHVzZXI6cEBzcw==", image.request_authorization_value);
                try std.testing.expectEqualStrings(
                    "http://127.0.0.1:9582/src/browser/tests/page/auth_image.html",
                    image.request_referer_value,
                );
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument suppresses image credentials for anonymous crossorigin" {
    var page = try testing.pageTest("page/auth_image_anonymous.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| {
                if (!std.mem.eql(u8, image.url, "http://img%20user:p%40ss@127.0.0.1:9582/private.png")) {
                    continue;
                }
                try std.testing.expect(!image.request_include_credentials);
                try std.testing.expectEqualStrings("", image.request_cookie_value);
                try std.testing.expectEqualStrings("", image.request_authorization_value);
                try std.testing.expectEqualStrings(
                    "http://127.0.0.1:9582/src/browser/tests/page/auth_image_anonymous.html",
                    image.request_referer_value,
                );
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument inherits image request authorization from same-origin page url" {
    var page = try testing.pageTest("page/auth_image_inherited.html");
    defer page._session.removePage();
    page.url = "http://img%20user:p%40ss@127.0.0.1:9582/src/browser/tests/page/auth_image_inherited.html";
    page.referer_header = null;

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| {
                if (!std.mem.endsWith(u8, image.url, "/private-inherit.png")) {
                    continue;
                }
                try std.testing.expect(image.request_include_credentials);
                try std.testing.expectEqualStrings("Basic aW1nIHVzZXI6cEBzcw==", image.request_authorization_value);
                try std.testing.expectEqualStrings(
                    "http://127.0.0.1:9582/src/browser/tests/page/auth_image_inherited.html",
                    image.request_referer_value,
                );
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument renders button controls without crashing" {
    var page = try testing.pageTest("page/button_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found_control = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Button")) {
                    found_control = true;
                    break;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(found_control);
}

test "paintDocument carries authored font family style and weight on text commands" {
    var page = try testing.pageTest("page/font_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found_mono = false;
    var found_serif = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "MMMMMMMMMMMM")) {
                    try std.testing.expect(std.mem.indexOf(u8, text.font_family, "Consolas") != null);
                    try std.testing.expectEqual(@as(i32, 700), text.font_weight);
                    try std.testing.expect(text.italic);
                    found_mono = true;
                } else if (std.mem.eql(u8, text.text, "NNNNNNNNNNNN")) {
                    try std.testing.expect(std.mem.indexOf(u8, text.font_family, "Times New Roman") != null);
                    try std.testing.expectEqual(@as(i32, 400), text.font_weight);
                    try std.testing.expect(!text.italic);
                    found_serif = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(found_mono);
    try std.testing.expect(found_serif);
}

test "paintDocument measures button widths from authored font families" {
    var page = try testing.pageTest("page/font_button_measure.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), display_list.control_regions.items.len);

    const first = display_list.control_regions.items[0];
    const second = display_list.control_regions.items[1];
    try std.testing.expect(first.width != second.width);
}

test "paintDocument keeps direct paragraph text in the same inline flow as child chips" {
    var page = try testing.pageTest("page/mixed_inline_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var prefix_y: ?i32 = null;
    var red_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Prefix ")) {
                    prefix_y = text.y;
                } else if (std.mem.eql(u8, text.text, "RED")) {
                    red_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(prefix_y != null);
    try std.testing.expect(red_y != null);
    try std.testing.expect(@abs(prefix_y.? - red_y.?) <= 4);
}

test "paintDocument wraps mixed inline paragraph content without splitting it into a separate label band" {
    var page = try testing.pageTest("page/mixed_inline_wrap_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var prefix_y: ?i32 = null;
    var red_y: ?i32 = null;
    var lower_chip_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Prefix ")) {
                    prefix_y = text.y;
                } else if (std.mem.eql(u8, text.text, "RED")) {
                    red_y = text.y;
                } else if (std.mem.eql(u8, text.text, "GREEN") or std.mem.eql(u8, text.text, "LINK")) {
                    lower_chip_y = if (lower_chip_y) |current| @max(current, text.y) else text.y;
                } else if (std.mem.eql(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(prefix_y != null);
    try std.testing.expect(red_y != null);
    try std.testing.expect(lower_chip_y != null);
    try std.testing.expect(below_y != null);
    _ = red_y.?;
    try std.testing.expect(lower_chip_y.? > red_y.? + 8);
    try std.testing.expect(below_y.? > lower_chip_y.? + 12);
}

test "paintDocument treats br as a real line break inside mixed inline flow" {
    var page = try testing.pageTest("page/mixed_inline_break_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
    });
    defer display_list.deinit(std.testing.allocator);

    var prefix_y: ?i32 = null;
    var red_y: ?i32 = null;
    var after_break_y: ?i32 = null;
    var green_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Prefix ")) {
                    prefix_y = text.y;
                } else if (std.mem.eql(u8, text.text, "RED")) {
                    red_y = text.y;
                } else if (std.mem.eql(u8, text.text, "After ")) {
                    after_break_y = text.y;
                } else if (std.mem.eql(u8, text.text, "GREEN")) {
                    green_y = text.y;
                } else if (std.mem.eql(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(prefix_y != null);
    try std.testing.expect(red_y != null);
    try std.testing.expect(after_break_y != null);
    try std.testing.expect(green_y != null);
    try std.testing.expect(below_y != null);
    try std.testing.expect(red_y.? >= prefix_y.? - 4);
    try std.testing.expect(after_break_y.? > red_y.? + 12);
    try std.testing.expect(green_y.? >= after_break_y.? - 4);
    try std.testing.expect(below_y.? > green_y.? + 12);
}

test "paintDocument wraps mixed inline anchor text across multiple rows" {
    var page = try testing.pageTest("page/mixed_inline_wrap_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var min_y: ?i32 = null;
    var max_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (!(std.mem.eql(u8, text.text, "go ") or
                    std.mem.eql(u8, text.text, "LINK") or
                    std.mem.eql(u8, text.text, "now ") or
                    std.mem.eql(u8, text.text, "suffix ")))
                {
                    continue;
                }
                min_y = if (min_y) |current| @min(current, text.y) else text.y;
                max_y = if (max_y) |current| @max(current, text.y + text.height) else (text.y + text.height);
            },
            else => {},
        }
    }

    try std.testing.expect(min_y != null);
    try std.testing.expect(max_y != null);
    try std.testing.expect(max_y.? > min_y.? + 24);
}

test "paintDocument keeps wrapped inline button controls in the shared flow" {
    var page = try testing.pageTest("page/mixed_inline_button_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    var button_region: ?ControlRegion = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.eql(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }
    for (display_list.control_regions.items) |region| {
        button_region = region;
        break;
    }

    try std.testing.expect(lead_y != null);
    try std.testing.expect(button_region != null);
    try std.testing.expect(below_y != null);
    try std.testing.expect(button_region.?.y > lead_y.? + 8);
    try std.testing.expect(below_y.? > button_region.?.y + button_region.?.height + 8);
}

test "paintDocument keeps br-split inline input controls on the later row" {
    var page = try testing.pageTest("page/mixed_inline_input_break_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 680,
    });
    defer display_list.deinit(std.testing.allocator);

    var prefix_y: ?i32 = null;
    var after_break_y: ?i32 = null;
    var below_y: ?i32 = null;
    var input_region: ?ControlRegion = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Prefix ")) {
                    prefix_y = text.y;
                } else if (std.mem.eql(u8, text.text, "After ")) {
                    after_break_y = text.y;
                } else if (std.mem.eql(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }
    for (display_list.control_regions.items) |region| {
        input_region = region;
        break;
    }

    try std.testing.expect(prefix_y != null);
    try std.testing.expect(after_break_y != null);
    try std.testing.expect(input_region != null);
    try std.testing.expect(below_y != null);
    try std.testing.expect(after_break_y.? > prefix_y.? + 12);
    try std.testing.expect(input_region.?.y >= after_break_y.? - 4);
    try std.testing.expect(below_y.? > input_region.?.y + input_region.?.height + 8);
}

test "paintDocument keeps wrapped inline button and later link regions distinct" {
    var page = try testing.pageTest("page/mixed_inline_control_link_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.control_regions.items.len);
    try std.testing.expect(display_list.link_regions.items.len >= 1);

    const control_region = display_list.control_regions.items[0];
    var latest_link_y: ?i32 = null;
    for (display_list.link_regions.items) |region| {
        latest_link_y = if (latest_link_y) |current| @max(current, region.y) else region.y;
    }

    try std.testing.expect(latest_link_y != null);
    try std.testing.expect(latest_link_y.? > control_region.y + 12);
}

test "paintDocument keeps dense mixed inline focus targets in DOM order across later rows" {
    var page = try testing.pageTest("page/mixed_inline_dense_focus_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), display_list.control_regions.items.len);
    try std.testing.expect(display_list.link_regions.items.len >= 1);

    const first_control = display_list.control_regions.items[0];
    const second_control = display_list.control_regions.items[1];
    var latest_link_y: ?i32 = null;
    for (display_list.link_regions.items) |region| {
        latest_link_y = if (latest_link_y) |current| @max(current, region.y) else region.y;
    }

    try std.testing.expect(latest_link_y != null);
    try std.testing.expect(second_control.y >= first_control.y + 8);
    try std.testing.expect(latest_link_y.? > second_control.y + 8);
}

test "paintDocument keeps wrapped inline checkbox and later link regions distinct" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_link_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), display_list.control_regions.items.len);
    try std.testing.expect(display_list.link_regions.items.len >= 1);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const control_region = display_list.control_regions.items[0];
    var latest_link_y: ?i32 = null;
    for (display_list.link_regions.items) |region| {
        latest_link_y = if (latest_link_y) |current| @max(current, region.y) else region.y;
    }

    try std.testing.expect(latest_link_y != null);
    try std.testing.expect(control_region.y > lead_y.? + 8);
    try std.testing.expect(latest_link_y.? > control_region.y + 8);
    try std.testing.expect(below_y.? > latest_link_y.? + 8);
}

test "paintDocument keeps wrapped inline radio and later link regions distinct" {
    var page = try testing.pageTest("page/mixed_inline_radio_link_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), display_list.control_regions.items.len);
    try std.testing.expect(display_list.link_regions.items.len >= 1);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const control_region = display_list.control_regions.items[0];
    var latest_link_y: ?i32 = null;
    for (display_list.link_regions.items) |region| {
        latest_link_y = if (latest_link_y) |current| @max(current, region.y) else region.y;
    }

    try std.testing.expect(latest_link_y != null);
    try std.testing.expect(control_region.y > lead_y.? + 8);
    try std.testing.expect(latest_link_y.? > control_region.y + 8);
    try std.testing.expect(below_y.? > latest_link_y.? + 8);
}

test "paintDocument keeps wrapped inline checkbox button and later link in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_button_link_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), display_list.control_regions.items.len);
    try std.testing.expect(display_list.link_regions.items.len >= 1);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_region = display_list.control_regions.items[0];
    const button_region = display_list.control_regions.items[1];
    var latest_link_y: ?i32 = null;
    for (display_list.link_regions.items) |region| {
        latest_link_y = if (latest_link_y) |current| @max(current, region.y) else region.y;
    }

    try std.testing.expect(checkbox_region.y > lead_y.? + 8);
    try std.testing.expect(button_region.y >= checkbox_region.y + 8);
    try std.testing.expect(latest_link_y != null);
    try std.testing.expect(latest_link_y.? > button_region.y + 8);
    try std.testing.expect(below_y.? > latest_link_y.? + 8);
}

test "paintDocument keeps wrapped inline radio button and later link in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_radio_button_link_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), display_list.control_regions.items.len);
    try std.testing.expect(display_list.link_regions.items.len >= 1);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const radio_region = display_list.control_regions.items[0];
    const button_region = display_list.control_regions.items[1];
    var latest_link_y: ?i32 = null;
    for (display_list.link_regions.items) |region| {
        latest_link_y = if (latest_link_y) |current| @max(current, region.y) else region.y;
    }

    try std.testing.expect(latest_link_y != null);
    try std.testing.expect(radio_region.y > lead_y.? + 8);
    try std.testing.expect(button_region.y >= radio_region.y + 8);
    try std.testing.expect(latest_link_y.? > button_region.y + 8);
    try std.testing.expect(below_y.? > latest_link_y.? + 8);
}

test "paintDocument keeps wrapped inline checkbox radio button and later link in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_radio_button_link_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), display_list.control_regions.items.len);
    try std.testing.expect(display_list.link_regions.items.len >= 1);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_region = display_list.control_regions.items[0];
    const radio_region = display_list.control_regions.items[1];
    const button_region = display_list.control_regions.items[2];
    var latest_link_y: ?i32 = null;
    for (display_list.link_regions.items) |region| {
        latest_link_y = if (latest_link_y) |current| @max(current, region.y) else region.y;
    }

    try std.testing.expect(latest_link_y != null);
    try std.testing.expect(checkbox_region.y > lead_y.? + 8);
    try std.testing.expect(radio_region.y >= checkbox_region.y + 8);
    try std.testing.expect(button_region.y >= radio_region.y + 8);
    try std.testing.expect(latest_link_y.? > button_region.y + 8);
    try std.testing.expect(below_y.? > latest_link_y.? + 8);
}

test "paintDocument keeps wrapped inline radio pair button and later link in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_radio_pair_button_link_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), display_list.control_regions.items.len);
    try std.testing.expect(display_list.link_regions.items.len >= 1);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const radio_one_region = display_list.control_regions.items[0];
    const radio_two_region = display_list.control_regions.items[1];
    const button_region = display_list.control_regions.items[2];
    var latest_link_y: ?i32 = null;
    for (display_list.link_regions.items) |region| {
        latest_link_y = if (latest_link_y) |current| @max(current, region.y) else region.y;
    }

    try std.testing.expect(latest_link_y != null);
    try std.testing.expect(radio_one_region.y > lead_y.? + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(button_region.y >= radio_two_region.y + 8);
    try std.testing.expect(latest_link_y.? > button_region.y + 8);
    try std.testing.expect(below_y.? > latest_link_y.? + 8);
}

test "paintDocument keeps wrapped inline checkbox pair button and later link in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_button_link_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), display_list.control_regions.items.len);
    try std.testing.expect(display_list.link_regions.items.len >= 1);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const button_region = display_list.control_regions.items[2];
    var latest_link_y: ?i32 = null;
    for (display_list.link_regions.items) |region| {
        latest_link_y = if (latest_link_y) |current| @max(current, region.y) else region.y;
    }

    try std.testing.expect(latest_link_y != null);
    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(button_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(latest_link_y.? > button_region.y + 8);
    try std.testing.expect(below_y.? > latest_link_y.? + 8);
}

test "paintDocument keeps wrapped inline checkbox pair and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_submit_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 0), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const submit_region = display_list.control_regions.items[2];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(submit_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline radio pair and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_radio_pair_submit_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 0), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const radio_one_region = display_list.control_regions.items[0];
    const radio_two_region = display_list.control_regions.items[1];
    const submit_region = display_list.control_regions.items[2];

    try std.testing.expect(radio_one_region.y > lead_y.? + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(submit_region.y >= radio_two_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair input and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_input_submit_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 0), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const input_region = display_list.control_regions.items[2];
    const submit_region = display_list.control_regions.items[3];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(input_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(submit_region.y >= input_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline radio pair input and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_radio_pair_input_submit_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 0), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const radio_one_region = display_list.control_regions.items[0];
    const radio_two_region = display_list.control_regions.items[1];
    const input_region = display_list.control_regions.items[2];
    const submit_region = display_list.control_regions.items[3];

    try std.testing.expect(radio_one_region.y > lead_y.? + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_region.y >= radio_two_region.y + 8);
    try std.testing.expect(submit_region.y >= input_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox radio input and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_radio_input_submit_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var lead_y: ?i32 = null;
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.startsWith(u8, text.text, "Lead ")) {
                    lead_y = text.y;
                } else if (std.mem.startsWith(u8, text.text, "Below ")) {
                    below_y = text.y;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 0), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_region = display_list.control_regions.items[0];
    const radio_region = display_list.control_regions.items[1];
    const input_region = display_list.control_regions.items[2];
    const submit_region = display_list.control_regions.items[3];

    try std.testing.expect(checkbox_region.y > lead_y.? + 8);
    try std.testing.expect(radio_region.y >= checkbox_region.y + 8);
    try std.testing.expect(input_region.y >= radio_region.y + 8);
    try std.testing.expect(submit_region.y >= input_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument carries loaded private font faces for headed rendering" {
    var page = try testing.pageTest("page/font_private_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.font_faces.items.len);
    try std.testing.expectEqualStrings("ABeeZee", display_list.font_faces.items[0].family);
    try std.testing.expectEqual(FontFaceFormat.truetype, display_list.font_faces.items[0].format);
    try std.testing.expect(display_list.font_faces.items[0].bytes.len > 0);

    var found_private_run = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "PrivateFontWidthProof")) {
                    try std.testing.expect(std.mem.indexOf(u8, text.font_family, "ABeeZee") != null);
                    found_private_run = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(found_private_run);
}

test "paintDocument carries loaded woff2 private font faces for headed rendering" {
    var page = try testing.pageTest("page/font_private_woff2_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.font_faces.items.len);
    try std.testing.expectEqualStrings("IBM Plex Mono", display_list.font_faces.items[0].family);
    try std.testing.expectEqual(FontFaceFormat.woff2, display_list.font_faces.items[0].format);
    try std.testing.expect(display_list.font_faces.items[0].bytes.len > 0);
}

test "paintDocument carries loaded woff private font faces for headed rendering" {
    var page = try testing.pageTest("page/font_private_woff_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.font_faces.items.len);
    try std.testing.expectEqualStrings("Azeret Mono", display_list.font_faces.items[0].family);
    try std.testing.expectEqual(FontFaceFormat.woff, display_list.font_faces.items[0].format);
    try std.testing.expect(display_list.font_faces.items[0].bytes.len > 0);
}
