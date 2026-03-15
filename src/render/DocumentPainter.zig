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
const TextCommand = @import("DisplayList.zig").TextCommand;
const LinkRegion = @import("DisplayList.zig").LinkRegion;
const ControlRegion = @import("DisplayList.zig").ControlRegion;
const ImageCommand = @import("DisplayList.zig").ImageCommand;
const CanvasCommand = @import("DisplayList.zig").CanvasCommand;
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
    viewport_height: i32 = 0,
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

const FlexChildMeasure = struct {
    node: *Node,
    width: i32,
    height: i32,
    flex_grow: f32 = 0,
    align_self: FlexCrossAlignment = .auto,
};

const FlexLineMeasure = struct {
    start_index: usize,
    end_index: usize,
    width: i32,
    height: i32,
};

const Bounds = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const FlexCrossAlignment = enum {
    auto,
    start,
    center,
    end,
};

const FloatMode = enum {
    none,
    left,
    right,
};

const Painter = struct {
    allocator: std.mem.Allocator,
    page: *Page,
    opts: PaintOpts,
    list: *DisplayList,
    forced_item_node: ?*Node = null,
    forced_item_width: i32 = 0,

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

    fn measureNodePaintedBox(self: *Painter, node: *Node, available_width: i32) !struct { width: i32, height: i32 } {
        var temp_list = DisplayList{
            .layout_scale = self.list.layout_scale,
            .page_margin = self.list.page_margin,
        };
        defer temp_list.deinit(self.allocator);

        var temp_painter = Painter{
            .allocator = self.allocator,
            .page = self.page,
            .opts = self.opts,
            .list = &temp_list,
        };
        var cursor = FlowCursor.init(0, 0, @max(@as(i32, 40), available_width));
        try temp_painter.paintNode(node, &cursor);

        if (displayListBounds(&temp_list)) |bounds| {
            return .{
                .width = bounds.width,
                .height = bounds.height,
            };
        }

        return .{
            .width = @max(@as(i32, 0), cursor.cursor_x - cursor.left),
            .height = cursor.consumedHeightSince(0),
        };
    }

    fn appendDisplayListWithOffset(
        self: *Painter,
        source: *const DisplayList,
        dx: i32,
        dy: i32,
    ) !void {
        for (source.commands.items) |command| {
            switch (command) {
                .fill_rect => |rect| try self.list.addFillRect(self.allocator, .{
                    .x = rect.x + dx,
                    .y = rect.y + dy,
                    .width = rect.width,
                    .height = rect.height,
                    .z_index = rect.z_index,
                    .color = rect.color,
                }),
                .stroke_rect => |rect| try self.list.addStrokeRect(self.allocator, .{
                    .x = rect.x + dx,
                    .y = rect.y + dy,
                    .width = rect.width,
                    .height = rect.height,
                    .z_index = rect.z_index,
                    .color = rect.color,
                }),
                .text => |text| try self.list.addText(self.allocator, .{
                    .x = text.x + dx,
                    .y = text.y + dy,
                    .width = text.width,
                    .height = text.height,
                    .z_index = text.z_index,
                    .font_size = text.font_size,
                    .font_family = text.font_family,
                    .font_weight = text.font_weight,
                    .italic = text.italic,
                    .color = text.color,
                    .underline = text.underline,
                    .text = text.text,
                }),
                .image => |image| try self.list.addImage(self.allocator, .{
                    .x = image.x + dx,
                    .y = image.y + dy,
                    .width = image.width,
                    .height = image.height,
                    .z_index = image.z_index,
                    .url = image.url,
                    .alt = image.alt,
                    .request_include_credentials = image.request_include_credentials,
                    .request_cookie_value = image.request_cookie_value,
                    .request_referer_value = image.request_referer_value,
                    .request_authorization_value = image.request_authorization_value,
                }),
                .canvas => |canvas| try self.list.addCanvas(self.allocator, .{
                    .x = canvas.x + dx,
                    .y = canvas.y + dy,
                    .width = canvas.width,
                    .height = canvas.height,
                    .z_index = canvas.z_index,
                    .pixel_width = canvas.pixel_width,
                    .pixel_height = canvas.pixel_height,
                    .pixels = try self.allocator.dupe(u8, canvas.pixels),
                }),
            }
        }

        for (source.link_regions.items) |region| {
            try self.list.addLinkRegion(self.allocator, .{
                .x = region.x + dx,
                .y = region.y + dy,
                .width = region.width,
                .height = region.height,
                .z_index = region.z_index,
                .url = region.url,
                .dom_path = region.dom_path,
                .download_filename = region.download_filename,
                .open_in_new_tab = region.open_in_new_tab,
                .target_name = region.target_name,
            });
        }

        for (source.control_regions.items) |region| {
            try self.list.addControlRegion(self.allocator, .{
                .x = region.x + dx,
                .y = region.y + dy,
                .width = region.width,
                .height = region.height,
                .z_index = region.z_index,
                .dom_path = region.dom_path,
            });
        }
    }

    fn paintInlineFlowChildren(
        self: *Painter,
        element: *Element,
        content_x: i32,
        content_y: i32,
        content_width: i32,
        text_align_value: []const u8,
    ) !i32 {
        var temp_list = DisplayList{
            .layout_scale = self.list.layout_scale,
            .page_margin = self.list.page_margin,
        };
        defer temp_list.deinit(self.allocator);
        var out_of_flow_children: std.ArrayList(*Node) = .{};
        defer out_of_flow_children.deinit(self.allocator);

        var temp_painter = Painter{
            .allocator = self.allocator,
            .page = self.page,
            .opts = self.opts,
            .list = &temp_list,
        };
        var child_cursor = FlowCursor.init(0, 0, @max(@as(i32, 40), content_width));
        var child_it = element.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (try isOutOfFlowNode(child, self.page)) {
                try out_of_flow_children.append(self.allocator, child);
                continue;
            }
            try temp_painter.paintNode(child, &child_cursor);
        }

        const child_height = child_cursor.consumedHeightSince(0);
        const text_align = std.mem.trim(u8, text_align_value, &std.ascii.whitespace);
        const bounds = displayListBounds(&temp_list);
        var offset_x = content_x;
        if (bounds) |child_bounds| {
            if (std.ascii.eqlIgnoreCase(text_align, "center")) {
                offset_x += @max(@as(i32, 0), @divTrunc(content_width - child_bounds.width, 2));
            } else if (std.ascii.eqlIgnoreCase(text_align, "right") or std.ascii.eqlIgnoreCase(text_align, "end")) {
                offset_x += @max(@as(i32, 0), content_width - child_bounds.width);
            }
            offset_x -= child_bounds.x;
        }

        try self.appendDisplayListWithOffset(&temp_list, offset_x, content_y);
        if (out_of_flow_children.items.len > 0) {
            var overlay_cursor = FlowCursor.init(content_x, content_y, @max(@as(i32, 40), content_width));
            for (out_of_flow_children.items) |child| {
                try self.paintNode(child, &overlay_cursor);
            }
        }
        return if (bounds) |child_bounds|
            @max(child_height, child_bounds.y + child_bounds.height)
        else
            child_height;
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
        const paint_z_index = try resolvePaintZIndex(parent, parent_decl, self.page);

        try self.list.addText(self.allocator, .{
            .x = pos.x,
            .y = pos.y,
            .width = width,
            .height = height,
            .z_index = paint_z_index,
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

        const display = resolvedDisplayValue(decl, self.page, element);
        const raw_has_child_elements = hasRenderableChildElements(element);
        const canvas_surface_present = tag == .canvas and canvasSurfaceForElement(element) != null;
        const has_child_elements = raw_has_child_elements and !canvas_surface_present;
        const block_like = isFlowBlockLike(tag, display, has_child_elements);
        const inline_leaf = !block_like and !has_child_elements;
        const margins = resolveEdgeSizes(decl, self.page, "margin");
        const padding = resolveEdgeSizes(decl, self.page, "padding");
        const font_family = resolveCssPropertyValue(decl, self.page, element, "font-family");
        const font_weight = parseCssFontWeight(resolveCssPropertyValue(decl, self.page, element, "font-weight"));
        const italic = parseCssFontItalic(resolveCssPropertyValue(decl, self.page, element, "font-style"));
        const inline_content_flow = block_like and try usesInlineContentFlowContainer(element, decl, self.page, display);
        const position_value = resolveCssPropertyValue(decl, self.page, element, "position");
        const out_of_flow_positioned = isOutOfFlowPositioned(position_value);
        const paint_z_index = try resolvePaintZIndex(element, decl, self.page);

        const label = if (canvas_surface_present)
            try self.allocator.dupe(u8, "")
        else
            try self.elementLabel(element);
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

            if (!canvas_surface_present) {
                var child_it = element.asNode().childrenIterator();
                while (child_it.next()) |child| {
                    try self.paintNode(child, cursor);
                }
            }

            try self.appendInlineLinkRegionsForCommandRange(element, command_start);
            return;
        }

        const available_width = resolveAvailableWidthForElement(self, element, cursor.*, decl, margins, out_of_flow_positioned);
        const width = resolveLayoutWidth(self, element, decl, self.page, tag, block_like, available_width, label, font_size, font_family, font_weight, italic);
        if (width <= 0) {
            return;
        }

        const pos = if (out_of_flow_positioned)
            resolveOutOfFlowPosition(self, element, cursor.*, decl, margins, width)
        else if (inline_leaf)
            cursor.beginInlineLeaf(width, margins)
        else
            cursor.beginBlock(margins);
        var x = pos.x;
        const y = pos.y;
        if (!inline_leaf) {
            x = resolveAutoMarginAlignedX(cursor.*, decl, self.page, width, margins, x);
        }
        if (block_like and isFlexDisplay(display)) {
            const rect = if (isFlexColumnContainer(display, decl, self.page))
                try self.paintFlexColumnElement(
                    element,
                    decl,
                    tag,
                    x,
                    y,
                    width,
                    padding,
                    margins,
                    block_like,
                )
            else
                try self.paintFlexRowElement(
                    element,
                    decl,
                    tag,
                    x,
                    y,
                    width,
                    padding,
                    margins,
                    block_like,
                );
            cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
            return;
        }
        if (block_like and isTableContainerDisplay(display)) {
            const rect = try self.paintTableElement(
                element,
                decl,
                tag,
                x,
                y,
                width,
                padding,
                margins,
                block_like,
            );
            cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
            return;
        }
        if (inline_content_flow) {
            const child_height = if (!canvas_surface_present)
                try self.paintInlineFlowChildren(
                    element,
                    x + padding.left,
                    y + padding.top,
                    @max(@as(i32, 40), width - padding.left - padding.right),
                    resolveCssPropertyValue(decl, self.page, element, "text-align"),
                )
            else
                0;
            const explicit_height = resolveExplicitHeight(self, element, decl, self.page, tag, self.opts.viewport_height);
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
                    .z_index = paint_z_index,
                    .color = stroke,
                });
            }
            if (!out_of_flow_positioned) {
                cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
            }
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
        const child_containing_top = y + padding.top;
        const child_top = y + padding.top + own_content_height + child_gap;
        const child_width = @max(@as(i32, 40), width - padding.left - padding.right - child_indent);
        var child_display_list: ?DisplayList = null;
        defer if (child_display_list) |*list| list.deinit(self.allocator);
        const child_height: i32 = if (has_child_elements and !canvas_surface_present) child_height: {
            var temp_list = DisplayList{
                .layout_scale = self.list.layout_scale,
                .page_margin = self.list.page_margin,
            };
            var temp_painter = Painter{
                .allocator = self.allocator,
                .page = self.page,
                .opts = self.opts,
                .list = &temp_list,
            };
            const height = try temp_painter.paintBlockChildrenWithFloats(
                element,
                child_left,
                child_containing_top,
                child_top,
                child_width,
            );
            child_display_list = temp_list;
            break :child_height height;
        } else 0;
        const explicit_height = resolveExplicitHeight(self, element, decl, self.page, tag, self.opts.viewport_height);
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
                        .z_index = paint_z_index,
                        .color = background,
                    });
                }
            } else if (tag == .input or tag == .textarea or tag == .button or tag == .select) {
                try self.list.addFillRect(self.allocator, .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = rect.height,
                    .z_index = paint_z_index,
                    .color = .{ .r = 248, .g = 248, .b = 248 },
                });
            } else if (tag == .img) {
                try self.list.addFillRect(self.allocator, .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = rect.height,
                    .z_index = paint_z_index,
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
                .z_index = paint_z_index,
                .color = stroke,
            });
        }

        const image_command = if (tag == .img)
            try resolvedImageCommand(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)
        else
            null;
        const canvas_command = if (tag == .canvas)
            try resolvedCanvasCommand(self.allocator, element, rect.x, rect.y, rect.width, rect.height, paint_z_index)
        else
            null;
        if (image_command) |command| {
            try self.list.addImage(self.allocator, command);
        }
        if (canvas_command) |command| {
            try self.list.addCanvas(self.allocator, command);
        }

        if (label.len > 0 and shouldPaintText(tag) and image_command == null and canvas_command == null) {
            const text_area_width = @max(@as(i32, 40), rect.width - padding.horizontal() - 12);
            const text_height = @max(
                font_size + 8,
                estimateTextHeight(
                    label,
                    text_area_width,
                    font_size,
                    font_family,
                    font_weight,
                    italic,
                ) + 8,
            );
            var text_x = rect.x + padding.left + 6;
            const text_align = resolveCssPropertyValue(decl, self.page, element, "text-align");
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, text_align, &std.ascii.whitespace), "center")) {
                const measured_text_width = estimateTextWidth(label, font_size, font_family, font_weight, italic);
                text_x += @max(@as(i32, 0), @divTrunc(text_area_width - measured_text_width, 2));
            }
            try self.list.addText(self.allocator, .{
                .x = text_x,
                .y = rect.y + padding.top + 4,
                .width = text_area_width,
                .height = text_height,
                .z_index = paint_z_index,
                .font_size = font_size,
                .font_family = @constCast(font_family),
                .font_weight = font_weight,
                .italic = italic,
                .color = fg,
                .underline = shouldUnderlineText(element, decl, self.page, tag),
                .text = label,
            });
        }

        if (try resolvedLinkRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            try self.list.addLinkRegion(self.allocator, region);
        }
        if (try resolvedControlRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            try self.list.addControlRegion(self.allocator, region);
        }

        if (child_display_list) |*list| {
            try self.appendDisplayListWithOffset(list, 0, 0);
        }

        if (out_of_flow_positioned) {
            return;
        }
        if (inline_leaf) {
            cursor.advanceInlineLeaf(rect, margins, flowSpacingAfter(tag, block_like));
        } else {
            cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
        }
    }

    fn paintFlexColumnElement(
        self: *Painter,
        element: *Element,
        decl: anytype,
        tag: Element.Tag,
        x: i32,
        y: i32,
        width: i32,
        padding: EdgeSizes,
        margins: EdgeSizes,
        block_like: bool,
    ) !Bounds {
        const paint_z_index = try resolvePaintZIndex(element, decl, self.page);
        const content_width = @max(@as(i32, 40), width - padding.left - padding.right);
        const gap = resolveFlexGapPx(decl, self.page);
        const justify_content = std.mem.trim(u8, resolveCssPropertyValue(decl, self.page, element, "justify-content"), &std.ascii.whitespace);
        const align_items = std.mem.trim(u8, resolveCssPropertyValue(decl, self.page, element, "align-items"), &std.ascii.whitespace);

        var measured_children: std.ArrayList(FlexChildMeasure) = .empty;
        defer measured_children.deinit(self.allocator);

        var child_total_height: i32 = 0;
        var child_it = element.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (!isFlexRenderableChild(child)) continue;

            const measurement = try self.measureNodePaintedBox(child, content_width);
            if (measurement.width <= 0 and measurement.height <= 0) continue;

            try measured_children.append(self.allocator, .{
                .node = child,
                .width = std.math.clamp(measurement.width, @as(i32, 0), content_width),
                .height = measurement.height,
            });
            child_total_height += measurement.height;
        }

        const gap_count = @max(@as(i32, 0), @as(i32, @intCast(measured_children.items.len)) - 1);
        const total_gap_height = gap * gap_count;
        const content_height = child_total_height + total_gap_height;
        const explicit_height = resolveExplicitHeight(self, element, decl, self.page, tag, self.opts.viewport_height);
        const min_height_css = parseCssLengthPxWithContext(
            decl.getPropertyValue("min-height", self.page),
            self.opts.viewport_height,
            self.opts.viewport_height,
        ) orelse 0;
        const container_content_height = @max(content_height, @max(explicit_height - padding.vertical(), min_height_css - padding.vertical()));

        const rect: Bounds = .{
            .x = x,
            .y = y,
            .width = width,
            .height = @max(resolveMinimumHeight(self, tag, block_like, 0), padding.top + container_content_height + padding.bottom),
        };

        const bg = parseCssColor(resolveCssPropertyValue(decl, self.page, element, "background-color"));
        if (shouldPaintBox(tag)) {
            if (bg) |background| {
                if (background.a > 0 and shouldPaintBackground(tag, true)) {
                    try self.list.addFillRect(self.allocator, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                        .z_index = paint_z_index,
                        .color = background,
                    });
                }
            }
        }
        if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
            try self.list.addStrokeRect(self.allocator, .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
                .z_index = paint_z_index,
                .color = stroke,
            });
        }

        var child_y = rect.y + padding.top;
        const free_vertical_space = @max(@as(i32, 0), container_content_height - content_height);
        if (std.ascii.eqlIgnoreCase(justify_content, "center")) {
            child_y += @divTrunc(free_vertical_space, 2);
        } else if (std.ascii.eqlIgnoreCase(justify_content, "flex-end") or std.ascii.eqlIgnoreCase(justify_content, "end")) {
            child_y += free_vertical_space;
        }

        for (measured_children.items, 0..) |child_measure, index| {
            var child_x = rect.x + padding.left;
            const free_horizontal_space = @max(@as(i32, 0), content_width - child_measure.width);
            if (std.ascii.eqlIgnoreCase(align_items, "center")) {
                child_x += @divTrunc(free_horizontal_space, 2);
            } else if (std.ascii.eqlIgnoreCase(align_items, "flex-end") or std.ascii.eqlIgnoreCase(align_items, "end")) {
                child_x += free_horizontal_space;
            }

            var child_cursor = FlowCursor.init(child_x, child_y, @max(@as(i32, 40), child_measure.width));
            try self.paintNode(child_measure.node, &child_cursor);

            child_y += child_measure.height;
            if (index + 1 < measured_children.items.len) {
                child_y += gap;
            }
        }

        if (try resolvedLinkRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            try self.list.addLinkRegion(self.allocator, region);
        }
        if (try resolvedControlRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            try self.list.addControlRegion(self.allocator, region);
        }

        _ = margins;
        return rect;
    }

    fn paintFlexRowElement(
        self: *Painter,
        element: *Element,
        decl: anytype,
        tag: Element.Tag,
        x: i32,
        y: i32,
        width: i32,
        padding: EdgeSizes,
        margins: EdgeSizes,
        block_like: bool,
    ) !Bounds {
        const paint_z_index = try resolvePaintZIndex(element, decl, self.page);
        const content_width = @max(@as(i32, 40), width - padding.left - padding.right);
        const main_gap = resolveFlexRowMainGapPx(decl, self.page);
        const cross_gap = resolveFlexRowCrossGapPx(decl, self.page);
        const wrap_enabled = flexWrapEnabled(decl, self.page);
        const justify_content = std.mem.trim(u8, resolveCssPropertyValue(decl, self.page, element, "justify-content"), &std.ascii.whitespace);
        const align_items = std.mem.trim(u8, resolveCssPropertyValue(decl, self.page, element, "align-items"), &std.ascii.whitespace);

        var measured_children: std.ArrayList(FlexChildMeasure) = .empty;
        defer measured_children.deinit(self.allocator);

        var child_it = element.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (!isFlexRenderableChild(child)) continue;

            var flex_grow: f32 = 0;
            var align_self: FlexCrossAlignment = .auto;
            var flex_basis: ?i32 = null;
            if (child.is(Element)) |child_element| {
                const child_style = try self.page.window.getComputedStyle(child_element, null, self.page);
                const child_decl = child_style.asCSSStyleDeclaration();
                flex_grow = resolveFlexGrow(child_decl, self.page);
                align_self = resolveFlexCrossAlignment(resolveCssPropertyValue(child_decl, self.page, child_element, "align-self"));
                flex_basis = resolveFlexBasisPx(self, child_element, child_decl, content_width);
            }

            const measurement = try self.measureNodePaintedBox(child, flex_basis orelse content_width);
            if (measurement.width <= 0 and measurement.height <= 0) continue;

            try measured_children.append(self.allocator, .{
                .node = child,
                .width = std.math.clamp(flex_basis orelse measurement.width, @as(i32, 0), content_width),
                .height = measurement.height,
                .flex_grow = flex_grow,
                .align_self = align_self,
            });
        }

        var lines: std.ArrayList(FlexLineMeasure) = .empty;
        defer lines.deinit(self.allocator);

        var line_start: usize = 0;
        var line_width: i32 = 0;
        var line_height: i32 = 0;
        var line_count: usize = 0;
        for (measured_children.items, 0..) |child_measure, index| {
            const next_width = if (line_count == 0)
                child_measure.width
            else
                line_width + main_gap + child_measure.width;

            if (wrap_enabled and line_count > 0 and next_width > content_width) {
                try lines.append(self.allocator, .{
                    .start_index = line_start,
                    .end_index = index,
                    .width = line_width,
                    .height = line_height,
                });
                line_start = index;
                line_width = child_measure.width;
                line_height = child_measure.height;
                line_count = 1;
                continue;
            }

            line_width = next_width;
            line_height = @max(line_height, child_measure.height);
            line_count += 1;
        }

        if (line_count > 0) {
            try lines.append(self.allocator, .{
                .start_index = line_start,
                .end_index = measured_children.items.len,
                .width = line_width,
                .height = line_height,
            });
        }

        var content_height: i32 = 0;
        for (lines.items, 0..) |line, index| {
            content_height += line.height;
            if (index + 1 < lines.items.len) {
                content_height += cross_gap;
            }
        }

        const explicit_height = resolveExplicitHeight(self, element, decl, self.page, tag, self.opts.viewport_height);
        const min_height_css = parseCssLengthPxWithContext(
            decl.getPropertyValue("min-height", self.page),
            self.opts.viewport_height,
            self.opts.viewport_height,
        ) orelse 0;
        const container_content_height = @max(content_height, @max(explicit_height - padding.vertical(), min_height_css - padding.vertical()));

        const rect: Bounds = .{
            .x = x,
            .y = y,
            .width = width,
            .height = @max(resolveMinimumHeight(self, tag, block_like, 0), padding.top + container_content_height + padding.bottom),
        };

        const bg = parseCssColor(resolveCssPropertyValue(decl, self.page, element, "background-color"));
        if (shouldPaintBox(tag)) {
            if (bg) |background| {
                if (background.a > 0 and shouldPaintBackground(tag, true)) {
                    try self.list.addFillRect(self.allocator, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                        .z_index = paint_z_index,
                        .color = background,
                    });
                }
            }
        }
        if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
            try self.list.addStrokeRect(self.allocator, .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
                .z_index = paint_z_index,
                .color = stroke,
            });
        }

        var child_y = rect.y + padding.top;
        for (lines.items, 0..) |line, line_index| {
            const item_count: i32 = @intCast(line.end_index - line.start_index);
            const free_horizontal_space = @max(@as(i32, 0), content_width - line.width);
            var child_x = rect.x + padding.left;
            var gap = main_gap;
            var total_flex_grow: f32 = 0;

            if (std.ascii.eqlIgnoreCase(justify_content, "center")) {
                child_x += @divTrunc(free_horizontal_space, 2);
            } else if (std.ascii.eqlIgnoreCase(justify_content, "flex-end") or std.ascii.eqlIgnoreCase(justify_content, "end")) {
                child_x += free_horizontal_space;
            } else if (std.ascii.eqlIgnoreCase(justify_content, "space-between") and item_count > 1) {
                gap += @divTrunc(free_horizontal_space, item_count - 1);
            } else if (std.ascii.eqlIgnoreCase(justify_content, "space-around") and item_count > 0) {
                const extra = @divTrunc(free_horizontal_space, item_count);
                child_x += @divTrunc(extra, 2);
                gap += extra;
            } else if (std.ascii.eqlIgnoreCase(justify_content, "space-evenly") and item_count > 0) {
                const extra = @divTrunc(free_horizontal_space, item_count + 1);
                child_x += extra;
                gap += extra;
            }

            var grow_index = line.start_index;
            while (grow_index < line.end_index) : (grow_index += 1) {
                total_flex_grow += measured_children.items[grow_index].flex_grow;
            }

            var remaining_grow_space: i32 = free_horizontal_space;
            var remaining_flex_grow = total_flex_grow;

            var child_index = line.start_index;
            while (child_index < line.end_index) : (child_index += 1) {
                const child_measure = measured_children.items[child_index];
                var child_width = child_measure.width;
                if (total_flex_grow > 0 and free_horizontal_space > 0 and child_measure.flex_grow > 0) {
                    const extra_width = if (child_index + 1 == line.end_index or remaining_flex_grow <= child_measure.flex_grow)
                        remaining_grow_space
                    else
                        @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(free_horizontal_space)) *
                            (@as(f64, @floatCast(child_measure.flex_grow)) / @as(f64, @floatCast(total_flex_grow))))));
                    child_width += extra_width;
                    remaining_grow_space -= extra_width;
                    remaining_flex_grow -= child_measure.flex_grow;
                }
                var item_y = child_y;
                const free_vertical_space = @max(@as(i32, 0), line.height - child_measure.height);
                const item_align = effectiveFlexCrossAlignment(align_items, child_measure.align_self);
                if (item_align == .center) {
                    item_y += @divTrunc(free_vertical_space, 2);
                } else if (item_align == .end) {
                    item_y += free_vertical_space;
                }

                {
                    const previous_forced_node = self.forced_item_node;
                    const previous_forced_width = self.forced_item_width;
                    self.forced_item_node = child_measure.node;
                    self.forced_item_width = child_width;

                    var child_cursor = FlowCursor.init(child_x, item_y, @max(@as(i32, 40), child_width));
                    try self.paintNode(child_measure.node, &child_cursor);

                    self.forced_item_node = previous_forced_node;
                    self.forced_item_width = previous_forced_width;
                }
                child_x += child_width;
                if (child_index + 1 < line.end_index) {
                    child_x += gap;
                }
            }

            child_y += line.height;
            if (line_index + 1 < lines.items.len) {
                child_y += cross_gap;
            }
        }

        if (try resolvedLinkRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            try self.list.addLinkRegion(self.allocator, region);
        }
        if (try resolvedControlRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            try self.list.addControlRegion(self.allocator, region);
        }

        _ = margins;
        return rect;
    }

    fn paintBlockChildrenWithFloats(
        self: *Painter,
        element: *Element,
        child_left: i32,
        child_containing_top: i32,
        child_top: i32,
        child_width: i32,
    ) !i32 {
        var child_cursor = FlowCursor.init(child_left, child_top, child_width);
        var out_of_flow_children: std.ArrayList(*Node) = .{};
        defer out_of_flow_children.deinit(self.allocator);
        var float_left_x = child_left;
        var float_right_x = child_left + child_width;
        var float_row_y = child_top;
        var float_row_bottom = child_top;
        var float_active = false;

        var it = element.asNode().childrenIterator();
        while (it.next()) |child| {
            if (try isOutOfFlowNode(child, self.page)) {
                try out_of_flow_children.append(self.allocator, child);
                continue;
            }
            if (child.is(Element)) |child_el| {
                const float_mode = try resolveFloatMode(child_el, self.page);
                if (float_mode != .none) {
                    const float_width = try self.resolveFloatPaintWidth(child_el, child_width);
                    if (float_width > 0) {
                        if (!float_active) {
                            float_left_x = child_left;
                            float_right_x = child_left + child_width;
                            float_row_y = child_cursor.cursor_y;
                            float_row_bottom = child_cursor.cursor_y;
                            float_active = true;
                        }

                        if (float_left_x + float_width > float_right_x) {
                            float_row_y = float_row_bottom + 4;
                            float_row_bottom = float_row_y;
                            float_left_x = child_left;
                            float_right_x = child_left + child_width;
                        }

                        const item_x = switch (float_mode) {
                            .left => float_left_x,
                            .right => float_right_x - float_width,
                            .none => unreachable,
                        };

                        const previous_forced_node = self.forced_item_node;
                        const previous_forced_width = self.forced_item_width;
                        self.forced_item_node = child;
                        self.forced_item_width = float_width;

                        var float_cursor = FlowCursor.init(item_x, float_row_y, @max(@as(i32, 40), float_width));
                        try self.paintNode(child, &float_cursor);

                        self.forced_item_node = previous_forced_node;
                        self.forced_item_width = previous_forced_width;

                        const float_height = @max(@as(i32, 1), float_cursor.consumedHeightSince(float_row_y));
                        switch (float_mode) {
                            .left => float_left_x = item_x + float_width + 4,
                            .right => float_right_x = item_x - 4,
                            .none => {},
                        }
                        float_row_bottom = @max(float_row_bottom, float_row_y + float_height);
                        continue;
                    }
                }
            }

            if (float_active) {
                child_cursor.cursor_y = @max(child_cursor.cursor_y, float_row_bottom);
                child_cursor.cursor_x = child_cursor.left;
                child_cursor.line_height = 0;
                float_active = false;
            }

            try self.paintNode(child, &child_cursor);
        }

        if (float_active) {
            child_cursor.cursor_y = @max(child_cursor.cursor_y, float_row_bottom);
            child_cursor.cursor_x = child_cursor.left;
            child_cursor.line_height = 0;
        }

        if (out_of_flow_children.items.len > 0) {
            var overlay_cursor = FlowCursor.init(child_left, child_containing_top, child_width);
            for (out_of_flow_children.items) |child| {
                try self.paintNode(child, &overlay_cursor);
            }
        }

        return child_cursor.consumedHeightSince(child_top);
    }

    fn resolveFloatPaintWidth(self: *Painter, element: *Element, available_width: i32) !i32 {
        const style = try self.page.window.getComputedStyle(element, null, self.page);
        const decl = style.asCSSStyleDeclaration();
        const display = resolvedDisplayValue(decl, self.page, element);
        const explicit_width = resolveExplicitWidth(self, element, decl, self.page, element.getTag(), available_width);
        if (explicit_width > 0) {
            return std.math.clamp(explicit_width, 40, available_width);
        }

        const trimmed_display = std.mem.trim(u8, display, &std.ascii.whitespace);
        if (!isInlineDisplay(trimmed_display) and !std.ascii.eqlIgnoreCase(trimmed_display, "inline-block")) {
            return 0;
        }

        const measured = try self.measureNodePaintedBox(element.asNode(), available_width);
        if (measured.width <= 0) {
            return 0;
        }
        return std.math.clamp(measured.width, 40, available_width);
    }

    fn paintTableElement(
        self: *Painter,
        element: *Element,
        decl: anytype,
        tag: Element.Tag,
        x: i32,
        y: i32,
        width: i32,
        padding: EdgeSizes,
        margins: EdgeSizes,
        block_like: bool,
    ) !Bounds {
        var rows = std.ArrayList(*Element).empty;
        defer rows.deinit(self.allocator);
        try collectTableRows(self.allocator, element, &rows);

        if (rows.items.len == 0) {
            const height = resolveMinimumHeight(self, tag, block_like, 0);
            return .{ .x = x, .y = y, .width = width, .height = height };
        }

        var column_count: usize = 0;
        for (rows.items) |row| {
            var cells = try collectTableCells(self.allocator, row);
            defer cells.deinit(self.allocator);
            column_count = @max(column_count, cells.items.len);
        }
        if (column_count == 0) {
            const height = resolveMinimumHeight(self, tag, block_like, 0);
            return .{ .x = x, .y = y, .width = width, .height = height };
        }

        const cell_spacing = tableCellSpacing(element);
        const content_x = x + padding.left;
        const content_y = y + padding.top;
        const content_width = @max(@as(i32, 40), width - padding.left - padding.right);
        const total_gap = cell_spacing * @as(i32, @intCast(@max(@as(usize, 0), column_count - 1)));
        const columns_available = @max(@as(i32, 40), content_width - total_gap);

        var column_widths = try self.allocator.alloc(i32, column_count);
        defer self.allocator.free(column_widths);
        @memset(column_widths, 0);

        for (rows.items) |row| {
            var cells = try collectTableCells(self.allocator, row);
            defer cells.deinit(self.allocator);
            for (cells.items, 0..) |cell, col_index| {
                const cell_style = try self.page.window.getComputedStyle(cell, null, self.page);
                const cell_decl = cell_style.asCSSStyleDeclaration();
                const explicit_width = resolveExplicitWidth(self, cell, cell_decl, self.page, cell.getTag(), columns_available);
                if (explicit_width > column_widths[col_index]) {
                    column_widths[col_index] = explicit_width;
                }
            }
        }

        var specified_width_sum: i32 = 0;
        var unspecified_columns: usize = 0;
        for (column_widths) |col_width| {
            if (col_width > 0) {
                specified_width_sum += col_width;
            } else {
                unspecified_columns += 1;
            }
        }

        const fallback_width = @max(@as(i32, 60), @divTrunc(columns_available, @as(i32, @intCast(column_count))));
        const distributed_width = if (unspecified_columns > 0 and columns_available > specified_width_sum)
            @max(@as(i32, 60), @divTrunc(columns_available - specified_width_sum, @as(i32, @intCast(unspecified_columns))))
        else
            fallback_width;
        for (column_widths) |*col_width| {
            if (col_width.* <= 0) {
                col_width.* = distributed_width;
            }
        }

        var row_y = content_y;
        for (rows.items, 0..) |row, row_index| {
            var cells = try collectTableCells(self.allocator, row);
            defer cells.deinit(self.allocator);

            var row_height: i32 = 0;
            var cell_x = content_x;
            for (column_widths, 0..) |cell_width, col_index| {
                if (col_index < cells.items.len) {
                    const cell = cells.items[col_index];
                    const previous_forced_node = self.forced_item_node;
                    const previous_forced_width = self.forced_item_width;
                    self.forced_item_node = cell.asNode();
                    self.forced_item_width = cell_width;

                    var cell_cursor = FlowCursor.init(cell_x, row_y, @max(@as(i32, 40), cell_width));
                    try self.paintNode(cell.asNode(), &cell_cursor);

                    self.forced_item_node = previous_forced_node;
                    self.forced_item_width = previous_forced_width;

                    row_height = @max(row_height, cell_cursor.consumedHeightSince(row_y));
                }

                cell_x += cell_width;
                if (col_index + 1 < column_widths.len) {
                    cell_x += cell_spacing;
                }
            }

            row_y += @max(row_height, self.opts.min_height);
            if (row_index + 1 < rows.items.len) {
                row_y += cell_spacing;
            }
        }

        const rect = Bounds{
            .x = x,
            .y = y,
            .width = width,
            .height = @max(resolveMinimumHeight(self, tag, block_like, 0), padding.top + (row_y - content_y) + padding.bottom),
        };

        const paint_z_index = try resolvePaintZIndex(element, decl, self.page);
        if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
            try self.list.addStrokeRect(self.allocator, .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
                .z_index = paint_z_index,
                .color = stroke,
            });
        }

        _ = margins;
        return rect;
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
                const child_display = resolvedDisplayValue(child_decl, self.page, child_el);
                if (!isInlineFlowDisplayForElement(child_el, child_display)) {
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
        const style = try self.page.window.getComputedStyle(element, null, self.page);
        const paint_z_index = try resolvePaintZIndex(element, style.asCSSStyleDeclaration(), self.page);
        for (fragments.items) |fragment| {
            try self.list.addLinkRegion(self.allocator, .{
                .x = fragment.x,
                .y = fragment.y,
                .width = fragment.width,
                .height = fragment.height,
                .z_index = paint_z_index,
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
        .img, .input, .textarea, .button, .select, .iframe => true,
        else => false,
    };
}

fn canvasSurfaceForElement(element: *Element) ?*const @import("../browser/webapi/canvas/CanvasSurface.zig") {
    const canvas = element.is(Element.Html.Canvas) orelse return null;
    return canvas.getSurface();
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
    z_index: i32,
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
        .z_index = z_index,
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
    z_index: i32,
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
        .z_index = z_index,
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
        .canvas => |canvas| if (canvas.width > 0 and canvas.height > 0) .{
            .x = canvas.x,
            .y = canvas.y,
            .width = canvas.width,
            .height = canvas.height,
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

fn commandZIndexForTest(command: Command) i32 {
    return switch (command) {
        .fill_rect => |rect| rect.z_index,
        .stroke_rect => |rect| rect.z_index,
        .text => |text| text.z_index,
        .image => |image| image.z_index,
        .canvas => |canvas| canvas.z_index,
    };
}

fn resolvedImageCommand(
    element: *Element,
    page: *Page,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_index: i32,
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
        .z_index = z_index,
        .url = @constCast(resolved),
        .alt = @constCast(alt),
        .request_include_credentials = include_credentials,
        .request_cookie_value = if (include_credentials) request_context.cookie_value else &.{},
        .request_referer_value = request_context.referer_value,
        .request_authorization_value = if (include_credentials) request_context.authorization_value else &.{},
    };
}

fn resolvedCanvasCommand(
    allocator: std.mem.Allocator,
    element: *Element,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_index: i32,
) !?CanvasCommand {
    const canvas = element.is(Element.Html.Canvas) orelse return null;
    const surface = canvas.getSurface() orelse return null;
    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .z_index = z_index,
        .pixel_width = surface.width,
        .pixel_height = surface.height,
        .pixels = try surface.copyPixels(allocator),
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

fn resolvedDisplayValue(
    decl: anytype,
    page: *Page,
    element: *Element,
) []const u8 {
    const display = resolveCssPropertyValue(decl, page, element, "display");
    if (std.mem.trim(u8, display, &std.ascii.whitespace).len > 0) {
        return display;
    }
    return defaultDisplayForTag(element.getTag());
}

fn defaultDisplayForTag(tag: Element.Tag) []const u8 {
    return switch (tag) {
        .span, .anchor, .strong, .em, .code, .label => "inline",
        .img, .input, .button, .select, .textarea, .canvas => "inline-block",
        .table => "table",
        .caption => "table-caption",
        .tr => "table-row",
        .td, .th => "table-cell",
        .tbody => "table-row-group",
        .thead => "table-header-group",
        .tfoot => "table-footer-group",
        else => "block",
    };
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

fn isInlineFlowDisplayForElement(element: *Element, display: []const u8) bool {
    if (isInlineDisplay(display)) return true;

    const trimmed = std.mem.trim(u8, display, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "block")) {
        if (inlineStylePropertyValue(element, "display") == null) {
            return isInlineDisplay(defaultDisplayForTag(element.getTag()));
        }
    }
    return false;
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
            const child_display = resolvedDisplayValue(child_style.asCSSStyleDeclaration(), page, child_el);
            if (!isInlineFlowDisplayForElement(child_el, child_display)) {
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

fn isFlexDisplay(display: []const u8) bool {
    const trimmed = std.mem.trim(u8, display, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(trimmed, "flex") or std.ascii.eqlIgnoreCase(trimmed, "inline-flex");
}

fn isTableContainerDisplay(display: []const u8) bool {
    const trimmed = std.mem.trim(u8, display, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(trimmed, "table") or std.ascii.eqlIgnoreCase(trimmed, "inline-table");
}

fn isTableRowDisplay(display: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, display, &std.ascii.whitespace), "table-row");
}

fn isTableCellDisplay(display: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, display, &std.ascii.whitespace), "table-cell");
}

fn isOutOfFlowPositioned(position: []const u8) bool {
    const trimmed = std.mem.trim(u8, position, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(trimmed, "absolute") or std.ascii.eqlIgnoreCase(trimmed, "fixed");
}

fn resolveFloatMode(element: *Element, page: *Page) !FloatMode {
    const style = try page.window.getComputedStyle(element, null, page);
    const decl = style.asCSSStyleDeclaration();
    if (isOutOfFlowPositioned(resolveCssPropertyValue(decl, page, element, "position"))) {
        return .none;
    }

    const float_value = std.mem.trim(u8, resolveCssPropertyValue(decl, page, element, "float"), &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(float_value, "left")) return .left;
    if (std.ascii.eqlIgnoreCase(float_value, "right")) return .right;
    return .none;
}

fn tableCellSpacing(element: *Element) i32 {
    if (element.getAttributeSafe(comptime .wrap("cellspacing"))) |raw| {
        return parseIntegerAttributePx(raw);
    }
    return 0;
}

fn parseIntegerAttributePx(raw: []const u8) i32 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(i32, trimmed, 10) catch 0;
}

fn collectTableRows(
    allocator: std.mem.Allocator,
    table: *Element,
    rows: *std.ArrayList(*Element),
) !void {
    var it = table.asNode().childrenIterator();
    while (it.next()) |child| {
        const child_el = child.is(Element) orelse continue;
        switch (child_el.getTag()) {
            .tr => try rows.append(allocator, child_el),
            .tbody, .thead, .tfoot => {
                var row_it = child_el.asNode().childrenIterator();
                while (row_it.next()) |row_child| {
                    const row_el = row_child.is(Element) orelse continue;
                    if (row_el.getTag() == .tr) {
                        try rows.append(allocator, row_el);
                    }
                }
            },
            else => {},
        }
    }
}

fn collectTableCells(
    allocator: std.mem.Allocator,
    row: *Element,
) !std.ArrayList(*Element) {
    var cells = std.ArrayList(*Element).empty;
    var it = row.asNode().childrenIterator();
    while (it.next()) |child| {
        const child_el = child.is(Element) orelse continue;
        switch (child_el.getTag()) {
            .td, .th => try cells.append(allocator, child_el),
            else => {},
        }
    }
    return cells;
}

fn isOutOfFlowNode(node: *Node, page: *Page) !bool {
    const element = node.is(Element) orelse return false;
    const style = try page.window.getComputedStyle(element, null, page);
    const decl = style.asCSSStyleDeclaration();
    return isOutOfFlowPositioned(resolveCssPropertyValue(decl, page, element, "position"));
}

fn isFixedPosition(position: []const u8) bool {
    const trimmed = std.mem.trim(u8, position, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(trimmed, "fixed");
}

fn positioningContextLeft(self: *const Painter, element: *Element, cursor: FlowCursor, position: []const u8) i32 {
    if (isFixedPosition(position)) {
        _ = self;
        return 0;
    }
    const parent = element.asNode().parentElement() orelse return 0;
    return switch (parent.getTag()) {
        .html, .body => 0,
        else => cursor.left,
    };
}

fn positioningContextTop(element: *Element, cursor: FlowCursor, position: []const u8) i32 {
    if (isFixedPosition(position)) {
        return 0;
    }
    const parent = element.asNode().parentElement() orelse return 0;
    return switch (parent.getTag()) {
        .html, .body => 0,
        else => cursor.cursor_y,
    };
}

fn positioningContextWidth(self: *const Painter, element: *Element, cursor: FlowCursor, position: []const u8) i32 {
    if (isFixedPosition(position)) {
        return self.opts.viewport_width;
    }
    const parent = element.asNode().parentElement() orelse return self.opts.viewport_width;
    return switch (parent.getTag()) {
        .html, .body => self.opts.viewport_width,
        else => cursor.width,
    };
}

fn positioningContextHeight(self: *const Painter, element: *Element, context_top: i32, position: []const u8) i32 {
    if (isFixedPosition(position)) {
        return self.opts.viewport_height;
    }
    const parent = element.asNode().parentElement() orelse return self.opts.viewport_height;
    return switch (parent.getTag()) {
        .html, .body => self.opts.viewport_height,
        else => @max(@as(i32, 0), self.opts.viewport_height - context_top),
    };
}

fn resolveAvailableWidthForElement(
    self: *const Painter,
    element: *Element,
    cursor: FlowCursor,
    decl: anytype,
    margins: EdgeSizes,
    out_of_flow_positioned: bool,
) i32 {
    const context_width = if (out_of_flow_positioned)
        positioningContextWidth(self, element, cursor, resolveCssPropertyValue(decl, self.page, element, "position"))
    else
        cursor.width;
    const available_width = @max(@as(i32, 80), context_width - margins.horizontal());
    if (!out_of_flow_positioned) return available_width;

    const left = parseCssLengthPxWithContext(decl.getPropertyValue("left", self.page), context_width, self.opts.viewport_width);
    const right = parseCssLengthPxWithContext(decl.getPropertyValue("right", self.page), context_width, self.opts.viewport_width);
    if (left != null and right != null and decl.getPropertyValue("width", self.page).len == 0) {
        return @max(@as(i32, 80), context_width - left.? - right.? - margins.horizontal());
    }
    return available_width;
}

fn resolveOutOfFlowPosition(
    self: *const Painter,
    element: *Element,
    cursor: FlowCursor,
    decl: anytype,
    margins: EdgeSizes,
    width: i32,
) FlowCursor.Position {
    const position = resolveCssPropertyValue(decl, self.page, element, "position");
    const context_left = positioningContextLeft(self, element, cursor, position);
    const context_top = positioningContextTop(element, cursor, position);
    const context_width = positioningContextWidth(self, element, cursor, position);
    const context_height = positioningContextHeight(self, element, context_top, position);
    const left = parseCssLengthPxWithContext(decl.getPropertyValue("left", self.page), context_width, self.opts.viewport_width);
    const right = parseCssLengthPxWithContext(decl.getPropertyValue("right", self.page), context_width, self.opts.viewport_width);
    const top = parseCssLengthPxWithContext(decl.getPropertyValue("top", self.page), context_height, self.opts.viewport_height);
    const bottom = parseCssLengthPxWithContext(decl.getPropertyValue("bottom", self.page), context_height, self.opts.viewport_height);

    const x = if (left) |value|
        context_left + value + margins.left
    else if (right) |value|
        context_left + @max(@as(i32, 0), context_width - value - width - margins.right)
    else
        context_left + margins.left;

    const y = if (top) |value|
        context_top + value + margins.top
    else if (bottom) |value|
        context_top + @max(@as(i32, 0), context_height - value - margins.bottom)
    else
        context_top + margins.top;

    return .{
        .x = x,
        .y = y,
    };
}

fn resolvePaintZIndex(element: *Element, decl: anytype, page: *Page) !i32 {
    if (resolveElementZIndex(element, decl, page)) |z_index| {
        return z_index;
    }

    var parent = element.asNode().parentElement();
    while (parent) |candidate| {
        const style = try page.window.getComputedStyle(candidate, null, page);
        if (resolveElementZIndex(candidate, style.asCSSStyleDeclaration(), page)) |z_index| {
            return z_index;
        }
        parent = candidate.asNode().parentElement();
    }

    return 0;
}

fn resolveElementZIndex(element: *Element, decl: anytype, page: *Page) ?i32 {
    const position = resolveCssPropertyValue(decl, page, element, "position");
    if (!isStackingPositioned(position)) {
        return null;
    }

    const raw = std.mem.trim(u8, decl.getPropertyValue("z-index", page), &std.ascii.whitespace);
    if (raw.len == 0 or std.ascii.eqlIgnoreCase(raw, "auto")) {
        return null;
    }
    return parseCssIntegerValue(raw);
}

fn isStackingPositioned(position: []const u8) bool {
    const trimmed = std.mem.trim(u8, position, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    return !std.ascii.eqlIgnoreCase(trimmed, "static");
}

fn isFlexColumnContainer(display: []const u8, decl: anytype, page: *Page) bool {
    if (!isFlexDisplay(display)) return false;
    const direction = std.mem.trim(u8, decl.getPropertyValue("flex-direction", page), &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(direction, "column") or
        std.ascii.eqlIgnoreCase(direction, "column-reverse");
}

fn isFlexRowContainer(display: []const u8, decl: anytype, page: *Page) bool {
    if (!isFlexDisplay(display)) return false;
    const direction = std.mem.trim(u8, decl.getPropertyValue("flex-direction", page), &std.ascii.whitespace);
    return direction.len == 0 or
        std.ascii.eqlIgnoreCase(direction, "row") or
        std.ascii.eqlIgnoreCase(direction, "row-reverse");
}

fn isFlexRenderableChild(node: *Node) bool {
    if (node.is(Node.CData.Text)) |text| {
        return std.mem.trim(u8, text.getWholeText(), &std.ascii.whitespace).len > 0;
    }
    if (node.is(Element)) |element| {
        return switch (element.getTag()) {
            .script, .style, .template, .head, .meta, .link, .title => false,
            else => true,
        };
    }
    return false;
}

fn resolveFlexGapPx(decl: anytype, page: *Page) i32 {
    const row_gap = parseCssLengthPxWithContext(decl.getPropertyValue("row-gap", page), 0, 0);
    if (row_gap) |value| return value;
    return parseCssLengthPxWithContext(decl.getPropertyValue("gap", page), 0, 0) orelse 0;
}

fn resolveFlexRowMainGapPx(decl: anytype, page: *Page) i32 {
    const column_gap = parseCssLengthPxWithContext(decl.getPropertyValue("column-gap", page), 0, 0);
    if (column_gap) |value| return value;
    return parseCssLengthPxWithContext(decl.getPropertyValue("gap", page), 0, 0) orelse 0;
}

fn resolveFlexRowCrossGapPx(decl: anytype, page: *Page) i32 {
    return resolveFlexGapPx(decl, page);
}

fn flexWrapEnabled(decl: anytype, page: *Page) bool {
    const wrap = std.mem.trim(u8, decl.getPropertyValue("flex-wrap", page), &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(wrap, "wrap") or std.ascii.eqlIgnoreCase(wrap, "wrap-reverse");
}

fn resolveFlexGrow(decl: anytype, page: *Page) f32 {
    if (parseCssFloatValue(decl.getPropertyValue("flex-grow", page))) |value| {
        return @max(@as(f32, 0), value);
    }

    const shorthand = std.mem.trim(u8, decl.getPropertyValue("flex", page), &std.ascii.whitespace);
    if (shorthand.len == 0) return 0;
    if (std.ascii.eqlIgnoreCase(shorthand, "none")) return 0;
    if (std.ascii.eqlIgnoreCase(shorthand, "auto")) return 1;

    var it = std.mem.tokenizeAny(u8, shorthand, &std.ascii.whitespace);
    const first = it.next() orelse return 0;
    return @max(@as(f32, 0), parseCssFloatValue(first) orelse 0);
}

fn resolveFlexBasisPx(self: *const Painter, element: *Element, decl: anytype, available_width: i32) ?i32 {
    if (parseCssLengthPxWithContext(decl.getPropertyValue("flex-basis", self.page), available_width, self.opts.viewport_width)) |value| {
        return value;
    }

    const shorthand = std.mem.trim(u8, decl.getPropertyValue("flex", self.page), &std.ascii.whitespace);
    if (shorthand.len != 0 and !std.ascii.eqlIgnoreCase(shorthand, "none") and !std.ascii.eqlIgnoreCase(shorthand, "auto")) {
        var parts = std.mem.tokenizeAny(u8, shorthand, &std.ascii.whitespace);
        _ = parts.next();
        if (parts.next()) |maybe_shrink| {
            _ = maybe_shrink;
            if (parts.next()) |basis_token| {
                if (parseCssLengthPxWithContext(basis_token, available_width, self.opts.viewport_width)) |value| {
                    return value;
                }
            }
        }
    }

    return resolveExplicitWidth(self, element, decl, self.page, element.getTag(), available_width);
}

fn resolveFlexCrossAlignment(value: []const u8) FlexCrossAlignment {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(trimmed, "center")) return .center;
    if (std.ascii.eqlIgnoreCase(trimmed, "flex-end") or std.ascii.eqlIgnoreCase(trimmed, "end")) return .end;
    if (std.ascii.eqlIgnoreCase(trimmed, "flex-start") or std.ascii.eqlIgnoreCase(trimmed, "start")) return .start;
    return .auto;
}

fn effectiveFlexCrossAlignment(container_align_items: []const u8, align_self: FlexCrossAlignment) FlexCrossAlignment {
    if (align_self != .auto) return align_self;
    return resolveFlexCrossAlignment(container_align_items);
}

fn resolveAutoMarginAlignedX(cursor: FlowCursor, decl: anytype, page: *Page, width: i32, margins: EdgeSizes, default_x: i32) i32 {
    const margin_left = decl.getPropertyValue("margin-left", page);
    const margin_right = decl.getPropertyValue("margin-right", page);
    const margin_shorthand = decl.getPropertyValue("margin", page);
    const auto_left = isCssAuto(margin_left) or (margin_left.len == 0 and edgeShorthandContainsAuto(margin_shorthand, .left));
    const auto_right = isCssAuto(margin_right) or (margin_right.len == 0 and edgeShorthandContainsAuto(margin_shorthand, .right));
    const free_space = @max(@as(i32, 0), cursor.width - width - margins.left - margins.right);

    if (auto_left and auto_right) {
        return cursor.left + margins.left + @divTrunc(free_space, 2);
    }
    if (auto_left) {
        return cursor.left + margins.left + free_space;
    }
    return default_x;
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
    const explicit_width = resolveExplicitWidth(self, element, decl, page, tag, available_width);
    const min_width = parseCssLengthPxWithContext(
        decl.getPropertyValue("min-width", page),
        available_width,
        self.opts.viewport_width,
    ) orelse 0;
    const max_width = parseCssLengthPxWithContext(
        decl.getPropertyValue("max-width", page),
        available_width,
        self.opts.viewport_width,
    );
    if (self.forced_item_node == element.asNode() and self.forced_item_width > 0) {
        var forced = std.math.clamp(self.forced_item_width, 60, available_width);
        forced = @max(forced, min_width);
        if (max_width) |limit| forced = @min(forced, limit);
        return forced;
    }

    if (block_like) {
        var resolved = std.math.clamp(
            if (explicit_width > 0) explicit_width else available_width,
            80,
            available_width,
        );
        resolved = @max(resolved, min_width);
        if (max_width) |limit| resolved = @min(resolved, limit);
        return resolved;
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
    preferred = @max(preferred, min_width);
    if (max_width) |limit| preferred = @min(preferred, limit);
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
    _ = self;
    _ = element;
    _ = decl;
    var height: i32 = 0;

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

fn resolveExplicitWidth(self: *const Painter, element: *Element, decl: anytype, page: *Page, tag: Element.Tag, available_width: i32) i32 {
    if (parseCssLengthPxWithContext(decl.getPropertyValue("width", page), available_width, self.opts.viewport_width)) |width| {
        return width;
    }
    if (tag == .canvas) {
        if (element.is(Element.Html.Canvas)) |canvas| {
            return @intCast(canvas.getWidth());
        }
    }
    if (tag == .img or tag == .iframe or tag == .canvas or tag == .input) {
        if (element.getAttributeSafe(comptime .wrap("width"))) |raw| {
            return parseCssLengthPxWithContext(raw, available_width, self.opts.viewport_width) orelse 0;
        }
    }
    return 0;
}

fn resolveExplicitHeight(self: *const Painter, element: *Element, decl: anytype, page: *Page, tag: Element.Tag, available_height: i32) i32 {
    const raw_height = decl.getPropertyValue("height", page);
    const height_basis = if (std.mem.indexOfScalar(u8, raw_height, '%') != null)
        resolveAncestorExplicitHeight(self, element, page, available_height)
    else
        available_height;
    if (parseCssLengthPxWithContext(raw_height, height_basis, self.opts.viewport_height)) |height| {
        return height;
    }
    if (tag == .canvas) {
        if (element.is(Element.Html.Canvas)) |canvas| {
            return @intCast(canvas.getHeight());
        }
    }
    if (tag == .img or tag == .iframe or tag == .canvas or tag == .textarea) {
        if (element.getAttributeSafe(comptime .wrap("height"))) |raw| {
            return parseCssLengthPxWithContext(raw, available_height, self.opts.viewport_height) orelse 0;
        }
    }
    return 0;
}

fn resolveAncestorExplicitHeight(self: *const Painter, element: *Element, page: *Page, fallback_height: i32) i32 {
    var parent = element.asNode().parentElement();
    while (parent) |candidate| {
        const style = page.window.getComputedStyle(candidate, null, page) catch break;
        const decl = style.asCSSStyleDeclaration();
        const raw_height = decl.getPropertyValue("height", page);
        if (std.mem.trim(u8, raw_height, &std.ascii.whitespace).len > 0 and std.mem.indexOfScalar(u8, raw_height, '%') == null) {
            if (parseCssLengthPxWithContext(raw_height, fallback_height, self.opts.viewport_height)) |height| {
                if (height > 0) return height;
            }
        }
        if (candidate.getAttributeSafe(comptime .wrap("height"))) |attr_height| {
            if (parseCssLengthPxWithContext(attr_height, fallback_height, self.opts.viewport_height)) |height| {
                if (height > 0) return height;
            }
        }
        parent = candidate.asNode().parentElement();
    }
    return fallback_height;
}

fn resolveMinimumHeight(self: *const Painter, tag: Element.Tag, block_like: bool, own_content_height: i32) i32 {
    if (tag == .html or tag == .body) {
        return @max(own_content_height, self.opts.viewport_height);
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
    _ = tag;
    _ = has_child_elements;
    return true;
}

fn resolveChildIndent(tag: Element.Tag, has_child_elements: bool) i32 {
    if (!has_child_elements) {
        return 0;
    }
    return switch (tag) {
        .html, .body, .table, .tr, .td, .th, .tbody, .thead, .tfoot, .caption => 0,
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

fn displayListBounds(list: *const DisplayList) ?Bounds {
    var min_x: i32 = 0;
    var min_y: i32 = 0;
    var max_x: i32 = 0;
    var max_y: i32 = 0;
    var saw_any = false;

    for (list.commands.items) |command| {
        const bounds = switch (command) {
            .fill_rect => |rect| Bounds{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height },
            .stroke_rect => |rect| Bounds{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height },
            .text => |text| Bounds{ .x = text.x, .y = text.y, .width = text.width, .height = text.height },
            .image => |image| Bounds{ .x = image.x, .y = image.y, .width = image.width, .height = image.height },
            .canvas => |canvas| Bounds{ .x = canvas.x, .y = canvas.y, .width = canvas.width, .height = canvas.height },
        };

        if (!saw_any) {
            min_x = bounds.x;
            min_y = bounds.y;
            max_x = bounds.x + bounds.width;
            max_y = bounds.y + bounds.height;
            saw_any = true;
            continue;
        }

        min_x = @min(min_x, bounds.x);
        min_y = @min(min_y, bounds.y);
        max_x = @max(max_x, bounds.x + bounds.width);
        max_y = @max(max_y, bounds.y + bounds.height);
    }

    if (!saw_any) return null;
    return .{
        .x = min_x,
        .y = min_y,
        .width = @max(@as(i32, 0), max_x - min_x),
        .height = @max(@as(i32, 0), max_y - min_y),
    };
}

fn isCssAuto(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, &std.ascii.whitespace), "auto");
}

const EdgeSide = enum {
    top,
    right,
    bottom,
    left,
};

fn edgeShorthandContainsAuto(value: []const u8, side: EdgeSide) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;

    var values: [4][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |part| {
        if (count == values.len) break;
        values[count] = std.mem.trim(u8, part, &std.ascii.whitespace);
        count += 1;
    }

    const idx: usize = switch (side) {
        .top => 0,
        .right => 1,
        .bottom => 2,
        .left => 3,
    };
    return switch (count) {
        1 => isCssAuto(values[0]),
        2 => isCssAuto(values[
            switch (side) {
                .top, .bottom => 0,
                .right, .left => 1,
            }
        ]),
        3 => isCssAuto(values[
            switch (side) {
                .top => 0,
                .right, .left => 1,
                .bottom => 2,
            }
        ]),
        else => isCssAuto(values[idx]),
    };
}

fn parseCssFloatValue(value: []const u8) ?f32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return std.fmt.parseFloat(f32, trimmed) catch null;
}

fn parseCssIntegerValue(value: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

fn parseCssLengthPxWithContext(value: []const u8, reference: i32, viewport: i32) ?i32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return null;
    }
    if (std.mem.startsWith(u8, trimmed, "min(") and trimmed[trimmed.len - 1] == ')') {
        return parseCssExtremumFunctionPx(trimmed[4 .. trimmed.len - 1], .min, reference, viewport);
    }
    if (std.mem.startsWith(u8, trimmed, "max(") and trimmed[trimmed.len - 1] == ')') {
        return parseCssExtremumFunctionPx(trimmed[4 .. trimmed.len - 1], .max, reference, viewport);
    }
    if (std.mem.startsWith(u8, trimmed, "clamp(") and trimmed[trimmed.len - 1] == ')') {
        return parseCssClampFunctionPx(trimmed[6 .. trimmed.len - 1], reference, viewport);
    }
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |_| {
        return null;
    }
    if (std.mem.endsWith(u8, trimmed, "px")) {
        const raw = trimmed[0 .. trimmed.len - 2];
        return @intFromFloat(std.fmt.parseFloat(f64, raw) catch return null);
    }
    if (std.mem.endsWith(u8, trimmed, "%")) {
        if (reference <= 0) return null;
        const raw = trimmed[0 .. trimmed.len - 1];
        const percent = std.fmt.parseFloat(f64, raw) catch return null;
        return @intFromFloat((@as(f64, @floatFromInt(reference)) * percent) / 100.0);
    }
    if (std.mem.endsWith(u8, trimmed, "vw")) {
        if (viewport <= 0) return null;
        const raw = trimmed[0 .. trimmed.len - 2];
        const percent = std.fmt.parseFloat(f64, raw) catch return null;
        return @intFromFloat((@as(f64, @floatFromInt(viewport)) * percent) / 100.0);
    }
    if (std.mem.endsWith(u8, trimmed, "vh")) {
        if (viewport <= 0) return null;
        const raw = trimmed[0 .. trimmed.len - 2];
        const percent = std.fmt.parseFloat(f64, raw) catch return null;
        return @intFromFloat((@as(f64, @floatFromInt(viewport)) * percent) / 100.0);
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "thin")) return 1;
    if (std.ascii.eqlIgnoreCase(trimmed, "medium")) return 2;
    if (std.ascii.eqlIgnoreCase(trimmed, "thick")) return 4;
    if (std.mem.eql(u8, trimmed, "0")) return 0;
    return @intFromFloat(std.fmt.parseFloat(f64, trimmed) catch return null);
}

const ExtremumKind = enum { min, max };

fn parseCssExtremumFunctionPx(value: []const u8, kind: ExtremumKind, reference: i32, viewport: i32) ?i32 {
    var args = std.mem.splitScalar(u8, value, ',');
    var best: ?i32 = null;
    while (args.next()) |raw_arg| {
        const arg = std.mem.trim(u8, raw_arg, &std.ascii.whitespace);
        const parsed = parseCssLengthPxWithContext(arg, reference, viewport) orelse continue;
        best = if (best) |current|
            switch (kind) {
                .min => @min(current, parsed),
                .max => @max(current, parsed),
            }
        else
            parsed;
    }
    return best;
}

fn parseCssClampFunctionPx(value: []const u8, reference: i32, viewport: i32) ?i32 {
    var args = std.mem.splitScalar(u8, value, ',');
    const min_value = parseCssLengthPxWithContext(std.mem.trim(u8, args.next() orelse return null, &std.ascii.whitespace), reference, viewport) orelse return null;
    const preferred_value = parseCssLengthPxWithContext(std.mem.trim(u8, args.next() orelse return null, &std.ascii.whitespace), reference, viewport) orelse return null;
    const max_value = parseCssLengthPxWithContext(std.mem.trim(u8, args.next() orelse return null, &std.ascii.whitespace), reference, viewport) orelse return null;
    return std.math.clamp(preferred_value, min_value, max_value);
}

fn parseCssLengthPx(value: []const u8) ?i32 {
    return parseCssLengthPxWithContext(value, 0, 0);
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

test "paintDocument emits canvas pixels for headed rendering" {
    var page = try testing.pageTest("page/canvas_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .canvas => |canvas| {
                try std.testing.expectEqual(@as(u32, 120), canvas.pixel_width);
                try std.testing.expectEqual(@as(u32, 80), canvas.pixel_height);
                try std.testing.expect(canvas.pixels.len >= 4);

                const red_index = (@as(usize, 12) * canvas.pixel_width + 12) * 4;
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[red_index + 0]);
                try std.testing.expectEqual(@as(u8, 0), canvas.pixels[red_index + 1]);
                try std.testing.expectEqual(@as(u8, 0), canvas.pixels[red_index + 2]);
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[red_index + 3]);

                const clear_index = (@as(usize, 60) * canvas.pixel_width + 90) * 4;
                try std.testing.expectEqual(@as(u8, 0), canvas.pixels[clear_index + 3]);
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument emits drawImage canvas pixels for headed rendering" {
    var page = try testing.pageTest("page/canvas_draw_image_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .canvas => |canvas| {
                try std.testing.expectEqual(@as(u32, 120), canvas.pixel_width);
                try std.testing.expectEqual(@as(u32, 80), canvas.pixel_height);

                const red_index = (@as(usize, 12) * canvas.pixel_width + 12) * 4;
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[red_index + 0]);
                try std.testing.expectEqual(@as(u8, 0), canvas.pixels[red_index + 2]);

                const blue_index = (@as(usize, 15) * canvas.pixel_width + 45) * 4;
                try std.testing.expectEqual(@as(u8, 0), canvas.pixels[blue_index + 0]);
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[blue_index + 2]);

                const green_index = (@as(usize, 25) * canvas.pixel_width + 75) * 4;
                try std.testing.expectEqual(@as(u8, 0), canvas.pixels[green_index + 0]);
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[green_index + 1]);
                try std.testing.expectEqual(@as(u8, 0), canvas.pixels[green_index + 2]);
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument emits HTMLImageElement drawImage canvas pixels for headed rendering" {
    var page = try testing.pageTest("page/canvas_draw_image_image_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .canvas => |canvas| {
                const red_index = (@as(usize, 12) * canvas.pixel_width + 12) * 4;
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[red_index + 0]);
                try std.testing.expectEqual(@as(u8, 0), canvas.pixels[red_index + 2]);

                const blue_index = (@as(usize, 25) * canvas.pixel_width + 75) * 4;
                try std.testing.expectEqual(@as(u8, 0), canvas.pixels[blue_index + 0]);
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[blue_index + 2]);
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument emits canvas path pixels for headed rendering" {
    var page = try testing.pageTest("page/canvas_path_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .canvas => |canvas| {
                const fill_index = (@as(usize, 20) * canvas.pixel_width + 35) * 4;
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[fill_index + 1]);

                const horizontal_index = (@as(usize, 70) * canvas.pixel_width + 60) * 4;
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[horizontal_index + 2]);

                const vertical_index = (@as(usize, 50) * canvas.pixel_width + 100) * 4;
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[vertical_index + 2]);
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument emits canvas text pixels for headed rendering" {
    var page = try testing.pageTest("page/canvas_text_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .canvas => |canvas| {
                var red_pixels: usize = 0;
                var blue_pixels: usize = 0;
                var i: usize = 0;
                while (i + 3 < canvas.pixels.len) : (i += 4) {
                    const r = canvas.pixels[i + 0];
                    const g = canvas.pixels[i + 1];
                    const b = canvas.pixels[i + 2];
                    const a = canvas.pixels[i + 3];
                    if (a == 0) continue;
                    if (r > 160 and g < 80 and b < 80) red_pixels += 1;
                    if (r < 80 and g < 80 and b > 120) blue_pixels += 1;
                }
                try std.testing.expect(red_pixels > 40);
                try std.testing.expect(blue_pixels > 40);
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument emits webgl clear canvas pixels for headed rendering" {
    var page = try testing.pageTest("page/canvas_webgl_clear_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .canvas => |canvas| {
                const sample_index = (@as(usize, 30) * canvas.pixel_width + 40) * 4;
                try std.testing.expectEqual(@as(u8, 64), canvas.pixels[sample_index + 0]);
                try std.testing.expectEqual(@as(u8, 128), canvas.pixels[sample_index + 1]);
                try std.testing.expectEqual(@as(u8, 191), canvas.pixels[sample_index + 2]);
                try std.testing.expectEqual(@as(u8, 255), canvas.pixels[sample_index + 3]);
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument emits webgl triangle canvas pixels for headed rendering" {
    var page = try testing.pageTest("page/canvas_webgl_triangle_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .canvas => |canvas| {
                var red_pixels: usize = 0;
                var white_pixels: usize = 0;
                var i: usize = 0;
                while (i + 3 < canvas.pixels.len) : (i += 4) {
                    const r = canvas.pixels[i + 0];
                    const g = canvas.pixels[i + 1];
                    const b = canvas.pixels[i + 2];
                    const a = canvas.pixels[i + 3];
                    if (a == 0) continue;
                    if (r > 200 and g < 80 and b < 80) red_pixels += 1;
                    if (r > 200 and g > 200 and b > 200) white_pixels += 1;
                }
                try std.testing.expect(red_pixels > 200);
                try std.testing.expect(white_pixels > 2000);
                found = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found);
}

test "paintDocument emits webgl varying-color canvas pixels for headed rendering" {
    var page = try testing.pageTest("page/canvas_webgl_varying_render.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var found = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .canvas => |canvas| {
                var red_pixels: usize = 0;
                var green_pixels: usize = 0;
                var blue_pixels: usize = 0;
                var white_pixels: usize = 0;
                var i: usize = 0;
                while (i + 3 < canvas.pixels.len) : (i += 4) {
                    const r = canvas.pixels[i + 0];
                    const g = canvas.pixels[i + 1];
                    const b = canvas.pixels[i + 2];
                    const a = canvas.pixels[i + 3];
                    if (a == 0) continue;
                    if (r > 170 and g < 130 and b < 130) red_pixels += 1;
                    if (r < 150 and g > 150 and b < 150) green_pixels += 1;
                    if (r < 150 and g < 150 and b > 170) blue_pixels += 1;
                    if (r > 200 and g > 200 and b > 200) white_pixels += 1;
                }
                try std.testing.expect(red_pixels > 50);
                try std.testing.expect(green_pixels > 50);
                try std.testing.expect(blue_pixels > 50);
                try std.testing.expect(white_pixels > 2000);
                found = true;
            },
            else => {},
        }
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

test "paintDocument keeps wrapped inline checkbox pair radio pair input and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_input_submit_flow.html");
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

    try std.testing.expectEqual(@as(usize, 6), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 0), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_region = display_list.control_regions.items[4];
    const submit_region = display_list.control_regions.items[5];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_region.y >= radio_two_region.y + 8);
    try std.testing.expect(submit_region.y >= input_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair radio pair two inputs and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_two_input_submit_flow.html");
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

    try std.testing.expectEqual(@as(usize, 7), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 0), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_one_region = display_list.control_regions.items[4];
    const input_two_region = display_list.control_regions.items[5];
    const submit_region = display_list.control_regions.items[6];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_one_region.y >= radio_two_region.y + 8);
    try std.testing.expect(input_two_region.y >= input_one_region.y + 8);
    try std.testing.expect(submit_region.y >= input_two_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair radio pair two inputs later link and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_two_input_submit_link_flow.html");
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

    try std.testing.expectEqual(@as(usize, 7), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 1), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_one_region = display_list.control_regions.items[4];
    const input_two_region = display_list.control_regions.items[5];
    const submit_region = display_list.control_regions.items[6];
    const link_region = display_list.link_regions.items[0];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_one_region.y >= radio_two_region.y + 8);
    try std.testing.expect(input_two_region.y >= input_one_region.y + 8);
    try std.testing.expect(link_region.y >= input_two_region.y + 8);
    try std.testing.expect(submit_region.y >= link_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair radio pair two inputs two later links and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_two_input_two_link_submit_flow.html");
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

    try std.testing.expectEqual(@as(usize, 7), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 2), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_one_region = display_list.control_regions.items[4];
    const input_two_region = display_list.control_regions.items[5];
    const submit_region = display_list.control_regions.items[6];
    const link_one_region = display_list.link_regions.items[0];
    const link_two_region = display_list.link_regions.items[1];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_one_region.y >= radio_two_region.y + 8);
    try std.testing.expect(input_two_region.y >= input_one_region.y + 8);
    try std.testing.expect(link_one_region.y >= input_two_region.y + 8);
    try std.testing.expect(link_two_region.y >= link_one_region.y + 8);
    try std.testing.expect(submit_region.y >= link_two_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair radio pair two inputs three later links and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_two_input_three_link_submit_flow.html");
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

    try std.testing.expectEqual(@as(usize, 7), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 3), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_one_region = display_list.control_regions.items[4];
    const input_two_region = display_list.control_regions.items[5];
    const submit_region = display_list.control_regions.items[6];
    const link_one_region = display_list.link_regions.items[0];
    const link_two_region = display_list.link_regions.items[1];
    const link_three_region = display_list.link_regions.items[2];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_one_region.y >= radio_two_region.y + 8);
    try std.testing.expect(input_two_region.y >= input_one_region.y + 8);
    try std.testing.expect(link_one_region.y >= input_two_region.y + 8);
    try std.testing.expect(link_two_region.y >= link_one_region.y + 8);
    try std.testing.expect(link_three_region.y >= link_two_region.y + 8);
    try std.testing.expect(submit_region.y >= link_three_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair radio pair two inputs four later links and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_two_input_four_link_submit_flow.html");
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

    try std.testing.expectEqual(@as(usize, 7), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 4), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_one_region = display_list.control_regions.items[4];
    const input_two_region = display_list.control_regions.items[5];
    const submit_region = display_list.control_regions.items[6];
    const link_one_region = display_list.link_regions.items[0];
    const link_two_region = display_list.link_regions.items[1];
    const link_three_region = display_list.link_regions.items[2];
    const link_four_region = display_list.link_regions.items[3];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_one_region.y >= radio_two_region.y + 8);
    try std.testing.expect(input_two_region.y >= input_one_region.y + 8);
    try std.testing.expect(link_one_region.y >= input_two_region.y + 8);
    try std.testing.expect(link_two_region.y >= link_one_region.y + 8);
    try std.testing.expect(link_three_region.y >= link_two_region.y + 8);
    try std.testing.expect(link_four_region.y >= link_three_region.y + 8);
    try std.testing.expect(submit_region.y >= link_four_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair radio pair two inputs five later links and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_two_input_five_link_submit_flow.html");
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

    try std.testing.expectEqual(@as(usize, 7), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 5), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_one_region = display_list.control_regions.items[4];
    const input_two_region = display_list.control_regions.items[5];
    const submit_region = display_list.control_regions.items[6];
    const link_one_region = display_list.link_regions.items[0];
    const link_two_region = display_list.link_regions.items[1];
    const link_three_region = display_list.link_regions.items[2];
    const link_four_region = display_list.link_regions.items[3];
    const link_five_region = display_list.link_regions.items[4];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_one_region.y >= radio_two_region.y + 8);
    try std.testing.expect(input_two_region.y >= input_one_region.y + 8);
    try std.testing.expect(link_one_region.y >= input_two_region.y + 8);
    try std.testing.expect(link_two_region.y >= link_one_region.y + 8);
    try std.testing.expect(link_three_region.y >= link_two_region.y + 8);
    try std.testing.expect(link_four_region.y >= link_three_region.y + 8);
    try std.testing.expect(link_five_region.y >= link_four_region.y + 8);
    try std.testing.expect(submit_region.y >= link_five_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair radio pair two inputs six later links and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_two_input_six_link_submit_flow.html");
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

    try std.testing.expectEqual(@as(usize, 7), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 6), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_one_region = display_list.control_regions.items[4];
    const input_two_region = display_list.control_regions.items[5];
    const submit_region = display_list.control_regions.items[6];
    const link_one_region = display_list.link_regions.items[0];
    const link_two_region = display_list.link_regions.items[1];
    const link_three_region = display_list.link_regions.items[2];
    const link_four_region = display_list.link_regions.items[3];
    const link_five_region = display_list.link_regions.items[4];
    const link_six_region = display_list.link_regions.items[5];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_one_region.y >= radio_two_region.y + 8);
    try std.testing.expect(input_two_region.y >= input_one_region.y + 8);
    try std.testing.expect(link_one_region.y >= input_two_region.y + 8);
    try std.testing.expect(link_two_region.y >= link_one_region.y + 8);
    try std.testing.expect(link_three_region.y >= link_two_region.y + 8);
    try std.testing.expect(link_four_region.y >= link_three_region.y + 8);
    try std.testing.expect(link_five_region.y >= link_four_region.y + 8);
    try std.testing.expect(link_six_region.y >= link_five_region.y + 8);
    try std.testing.expect(submit_region.y >= link_six_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair radio pair two inputs seven later links and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_two_input_seven_link_submit_flow.html");
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

    try std.testing.expectEqual(@as(usize, 7), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 7), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_one_region = display_list.control_regions.items[4];
    const input_two_region = display_list.control_regions.items[5];
    const submit_region = display_list.control_regions.items[6];
    const link_one_region = display_list.link_regions.items[0];
    const link_two_region = display_list.link_regions.items[1];
    const link_three_region = display_list.link_regions.items[2];
    const link_four_region = display_list.link_regions.items[3];
    const link_five_region = display_list.link_regions.items[4];
    const link_six_region = display_list.link_regions.items[5];
    const link_seven_region = display_list.link_regions.items[6];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_one_region.y >= radio_two_region.y + 8);
    try std.testing.expect(input_two_region.y >= input_one_region.y + 8);
    try std.testing.expect(link_one_region.y >= input_two_region.y + 8);
    try std.testing.expect(link_two_region.y >= link_one_region.y + 8);
    try std.testing.expect(link_three_region.y >= link_two_region.y + 8);
    try std.testing.expect(link_four_region.y >= link_three_region.y + 8);
    try std.testing.expect(link_five_region.y >= link_four_region.y + 8);
    try std.testing.expect(link_six_region.y >= link_five_region.y + 8);
    try std.testing.expect(link_seven_region.y >= link_six_region.y + 8);
    try std.testing.expect(submit_region.y >= link_seven_region.y + 8);
    try std.testing.expect(below_y.? > submit_region.y + 8);
}

test "paintDocument keeps wrapped inline checkbox pair radio pair two inputs eight later links and later submit in DOM order" {
    var page = try testing.pageTest("page/mixed_inline_checkbox_pair_radio_pair_two_input_eight_link_submit_flow.html");
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

    try std.testing.expectEqual(@as(usize, 7), display_list.control_regions.items.len);
    try std.testing.expectEqual(@as(usize, 8), display_list.link_regions.items.len);
    try std.testing.expect(lead_y != null);
    try std.testing.expect(below_y != null);

    const checkbox_one_region = display_list.control_regions.items[0];
    const checkbox_two_region = display_list.control_regions.items[1];
    const radio_one_region = display_list.control_regions.items[2];
    const radio_two_region = display_list.control_regions.items[3];
    const input_one_region = display_list.control_regions.items[4];
    const input_two_region = display_list.control_regions.items[5];
    const submit_region = display_list.control_regions.items[6];
    const link_one_region = display_list.link_regions.items[0];
    const link_two_region = display_list.link_regions.items[1];
    const link_three_region = display_list.link_regions.items[2];
    const link_four_region = display_list.link_regions.items[3];
    const link_five_region = display_list.link_regions.items[4];
    const link_six_region = display_list.link_regions.items[5];
    const link_seven_region = display_list.link_regions.items[6];
    const link_eight_region = display_list.link_regions.items[7];

    try std.testing.expect(checkbox_one_region.y > lead_y.? + 8);
    try std.testing.expect(checkbox_two_region.y >= checkbox_one_region.y + 8);
    try std.testing.expect(radio_one_region.y >= checkbox_two_region.y + 8);
    try std.testing.expect(radio_two_region.y >= radio_one_region.y + 8);
    try std.testing.expect(input_one_region.y >= radio_two_region.y + 8);
    try std.testing.expect(input_two_region.y >= input_one_region.y + 8);
    try std.testing.expect(link_one_region.y >= input_two_region.y + 8);
    try std.testing.expect(link_two_region.y >= link_one_region.y + 8);
    try std.testing.expect(link_three_region.y >= link_two_region.y + 8);
    try std.testing.expect(link_four_region.y >= link_three_region.y + 8);
    try std.testing.expect(link_five_region.y >= link_four_region.y + 8);
    try std.testing.expect(link_six_region.y >= link_five_region.y + 8);
    try std.testing.expect(link_seven_region.y >= link_six_region.y + 8);
    try std.testing.expect(link_eight_region.y >= link_seven_region.y + 8);
    try std.testing.expect(submit_region.y >= link_eight_region.y + 8);
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

test "paintDocument centers a flex column hero container" {
    var page = try testing.pageTest("page/flex_center_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var input_region: ?ControlRegion = null;
    var heading_text: ?TextCommand = null;
    if (display_list.control_regions.items.len > 0) {
        input_region = display_list.control_regions.items[0];
    }
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.indexOf(u8, text.text, "Search") != null) {
                    heading_text = text;
                }
            },
            else => {},
        }
    }

    const input = input_region orelse return error.InputRegionMissing;
    const heading = heading_text orelse return error.HeadingTextMissing;

    try std.testing.expect(input.x > 150);
    try std.testing.expect(input.x < 280);
    try std.testing.expect(input.width >= 400);
    try std.testing.expect(input.y > 220);
    try std.testing.expect(heading.x > 220);
    try std.testing.expect(heading.x < 360);
    try std.testing.expect(heading.y > 180);
    try std.testing.expect(heading.y < input.y);
}

test "paintDocument wraps centered flex row children onto later lines" {
    var page = try testing.pageTest("page/flex_row_wrap_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 420,
        .viewport_height = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var red_text: ?TextCommand = null;
    var blue_text: ?TextCommand = null;
    var green_text: ?TextCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (text.color.r >= 180 and text.color.g <= 90 and text.color.b <= 90) {
                    red_text = text;
                } else if (text.color.b >= 180 and text.color.r <= 90 and text.color.g <= 150) {
                    blue_text = text;
                } else if (text.color.g >= 140 and text.color.r <= 100 and text.color.b <= 140) {
                    green_text = text;
                }
            },
            else => {},
        }
    }

    const red = red_text orelse return error.RedChipTextMissing;
    const blue = blue_text orelse return error.BlueChipTextMissing;
    const green = green_text orelse return error.GreenChipTextMissing;

    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(red.y)), @as(f64, @floatFromInt(blue.y)), 4.0);
    try std.testing.expect(green.y >= red.y + red.height + 8);
    try std.testing.expect(red.x > 40);
    try std.testing.expect(blue.x > red.x + 60);
    try std.testing.expect(green.x > 120);
    try std.testing.expect(green.x < 220);
}

test "paintDocument grows flex row items with bounded docked siblings" {
    var page = try testing.pageTest("page/flex_grow_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var red_rect: ?Bounds = null;
    var gray_rect: ?Bounds = null;
    var blue_rect: ?Bounds = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r >= 180 and rect.color.g <= 90 and rect.color.b <= 90) {
                    red_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.r >= 130 and rect.color.r <= 190 and rect.color.g >= 130 and rect.color.g <= 190 and rect.color.b >= 130 and rect.color.b <= 190) {
                    gray_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.b >= 180 and rect.color.r <= 90 and rect.color.g <= 150) {
                    blue_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                }
            },
            else => {},
        }
    }

    const red = red_rect orelse return error.FlexGrowLeftBoxMissing;
    const gray = gray_rect orelse return error.FlexGrowSearchBoxMissing;
    const blue = blue_rect orelse return error.FlexGrowRightBoxMissing;

    try std.testing.expect(gray.width >= 220);
    try std.testing.expect(gray.x > red.x + red.width);
    try std.testing.expect(blue.x > gray.x + gray.width);
}

test "paintDocument lays out legacy centered table search form" {
    var page = try testing.pageTest("page/legacy_table_layout.html");
    defer page._session.removePage();

    const table = (try page.window._document.querySelector(.wrap("#search-table"), page)).?;
    const row = (try page.window._document.querySelector(.wrap("#search-row"), page)).?;
    const main_cell = (try page.window._document.querySelector(.wrap("#main-cell"), page)).?;
    const side_cell = (try page.window._document.querySelector(.wrap("#side-cell"), page)).?;
    const side_pill = (try page.window._document.querySelector(.wrap(".side-pill"), page)).?;
    const logo = (try page.window._document.querySelector(.wrap(".logo"), page)).?;
    const shell = (try page.window._document.querySelector(.wrap(".search-shell"), page)).?;

    const table_style = try page.window.getComputedStyle(table, null, page);
    const row_style = try page.window.getComputedStyle(row, null, page);
    const main_style = try page.window.getComputedStyle(main_cell, null, page);
    const side_style = try page.window.getComputedStyle(side_cell, null, page);
    const side_pill_style = try page.window.getComputedStyle(side_pill, null, page);
    const logo_style = try page.window.getComputedStyle(logo, null, page);
    const shell_style = try page.window.getComputedStyle(shell, null, page);

    try std.testing.expectEqualStrings("table", table_style.asCSSStyleDeclaration().getPropertyValue("display", page));
    try std.testing.expectEqualStrings("table-row", row_style.asCSSStyleDeclaration().getPropertyValue("display", page));
    try std.testing.expectEqualStrings("table-cell", main_style.asCSSStyleDeclaration().getPropertyValue("display", page));
    try std.testing.expectEqualStrings("top", row_style.asCSSStyleDeclaration().getPropertyValue("vertical-align", page));
    try std.testing.expectEqualStrings("center", main_style.asCSSStyleDeclaration().getPropertyValue("text-align", page));
    try std.testing.expectEqualStrings("nowrap", main_style.asCSSStyleDeclaration().getPropertyValue("white-space", page));
    try std.testing.expectEqualStrings("#4d88ff", logo_style.asCSSStyleDeclaration().getPropertyValue("background-color", page));
    try std.testing.expectEqualStrings("#cfcfcf", shell_style.asCSSStyleDeclaration().getPropertyValue("background-color", page));
    try std.testing.expectEqualStrings("#24a264", side_pill_style.asCSSStyleDeclaration().getPropertyValue("background-color", page));
    try std.testing.expectEqualStrings("solid", shell_style.asCSSStyleDeclaration().getPropertyValue("border-style", page));
    try std.testing.expectEqualStrings("1px", shell_style.asCSSStyleDeclaration().getPropertyValue("border-width", page));
    try std.testing.expectEqualStrings("15px", (try page.window.getComputedStyle(
        (try page.window._document.querySelector(.wrap(".lsb"), page)).?,
        null,
        page,
    )).asCSSStyleDeclaration().getPropertyValue("font-size", page));

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var input_region: ?ControlRegion = null;
    var shell_rect: ?Bounds = null;
    var logo_rect: ?Bounds = null;
    var green_rect: ?Bounds = null;
    for (display_list.control_regions.items) |control| {
        if (control.width > 300) {
            input_region = control;
        }
    }
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r >= 70 and rect.color.r <= 90 and rect.color.g >= 120 and rect.color.g <= 150 and rect.color.b >= 220) {
                    logo_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                }
                if (rect.color.r >= 195 and rect.color.r <= 220 and rect.color.g >= 195 and rect.color.g <= 220 and rect.color.b >= 195 and rect.color.b <= 220) {
                    shell_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                }
                if (rect.color.g >= 140 and rect.color.r <= 80 and rect.color.b <= 120) {
                    green_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                }
            },
            else => {},
        }
    }

    const input = input_region orelse return error.LegacyTableInputMissing;
    const logo_box = logo_rect orelse return error.LegacyTableLogoMissing;
    const shell_box = shell_rect orelse return error.LegacyTableShellMissing;
    const side = green_rect orelse return error.LegacyTableSidePillMissing;

    try std.testing.expect(logo_box.x >= 320);
    try std.testing.expect(logo_box.x <= 380);
    try std.testing.expect(shell_box.x >= 240);
    try std.testing.expect(shell_box.x <= 300);
    try std.testing.expect(shell_box.width >= 430);
    try std.testing.expect(input.x >= shell_box.x);
    try std.testing.expect(input.x <= shell_box.x + 24);
    try std.testing.expect(input.width >= 420);
    try std.testing.expect(input.height <= 40);
    try std.testing.expect(side.x >= shell_box.x + shell_box.width);
    try std.testing.expect(side.y <= shell_box.y + 12);
    try std.testing.expectEqualStrings("left", side_style.asCSSStyleDeclaration().getPropertyValue("text-align", page));
}

test "paintDocument docks floated blocks and keeps body flow below them" {
    var page = try testing.pageTest("page/float_dock_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 760,
        .viewport_height = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var red_rect: ?Bounds = null;
    var blue_rect: ?Bounds = null;
    var green_rect: ?Bounds = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r >= 180 and rect.color.g <= 100 and rect.color.b <= 100) {
                    red_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.b >= 170 and rect.color.r <= 80 and rect.color.g <= 140) {
                    blue_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.g >= 140 and rect.color.r <= 120 and rect.color.b <= 120) {
                    green_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                }
            },
            else => {},
        }
    }

    const red = red_rect orelse return error.FloatLeftRectMissing;
    const blue = blue_rect orelse return error.FloatRightRectMissing;
    const green = green_rect orelse return error.FloatBodyRectMissing;

    try std.testing.expect(red.x < 80);
    try std.testing.expect(blue.x > 520);
    try std.testing.expect(green.y >= red.y + red.height);
    try std.testing.expect(green.y >= blue.y + blue.height);
}

test "paintDocument anchors absolute boxes to the viewport without consuming normal flow" {
    var page = try testing.pageTest("page/absolute_position_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var saw_left = false;
    var saw_right = false;
    var saw_body = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.indexOf(u8, text.text, "Left") != null or std.mem.indexOf(u8, text.text, "Dock") != null) {
                    if (text.x < 60 and text.y < 20) saw_left = true;
                }
                if (std.mem.indexOf(u8, text.text, "Right") != null or std.mem.indexOf(u8, text.text, "Dock") != null) {
                    if (text.x > 780 and text.y < 20) saw_right = true;
                }
                if (std.mem.indexOf(u8, text.text, "Body") != null or std.mem.indexOf(u8, text.text, "Flow") != null) {
                    if (text.y > 120) saw_body = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_left);
    try std.testing.expect(saw_right);
    try std.testing.expect(saw_body);
}

test "paintDocument anchors later absolute siblings to the containing block and carries z-index" {
    var page = try testing.pageTest("page/absolute_zindex_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var dark_rect: ?Command = null;
    var blue_rect: ?Command = null;
    var red_rect: ?Command = null;
    var green_rect: ?Command = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r <= 50 and rect.color.g <= 50 and rect.color.b <= 50) {
                    dark_rect = command;
                } else if (rect.color.b >= 180 and rect.color.r <= 90 and rect.color.g <= 130) {
                    blue_rect = command;
                } else if (rect.color.r >= 180 and rect.color.g <= 100 and rect.color.b <= 100) {
                    red_rect = command;
                } else if (rect.color.g >= 140 and rect.color.r <= 100 and rect.color.b <= 140) {
                    green_rect = command;
                }
            },
            else => {},
        }
    }

    const dark = dark_rect orelse return error.AbsoluteZIndexDarkBarMissing;
    const blue = blue_rect orelse return error.AbsoluteZIndexLowOverlayMissing;
    const red = red_rect orelse return error.AbsoluteZIndexHighOverlayMissing;
    const green = green_rect orelse return error.AbsoluteZIndexBodyMissing;

    try std.testing.expect(commandBounds(dark).?.y < 60);
    try std.testing.expect(commandBounds(blue).?.y < 60);
    try std.testing.expect(commandBounds(red).?.y < 60);
    try std.testing.expect(commandBounds(green).?.y >= 120);
    try std.testing.expect(commandBounds(green).?.y < 220);
    try std.testing.expect(commandZIndexForTest(red) > commandZIndexForTest(blue));
    try std.testing.expect(commandZIndexForTest(blue) > commandZIndexForTest(dark));
}

test "paintDocument anchors fixed boxes to the viewport instead of the parent flow" {
    var page = try testing.pageTest("page/fixed_position_layout.html");
    defer page._session.removePage();

    const fixed_left = (try page.window._document.querySelector(.wrap(".fixed-left"), page)).?;
    const fixed_right = (try page.window._document.querySelector(.wrap(".fixed-right"), page)).?;
    const fixed_left_style = try page.window.getComputedStyle(fixed_left, null, page);
    const fixed_right_style = try page.window.getComputedStyle(fixed_right, null, page);
    try std.testing.expectEqualStrings("inline-block", fixed_left_style.asCSSStyleDeclaration().getPropertyValue("display", page));
    try std.testing.expectEqualStrings("inline-block", fixed_right_style.asCSSStyleDeclaration().getPropertyValue("display", page));

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var red_text: ?TextCommand = null;
    var blue_text: ?TextCommand = null;
    var green_text: ?TextCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (text.color.r >= 180 and text.color.g <= 90 and text.color.b <= 90) {
                    red_text = text;
                } else if (text.color.b >= 180 and text.color.r <= 90 and text.color.g <= 150) {
                    blue_text = text;
                } else if (text.color.g >= 140 and text.color.r <= 100 and text.color.b <= 140) {
                    green_text = text;
                }
            },
            else => {},
        }
    }

    const red = red_text orelse return error.FixedLeftTextMissing;
    const blue = blue_text orelse return error.FixedRightTextMissing;
    const green = green_text orelse return error.FlowBoxTextMissing;

    try std.testing.expect(red.x < 60);
    try std.testing.expect(red.y < 30);
    try std.testing.expect(blue.x > 760);
    try std.testing.expect(blue.y < 30);
    try std.testing.expect(green.y > 180);
}

test "paintDocument centers inline children when text-align is center" {
    var page = try testing.pageTest("page/text_align_center_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    const input = if (display_list.control_regions.items.len > 0)
        display_list.control_regions.items[0]
    else
        return error.InputRegionMissing;

    try std.testing.expect(input.x > 150);
    try std.testing.expect(input.x < 190);
    try std.testing.expect(input.width >= 280);
}
