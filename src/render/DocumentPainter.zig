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
const RectCommand = @import("DisplayList.zig").RectCommand;
const TextCommand = @import("DisplayList.zig").TextCommand;
const LinkRegion = @import("DisplayList.zig").LinkRegion;
const ControlRegion = @import("DisplayList.zig").ControlRegion;
const ImageCommand = @import("DisplayList.zig").ImageCommand;
const CanvasCommand = @import("DisplayList.zig").CanvasCommand;
const FontFaceResource = @import("DisplayList.zig").FontFaceResource;
const FontFaceFormat = @import("DisplayList.zig").FontFaceFormat;
const ClipRect = @import("DisplayList.zig").ClipRect;
const CSSStyleSheet = @import("../browser/webapi/css/CSSStyleSheet.zig");
const CSSStyleProperties = @import("../browser/webapi/css/CSSStyleProperties.zig");
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

const MeasurementKey = struct {
    node_ptr: usize,
    available_width: i32,
    forced_width: i32,
    forced_height: i32,
};

const ChildrenMeasurementKey = struct {
    element_ptr: usize,
    available_width: i32,
    forced_node_ptr: usize,
    forced_width: i32,
    forced_height: i32,
};

const MeasurementValue = struct {
    width: i32,
    height: i32,
};

pub fn paintDocument(allocator: std.mem.Allocator, page: *Page, opts: PaintOpts) !DisplayList {
    page.resetElementScrollMetrics();
    page.resetElementLayoutBoxes();
    var list = DisplayList{
        .layout_scale = opts.layout_scale,
        .page_margin = opts.page_margin,
    };
    errdefer list.deinit(allocator);
    var paint_text_styles = std.AutoHashMap(usize, PaintTextStyle).init(allocator);
    defer paint_text_styles.deinit();
    var measurement_cache = std.AutoHashMap(MeasurementKey, MeasurementValue).init(allocator);
    defer measurement_cache.deinit();
    var children_measurement_cache = std.AutoHashMap(ChildrenMeasurementKey, MeasurementValue).init(allocator);
    defer children_measurement_cache.deinit();
    var computed_style_cache = std.AutoHashMap(usize, *CSSStyleProperties).init(allocator);
    defer computed_style_cache.deinit();

    const root = if (page.window._document.is(HTMLDocument)) |html_doc|
        if (html_doc.getBody()) |body| body.asNode() else page.window._document.asNode()
    else
        page.window._document.asNode();

    var painter = Painter{
        .allocator = allocator,
        .page = page,
        .opts = opts,
        .list = &list,
        .paint_text_styles = &paint_text_styles,
        .measurement_cache = &measurement_cache,
        .children_measurement_cache = &children_measurement_cache,
        .computed_style_cache = &computed_style_cache,
    };
    var cursor = FlowCursor.init(
        opts.page_margin,
        opts.page_margin,
        @max(@as(i32, 160), opts.viewport_width - (opts.page_margin * 2)),
    );
    try painter.paintNode(root, &cursor);
    list.recomputeContentHeight();
    try appendLoadedFontFacesToDisplayList(allocator, page, &list);
    return list;
}

pub fn patchTextControlDisplayList(
    allocator: std.mem.Allocator,
    page: *Page,
    display_list: *DisplayList,
    element: *Element,
    opts: PaintOpts,
) !bool {
    if (!supportsIncrementalTextControlPatch(element)) {
        return false;
    }

    const dom_path = try encodeNodePath(page.call_arena, element.asNode());
    const control_region_index = findControlRegionIndexForNodePath(display_list, dom_path) orelse return false;
    const control_region = display_list.control_regions.items[control_region_index];
    const control_bounds = Bounds{
        .x = control_region.x,
        .y = control_region.y,
        .width = control_region.width,
        .height = control_region.height,
    };

    var paint_text_styles = std.AutoHashMap(usize, PaintTextStyle).init(allocator);
    defer paint_text_styles.deinit();
    var measurement_cache = std.AutoHashMap(MeasurementKey, MeasurementValue).init(allocator);
    defer measurement_cache.deinit();
    var children_measurement_cache = std.AutoHashMap(ChildrenMeasurementKey, MeasurementValue).init(allocator);
    defer children_measurement_cache.deinit();
    var computed_style_cache = std.AutoHashMap(usize, *CSSStyleProperties).init(allocator);
    defer computed_style_cache.deinit();

    var painter = Painter{
        .allocator = allocator,
        .page = page,
        .opts = opts,
        .list = display_list,
        .paint_text_styles = &paint_text_styles,
        .measurement_cache = &measurement_cache,
        .children_measurement_cache = &children_measurement_cache,
        .computed_style_cache = &computed_style_cache,
    };

    return painter.replaceCommandsForIncrementalControl(element, control_region_index, control_bounds);
}

fn supportsIncrementalTextControlPatch(element: *Element) bool {
    const html = element.is(Element.Html) orelse return false;
    return switch (html._type) {
        .input => |input| input.supportsIncrementalTextPresentation(),
        .textarea => true,
        .button => true,
        .select => true,
        else => false,
    };
}

fn findControlRegionIndexForNodePath(display_list: *const DisplayList, dom_path: []const u16) ?usize {
    for (display_list.control_regions.items, 0..) |region, index| {
        if (std.mem.eql(u16, region.dom_path, dom_path)) {
            return index;
        }
    }
    return null;
}

fn setControlRegionCommandSpan(
    display_list: *DisplayList,
    control_region_index: usize,
    command_start: usize,
    command_end: usize,
) void {
    display_list.control_regions.items[control_region_index].command_start = command_start;
    display_list.control_regions.items[control_region_index].command_end = command_end;
}

fn invalidateAllControlRegionCommandSpans(display_list: *DisplayList) void {
    for (display_list.control_regions.items) |*region| {
        region.clearCommandSpan();
    }
}

fn shiftControlRegionCommandSpansAfterRemoval(
    display_list: *DisplayList,
    skipped_region_index: usize,
    removed_start: usize,
    removed_end: usize,
    original_command_count: usize,
) void {
    const removed_count = removed_end - removed_start;
    if (removed_count == 0) {
        return;
    }

    for (display_list.control_regions.items, 0..) |*region, index| {
        if (index == skipped_region_index or !region.hasCommandSpan(original_command_count)) {
            continue;
        }
        if (region.command_end <= removed_start) {
            continue;
        }
        if (region.command_start >= removed_end) {
            region.command_start -= removed_count;
            region.command_end -= removed_count;
            continue;
        }
        region.clearCommandSpan();
    }
}

fn removeControlPaintCommandsForRegion(
    allocator: std.mem.Allocator,
    display_list: *DisplayList,
    control_region_index: usize,
    bounds: Bounds,
) bool {
    const region = display_list.control_regions.items[control_region_index];
    if (region.hasCommandSpan(display_list.commands.items.len)) {
        const original_command_count = display_list.commands.items.len;
        const removed_start = region.command_start;
        const removed_end = region.command_end;
        var index = removed_end;
        while (index > removed_start) {
            index -= 1;
            var removed = display_list.commands.orderedRemove(index);
            removed.deinit(allocator);
        }
        if (removed_end > removed_start) {
            display_list.recomputeContentHeight();
        }
        shiftControlRegionCommandSpansAfterRemoval(
            display_list,
            control_region_index,
            removed_start,
            removed_end,
            original_command_count,
        );
        display_list.control_regions.items[control_region_index].clearCommandSpan();
        return removed_end > removed_start;
    }

    invalidateAllControlRegionCommandSpans(display_list);
    return removeControlPaintCommandsWithinBounds(allocator, display_list, bounds);
}

fn withControlRegionCommandSpan(region: ControlRegion, command_start: usize, command_end: usize) ControlRegion {
    var annotated = region;
    annotated.command_start = command_start;
    annotated.command_end = command_end;
    return annotated;
}

fn withControlRegionCommandOffset(
    region: ControlRegion,
    source_command_count: usize,
    command_offset: usize,
) ControlRegion {
    var annotated = region;
    if (region.hasCommandSpan(source_command_count)) {
        annotated.command_start = command_offset + region.command_start;
        annotated.command_end = command_offset + region.command_end;
    } else {
        annotated.clearCommandSpan();
    }
    return annotated;
}

fn removeControlPaintCommandsWithinBounds(
    allocator: std.mem.Allocator,
    display_list: *DisplayList,
    bounds: Bounds,
) bool {
    var removed_any = false;
    var index = display_list.commands.items.len;
    while (index > 0) {
        index -= 1;
        const remove = switch (display_list.commands.items[index]) {
            .fill_rect => |rect| rectCommandBelongsToBounds(rect, bounds),
            .stroke_rect => |rect| rectCommandBelongsToBounds(rect, bounds),
            .text => |text| textCommandBelongsToBounds(text, bounds),
            else => false,
        };
        if (!remove) {
            continue;
        }
        var removed = display_list.commands.orderedRemove(index);
        removed.deinit(allocator);
        removed_any = true;
    }
    if (removed_any) {
        display_list.recomputeContentHeight();
    }
    return removed_any;
}

fn rectCommandBelongsToBounds(rect: RectCommand, bounds: Bounds) bool {
    return pointWithinBounds(
        rect.x + @divTrunc(@max(rect.width, 1), 2),
        rect.y + @divTrunc(@max(rect.height, 1), 2),
        bounds,
    );
}

fn textCommandBelongsToBounds(text: TextCommand, bounds: Bounds) bool {
    const text_height = @max(text.height, text.font_size + 8);
    return pointWithinBounds(
        text.x + @divTrunc(@max(text.width, 1), 2),
        text.y + @divTrunc(@max(text_height, 1), 2),
        bounds,
    );
}

fn pointWithinBounds(x: i32, y: i32, bounds: Bounds) bool {
    return x >= bounds.x and x < bounds.x + bounds.width and
        y >= bounds.y and y < bounds.y + bounds.height;
}

fn rendererDiagnosticsEnabled(page: *Page) bool {
    return std.mem.indexOf(u8, page.url, "consent.google.com") != null;
}

fn appendRendererDiagnosticsLine(comptime label: []const u8, message: []const u8) void {
    const file = std.fs.cwd().createFile("tmp-browser-smoke/google-investigation-next/runtime-renderer.log", .{
        .truncate = false,
    }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}|{s}\n", .{ label, message }) catch return;
    file.writeAll(line) catch return;
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

    fn beginInlineLeaf(self: *FlowCursor, width: i32, margins: EdgeSizes, spacing: i32) Position {
        const total_width = margins.left + width + margins.right + spacing;
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
    margins: EdgeSizes = .{},
    order: i32 = 0,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    align_self: FlexCrossAlignment = .auto,
    source_index: usize = 0,

    fn outerWidth(self: FlexChildMeasure) i32 {
        return self.width + self.margins.horizontal();
    }

    fn outerHeight(self: FlexChildMeasure) i32 {
        return self.height + self.margins.vertical();
    }
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

const TranslateTransform = struct {
    x: i32 = 0,
    y: i32 = 0,
};

fn clipRectFromBounds(bounds: Bounds) ClipRect {
    return .{
        .x = bounds.x,
        .y = bounds.y,
        .width = bounds.width,
        .height = bounds.height,
    };
}

fn translateClipRect(clip_rect: ClipRect, dx: i32, dy: i32) ClipRect {
    return .{
        .x = clip_rect.x + dx,
        .y = clip_rect.y + dy,
        .width = clip_rect.width,
        .height = clip_rect.height,
    };
}

fn intersectClipRects(lhs: ClipRect, rhs: ClipRect) ?ClipRect {
    const left = @max(lhs.x, rhs.x);
    const top = @max(lhs.y, rhs.y);
    const right = @min(lhs.x + lhs.width, rhs.x + rhs.width);
    const bottom = @min(lhs.y + lhs.height, rhs.y + rhs.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = left,
        .y = top,
        .width = right - left,
        .height = bottom - top,
    };
}

fn emptyClipRect(anchor: ClipRect) ClipRect {
    return .{
        .x = anchor.x,
        .y = anchor.y,
        .width = 0,
        .height = 0,
    };
}

fn combineTranslatedClipRect(existing_clip_rect: ?ClipRect, dx: i32, dy: i32, parent_clip_rect: ?ClipRect) ?ClipRect {
    const shifted = if (existing_clip_rect) |clip_rect| translateClipRect(clip_rect, dx, dy) else null;
    if (parent_clip_rect) |parent_clip| {
        return if (shifted) |child_clip|
            intersectClipRects(child_clip, parent_clip) orelse emptyClipRect(parent_clip)
        else
            parent_clip;
    }
    return shifted;
}

fn intersectBoundsWithClipRect(bounds: Bounds, clip_rect: ?ClipRect) ?Bounds {
    if (clip_rect) |clip| {
        const left = @max(bounds.x, clip.x);
        const top = @max(bounds.y, clip.y);
        const right = @min(bounds.x + bounds.width, clip.x + clip.width);
        const bottom = @min(bounds.y + bounds.height, clip.y + clip.height);
        if (right <= left or bottom <= top) return null;
        return .{
            .x = left,
            .y = top,
            .width = right - left,
            .height = bottom - top,
        };
    }
    return bounds;
}

fn translateRecentOutput(self: *Painter, command_start: usize, link_start: usize, control_start: usize, dx: i32, dy: i32) void {
    if (dx == 0 and dy == 0) {
        return;
    }

    var command_index = command_start;
    while (command_index < self.list.commands.items.len) : (command_index += 1) {
        switch (self.list.commands.items[command_index]) {
            .fill_rect => |*rect| {
                rect.x += dx;
                rect.y += dy;
                if (rect.clip_rect) |clip_rect| {
                    rect.clip_rect = translateClipRect(clip_rect, dx, dy);
                }
            },
            .stroke_rect => |*rect| {
                rect.x += dx;
                rect.y += dy;
                if (rect.clip_rect) |clip_rect| {
                    rect.clip_rect = translateClipRect(clip_rect, dx, dy);
                }
            },
            .text => |*text| {
                text.x += dx;
                text.y += dy;
                if (text.clip_rect) |clip_rect| {
                    text.clip_rect = translateClipRect(clip_rect, dx, dy);
                }
            },
            .image => |*image| {
                image.x += dx;
                image.y += dy;
                if (image.clip_rect) |clip_rect| {
                    image.clip_rect = translateClipRect(clip_rect, dx, dy);
                }
            },
            .canvas => |*canvas| {
                canvas.x += dx;
                canvas.y += dy;
                if (canvas.clip_rect) |clip_rect| {
                    canvas.clip_rect = translateClipRect(clip_rect, dx, dy);
                }
            },
        }
    }

    var link_index = link_start;
    while (link_index < self.list.link_regions.items.len) : (link_index += 1) {
        self.list.link_regions.items[link_index].x += dx;
        self.list.link_regions.items[link_index].y += dy;
    }

    var control_index = control_start;
    while (control_index < self.list.control_regions.items.len) : (control_index += 1) {
        self.list.control_regions.items[control_index].x += dx;
        self.list.control_regions.items[control_index].y += dy;
    }
}

fn nextTransformArgumentToken(args: []const u8, index: *usize) ?[]const u8 {
    while (index.* < args.len and (std.ascii.isWhitespace(args[index.*]) or args[index.*] == ',')) : (index.* += 1) {}
    if (index.* >= args.len) return null;

    const start = index.*;
    while (index.* < args.len and args[index.*] != ',' and !std.ascii.isWhitespace(args[index.*])) : (index.* += 1) {}
    return std.mem.trim(u8, args[start..index.*], &std.ascii.whitespace);
}

fn parseTranslateLength(token: []const u8, basis: i32, viewport: i32) ?i32 {
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return parseCssLengthPxWithContext(trimmed, basis, viewport);
}

fn resolveTranslateTransform(
    value: []const u8,
    reference_width: i32,
    reference_height: i32,
    viewport_width: i32,
    viewport_height: i32,
) ?TranslateTransform {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "none")) {
        return null;
    }

    var translate: TranslateTransform = .{};
    var cursor: usize = 0;
    while (cursor < trimmed.len) {
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
        if (cursor >= trimmed.len) break;

        const name_start = cursor;
        while (cursor < trimmed.len and trimmed[cursor] != '(' and !std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
        const name_end = cursor;
        while (cursor < trimmed.len and std.ascii.isWhitespace(trimmed[cursor])) : (cursor += 1) {}
        if (cursor >= trimmed.len or trimmed[cursor] != '(') {
            return null;
        }

        const name = std.mem.trim(u8, trimmed[name_start..name_end], &std.ascii.whitespace);
        cursor += 1;
        const args_start = cursor;
        var depth: usize = 1;
        while (cursor < trimmed.len and depth > 0) : (cursor += 1) {
            switch (trimmed[cursor]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        }
        if (depth != 0 or cursor >= trimmed.len) {
            return null;
        }

        const args = trimmed[args_start..cursor];
        cursor += 1;

        if (std.ascii.eqlIgnoreCase(name, "translate")) {
            var arg_index: usize = 0;
            const x_token = nextTransformArgumentToken(args, &arg_index) orelse return null;
            const y_token = nextTransformArgumentToken(args, &arg_index);
            const x = parseTranslateLength(x_token, reference_width, viewport_width) orelse return null;
            const y = if (y_token) |token|
                parseTranslateLength(token, reference_height, viewport_height) orelse return null
            else
                0;
            translate.x += x;
            translate.y += y;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "translatex")) {
            var arg_index: usize = 0;
            const x_token = nextTransformArgumentToken(args, &arg_index) orelse return null;
            translate.x += parseTranslateLength(x_token, reference_width, viewport_width) orelse return null;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "translatey")) {
            var arg_index: usize = 0;
            const y_token = nextTransformArgumentToken(args, &arg_index) orelse return null;
            translate.y += parseTranslateLength(y_token, reference_height, viewport_height) orelse return null;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "translate3d")) {
            var arg_index: usize = 0;
            const x_token = nextTransformArgumentToken(args, &arg_index) orelse return null;
            const y_token = nextTransformArgumentToken(args, &arg_index);
            translate.x += parseTranslateLength(x_token, reference_width, viewport_width) orelse return null;
            if (y_token) |token| {
                translate.y += parseTranslateLength(token, reference_height, viewport_height) orelse return null;
            }
            continue;
        }

        return null;
    }

    return translate;
}

fn applyTranslateTransformToRecentOutput(
    self: *Painter,
    command_start: usize,
    link_start: usize,
    control_start: usize,
    raw_transform: []const u8,
    reference_width: i32,
    reference_height: i32,
) void {
    const translate = resolveTranslateTransform(
        raw_transform,
        reference_width,
        reference_height,
        self.opts.viewport_width,
        self.opts.viewport_height,
    ) orelse return;
    if (translate.x == 0 and translate.y == 0) {
        return;
    }
    translateRecentOutput(self, command_start, link_start, control_start, translate.x, translate.y);
}

fn recentOutputBounds(self: *const Painter, command_start: usize, link_start: usize, control_start: usize) ?Bounds {
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    var found = false;

    var command_index = command_start;
    while (command_index < self.list.commands.items.len) : (command_index += 1) {
        const bounds = switch (self.list.commands.items[command_index]) {
            .fill_rect => |rect| Bounds{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height },
            .stroke_rect => |rect| Bounds{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height },
            .text => |text| Bounds{ .x = text.x, .y = text.y, .width = text.width, .height = @max(text.height, text.font_size + 8) },
            .image => |image| Bounds{ .x = image.x, .y = image.y, .width = image.width, .height = image.height },
            .canvas => |canvas| Bounds{ .x = canvas.x, .y = canvas.y, .width = canvas.width, .height = canvas.height },
        };
        min_x = @min(min_x, bounds.x);
        min_y = @min(min_y, bounds.y);
        max_x = @max(max_x, bounds.x + bounds.width);
        max_y = @max(max_y, bounds.y + bounds.height);
        found = true;
    }

    for (self.list.link_regions.items[link_start..]) |region| {
        min_x = @min(min_x, region.x);
        min_y = @min(min_y, region.y);
        max_x = @max(max_x, region.x + region.width);
        max_y = @max(max_y, region.y + region.height);
        found = true;
    }

    for (self.list.control_regions.items[control_start..]) |region| {
        min_x = @min(min_x, region.x);
        min_y = @min(min_y, region.y);
        max_x = @max(max_x, region.x + region.width);
        max_y = @max(max_y, region.y + region.height);
        found = true;
    }

    if (!found) {
        return null;
    }

    return .{
        .x = min_x,
        .y = min_y,
        .width = max_x - min_x,
        .height = max_y - min_y,
    };
}

fn trackElementScrollMetrics(
    self: *Painter,
    element: *Element,
    client_width: i32,
    client_height: i32,
    content_width: i32,
    content_height: i32,
) !Element.ScrollPosition {
    try self.page.setElementScrollMetrics(element, .{
        .client_width = @intCast(@max(0, client_width)),
        .client_height = @intCast(@max(0, client_height)),
        .scroll_width = @intCast(@max(client_width, content_width)),
        .scroll_height = @intCast(@max(client_height, content_height)),
    });
    return .{
        .x = element.getScrollLeft(self.page),
        .y = element.getScrollTop(self.page),
    };
}

const FlexCrossAlignment = enum {
    auto,
    start,
    center,
    end,
    stretch,
};

const FloatMode = enum {
    none,
    left,
    right,
};

const TextTransform = enum {
    none,
    uppercase,
    lowercase,
    capitalize,
};

const WhiteSpaceMode = enum {
    normal,
    nowrap,
};

const TextLineHeight = union(enum) {
    normal,
    px: i32,
    multiplier: f32,
};

const PaintTextStyle = struct {
    font_size: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
    color: Color,
    line_height: TextLineHeight = .normal,
    letter_spacing: i32 = 0,
    word_spacing: i32 = 0,
    text_transform: TextTransform = .none,
    white_space: WhiteSpaceMode = .normal,
};

const Painter = struct {
    allocator: std.mem.Allocator,
    page: *Page,
    opts: PaintOpts,
    list: *DisplayList,
    paint_text_styles: *std.AutoHashMap(usize, PaintTextStyle),
    measurement_cache: *std.AutoHashMap(MeasurementKey, MeasurementValue),
    children_measurement_cache: *std.AutoHashMap(ChildrenMeasurementKey, MeasurementValue),
    computed_style_cache: *std.AutoHashMap(usize, *CSSStyleProperties),
    cache_layout_boxes: bool = true,
    forced_item_node: ?*Node = null,
    forced_item_width: i32 = 0,
    forced_item_height: i32 = 0,
    preemption_checkpoint_counter: usize = 0,

    fn preemptionCheckpoint(self: *Painter) !void {
        self.preemption_checkpoint_counter += 1;
        if ((self.preemption_checkpoint_counter & 0x3F) != 0) {
            return;
        }
        if (self.page._session.browser.app.display.hasPendingNativeInput()) {
            return error.PaintInterrupted;
        }
    }

    fn paintNode(self: *Painter, node: *Node, cursor: *FlowCursor) anyerror!void {
        try self.paintNodeWithOpacity(node, cursor, 255);
    }

    fn paintNodeWithOpacity(self: *Painter, node: *Node, cursor: *FlowCursor, opacity: u8) anyerror!void {
        try self.preemptionCheckpoint();
        switch (node._type) {
            .document, .document_fragment => {
                var it = node.childrenIterator();
                while (it.next()) |child| {
                    try self.paintNodeWithOpacity(child, cursor, opacity);
                }
            },
            .element => |element| try self.paintElement(element, cursor, opacity),
            .cdata => |cdata| switch (cdata._type) {
                .text => try self.paintInlineTextNode(cdata, cursor, opacity),
                else => {},
            },
            else => {},
        }
    }

    fn recordElementLayoutBox(self: *Painter, element: *Element, rect: Bounds) !void {
        if (!self.cache_layout_boxes) return;
        try self.page.setElementLayoutBox(element, .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        });
        if (rendererDiagnosticsEnabled(self.page)) {
            const class_name = element.getAttributeSafe(comptime .wrap("class")) orelse "";
            const href = element.getAttributeSafe(comptime .wrap("href")) orelse "";
            const should_log = std.mem.indexOf(u8, class_name, "footer") != null or
                std.mem.indexOf(u8, class_name, "languagePicker") != null or
                std.mem.indexOf(u8, href, "/privacy") != null or
                std.mem.indexOf(u8, href, "/terms") != null;
            if (should_log) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "record_layout_box|tag={any}|class={s}|href={s}|x={d}|y={d}|w={d}|h={d}",
                    .{ element.getTag(), class_name, href, rect.x, rect.y, rect.width, rect.height },
                ) catch "";
                defer if (msg.len > 0) self.allocator.free(msg);
                appendRendererDiagnosticsLine("layout_box", msg);
            }
        }
    }

    fn translateSubtreeLayoutBoxes(self: *Painter, node: *Node, dx: i32, dy: i32) void {
        if (!self.cache_layout_boxes) return;
        if (dx == 0 and dy == 0) return;

        if (node.is(Element)) |element| {
            if (self.page._element_layout_boxes.getPtr(element)) |layout_box| {
                layout_box.x += dx;
                layout_box.y += dy;
            }
        }

        var child = node.firstChild();
        while (child) |current| : (child = current.nextSibling()) {
            self.translateSubtreeLayoutBoxes(current, dx, dy);
        }
    }

    fn computedStyle(self: *Painter, element: *Element) !*CSSStyleProperties {
        const key = @intFromPtr(element);
        if (self.computed_style_cache.get(key)) |style| {
            return style;
        }
        const style = try self.page.window.getComputedStyle(element, null, self.page);
        try self.computed_style_cache.put(key, style);
        return style;
    }

    fn replaceCommandsForIncrementalControl(
        self: *Painter,
        element: *Element,
        control_region_index: usize,
        rect: Bounds,
    ) !bool {
        const removed_any = removeControlPaintCommandsForRegion(
            self.allocator,
            self.list,
            control_region_index,
            rect,
        );
        const replacement_command_start = self.list.commands.items.len;

        const style = try self.computedStyle(element);
        const decl = style.asCSSStyleDeclaration();
        const tag = element.getTag();
        const text_style = try self.resolvePaintTextStyle(element, decl, tag);
        const label = try self.elementLabel(element);
        defer self.allocator.free(label);

        const padding = resolveEdgeSizes(decl, self.page, "padding");
        const fg = text_style.color;
        const font_size = text_style.font_size;
        const font_family = text_style.font_family;
        const font_weight = text_style.font_weight;
        const italic = text_style.italic;
        const paint_z_index = try resolvePaintZIndex(element, decl, self.page);
        const opacity = resolvePaintOpacity(decl, self.page, element);
        const corner_radius = resolveBorderRadiusPx(
            decl,
            self.page,
            rect.width,
            rect.height,
            self.opts.viewport_width,
            self.opts.viewport_height,
        );
        const background_color = parseCssColor(resolveCssPropertyValue(decl, self.page, element, "background-color"));
        if (shouldPaintBox(tag)) {
            if (background_color) |background| {
                if (background.a > 0 and shouldPaintBackground(tag, false)) {
                    try self.list.addFillRect(self.allocator, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                        .z_index = paint_z_index,
                        .corner_radius = corner_radius,
                        .clip_rect = null,
                        .opacity = opacity,
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
                    .corner_radius = corner_radius,
                    .clip_rect = null,
                    .opacity = opacity,
                    .color = .{ .r = 248, .g = 248, .b = 248 },
                });
            }

            if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
                try self.list.addStrokeRect(self.allocator, .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = rect.height,
                    .z_index = paint_z_index,
                    .corner_radius = corner_radius,
                    .clip_rect = null,
                    .opacity = opacity,
                    .color = stroke,
                });
            }
        }

        if (label.len == 0) {
            setControlRegionCommandSpan(
                self.list,
                control_region_index,
                replacement_command_start,
                self.list.commands.items.len,
            );
            return removed_any or shouldPaintBox(tag);
        }

        const text_area_width = @max(@as(i32, 40), rect.width - padding.horizontal() - 12);
        const painted_label = if (text_style.text_transform == .none) label else blk: {
            const transformed = try transformTextForPaint(self.allocator, label, text_style.text_transform);
            break :blk transformed;
        };
        defer if (text_style.text_transform != .none) self.allocator.free(painted_label);

        const base_text_height = @max(
            font_size + 8,
            estimateTextHeight(
                painted_label,
                text_area_width,
                font_size,
                font_family,
                font_weight,
                italic,
            ) + 8,
        );
        const element_nowrap = text_style.white_space == .nowrap;
        const text_height = if (element_nowrap)
            @max(base_text_height, resolveTextLineHeightPx(text_style.line_height, font_size) orelse 0)
        else
            estimateStyledTextHeight(
                painted_label,
                text_area_width,
                font_size,
                font_family,
                font_weight,
                italic,
                text_style.line_height,
            );
        var text_x = rect.x + padding.left + 6;
        const text_align = resolveCssPropertyValue(decl, self.page, element, "text-align");
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, text_align, &std.ascii.whitespace), "center")) {
            const measured_text_width = estimateStyledTextWidth(
                painted_label,
                font_size,
                font_family,
                font_weight,
                italic,
                text_style.letter_spacing,
                text_style.word_spacing,
            );
            text_x += @max(@as(i32, 0), @divTrunc(text_area_width - measured_text_width, 2));
        }
        const text_y = rect.y + padding.top + 4 + @divTrunc(@max(@as(i32, 0), text_height - base_text_height), 2);
        try self.list.addText(self.allocator, .{
            .x = text_x,
            .y = text_y,
            .width = text_area_width,
            .height = text_height,
            .z_index = paint_z_index,
            .font_size = font_size,
            .font_family = @constCast(font_family),
            .font_weight = font_weight,
            .italic = italic,
            .clip_rect = null,
            .opacity = opacity,
            .color = fg,
            .letter_spacing = text_style.letter_spacing,
            .word_spacing = text_style.word_spacing,
            .underline = shouldUnderlineText(element, decl, self.page, tag),
            .nowrap = element_nowrap,
            .text = @constCast(painted_label),
        });
        setControlRegionCommandSpan(
            self.list,
            control_region_index,
            replacement_command_start,
            self.list.commands.items.len,
        );
        return true;
    }

    fn hiddenBySpecifiedVisibilityChain(self: *Painter, element: *Element) !bool {
        var current: ?*Element = element;
        while (current) |candidate| {
            const decl = (try self.computedStyle(candidate)).asCSSStyleDeclaration();
            const specified = std.mem.trim(u8, decl.getSpecifiedPropertyValue("visibility", self.page), &std.ascii.whitespace);
            if (specified.len == 0 or std.ascii.eqlIgnoreCase(specified, "inherit")) {
                current = candidate.asNode().parentElement();
                continue;
            }
            if (std.ascii.eqlIgnoreCase(specified, "visible")) {
                return false;
            }
            if (std.ascii.eqlIgnoreCase(specified, "hidden") or std.ascii.eqlIgnoreCase(specified, "collapse")) {
                return true;
            }
            return false;
        }
        return false;
    }

    fn measureNodePaintedBox(self: *Painter, node: *Node, available_width: i32) !struct { width: i32, height: i32 } {
        const key = MeasurementKey{
            .node_ptr = @intFromPtr(node),
            .available_width = available_width,
            .forced_width = if (self.forced_item_node == node) self.forced_item_width else 0,
            .forced_height = if (self.forced_item_node == node) self.forced_item_height else 0,
        };
        if (self.measurement_cache.get(key)) |cached| {
            return .{ .width = cached.width, .height = cached.height };
        }

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
            .paint_text_styles = self.paint_text_styles,
            .measurement_cache = self.measurement_cache,
            .children_measurement_cache = self.children_measurement_cache,
            .computed_style_cache = self.computed_style_cache,
            .cache_layout_boxes = self.cache_layout_boxes,
        };
        var cursor = FlowCursor.init(0, 0, @max(@as(i32, 40), available_width));
        try temp_painter.paintNode(node, &cursor);

        if (displayListBounds(&temp_list)) |bounds| {
            const measured = MeasurementValue{
                .width = bounds.width,
                .height = bounds.height,
            };
            try self.measurement_cache.put(key, measured);
            return .{ .width = measured.width, .height = measured.height };
        }

        const measured = MeasurementValue{
            .width = @max(@as(i32, 0), cursor.cursor_x - cursor.left),
            .height = cursor.consumedHeightSince(0),
        };
        try self.measurement_cache.put(key, measured);
        return .{ .width = measured.width, .height = measured.height };
    }

    fn measureElementChildrenPaintedBox(self: *Painter, element: *Element, available_width: i32) !struct { width: i32, height: i32 } {
        const key = ChildrenMeasurementKey{
            .element_ptr = @intFromPtr(element),
            .available_width = available_width,
            .forced_node_ptr = if (self.forced_item_node) |node| @intFromPtr(node) else 0,
            .forced_width = self.forced_item_width,
            .forced_height = self.forced_item_height,
        };
        if (self.children_measurement_cache.get(key)) |cached| {
            return .{ .width = cached.width, .height = cached.height };
        }

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
            .paint_text_styles = self.paint_text_styles,
            .measurement_cache = self.measurement_cache,
            .children_measurement_cache = self.children_measurement_cache,
            .computed_style_cache = self.computed_style_cache,
            .cache_layout_boxes = self.cache_layout_boxes,
        };
        var cursor = FlowCursor.init(0, 0, @max(@as(i32, 40), available_width));
        var child_it = element.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (try isOutOfFlowNode(child, self.page)) {
                try out_of_flow_children.append(self.allocator, child);
                continue;
            }
            try temp_painter.paintNode(child, &cursor);
        }

        if (out_of_flow_children.items.len > 0) {
            var overlay_cursor = FlowCursor.init(0, 0, @max(@as(i32, 40), available_width));
            for (out_of_flow_children.items) |child| {
                try temp_painter.paintNode(child, &overlay_cursor);
            }
        }

        if (displayListBounds(&temp_list)) |bounds| {
            const measured = MeasurementValue{
                .width = bounds.width,
                .height = bounds.height,
            };
            try self.children_measurement_cache.put(key, measured);
            return .{
                .width = measured.width,
                .height = measured.height,
            };
        }

        const measured = MeasurementValue{
            .width = @max(@as(i32, 0), cursor.cursor_x - cursor.left),
            .height = cursor.consumedHeightSince(0),
        };
        try self.children_measurement_cache.put(key, measured);
        return .{
            .width = measured.width,
            .height = measured.height,
        };
    }

    fn appendDisplayListWithOffset(
        self: *Painter,
        source: *const DisplayList,
        dx: i32,
        dy: i32,
        parent_clip_rect: ?ClipRect,
    ) !void {
        const command_base = self.list.commands.items.len;
        try self.appendDisplayCommandsWithOffset(source, dx, dy, parent_clip_rect);

        for (source.link_regions.items) |region| {
            const shifted = Bounds{
                .x = region.x + dx,
                .y = region.y + dy,
                .width = region.width,
                .height = region.height,
            };
            if (intersectBoundsWithClipRect(shifted, parent_clip_rect)) |clipped| {
                try self.list.addLinkRegion(self.allocator, .{
                    .x = clipped.x,
                    .y = clipped.y,
                    .width = clipped.width,
                    .height = clipped.height,
                    .z_index = region.z_index,
                    .url = region.url,
                    .dom_path = region.dom_path,
                    .download_filename = region.download_filename,
                    .open_in_new_tab = region.open_in_new_tab,
                    .target_name = region.target_name,
                });
            }
        }

        for (source.control_regions.items) |region| {
            const shifted = Bounds{
                .x = region.x + dx,
                .y = region.y + dy,
                .width = region.width,
                .height = region.height,
            };
            if (intersectBoundsWithClipRect(shifted, parent_clip_rect)) |clipped| {
                var shifted_region = withControlRegionCommandOffset(region, source.commands.items.len, command_base);
                shifted_region.x = clipped.x;
                shifted_region.y = clipped.y;
                shifted_region.width = clipped.width;
                shifted_region.height = clipped.height;
                try self.list.addControlRegion(
                    self.allocator,
                    shifted_region,
                );
            }
        }
    }

    fn appendDisplayCommandsWithOffset(
        self: *Painter,
        source: *const DisplayList,
        dx: i32,
        dy: i32,
        parent_clip_rect: ?ClipRect,
    ) !void {
        for (source.commands.items) |command| {
            switch (command) {
                .fill_rect => |rect| try self.list.addFillRect(self.allocator, .{
                    .x = rect.x + dx,
                    .y = rect.y + dy,
                    .width = rect.width,
                    .height = rect.height,
                    .z_index = rect.z_index,
                    .corner_radius = rect.corner_radius,
                    .clip_rect = combineTranslatedClipRect(rect.clip_rect, dx, dy, parent_clip_rect),
                    .opacity = rect.opacity,
                    .color = rect.color,
                }),
                .stroke_rect => |rect| try self.list.addStrokeRect(self.allocator, .{
                    .x = rect.x + dx,
                    .y = rect.y + dy,
                    .width = rect.width,
                    .height = rect.height,
                    .z_index = rect.z_index,
                    .corner_radius = rect.corner_radius,
                    .clip_rect = combineTranslatedClipRect(rect.clip_rect, dx, dy, parent_clip_rect),
                    .opacity = rect.opacity,
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
                    .clip_rect = combineTranslatedClipRect(text.clip_rect, dx, dy, parent_clip_rect),
                    .opacity = text.opacity,
                    .color = text.color,
                    .letter_spacing = text.letter_spacing,
                    .word_spacing = text.word_spacing,
                    .underline = text.underline,
                    .nowrap = text.nowrap,
                    .text = text.text,
                }),
                .image => |image| try self.list.addImage(self.allocator, .{
                    .x = image.x + dx,
                    .y = image.y + dy,
                    .width = image.width,
                    .height = image.height,
                    .z_index = image.z_index,
                    .clip_rect = combineTranslatedClipRect(image.clip_rect, dx, dy, parent_clip_rect),
                    .draw_mode = image.draw_mode,
                    .object_fit = image.object_fit,
                    .object_position_x_mode = image.object_position_x_mode,
                    .object_position_y_mode = image.object_position_y_mode,
                    .object_position_x_percent_bp = image.object_position_x_percent_bp,
                    .object_position_y_percent_bp = image.object_position_y_percent_bp,
                    .object_position_x_offset = image.object_position_x_offset,
                    .object_position_y_offset = image.object_position_y_offset,
                    .background_offset_x = image.background_offset_x,
                    .background_offset_y = image.background_offset_y,
                    .background_position_x_mode = image.background_position_x_mode,
                    .background_position_y_mode = image.background_position_y_mode,
                    .background_position_x_percent_bp = image.background_position_x_percent_bp,
                    .background_position_y_percent_bp = image.background_position_y_percent_bp,
                    .background_size_mode = image.background_size_mode,
                    .background_size_width_mode = image.background_size_width_mode,
                    .background_size_height_mode = image.background_size_height_mode,
                    .background_size_width = image.background_size_width,
                    .background_size_height = image.background_size_height,
                    .background_size_width_percent_bp = image.background_size_width_percent_bp,
                    .background_size_height_percent_bp = image.background_size_height_percent_bp,
                    .repeat_x = image.repeat_x,
                    .repeat_y = image.repeat_y,
                    .opacity = image.opacity,
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
                    .clip_rect = combineTranslatedClipRect(canvas.clip_rect, dx, dy, parent_clip_rect),
                    .pixel_width = canvas.pixel_width,
                    .pixel_height = canvas.pixel_height,
                    .pixels = try self.allocator.dupe(u8, canvas.pixels),
                    .opacity = canvas.opacity,
                }),
            }
        }
    }

    fn appendDisplayListFontFaces(self: *Painter, source: *const DisplayList) !void {
        for (source.font_faces.items) |font_face| {
            try self.list.addFontFace(self.allocator, font_face);
        }
    }

    fn appendResolvedControlRegion(
        self: *Painter,
        element: *Element,
        rect: Bounds,
        paint_z_index: i32,
        command_start: usize,
    ) !void {
        if (try resolvedControlRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            if (rendererDiagnosticsEnabled(self.page)) {
                const id = element.getAttributeSafe(comptime .wrap("id")) orelse "";
                const class_name = element.getAttributeSafe(comptime .wrap("class")) orelse "";
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "add_control_region|tag={any}|id={s}|class={s}|x={d}|y={d}|w={d}|h={d}|path_len={d}",
                    .{ element.getTag(), id, class_name, region.x, region.y, region.width, region.height, region.dom_path.len },
                ) catch "";
                defer if (msg.len > 0) self.allocator.free(msg);
                appendRendererDiagnosticsLine("layout_box", msg);
            }
            try self.list.addControlRegion(
                self.allocator,
                withControlRegionCommandSpan(region, command_start, self.list.commands.items.len),
            );
        }
    }

    fn applyClipRectToRecentOutput(
        self: *Painter,
        command_start: usize,
        link_start: usize,
        control_start: usize,
        clip_rect: ClipRect,
    ) void {
        for (self.list.commands.items[command_start..]) |*command| {
            switch (command.*) {
                .fill_rect => |*rect| rect.clip_rect = if (rect.clip_rect) |existing|
                    intersectClipRects(existing, clip_rect) orelse emptyClipRect(clip_rect)
                else
                    clip_rect,
                .stroke_rect => |*rect| rect.clip_rect = if (rect.clip_rect) |existing|
                    intersectClipRects(existing, clip_rect) orelse emptyClipRect(clip_rect)
                else
                    clip_rect,
                .text => |*text| text.clip_rect = if (text.clip_rect) |existing|
                    intersectClipRects(existing, clip_rect) orelse emptyClipRect(clip_rect)
                else
                    clip_rect,
                .image => |*image| image.clip_rect = if (image.clip_rect) |existing|
                    intersectClipRects(existing, clip_rect) orelse emptyClipRect(clip_rect)
                else
                    clip_rect,
                .canvas => |*canvas| canvas.clip_rect = if (canvas.clip_rect) |existing|
                    intersectClipRects(existing, clip_rect) orelse emptyClipRect(clip_rect)
                else
                    clip_rect,
            }
        }

        var link_index = self.list.link_regions.items.len;
        while (link_index > link_start) {
            link_index -= 1;
            const region = self.list.link_regions.items[link_index];
            if (intersectBoundsWithClipRect(.{
                .x = region.x,
                .y = region.y,
                .width = region.width,
                .height = region.height,
            }, clip_rect)) |clipped| {
                self.list.link_regions.items[link_index].x = clipped.x;
                self.list.link_regions.items[link_index].y = clipped.y;
                self.list.link_regions.items[link_index].width = clipped.width;
                self.list.link_regions.items[link_index].height = clipped.height;
            } else {
                const removed = self.list.link_regions.orderedRemove(link_index);
                self.allocator.free(removed.url);
                self.allocator.free(removed.dom_path);
                self.allocator.free(removed.download_filename);
                self.allocator.free(removed.target_name);
            }
        }

        var control_index = self.list.control_regions.items.len;
        while (control_index > control_start) {
            control_index -= 1;
            const region = self.list.control_regions.items[control_index];
            if (intersectBoundsWithClipRect(.{
                .x = region.x,
                .y = region.y,
                .width = region.width,
                .height = region.height,
            }, clip_rect)) |clipped| {
                self.list.control_regions.items[control_index].x = clipped.x;
                self.list.control_regions.items[control_index].y = clipped.y;
                self.list.control_regions.items[control_index].width = clipped.width;
                self.list.control_regions.items[control_index].height = clipped.height;
            } else {
                const removed = self.list.control_regions.orderedRemove(control_index);
                self.allocator.free(removed.dom_path);
            }
        }
    }

    fn paintInlineFlowChildren(
        self: *Painter,
        element: *Element,
        content_x: i32,
        content_y: i32,
        content_width: i32,
        text_align_value: []const u8,
        opacity: u8,
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
            .paint_text_styles = self.paint_text_styles,
            .measurement_cache = self.measurement_cache,
            .children_measurement_cache = self.children_measurement_cache,
            .computed_style_cache = self.computed_style_cache,
            .cache_layout_boxes = self.cache_layout_boxes,
        };
        var child_cursor = FlowCursor.init(0, 0, @max(@as(i32, 40), content_width));
        var child_it = element.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (try isOutOfFlowNode(child, self.page)) {
                try out_of_flow_children.append(self.allocator, child);
                continue;
            }
            try temp_painter.paintNodeWithOpacity(child, &child_cursor, opacity);
        }

        const child_height = child_cursor.consumedHeightSince(0);
        const text_align = std.mem.trim(u8, text_align_value, &std.ascii.whitespace);
        const bounds = displayListBounds(&temp_list);
        if (bounds) |child_bounds| {
            try alignInlineFlowRows(&temp_list, self.allocator, content_width, text_align, child_bounds.x);
            try self.appendDisplayListWithOffset(&temp_list, content_x - child_bounds.x, content_y, null);
        } else {
            try self.appendDisplayListWithOffset(&temp_list, content_x, content_y, null);
        }
        if (self.cache_layout_boxes) {
            var child_it_translate = element.asNode().childrenIterator();
            while (child_it_translate.next()) |child| {
                if (bounds) |child_bounds| {
                    self.translateSubtreeLayoutBoxes(child, content_x - child_bounds.x, content_y);
                } else {
                    self.translateSubtreeLayoutBoxes(child, content_x, content_y);
                }
            }
        }
        if (out_of_flow_children.items.len > 0) {
            var overlay_cursor = FlowCursor.init(content_x, content_y, @max(@as(i32, 40), content_width));
            for (out_of_flow_children.items) |child| {
                try self.paintNodeWithOpacity(child, &overlay_cursor, opacity);
            }
        }
        return if (bounds) |child_bounds|
            @max(child_height, child_bounds.y + child_bounds.height)
        else
            child_height;
    }

    fn resolvePaintTextStyle(self: *Painter, element: *Element, decl: anytype, tag: Element.Tag) !PaintTextStyle {
        const key = @intFromPtr(element);
        if (self.paint_text_styles.get(key)) |cached| {
            return cached;
        }

        var resolved = PaintTextStyle{
            .font_size = defaultFontSize(tag),
            .font_family = "",
            .font_weight = 400,
            .italic = false,
            .color = .{ .r = 0, .g = 0, .b = 0 },
        };

        if (element.asNode().parentElement()) |parent| {
            const parent_style = try self.computedStyle(parent);
            resolved = try self.resolvePaintTextStyle(parent, parent_style.asCSSStyleDeclaration(), parent.getTag());
        }

        const raw_font_size = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("font-size", self.page));
        if (raw_font_size.len > 0) {
            resolved.font_size = parseFontSizePx(raw_font_size) orelse resolved.font_size;
        }

        const raw_line_height = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("line-height", self.page));
        if (raw_line_height.len > 0) {
            if (parseTextLineHeight(raw_line_height, resolved.font_size, self.opts.viewport_height)) |line_height| {
                resolved.line_height = line_height;
            }
        }

        const raw_font_family = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("font-family", self.page));
        if (raw_font_family.len > 0) {
            resolved.font_family = raw_font_family;
        }

        const raw_font_weight = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("font-weight", self.page));
        if (raw_font_weight.len > 0) {
            resolved.font_weight = parseCssFontWeight(raw_font_weight);
        }

        const raw_font_style = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("font-style", self.page));
        if (raw_font_style.len > 0) {
            resolved.italic = parseCssFontItalic(raw_font_style);
        }

        const raw_letter_spacing = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("letter-spacing", self.page));
        if (raw_letter_spacing.len > 0) {
            if (parseTextSpacingPx(raw_letter_spacing, resolved.font_size, self.opts.viewport_height)) |letter_spacing| {
                resolved.letter_spacing = letter_spacing;
            }
        }

        const raw_word_spacing = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("word-spacing", self.page));
        if (raw_word_spacing.len > 0) {
            if (parseTextSpacingPx(raw_word_spacing, resolved.font_size, self.opts.viewport_height)) |word_spacing| {
                resolved.word_spacing = word_spacing;
            }
        }

        const raw_text_transform = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("text-transform", self.page));
        if (raw_text_transform.len > 0) {
            if (parseTextTransform(raw_text_transform)) |text_transform| {
                resolved.text_transform = text_transform;
            }
        }

        const raw_white_space = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("white-space", self.page));
        if (raw_white_space.len > 0) {
            resolved.white_space = parseWhiteSpaceMode(raw_white_space);
        }

        const raw_color = normalizeInheritedTextPropertyValue(decl.getSpecifiedPropertyValue("color", self.page));
        if (parseCssColor(raw_color)) |color| {
            resolved.color = color;
        } else if (tag == .anchor and element.getAttributeSafe(comptime .wrap("href")) != null) {
            resolved.color = .{ .r = 0, .g = 102, .b = 204 };
        }

        try self.paint_text_styles.put(key, resolved);
        return resolved;
    }

    fn paintInlineTextNode(self: *Painter, cdata: *Node.CData, cursor: *FlowCursor, opacity: u8) anyerror!void {
        const parent = cdata.asNode().parentElement() orelse return;
        const parent_style = try self.computedStyle(parent);
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
        const parent_tag = parent.getTag();
        const text_style = try self.resolvePaintTextStyle(parent, parent_decl, parent_tag);
        const parent_nowrap = text_style.white_space == .nowrap;
        const painted_text = if (text_style.text_transform == .none) normalized else blk: {
            const transformed = try transformTextForPaint(self.allocator, normalized, text_style.text_transform);
            break :blk transformed;
        };
        defer if (text_style.text_transform != .none) self.allocator.free(painted_text);
        if (cursor.line_height <= 0 and std.mem.trim(u8, painted_text, " ").len == 0) {
            return;
        }
        const paint_z_index = try resolvePaintZIndex(parent, parent_decl, self.page);
        const underline = shouldUnderlineText(parent, parent_decl, self.page, parent_tag);
        const segment_gap = resolveStyledTextGap(text_style);
        if (parent_nowrap) {
            try self.paintInlineTextSegment(
                painted_text,
                text_style,
                parent_nowrap,
                cursor,
                paint_z_index,
                underline,
                0,
                opacity,
            );
            return;
        }

        var segment_start: usize = 0;
        while (segment_start < painted_text.len) {
            while (segment_start < painted_text.len and painted_text[segment_start] == ' ') : (segment_start += 1) {}
            if (segment_start >= painted_text.len) break;

            var segment_end = segment_start;
            while (segment_end < painted_text.len and painted_text[segment_end] != ' ') : (segment_end += 1) {}
            while (segment_end < painted_text.len and painted_text[segment_end] == ' ') : (segment_end += 1) {}

            try self.paintInlineTextSegment(
                painted_text[segment_start..segment_end],
                text_style,
                parent_nowrap,
                cursor,
                paint_z_index,
                underline,
                segment_gap,
                opacity,
            );
            segment_start = segment_end;
        }
    }

    fn paintInlineTextSegment(
        self: *Painter,
        segment: []const u8,
        text_style: PaintTextStyle,
        nowrap: bool,
        cursor: *FlowCursor,
        paint_z_index: i32,
        underline: bool,
        spacing: i32,
        opacity: u8,
    ) !void {
        if (segment.len == 0) return;

        const base_height = @max(
            text_style.font_size + 8,
            estimateTextHeight(segment, @max(@as(i32, 40), cursor.width), text_style.font_size, text_style.font_family, text_style.font_weight, text_style.italic) + 8,
        );
        const width = std.math.clamp(
            estimateStyledTextWidth(
                segment,
                text_style.font_size,
                text_style.font_family,
                text_style.font_weight,
                text_style.italic,
                text_style.letter_spacing,
                text_style.word_spacing,
            ),
            1,
            @max(@as(i32, 16), cursor.width),
        );
        const height = @max(base_height, resolveTextLineHeightPx(text_style.line_height, text_style.font_size) orelse 0);
        const pos = cursor.beginInlineLeaf(width, .{}, spacing);
        const text_y = pos.y + @divTrunc(@max(@as(i32, 0), height - base_height), 2);

        try self.list.addText(self.allocator, .{
            .x = pos.x,
            .y = text_y,
            .width = width,
            .height = height,
            .z_index = paint_z_index,
            .font_size = text_style.font_size,
            .font_family = @constCast(text_style.font_family),
            .font_weight = text_style.font_weight,
            .italic = text_style.italic,
            .color = text_style.color,
            .letter_spacing = text_style.letter_spacing,
            .word_spacing = text_style.word_spacing,
            .underline = underline,
            .opacity = opacity,
            .text = @constCast(segment),
            .nowrap = nowrap,
        });

        cursor.advanceInlineLeaf(.{ .x = pos.x, .y = text_y, .width = width, .height = height }, .{}, spacing);
    }

    fn paintElement(self: *Painter, element: *Element, cursor: *FlowCursor, opacity: u8) anyerror!void {
        const tag = element.getTag();
        var paint_timer: ?std.time.Timer = null;
        if (rendererDiagnosticsEnabled(self.page)) {
            paint_timer = try std.time.Timer.start();
        }
        defer if (paint_timer) |timer| {
            var mutable_timer = timer;
            const elapsed_ms = mutable_timer.read() / std.time.ns_per_ms;
            if (elapsed_ms >= 25) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "tag={any}|id={s}|class={s}|elapsed_ms={d}",
                    .{
                        tag,
                        element.getAttributeSafe(comptime .wrap("id")) orelse "",
                        element.getAttributeSafe(comptime .wrap("class")) orelse "",
                        elapsed_ms,
                    },
                ) catch "";
                defer if (msg.len > 0) self.allocator.free(msg);
                appendRendererDiagnosticsLine("paint_element_slow", msg);
            }
        };
        if (isNonRenderedTag(tag)) return;
        if (isHiddenFormControl(element)) return;

        const style = try self.computedStyle(element);
        const decl = style.asCSSStyleDeclaration();
        if (std.mem.eql(u8, decl.getPropertyValue("display", self.page), "none")) {
            return;
        }

        const text_style = try self.resolvePaintTextStyle(element, decl, tag);
        const font_size = text_style.font_size;
        if (tag == .br) {
            cursor.forceLineBreak(resolveTextLineHeightPx(text_style.line_height, font_size) orelse @max(font_size + 8, 20), 2);
            return;
        }

        const display = resolvedDisplayValue(decl, self.page, element);
        const raw_has_child_elements = hasRenderableChildElements(element);
        const canvas_surface_present = tag == .canvas and canvasSurfaceForElement(element) != null;
        const has_child_elements = raw_has_child_elements and !canvas_surface_present;
        const inline_atomic_box = isAtomicInlineDisplay(display);
        const block_like = isFlowBlockLike(tag, display, has_child_elements);
        const inline_leaf = !block_like and !inline_atomic_box and !has_child_elements;
        const inline_box = inline_leaf or inline_atomic_box;
        const margins = resolveEdgeSizes(decl, self.page, "margin");
        const padding = resolveEdgeSizes(decl, self.page, "padding");
        const font_family = text_style.font_family;
        const font_weight = text_style.font_weight;
        const italic = text_style.italic;
        const transform_value = std.mem.trim(u8, decl.getPropertyValue("transform", self.page), &std.ascii.whitespace);
        const element_command_start = self.list.commands.items.len;
        const element_link_start = self.list.link_regions.items.len;
        const element_control_start = self.list.control_regions.items.len;
        const inline_content_flow = (block_like or inline_atomic_box) and try usesInlineContentFlowContainer(element, decl, self.page, display);
        const position_value = resolveCssPropertyValue(decl, self.page, element, "position");
        const out_of_flow_positioned = isOutOfFlowPositioned(position_value);
        const specified_visibility_value = std.mem.trim(u8, decl.getSpecifiedPropertyValue("visibility", self.page), &std.ascii.whitespace);
        const visibility_value = std.mem.trim(u8, resolveCssPropertyValue(decl, self.page, element, "visibility"), &std.ascii.whitespace);
        const visibility_hidden = std.ascii.eqlIgnoreCase(visibility_value, "hidden") or
            std.ascii.eqlIgnoreCase(visibility_value, "collapse") or
            std.ascii.eqlIgnoreCase(specified_visibility_value, "hidden") or
            std.ascii.eqlIgnoreCase(specified_visibility_value, "collapse");
        if (try self.hiddenBySpecifiedVisibilityChain(element)) {
            return;
        }
        if (out_of_flow_positioned and visibility_hidden) {
            return;
        }
        const paint_z_index = try resolvePaintZIndex(element, decl, self.page);
        const element_opacity = resolvePaintOpacity(decl, self.page, element);
        const combined_opacity = multiplyOpacity(opacity, element_opacity);

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
            if (!canvas_surface_present) {
                var child_it = element.asNode().childrenIterator();
                while (child_it.next()) |child| {
                    if (child.is(Element)) |child_el| {
                        if (try self.isInlineAdornmentElement(child_el)) {
                            continue;
                        }
                    }
                    try self.paintNodeWithOpacity(child, cursor, combined_opacity);
                }
            }

            try self.appendInlineLinkRegionsForCommandRange(element, element_command_start);
            if (recentOutputBounds(self, element_command_start, element_link_start, element_control_start)) |bounds| {
                try self.recordElementLayoutBox(element, bounds);
            }
            if (transform_value.len > 0) {
                if (recentOutputBounds(self, element_command_start, element_link_start, element_control_start)) |bounds| {
                    applyTranslateTransformToRecentOutput(
                        self,
                        element_command_start,
                        element_link_start,
                        element_control_start,
                        transform_value,
                        bounds.width,
                        bounds.height,
                    );
                }
            }
            return;
        }

        const available_width = resolveAvailableWidthForElement(self, element, cursor.*, decl, margins, out_of_flow_positioned);
        var width = try resolveLayoutWidth(
            self,
            element,
            decl,
            self.page,
            tag,
            block_like,
            inline_atomic_box,
            has_child_elements,
            available_width,
            label,
            text_style,
        );
        if (width <= 0) {
            return;
        }
        const content_box_sizing = isContentBoxSizing(decl, self.page);
        const has_explicit_width = hasExplicitDimensionValue(decl, self.page, "width");
        const has_forced_height = self.forced_item_node == element.asNode() and self.forced_item_height > 0;
        const has_explicit_height = hasExplicitDimensionValue(decl, self.page, "height") or has_forced_height;
        const box_sizing_extra_width = if (content_box_sizing and has_explicit_width) padding.horizontal() else 0;
        const box_sizing_extra_height = if (content_box_sizing and has_explicit_height and !has_forced_height) padding.vertical() else 0;
        width += box_sizing_extra_width;

        const pos = if (out_of_flow_positioned)
            resolveOutOfFlowPosition(self, element, cursor.*, decl, margins, width)
        else if (inline_box)
            cursor.beginInlineLeaf(width, margins, 0)
        else
            cursor.beginBlock(margins);
        var x = pos.x;
        const y = pos.y;
        if (!inline_box) {
            x = resolveAutoMarginAlignedX(cursor.*, decl, self.page, width, margins, x);
        }
        if (out_of_flow_positioned and isFarOutsideViewport(x, y, width, self.opts.viewport_width, self.opts.viewport_height)) {
            return;
        }
        if (tag != .select and tag != .input and (block_like or inline_atomic_box) and isFlexDisplay(display)) {
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
                    combined_opacity,
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
                    combined_opacity,
                );
            if (inline_box) {
                cursor.advanceInlineLeaf(rect, margins, flowSpacingAfter(tag, block_like));
            } else {
                cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
            }
            if (transform_value.len > 0) {
                applyTranslateTransformToRecentOutput(
                    self,
                    element_command_start,
                    element_link_start,
                    element_control_start,
                    transform_value,
                    rect.width,
                    rect.height,
                );
            }
            return;
        }
        if ((block_like or inline_atomic_box) and isTableContainerDisplay(display)) {
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
                combined_opacity,
            );
            if (inline_box) {
                cursor.advanceInlineLeaf(rect, margins, flowSpacingAfter(tag, block_like));
            } else {
                cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
            }
            if (transform_value.len > 0) {
                applyTranslateTransformToRecentOutput(
                    self,
                    element_command_start,
                    element_link_start,
                    element_control_start,
                    transform_value,
                    rect.width,
                    rect.height,
                );
            }
            return;
        }
        if (inline_content_flow) {
            const child_command_start = self.list.commands.items.len;
            const child_link_start = self.list.link_regions.items.len;
            const child_control_start = self.list.control_regions.items.len;
            const child_height = if (!canvas_surface_present)
                try self.paintInlineFlowChildren(
                    element,
                    x + padding.left,
                    y + padding.top,
                    @max(@as(i32, 40), width - padding.left - padding.right),
                    resolveCssPropertyValue(decl, self.page, element, "text-align"),
                    combined_opacity,
                )
            else
                0;
            const explicit_height = resolveExplicitHeight(self, element, decl, self.page, tag, self.opts.viewport_height);
            const css_min_height = resolveCssMinHeightPx(self, element, decl, self.page, self.opts.viewport_height);
            const css_max_height = resolveCssMaxHeightPx(self, element, decl, self.page, self.opts.viewport_height);
            const min_required_height = @max(resolveMinimumHeight(self, tag, block_like, 0), css_min_height);
            const height = clampBoxHeight(
                min_required_height,
                css_max_height,
                if (has_explicit_height)
                    explicit_height + box_sizing_extra_height
                else
                    padding.top + child_height + padding.bottom,
            );
            const rect: Bounds = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            };
            try self.recordElementLayoutBox(element, rect);
            if (clipsOverflowContents(decl, self.page)) {
                self.applyClipRectToRecentOutput(
                    child_command_start,
                    child_link_start,
                    child_control_start,
                    clipRectFromBounds(rect),
                );
            }

            if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
                try self.list.addStrokeRect(self.allocator, .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = rect.height,
                    .z_index = paint_z_index,
                    .clip_rect = null,
                    .opacity = combined_opacity,
                    .color = stroke,
                });
            }
            try appendUnorderedListMarker(self, element, rect, padding, text_style, paint_z_index, combined_opacity);
            if (transform_value.len > 0) {
                applyTranslateTransformToRecentOutput(
                    self,
                    element_command_start,
                    element_link_start,
                    element_control_start,
                    transform_value,
                    rect.width,
                    rect.height,
                );
            }
            if (!out_of_flow_positioned) {
                if (inline_box) {
                    cursor.advanceInlineLeaf(rect, margins, flowSpacingAfter(tag, block_like));
                } else {
                    cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
                }
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
            text_style,
        );
        const background_color = parseCssColor(resolveCssPropertyValue(decl, self.page, element, "background-color"));
        const stroke_color = resolveStrokeColor(decl, self.page, tag);
        const raw_box_shadow = std.mem.trim(u8, decl.getPropertyValue("box-shadow", self.page), &std.ascii.whitespace);
        const raw_background_image = std.mem.trim(u8, decl.getPropertyValue("background-image", self.page), &std.ascii.whitespace);
        const has_box_shadow = raw_box_shadow.len > 0 and !std.ascii.eqlIgnoreCase(raw_box_shadow, "none");
        const has_background_image = raw_background_image.len > 0 and !std.ascii.eqlIgnoreCase(raw_background_image, "none");
        const has_paintable_background = if (background_color) |background|
            background.a > 0 and shouldPaintBackground(tag, has_child_elements)
        else
            false;
        const has_default_box_fill = background_color == null and switch (tag) {
            .input, .textarea, .button, .select, .img => true,
            else => false,
        };
        const clips_overflow = clipsOverflowContents(decl, self.page);
        const tracks_scroll_metrics = clips_overflow or self.page._element_scroll_positions.contains(element);
        const can_direct_paint_plain_block_children = has_child_elements and
            !canvas_surface_present and
            label.len == 0 and
            own_content_height == 0 and
            !inline_box and
            !out_of_flow_positioned and
            transform_value.len == 0 and
            !tracks_scroll_metrics and
            !has_box_shadow and
            !has_background_image and
            !has_paintable_background and
            stroke_color == null and
            !has_default_box_fill;

        const child_gap: i32 = if (has_child_elements and own_content_height > 0) 8 else 0;
        const child_indent = resolveChildIndent(tag, has_child_elements);
        const child_left = x + padding.left + child_indent;
        const child_containing_top = y + padding.top;
        const child_top = y + padding.top + own_content_height + child_gap;
        const child_width = @max(@as(i32, 40), width - padding.left - padding.right - child_indent);
        if (can_direct_paint_plain_block_children) {
            const child_height = try self.paintBlockChildrenWithFloats(
                element,
                child_left,
                child_containing_top,
                child_top,
                child_width,
                combined_opacity,
            );
            const explicit_height = resolveExplicitHeight(self, element, decl, self.page, tag, self.opts.viewport_height);
            const min_height = resolveMinimumHeight(self, tag, block_like, own_content_height);
            const css_min_height = resolveCssMinHeightPx(self, element, decl, self.page, self.opts.viewport_height);
            const css_max_height = resolveCssMaxHeightPx(self, element, decl, self.page, self.opts.viewport_height);
            const min_required_height = @max(min_height, css_min_height);
            const height = clampBoxHeight(
                min_required_height,
                css_max_height,
                if (has_explicit_height)
                    explicit_height + box_sizing_extra_height
                else
                    padding.top + own_content_height + child_gap + child_height + padding.bottom,
            );
            const rect: Bounds = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            };
            try self.recordElementLayoutBox(element, rect);
            if (try resolvedLinkRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
                try self.list.addLinkRegion(self.allocator, region);
            }
            try self.appendResolvedControlRegion(element, rect, paint_z_index, element_command_start);
            try appendUnorderedListMarker(self, element, rect, padding, text_style, paint_z_index, combined_opacity);
            cursor.advanceBlock(rect, margins, flowSpacingAfter(tag, block_like));
            return;
        }

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
                .paint_text_styles = self.paint_text_styles,
                .measurement_cache = self.measurement_cache,
                .children_measurement_cache = self.children_measurement_cache,
                .computed_style_cache = self.computed_style_cache,
                .cache_layout_boxes = self.cache_layout_boxes,
            };
            const height = try temp_painter.paintBlockChildrenWithFloats(
                element,
                child_left,
                child_containing_top,
                child_top,
                child_width,
                combined_opacity,
            );
            child_display_list = temp_list;
            break :child_height height;
        } else 0;
        const explicit_height = resolveExplicitHeight(self, element, decl, self.page, tag, self.opts.viewport_height);
        const min_height = resolveMinimumHeight(self, tag, block_like, own_content_height);
        const css_min_height = resolveCssMinHeightPx(self, element, decl, self.page, self.opts.viewport_height);
        const css_max_height = resolveCssMaxHeightPx(self, element, decl, self.page, self.opts.viewport_height);
        const min_required_height = @max(min_height, css_min_height);
        const height = clampBoxHeight(
            min_required_height,
            css_max_height,
            if (has_explicit_height)
                explicit_height + box_sizing_extra_height
            else
                padding.top + own_content_height + child_gap + child_height + padding.bottom,
        );

        const rect: Bounds = .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        };
        try self.recordElementLayoutBox(element, rect);
        const overflow_clip_rect = if (clips_overflow) clipRectFromBounds(rect) else null;

        const fg = text_style.color;
        const corner_radius = resolveBorderRadiusPx(decl, self.page, rect.width, rect.height, self.opts.viewport_width, self.opts.viewport_height);

        if (shouldPaintBox(tag)) {
            try appendResolvedBoxShadow(self, decl, rect, paint_z_index, combined_opacity, corner_radius, overflow_clip_rect);
            if (background_color) |background| {
                if (background.a > 0 and shouldPaintBackground(tag, has_child_elements)) {
                    try self.list.addFillRect(self.allocator, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                        .z_index = paint_z_index,
                        .corner_radius = corner_radius,
                        .clip_rect = null,
                        .opacity = combined_opacity,
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
                    .corner_radius = corner_radius,
                    .clip_rect = null,
                    .opacity = combined_opacity,
                    .color = .{ .r = 248, .g = 248, .b = 248 },
                });
            } else if (tag == .img) {
                try self.list.addFillRect(self.allocator, .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = rect.width,
                    .height = rect.height,
                    .z_index = paint_z_index,
                    .corner_radius = corner_radius,
                    .clip_rect = null,
                    .opacity = combined_opacity,
                    .color = .{ .r = 236, .g = 236, .b = 236 },
                });
            }
        }
        try appendResolvedBackgroundImage(self, decl, rect, paint_z_index, combined_opacity);

        if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
            try self.list.addStrokeRect(self.allocator, .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
                .z_index = paint_z_index,
                .corner_radius = corner_radius,
                .clip_rect = null,
                .opacity = combined_opacity,
                .color = stroke,
            });
        }

        const scrolled_command_start = self.list.commands.items.len;
        const scrolled_link_start = self.list.link_regions.items.len;
        const scrolled_control_start = self.list.control_regions.items.len;

        const image_command = if (tag == .img)
            try resolvedImageCommand(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index, combined_opacity)
        else
            null;
        const canvas_command = if (tag == .canvas)
            try resolvedCanvasCommand(self.allocator, element, rect.x, rect.y, rect.width, rect.height, paint_z_index, combined_opacity)
        else
            null;
        var iframe_display_list = if (tag == .iframe)
            try resolvedIFrameContentDisplayList(self.allocator, element, self.page, self.opts, rect.width, rect.height)
        else
            null;
        defer if (iframe_display_list) |*list| list.deinit(self.allocator);
        if (image_command) |command| {
            try self.list.addImage(self.allocator, command);
        }
        if (canvas_command) |command| {
            try self.list.addCanvas(self.allocator, command);
        }
        if (iframe_display_list) |*list| {
            const iframe_clip_rect = clipRectFromBounds(rect);
            try self.appendDisplayListFontFaces(list);
            try self.appendDisplayCommandsWithOffset(list, rect.x, rect.y, iframe_clip_rect);
        }

        if (label.len > 0 and shouldPaintText(tag) and image_command == null and canvas_command == null) {
            const text_area_width = @max(@as(i32, 40), rect.width - padding.horizontal() - 12);
            const painted_label = if (text_style.text_transform == .none) label else blk: {
                const transformed = try transformTextForPaint(self.allocator, label, text_style.text_transform);
                break :blk transformed;
            };
            defer if (text_style.text_transform != .none) self.allocator.free(painted_label);
            const base_text_height = @max(
                font_size + 8,
                estimateTextHeight(
                    painted_label,
                    text_area_width,
                    font_size,
                    font_family,
                    font_weight,
                    italic,
                ) + 8,
            );
            const element_nowrap = text_style.white_space == .nowrap;
            const text_height = if (element_nowrap)
                @max(base_text_height, resolveTextLineHeightPx(text_style.line_height, font_size) orelse 0)
            else
                estimateStyledTextHeight(
                    painted_label,
                    text_area_width,
                    font_size,
                    font_family,
                    font_weight,
                    italic,
                    text_style.line_height,
                );
            var text_x = rect.x + padding.left + 6;
            const text_align = resolveCssPropertyValue(decl, self.page, element, "text-align");
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, text_align, &std.ascii.whitespace), "center")) {
                const measured_text_width = estimateStyledTextWidth(
                    painted_label,
                    font_size,
                    font_family,
                    font_weight,
                    italic,
                    text_style.letter_spacing,
                    text_style.word_spacing,
                );
                text_x += @max(@as(i32, 0), @divTrunc(text_area_width - measured_text_width, 2));
            }
            const text_y = rect.y + padding.top + 4 + @divTrunc(@max(@as(i32, 0), text_height - base_text_height), 2);
            try self.list.addText(self.allocator, .{
                .x = text_x,
                .y = text_y,
                .width = text_area_width,
                .height = text_height,
                .z_index = paint_z_index,
                .font_size = font_size,
                .font_family = @constCast(font_family),
                .font_weight = font_weight,
                .italic = italic,
                .clip_rect = null,
                .opacity = combined_opacity,
                .color = fg,
                .letter_spacing = text_style.letter_spacing,
                .word_spacing = text_style.word_spacing,
                .underline = shouldUnderlineText(element, decl, self.page, tag),
                .nowrap = element_nowrap,
                .text = @constCast(painted_label),
            });
        }

        if (child_display_list) |*list| {
            try self.appendDisplayListWithOffset(list, 0, 0, null);
        }
        try appendUnorderedListMarker(self, element, rect, padding, text_style, paint_z_index, combined_opacity);

        if (tracks_scroll_metrics) {
            const content_box_width = @max(@as(i32, 0), rect.width - padding.horizontal());
            const content_box_height = @max(@as(i32, 0), rect.height - padding.vertical());
            const content_origin_x = rect.x + padding.left;
            const content_origin_y = rect.y + padding.top;
            const recent_bounds = recentOutputBounds(self, scrolled_command_start, scrolled_link_start, scrolled_control_start);
            const bounds_width = if (recent_bounds) |bounds|
                @max(@as(i32, 0), bounds.x + bounds.width - content_origin_x)
            else
                0;
            const bounds_height = if (recent_bounds) |bounds|
                @max(@as(i32, 0), bounds.y + bounds.height - content_origin_y)
            else
                0;
            const scroll_position = try trackElementScrollMetrics(
                self,
                element,
                content_box_width,
                content_box_height,
                @max(content_box_width, bounds_width),
                @max(@max(content_box_height, bounds_height), own_content_height + child_gap + child_height),
            );
            if (scroll_position.x > 0 or scroll_position.y > 0) {
                translateRecentOutput(
                    self,
                    scrolled_command_start,
                    scrolled_link_start,
                    scrolled_control_start,
                    -@as(i32, @intCast(scroll_position.x)),
                    -@as(i32, @intCast(scroll_position.y)),
                );
            }
        }

        if (overflow_clip_rect) |clip_rect| {
            self.applyClipRectToRecentOutput(
                scrolled_command_start,
                scrolled_link_start,
                scrolled_control_start,
                clip_rect,
            );
        }

        if (try resolvedLinkRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            try self.list.addLinkRegion(self.allocator, region);
        }
        try self.appendResolvedControlRegion(element, rect, paint_z_index, element_command_start);

        if (transform_value.len > 0) {
            applyTranslateTransformToRecentOutput(
                self,
                element_command_start,
                element_link_start,
                element_control_start,
                transform_value,
                rect.width,
                rect.height,
            );
        }
        if (out_of_flow_positioned) {
            return;
        }
        if (inline_box) {
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
        opacity: u8,
    ) !Bounds {
        const paint_z_index = try resolvePaintZIndex(element, decl, self.page);
        const content_width = @max(@as(i32, 40), width - padding.left - padding.right);
        const gap = resolveFlexGapPx(decl, self.page);
        const justify_content = std.mem.trim(u8, resolveCssPropertyValue(decl, self.page, element, "justify-content"), &std.ascii.whitespace);
        const align_items = std.mem.trim(u8, resolveCssPropertyValue(decl, self.page, element, "align-items"), &std.ascii.whitespace);
        const reverse_main_axis = flexDirectionIsReverse(decl, self.page);

        var measured_children: std.ArrayList(FlexChildMeasure) = .empty;
        defer measured_children.deinit(self.allocator);

        var child_total_height: i32 = 0;
        var child_it = element.asNode().childrenIterator();
        var child_index: usize = 0;
        while (child_it.next()) |child| : (child_index += 1) {
            if (!isFlexRenderableChild(child)) continue;

            var measured_width_override: ?i32 = null;
            var flex_grow: f32 = 0;
            var flex_shrink: f32 = 1;
            var order: i32 = 0;
            var align_self: FlexCrossAlignment = .auto;
            var min_height: i32 = 0;
            var max_height: ?i32 = null;
            var flex_basis: ?i32 = null;
            var child_margins: EdgeSizes = .{};
            if (child.is(Element)) |child_element| {
                const child_style = try self.computedStyle(child_element);
                const child_decl = child_style.asCSSStyleDeclaration();
                const child_tag = child_element.getTag();
                child_margins = resolveEdgeSizes(child_decl, self.page, "margin");
                flex_grow = resolveFlexGrow(child_decl, self.page);
                flex_shrink = resolveFlexShrink(child_decl, self.page);
                order = resolveFlexOrder(child_decl, self.page);
                align_self = resolveFlexCrossAlignment(resolveCssPropertyValue(child_decl, self.page, child_element, "align-self"));
                flex_basis = resolveFlexBasisHeightPx(self, child_element, child_decl, self.opts.viewport_height);
                min_height = resolveCssHeightConstraint(self, child_element, child_decl, self.page, "min-height", self.opts.viewport_height) orelse 0;
                max_height = resolveCssHeightConstraint(self, child_element, child_decl, self.page, "max-height", self.opts.viewport_height);
                const explicit_width = resolveExplicitWidth(self, child_element, child_decl, self.page, child_tag, content_width);
                if (explicit_width > 0) {
                    const child_padding = resolveEdgeSizes(child_decl, self.page, "padding");
                    const has_explicit_width = hasExplicitDimensionValue(child_decl, self.page, "width");
                    const box_sizing_extra_width = if (isContentBoxSizing(child_decl, self.page) and has_explicit_width)
                        child_padding.horizontal()
                    else
                        0;
                    const min_width = resolveWidthConstraintPx(child_decl, self.page, "min-width", "min-inline-size", content_width, self.opts.viewport_width) orelse 0;
                    const max_width = resolveWidthConstraintPx(child_decl, self.page, "max-width", "max-inline-size", content_width, self.opts.viewport_width);
                    var resolved_width = explicit_width + box_sizing_extra_width;
                    resolved_width = @max(resolved_width, min_width);
                    if (max_width) |limit| {
                        resolved_width = @min(resolved_width, limit);
                    }
                    measured_width_override = resolved_width;
                }
            }

            const measurement = try self.measureNodePaintedBox(child, content_width);
            if (measurement.width <= 0 and measurement.height <= 0) continue;

            var measured_height = flex_basis orelse measurement.height;
            measured_height = @max(measured_height, min_height);
            if (max_height) |limit| {
                measured_height = @min(measured_height, limit);
            }

            try measured_children.append(self.allocator, .{
                .node = child,
                .width = std.math.clamp(measured_width_override orelse measurement.width, @as(i32, 0), content_width),
                .height = measured_height,
                .margins = child_margins,
                .order = order,
                .flex_grow = flex_grow,
                .flex_shrink = flex_shrink,
                .align_self = align_self,
                .source_index = child_index,
            });
            child_total_height += measured_height + child_margins.vertical();
        }

        std.mem.sort(FlexChildMeasure, measured_children.items, {}, flexChildMeasureLessThan);
        if (reverse_main_axis) {
            std.mem.reverse(FlexChildMeasure, measured_children.items);
        }

        const gap_count = @max(@as(i32, 0), @as(i32, @intCast(measured_children.items.len)) - 1);
        const total_gap_height = gap * gap_count;
        const content_height = child_total_height + total_gap_height;
        const explicit_height = resolveExplicitHeight(self, element, decl, self.page, tag, self.opts.viewport_height);
        const min_height_css = resolveCssMinHeightPx(self, element, decl, self.page, self.opts.viewport_height);
        const max_height_css = resolveCssMaxHeightPx(self, element, decl, self.page, self.opts.viewport_height);
        const min_required_height = @max(resolveMinimumHeight(self, tag, block_like, 0), min_height_css);
        const has_forced_height = self.forced_item_node == element.asNode() and self.forced_item_height > 0;
        const has_explicit_height = hasExplicitDimensionValue(decl, self.page, "height") or has_forced_height;
        const box_sizing_extra_height = if (isContentBoxSizing(decl, self.page) and has_explicit_height and !has_forced_height) padding.vertical() else 0;

        const rect: Bounds = .{
            .x = x,
            .y = y,
            .width = width,
            .height = clampBoxHeight(
                min_required_height,
                max_height_css,
                if (has_forced_height)
                    self.forced_item_height
                else if (has_explicit_height)
                    explicit_height + box_sizing_extra_height
                else
                    padding.top + content_height + padding.bottom,
            ),
        };
        try self.recordElementLayoutBox(element, rect);
        const container_content_height = @max(@as(i32, 0), rect.height - padding.vertical());
        const bg = parseCssColor(resolveCssPropertyValue(decl, self.page, element, "background-color"));
        const corner_radius = resolveBorderRadiusPx(decl, self.page, rect.width, rect.height, self.opts.viewport_width, self.opts.viewport_height);
        if (shouldPaintBox(tag)) {
            try appendResolvedBoxShadow(self, decl, rect, paint_z_index, opacity, corner_radius, null);
            if (bg) |background| {
                if (background.a > 0 and shouldPaintBackground(tag, true)) {
                    try self.list.addFillRect(self.allocator, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                        .z_index = paint_z_index,
                        .corner_radius = corner_radius,
                        .clip_rect = null,
                        .opacity = opacity,
                        .color = background,
                    });
                }
            }
        }
        try appendResolvedBackgroundImage(self, decl, rect, paint_z_index, opacity);
        if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
            try self.list.addStrokeRect(self.allocator, .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
                .z_index = paint_z_index,
                .corner_radius = corner_radius,
                .clip_rect = null,
                .opacity = opacity,
                .color = stroke,
            });
        }

        const child_command_start = self.list.commands.items.len;
        const child_link_start = self.list.link_regions.items.len;
        const child_control_start = self.list.control_regions.items.len;
        var child_y = rect.y + padding.top;
        const free_vertical_space = @max(@as(i32, 0), container_content_height - content_height);
        var gap_between_items = gap;
        const justify_start = std.ascii.eqlIgnoreCase(justify_content, "flex-start") or
            std.ascii.eqlIgnoreCase(justify_content, "start") or
            std.ascii.eqlIgnoreCase(justify_content, "normal") or
            justify_content.len == 0;
        const justify_end = std.ascii.eqlIgnoreCase(justify_content, "flex-end") or std.ascii.eqlIgnoreCase(justify_content, "end");
        if (std.ascii.eqlIgnoreCase(justify_content, "center")) {
            child_y += @divTrunc(free_vertical_space, 2);
        } else if (justify_start) {
            if (reverse_main_axis) child_y += free_vertical_space;
        } else if (justify_end) {
            if (!reverse_main_axis) child_y += free_vertical_space;
        } else if (std.ascii.eqlIgnoreCase(justify_content, "space-between") and measured_children.items.len > 1) {
            gap_between_items += @divTrunc(free_vertical_space, @as(i32, @intCast(measured_children.items.len - 1)));
        } else if (std.ascii.eqlIgnoreCase(justify_content, "space-around") and measured_children.items.len > 0) {
            const extra = @divTrunc(free_vertical_space, @as(i32, @intCast(measured_children.items.len)));
            child_y += @divTrunc(extra, 2);
            gap_between_items += extra;
        } else if (std.ascii.eqlIgnoreCase(justify_content, "space-evenly") and measured_children.items.len > 0) {
            const extra = @divTrunc(free_vertical_space, @as(i32, @intCast(measured_children.items.len + 1)));
            child_y += extra;
            gap_between_items += extra;
        }

        var resolved_heights: std.ArrayList(i32) = .empty;
        defer resolved_heights.deinit(self.allocator);
        try resolved_heights.ensureTotalCapacity(self.allocator, measured_children.items.len);
        var total_flex_grow: f32 = 0;
        var total_shrink_weight: f64 = 0;
        for (measured_children.items) |child_measure| {
            try resolved_heights.append(self.allocator, child_measure.height);
            if (child_measure.flex_grow > 0) {
                total_flex_grow += child_measure.flex_grow;
            }
            if (child_measure.flex_shrink > 0) {
                total_shrink_weight += @as(f64, @floatFromInt(@max(@as(i32, 1), child_measure.height))) * @as(f64, @floatCast(child_measure.flex_shrink));
            }
        }

        if (content_height > container_content_height and total_shrink_weight > 0) {
            var remaining_shrink_space: i32 = content_height - container_content_height;
            var remaining_weight = total_shrink_weight;
            for (resolved_heights.items, 0..) |*child_height, local_index| {
                const child_measure = measured_children.items[local_index];
                const shrink_weight = @as(f64, @floatFromInt(@max(@as(i32, 1), child_measure.height))) * @as(f64, @floatCast(child_measure.flex_shrink));
                if (shrink_weight <= 0) continue;
                const extra = if (local_index + 1 == measured_children.items.len or remaining_weight <= shrink_weight)
                    remaining_shrink_space
                else
                    @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(content_height - container_content_height)) * (shrink_weight / total_shrink_weight))));
                child_height.* = @max(@as(i32, 0), child_height.* - extra);
                remaining_shrink_space -= extra;
                remaining_weight -= shrink_weight;
            }
        } else if (free_vertical_space > 0 and total_flex_grow > 0) {
            var remaining_grow_space: i32 = free_vertical_space;
            var remaining_grow_weight = total_flex_grow;
            for (resolved_heights.items, 0..) |*child_height, local_index| {
                const child_measure = measured_children.items[local_index];
                if (child_measure.flex_grow <= 0) continue;
                const extra = if (local_index + 1 == measured_children.items.len or remaining_grow_weight <= child_measure.flex_grow)
                    remaining_grow_space
                else
                    @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(free_vertical_space)) *
                        (@as(f64, @floatCast(child_measure.flex_grow)) / @as(f64, @floatCast(total_flex_grow))))));
                child_height.* += extra;
                remaining_grow_space -= extra;
                remaining_grow_weight -= child_measure.flex_grow;
            }
        }

        for (measured_children.items, 0..) |child_measure, index| {
            var child_x = rect.x + padding.left;
            var child_width = child_measure.width;
            const item_align = effectiveFlexCrossAlignment(align_items, child_measure.align_self);
            if (item_align == .stretch) {
                child_width = content_width;
            }
            const free_horizontal_space = @max(@as(i32, 0), content_width - (child_width + child_measure.margins.horizontal()));
            if (item_align == .center) {
                child_x += @divTrunc(free_horizontal_space, 2);
            } else if (item_align == .end) {
                child_x += free_horizontal_space;
            }

            const child_height = resolved_heights.items[index];
            var child_cursor = FlowCursor.init(child_x, child_y, @max(@as(i32, 40), child_width));
            const previous_forced_node = self.forced_item_node;
            const previous_forced_height = self.forced_item_height;
            self.forced_item_node = child_measure.node;
            self.forced_item_height = child_height;
            try self.paintNodeWithOpacity(child_measure.node, &child_cursor, opacity);
            self.forced_item_node = previous_forced_node;
            self.forced_item_height = previous_forced_height;

            child_y += child_height + child_measure.margins.vertical();
            if (index + 1 < measured_children.items.len) {
                child_y += gap_between_items;
            }
        }

        const overflow_clip_rect = if (clipsOverflowContents(decl, self.page)) clipRectFromBounds(rect) else null;
        const tracks_scroll_metrics = overflow_clip_rect != null or self.page._element_scroll_positions.contains(element);
        if (tracks_scroll_metrics) {
            const scroll_position = try trackElementScrollMetrics(
                self,
                element,
                content_width,
                container_content_height,
                content_width,
                content_height,
            );
            if (scroll_position.x > 0 or scroll_position.y > 0) {
                translateRecentOutput(
                    self,
                    child_command_start,
                    child_link_start,
                    child_control_start,
                    -@as(i32, @intCast(scroll_position.x)),
                    -@as(i32, @intCast(scroll_position.y)),
                );
            }
        }

        if (overflow_clip_rect) |clip_rect| {
            self.applyClipRectToRecentOutput(
                child_command_start,
                child_link_start,
                child_control_start,
                clip_rect,
            );
        }

        if (try resolvedLinkRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            try self.list.addLinkRegion(self.allocator, region);
        }
        try self.appendResolvedControlRegion(element, rect, paint_z_index, child_command_start);

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
        opacity: u8,
    ) !Bounds {
        const paint_z_index = try resolvePaintZIndex(element, decl, self.page);
        const content_width = @max(@as(i32, 40), width - padding.left - padding.right);
        const main_gap = resolveFlexRowMainGapPx(decl, self.page);
        const cross_gap = resolveFlexRowCrossGapPx(decl, self.page);
        const wrap_enabled = flexWrapEnabled(decl, self.page);
        const reverse_main_axis = flexDirectionIsReverse(decl, self.page);
        const justify_content = std.mem.trim(u8, resolveCssPropertyValue(decl, self.page, element, "justify-content"), &std.ascii.whitespace);
        const align_items = std.mem.trim(u8, resolveCssPropertyValue(decl, self.page, element, "align-items"), &std.ascii.whitespace);
        const align_content = resolveFlexAlignContent(resolveCssPropertyValue(decl, self.page, element, "align-content"));
        const specified_align_content = std.mem.trim(u8, decl.getSpecifiedPropertyValue("align-content", self.page), &std.ascii.whitespace);

        var measured_children: std.ArrayList(FlexChildMeasure) = .empty;
        defer measured_children.deinit(self.allocator);

        var child_it = element.asNode().childrenIterator();
        var child_index: usize = 0;
        while (child_it.next()) |child| : (child_index += 1) {
            if (!isFlexRenderableChild(child)) continue;

            var flex_grow: f32 = 0;
            var flex_shrink: f32 = 1;
            var align_self: FlexCrossAlignment = .auto;
            var flex_basis: ?i32 = null;
            var auto_main_width: ?i32 = null;
            var order: i32 = 0;
            var min_width: i32 = 0;
            var max_width: ?i32 = null;
            var child_margins: EdgeSizes = .{};
            if (child.is(Element)) |child_element| {
                const child_style = try self.computedStyle(child_element);
                const child_decl = child_style.asCSSStyleDeclaration();
                const child_display = resolvedDisplayValue(child_decl, self.page, child_element);
                child_margins = resolveEdgeSizes(child_decl, self.page, "margin");
                flex_grow = resolveFlexGrow(child_decl, self.page);
                flex_shrink = resolveFlexShrink(child_decl, self.page);
                align_self = resolveFlexCrossAlignment(resolveCssPropertyValue(child_decl, self.page, child_element, "align-self"));
                flex_basis = resolveFlexBasisPx(self, child_element, child_decl, content_width);
                order = resolveFlexOrder(child_decl, self.page);
                min_width = resolveWidthConstraintPx(child_decl, self.page, "min-width", "min-inline-size", content_width, self.opts.viewport_width) orelse 0;
                max_width = resolveWidthConstraintPx(child_decl, self.page, "max-width", "max-inline-size", content_width, self.opts.viewport_width);
                if (flex_basis == null and !hasSpecifiedDimensionValue(child_decl, self.page, "width") and isFlexDisplay(child_display)) {
                    const measured_auto_width = try measureFlexAutoMainWidth(self, child_element, child_decl, content_width);
                    if (measured_auto_width > 0) {
                        auto_main_width = measured_auto_width;
                    }
                }
            }

            const measurement = try self.measureNodePaintedBox(child, flex_basis orelse auto_main_width orelse content_width);
            if (measurement.width <= 0 and measurement.height <= 0) continue;

            var measured_width = flex_basis orelse auto_main_width orelse measurement.width;
            measured_width = @max(measured_width, min_width);
            if (max_width) |limit| {
                measured_width = @min(measured_width, limit);
            }

            try measured_children.append(self.allocator, .{
                .node = child,
                .width = std.math.clamp(measured_width, @as(i32, 0), content_width),
                .height = measurement.height,
                .margins = child_margins,
                .order = order,
                .flex_grow = flex_grow,
                .flex_shrink = flex_shrink,
                .align_self = align_self,
                .source_index = child_index,
            });
        }

        std.mem.sort(FlexChildMeasure, measured_children.items, {}, flexChildMeasureLessThan);
        if (reverse_main_axis) {
            std.mem.reverse(FlexChildMeasure, measured_children.items);
        }

        var lines: std.ArrayList(FlexLineMeasure) = .empty;
        defer lines.deinit(self.allocator);

        var line_start: usize = 0;
        var line_width: i32 = 0;
        var line_height: i32 = 0;
        var line_count: usize = 0;
        for (measured_children.items, 0..) |child_measure, index| {
            const child_outer_width = child_measure.outerWidth();
            const next_width = if (line_count == 0)
                child_outer_width
            else
                line_width + main_gap + child_outer_width;

            if (wrap_enabled and line_count > 0 and next_width > content_width) {
                try lines.append(self.allocator, .{
                    .start_index = line_start,
                    .end_index = index,
                    .width = line_width,
                    .height = line_height,
                });
                line_start = index;
                line_width = child_outer_width;
                line_height = child_measure.outerHeight();
                line_count = 1;
                continue;
            }

            line_width = next_width;
            line_height = @max(line_height, child_measure.outerHeight());
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
        const min_height_css = resolveCssMinHeightPx(self, element, decl, self.page, self.opts.viewport_height);
        const max_height_css = resolveCssMaxHeightPx(self, element, decl, self.page, self.opts.viewport_height);
        const min_required_height = @max(resolveMinimumHeight(self, tag, block_like, 0), min_height_css);
        const has_forced_height = self.forced_item_node == element.asNode() and self.forced_item_height > 0;
        const has_explicit_height = hasExplicitDimensionValue(decl, self.page, "height") or has_forced_height;
        const box_sizing_extra_height = if (isContentBoxSizing(decl, self.page) and has_explicit_height and !has_forced_height) padding.vertical() else 0;

        const rect: Bounds = .{
            .x = x,
            .y = y,
            .width = width,
            .height = clampBoxHeight(
                min_required_height,
                max_height_css,
                if (has_forced_height)
                    self.forced_item_height
                else if (has_explicit_height)
                    explicit_height + box_sizing_extra_height
                else
                    padding.top + content_height + padding.bottom,
            ),
        };
        try self.recordElementLayoutBox(element, rect);
        const container_content_height = @max(@as(i32, 0), rect.height - padding.vertical());
        const bg = parseCssColor(resolveCssPropertyValue(decl, self.page, element, "background-color"));
        const corner_radius = resolveBorderRadiusPx(decl, self.page, rect.width, rect.height, self.opts.viewport_width, self.opts.viewport_height);
        if (shouldPaintBox(tag)) {
            try appendResolvedBoxShadow(self, decl, rect, paint_z_index, opacity, corner_radius, null);
            if (bg) |background| {
                if (background.a > 0 and shouldPaintBackground(tag, true)) {
                    try self.list.addFillRect(self.allocator, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                        .z_index = paint_z_index,
                        .corner_radius = corner_radius,
                        .clip_rect = null,
                        .opacity = opacity,
                        .color = background,
                    });
                }
            }
        }
        try appendResolvedBackgroundImage(self, decl, rect, paint_z_index, opacity);
        if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
            try self.list.addStrokeRect(self.allocator, .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
                .z_index = paint_z_index,
                .corner_radius = corner_radius,
                .clip_rect = null,
                .opacity = opacity,
                .color = stroke,
            });
        }

        const child_command_start = self.list.commands.items.len;
        const child_link_start = self.list.link_regions.items.len;
        const child_control_start = self.list.control_regions.items.len;
        var child_y = rect.y + padding.top;
        var line_gap = cross_gap;
        var line_extra_height: i32 = 0;
        const free_vertical_space = @max(@as(i32, 0), container_content_height - content_height);
        if (lines.items.len > 1 and specified_align_content.len > 0) {
            if (std.ascii.eqlIgnoreCase(align_content, "center")) {
                child_y += @divTrunc(free_vertical_space, 2);
            } else if (std.ascii.eqlIgnoreCase(align_content, "flex-end") or std.ascii.eqlIgnoreCase(align_content, "end")) {
                child_y += free_vertical_space;
            } else if (std.ascii.eqlIgnoreCase(align_content, "space-between")) {
                line_gap += @divTrunc(free_vertical_space, @as(i32, @intCast(lines.items.len - 1)));
            } else if (std.ascii.eqlIgnoreCase(align_content, "space-around")) {
                const extra = @divTrunc(free_vertical_space, @as(i32, @intCast(lines.items.len)));
                child_y += @divTrunc(extra, 2);
                line_gap += extra;
            } else if (std.ascii.eqlIgnoreCase(align_content, "space-evenly")) {
                const extra = @divTrunc(free_vertical_space, @as(i32, @intCast(lines.items.len + 1)));
                child_y += extra;
                line_gap += extra;
            } else if (std.ascii.eqlIgnoreCase(align_content, "stretch")) {
                line_extra_height = @divTrunc(free_vertical_space, @as(i32, @intCast(lines.items.len)));
            }
        }

        for (lines.items, 0..) |line, line_index| {
            const item_count: i32 = @intCast(line.end_index - line.start_index);
            var resolved_widths: std.ArrayList(i32) = .empty;
            defer resolved_widths.deinit(self.allocator);
            try resolved_widths.ensureTotalCapacity(self.allocator, @intCast(item_count));
            var line_width_used: i32 = 0;
            var total_shrink_weight: f64 = 0;

            for (measured_children.items[line.start_index..line.end_index]) |child_measure| {
                try resolved_widths.append(self.allocator, child_measure.width);
                if (child_measure.flex_shrink > 0) {
                    total_shrink_weight += @as(f64, @floatFromInt(@max(@as(i32, 1), child_measure.width))) * @as(f64, @floatCast(child_measure.flex_shrink));
                }
            }

            if (line.width > content_width and total_shrink_weight > 0) {
                var remaining_shrink_space = line.width - content_width;
                var remaining_weight = total_shrink_weight;
                for (resolved_widths.items, 0..) |*child_width, local_index| {
                    const line_child_index = line.start_index + local_index;
                    const child_measure = measured_children.items[line_child_index];
                    const shrink_weight = @as(f64, @floatFromInt(@max(@as(i32, 1), child_measure.width))) * @as(f64, @floatCast(child_measure.flex_shrink));
                    if (shrink_weight <= 0) continue;
                    const extra = if (line_child_index + 1 == line.end_index or remaining_weight <= shrink_weight)
                        remaining_shrink_space
                    else
                        @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(line.width - content_width)) * (shrink_weight / total_shrink_weight))));
                    child_width.* = @max(@as(i32, 0), child_width.* - extra);
                    remaining_shrink_space -= extra;
                    remaining_weight -= shrink_weight;
                }
            }

            for (resolved_widths.items, 0..) |child_width, local_index| {
                line_width_used += child_width + measured_children.items[line.start_index + local_index].margins.horizontal();
            }
            if (item_count > 1) {
                line_width_used += main_gap * (item_count - 1);
            }

            const free_horizontal_space = @max(@as(i32, 0), content_width - line_width_used);
            var child_x = rect.x + padding.left;
            var gap = main_gap;
            var total_flex_grow: f32 = 0;

            const justify_start = std.ascii.eqlIgnoreCase(justify_content, "flex-start") or
                std.ascii.eqlIgnoreCase(justify_content, "start") or
                std.ascii.eqlIgnoreCase(justify_content, "normal") or
                justify_content.len == 0;
            const justify_end = std.ascii.eqlIgnoreCase(justify_content, "flex-end") or std.ascii.eqlIgnoreCase(justify_content, "end");
            if (std.ascii.eqlIgnoreCase(justify_content, "center")) {
                child_x += @divTrunc(free_horizontal_space, 2);
            } else if (justify_start) {
                if (reverse_main_axis) child_x += free_horizontal_space;
            } else if (justify_end) {
                if (!reverse_main_axis) child_x += free_horizontal_space;
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

            var line_child_index = line.start_index;
            while (line_child_index < line.end_index) : (line_child_index += 1) {
                const child_measure = measured_children.items[line_child_index];
                var child_width = resolved_widths.items[line_child_index - line.start_index];
                if (total_flex_grow > 0 and free_horizontal_space > 0 and child_measure.flex_grow > 0) {
                    const extra_width = if (line_child_index + 1 == line.end_index or remaining_flex_grow <= child_measure.flex_grow)
                        remaining_grow_space
                    else
                        @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(free_horizontal_space)) *
                            (@as(f64, @floatCast(child_measure.flex_grow)) / @as(f64, @floatCast(total_flex_grow))))));
                    child_width += extra_width;
                    remaining_grow_space -= extra_width;
                    remaining_flex_grow -= child_measure.flex_grow;
                }
                var item_y = child_y;
                const item_outer_height = child_measure.height + child_measure.margins.vertical();
                const item_free_vertical_space = @max(@as(i32, 0), (line.height + line_extra_height) - item_outer_height);
                const item_align = effectiveFlexCrossAlignment(align_items, child_measure.align_self);
                var item_forced_height: i32 = 0;
                if (item_align == .center) {
                    item_y += @divTrunc(item_free_vertical_space, 2);
                } else if (item_align == .end) {
                    item_y += item_free_vertical_space;
                } else if (item_align == .stretch) {
                    item_forced_height = @max(
                        child_measure.height,
                        @max(@as(i32, 0), line.height + line_extra_height - child_measure.margins.vertical()),
                    );
                }

                {
                    const previous_forced_node = self.forced_item_node;
                    const previous_forced_width = self.forced_item_width;
                    const previous_forced_height = self.forced_item_height;
                    self.forced_item_node = child_measure.node;
                    self.forced_item_width = child_width;
                    self.forced_item_height = item_forced_height;

                    var child_cursor = FlowCursor.init(child_x, item_y, @max(@as(i32, 40), child_width));
                    try self.paintNodeWithOpacity(child_measure.node, &child_cursor, opacity);

                    self.forced_item_node = previous_forced_node;
                    self.forced_item_width = previous_forced_width;
                    self.forced_item_height = previous_forced_height;
                }
                child_x += child_width + child_measure.margins.horizontal();
                if (line_child_index + 1 < line.end_index) {
                    child_x += gap;
                }
            }

            child_y += line.height + line_extra_height;
            if (line_index + 1 < lines.items.len) {
                child_y += line_gap;
            }
        }

        const overflow_clip_rect = if (clipsOverflowContents(decl, self.page)) clipRectFromBounds(rect) else null;
        const tracks_scroll_metrics = overflow_clip_rect != null or self.page._element_scroll_positions.contains(element);
        if (tracks_scroll_metrics) {
            const scroll_position = try trackElementScrollMetrics(
                self,
                element,
                content_width,
                container_content_height,
                content_width,
                content_height,
            );
            if (scroll_position.x > 0 or scroll_position.y > 0) {
                translateRecentOutput(
                    self,
                    child_command_start,
                    child_link_start,
                    child_control_start,
                    -@as(i32, @intCast(scroll_position.x)),
                    -@as(i32, @intCast(scroll_position.y)),
                );
            }
        }

        if (overflow_clip_rect) |clip_rect| {
            self.applyClipRectToRecentOutput(
                child_command_start,
                child_link_start,
                child_control_start,
                clip_rect,
            );
        }

        if (try resolvedLinkRegion(element, self.page, rect.x, rect.y, rect.width, rect.height, paint_z_index)) |region| {
            try self.list.addLinkRegion(self.allocator, region);
        }
        try self.appendResolvedControlRegion(element, rect, paint_z_index, child_command_start);

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
        opacity: u8,
    ) !i32 {
        var child_cursor = FlowCursor.init(child_left, child_top, child_width);
        var out_of_flow_children: std.ArrayList(*Node) = .{};
        defer out_of_flow_children.deinit(self.allocator);
        var float_left_x = child_left;
        var float_right_x = child_left + child_width;
        var float_row_y = child_top;
        var float_row_bottom = child_top;
        var float_active = false;
        const legacy_center = isLegacyCenterElement(element);
        const trace_children = rendererDiagnosticsEnabled(self.page) and switch (element.getTag()) {
            .body, .div => true,
            else => false,
        };

        var it = element.asNode().childrenIterator();
        while (it.next()) |child| {
            const child_command_start = self.list.commands.items.len;
            const child_link_start = self.list.link_regions.items.len;
            const child_control_start = self.list.control_regions.items.len;
            var legacy_center_width = child_width;
            var legacy_center_use_viewport_width = false;

            if (try isOutOfFlowNode(child, self.page)) {
                try out_of_flow_children.append(self.allocator, child);
                continue;
            }
            if (legacy_center) {
                if (child.is(Node.CData.Text)) |_| {
                    legacy_center_use_viewport_width = true;
                    legacy_center_width = @max(child_width, self.opts.viewport_width - (self.opts.page_margin * 2));
                } else if (child.is(Element)) |child_el| {
                    const child_style = try self.computedStyle(child_el);
                    const child_decl = child_style.asCSSStyleDeclaration();
                    const child_display = resolvedDisplayValue(child_decl, self.page, child_el);
                    if (isInlineDisplay(child_display) or isAtomicInlineDisplay(child_display)) {
                        legacy_center_use_viewport_width = true;
                        legacy_center_width = @max(child_width, self.opts.viewport_width - (self.opts.page_margin * 2));
                    }
                }
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
                        try self.paintNodeWithOpacity(child, &float_cursor, opacity);

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

            if (trace_children) {
                const msg = if (child.is(Element)) |child_el|
                    std.fmt.allocPrint(
                        self.allocator,
                        "parent={any}#{s}|before={any}#{s}",
                        .{
                            element.getTag(),
                            element.getAttributeSafe(comptime .wrap("id")) orelse "",
                            child_el.getTag(),
                            child_el.getAttributeSafe(comptime .wrap("id")) orelse "",
                        },
                    ) catch ""
                else
                    std.fmt.allocPrint(
                        self.allocator,
                        "parent={any}#{s}|before=node:{any}",
                        .{
                            element.getTag(),
                            element.getAttributeSafe(comptime .wrap("id")) orelse "",
                            child._type,
                        },
                    ) catch "";
                defer if (msg.len > 0) self.allocator.free(msg);
                appendRendererDiagnosticsLine("paint_block_child_before", msg);
            }
            try self.paintNodeWithOpacity(child, &child_cursor, opacity);
            if (trace_children) {
                const msg = if (child.is(Element)) |child_el|
                    std.fmt.allocPrint(
                        self.allocator,
                        "parent={any}#{s}|after={any}#{s}|cursor_y={d}|cursor_x={d}|line_height={d}",
                        .{
                            element.getTag(),
                            element.getAttributeSafe(comptime .wrap("id")) orelse "",
                            child_el.getTag(),
                            child_el.getAttributeSafe(comptime .wrap("id")) orelse "",
                            child_cursor.cursor_y,
                            child_cursor.cursor_x,
                            child_cursor.line_height,
                        },
                    ) catch ""
                else
                    std.fmt.allocPrint(
                        self.allocator,
                        "parent={any}#{s}|after=node:{any}|cursor_y={d}|cursor_x={d}|line_height={d}",
                        .{
                            element.getTag(),
                            element.getAttributeSafe(comptime .wrap("id")) orelse "",
                            child._type,
                            child_cursor.cursor_y,
                            child_cursor.cursor_x,
                            child_cursor.line_height,
                        },
                    ) catch "";
                defer if (msg.len > 0) self.allocator.free(msg);
                appendRendererDiagnosticsLine("paint_block_child_after", msg);
            }

            if (legacy_center) {
                if (recentOutputBounds(self, child_command_start, child_link_start, child_control_start)) |_| {
                    const center_width = if (legacy_center_use_viewport_width) legacy_center_width else child_width;
                    alignRecentOutputRows(
                        self,
                        child_command_start,
                        child_link_start,
                        child_control_start,
                        child_left,
                        center_width,
                    ) catch {};
                    if (recentOutputBounds(self, child_command_start, child_link_start, child_control_start)) |centered_bounds| {
                        const centered_x = child_left + @max(@as(i32, 0), @divTrunc(center_width - centered_bounds.width, 2));
                        const dx = centered_x - centered_bounds.x;
                        translateRecentOutput(self, child_command_start, child_link_start, child_control_start, dx, 0);
                        self.translateSubtreeLayoutBoxes(child, dx, 0);
                    }
                }
            }
        }

        if (float_active) {
            child_cursor.cursor_y = @max(child_cursor.cursor_y, float_row_bottom);
            child_cursor.cursor_x = child_cursor.left;
            child_cursor.line_height = 0;
        }

        if (out_of_flow_children.items.len > 0) {
            var overlay_cursor = FlowCursor.init(child_left, child_containing_top, child_width);
            for (out_of_flow_children.items) |child| {
                try self.paintNodeWithOpacity(child, &overlay_cursor, opacity);
            }
        }

        return child_cursor.consumedHeightSince(child_top);
    }

    fn resolveFloatPaintWidth(self: *Painter, element: *Element, available_width: i32) !i32 {
        const style = try self.computedStyle(element);
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
        opacity: u8,
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
                const cell_style = try self.computedStyle(cell);
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
                    try self.paintNodeWithOpacity(cell.asNode(), &cell_cursor, opacity);

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
        try self.recordElementLayoutBox(element, rect);

        const paint_z_index = try resolvePaintZIndex(element, decl, self.page);
        const corner_radius = resolveBorderRadiusPx(decl, self.page, rect.width, rect.height, self.opts.viewport_width, self.opts.viewport_height);
        try appendResolvedBoxShadow(self, decl, rect, paint_z_index, opacity, corner_radius, null);
        if (resolveStrokeColor(decl, self.page, tag)) |stroke| {
            try self.list.addStrokeRect(self.allocator, .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
                .z_index = paint_z_index,
                .corner_radius = corner_radius,
                .opacity = opacity,
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
                if (input._input_type == .hidden) {
                    return self.allocator.dupe(u8, "");
                }
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
                return switch (input._input_type) {
                    .text,
                    .password,
                    .email,
                    .url,
                    .tel,
                    .search,
                    .number,
                    .date,
                    .time,
                    .@"datetime-local",
                    .month,
                    .week,
                    => self.allocator.dupe(u8, ""),
                    else => self.allocator.dupe(u8, "[input]"),
                };
            },
            .textarea => {
                const textarea = element.as(Element.Html.TextArea);
                const current_value = textarea.getValue();
                if (element.getAttributeSafe(comptime .wrap("placeholder"))) |placeholder| {
                    if (current_value.len == 0) {
                        return self.allocator.dupe(u8, placeholder);
                    }
                }
                if (std.mem.trim(u8, current_value, &std.ascii.whitespace).len > 0) {
                    return collapseWhitespace(self.allocator, current_value);
                }
                return self.allocator.dupe(u8, "[textarea]");
            },
            .select => {
                const select = element.as(Element.Html.Select);
                const label = try select.getDisplayedTextAlloc(self.allocator, self.page);
                if (label.len > 0) {
                    return label;
                }
                self.allocator.free(label);
                return self.allocator.dupe(u8, "[control]");
            },
            .button, .option => {
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
        if (!isPureInlineDisplay(display)) {
            return false;
        }
        _ = margins;
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
                if (try self.isInlineAdornmentElement(child_el)) {
                    continue;
                }
                const child_style = try self.computedStyle(child_el);
                const child_decl = child_style.asCSSStyleDeclaration();
                const child_display = resolvedDisplayValue(child_decl, self.page, child_el);
                const child_atomic_inline = isAtomicInlineDisplay(child_display);
                if (!child_atomic_inline and !isInlineFlowDisplayForElement(child_el, child_display)) {
                    return false;
                }
                const child_has_children = hasRenderableChildElements(child_el);
                if (child_has_children and !child_atomic_inline) {
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

    fn isInlineAdornmentElement(self: *Painter, element: *Element) !bool {
        if (element._namespace == .svg) {
            return true;
        }

        var saw_adornment_descendant = false;
        var it = element.asNode().childrenIterator();
        while (it.next()) |child| {
            if (child.is(Node.CData.Text)) |text| {
                if (std.mem.trim(u8, text.getWholeText(), &std.ascii.whitespace).len > 0) {
                    return false;
                }
                continue;
            }
            if (child.is(Element)) |child_el| {
                if (isNonRenderedTag(child_el.getTag())) {
                    continue;
                }
                if (!(try self.isInlineAdornmentElement(child_el))) {
                    return false;
                }
                saw_adornment_descendant = true;
                continue;
            }
            return false;
        }

        return saw_adornment_descendant;
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
        const style = try self.computedStyle(element);
        const paint_z_index = try resolvePaintZIndex(element, style.asCSSStyleDeclaration(), self.page);
        for (fragments.items) |fragment| {
            if (rendererDiagnosticsEnabled(self.page)) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "add_link_region|href={s}|x={d}|y={d}|w={d}|h={d}|path_len={d}",
                    .{ href, fragment.x, fragment.y, fragment.width, fragment.height, dom_path.len },
                ) catch "";
                defer if (msg.len > 0) self.allocator.free(msg);
                appendRendererDiagnosticsLine("layout_box", msg);
            }
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
        .html, .body => false,
        else => !isNonRenderedTag(tag),
    };
}

fn isNonRenderedTag(tag: Element.Tag) bool {
    return switch (tag) {
        .head, .meta, .link, .script, .style, .template, .title, .noscript => true,
        else => false,
    };
}

fn isFarOutsideViewport(x: i32, y: i32, width: i32, viewport_width: i32, viewport_height: i32) bool {
    const slack = 256;
    return x + width < -slack or
        x > viewport_width + slack or
        y < -slack or
        y > viewport_height + slack;
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

fn normalizeInheritedTextPropertyValue(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "inherit")) {
        return "";
    }
    return trimmed;
}

fn parseTextLineHeight(value: []const u8, font_size: i32, viewport: i32) ?TextLineHeight {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "normal")) {
        return .normal;
    }
    if (std.mem.endsWith(u8, trimmed, "em") or std.mem.endsWith(u8, trimmed, "rem")) {
        const raw = trimmed[0 .. trimmed.len - 2];
        const multiplier = std.fmt.parseFloat(f32, raw) catch return null;
        return .{ .multiplier = multiplier };
    }
    if (std.mem.endsWith(u8, trimmed, "%")) {
        const raw = trimmed[0 .. trimmed.len - 1];
        const multiplier = std.fmt.parseFloat(f32, raw) catch return null;
        return .{ .multiplier = multiplier / 100.0 };
    }
    if (parseCssFloatValue(trimmed)) |multiplier| {
        if (std.mem.indexOfAny(u8, trimmed, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") == null) {
            return .{ .multiplier = multiplier };
        }
    }
    if (parseCssLengthPxWithContext(trimmed, font_size, viewport)) |px| {
        return .{ .px = px };
    }
    return null;
}

fn resolveTextLineHeightPx(line_height: TextLineHeight, font_size: i32) ?i32 {
    return switch (line_height) {
        .normal => null,
        .px => |px| @max(@as(i32, 0), px),
        .multiplier => |multiplier| blk: {
            if (!(multiplier > 0)) break :blk null;
            break :blk @max(@as(i32, 0), @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(font_size)) * @as(f64, multiplier)))));
        },
    };
}

fn parseTextSpacingPx(value: []const u8, font_size: i32, viewport: i32) ?i32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "normal")) return 0;
    if (std.mem.endsWith(u8, trimmed, "em") or std.mem.endsWith(u8, trimmed, "rem")) {
        const raw = trimmed[0 .. trimmed.len - 2];
        const multiplier = std.fmt.parseFloat(f32, raw) catch return null;
        return @max(@as(i32, 0), @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(font_size)) * @as(f64, multiplier)))));
    }
    if (parseCssLengthPxWithContext(trimmed, font_size, viewport)) |px| {
        return px;
    }
    return null;
}

fn parseTextTransform(value: []const u8) ?TextTransform {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "uppercase")) return .uppercase;
    if (std.ascii.eqlIgnoreCase(trimmed, "lowercase")) return .lowercase;
    if (std.ascii.eqlIgnoreCase(trimmed, "capitalize")) return .capitalize;
    return null;
}

fn parseWhiteSpaceMode(value: []const u8) WhiteSpaceMode {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "nowrap")) return .nowrap;
    return .normal;
}

fn whiteSpaceNowrap(decl: anytype, page: *Page) bool {
    return parseWhiteSpaceMode(decl.getPropertyValue("white-space", page)) == .nowrap;
}

fn transformTextForPaint(allocator: std.mem.Allocator, text: []const u8, transform: TextTransform) ![]u8 {
    return switch (transform) {
        .none => allocator.dupe(u8, text),
        .uppercase => blk: {
            const out = try allocator.dupe(u8, text);
            _ = std.ascii.upperString(out, out);
            break :blk out;
        },
        .lowercase => blk: {
            const out = try allocator.dupe(u8, text);
            _ = std.ascii.lowerString(out, out);
            break :blk out;
        },
        .capitalize => blk: {
            const out = try allocator.dupe(u8, text);
            var start_word = true;
            for (out) |*c| {
                if (std.ascii.isAlphabetic(c.*)) {
                    if (start_word) {
                        c.* = std.ascii.toUpper(c.*);
                        start_word = false;
                    }
                } else if (std.ascii.isWhitespace(c.*)) {
                    start_word = true;
                } else {
                    start_word = true;
                }
            }
            break :blk out;
        },
    };
}

fn countAsciiSpaces(text: []const u8) i32 {
    var count: i32 = 0;
    for (text) |c| {
        if (c == ' ') {
            count += 1;
        }
    }
    return count;
}

fn resolveTextSpacingGap(style: PaintTextStyle) i32 {
    _ = style;
    return 0;
}

fn appendUnorderedListMarker(
    self: *Painter,
    element: *Element,
    rect: Bounds,
    padding: EdgeSizes,
    text_style: PaintTextStyle,
    paint_z_index: i32,
    opacity: u8,
) !void {
    if (element.getTag() != .li) return;
    const parent = element.asNode().parentElement() orelse return;
    if (parent.getTag() != .ul) return;

    const marker_size = @max(@as(i32, 4), @divTrunc(text_style.font_size, 3));
    const marker_gap = @max(@as(i32, 8), marker_size + 4);
    const line_height = resolveTextLineHeightPx(text_style.line_height, text_style.font_size) orelse @max(text_style.font_size + 8, 20);
    const marker_y = rect.y + padding.top + @max(@as(i32, 0), @divTrunc(line_height - marker_size, 2));

    try self.list.addFillRect(self.allocator, .{
        .x = rect.x - marker_gap,
        .y = marker_y,
        .width = marker_size,
        .height = marker_size,
        .z_index = paint_z_index,
        .corner_radius = @divTrunc(marker_size, 2),
        .clip_rect = null,
        .opacity = opacity,
        .color = text_style.color,
    });
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

fn alignInlineFlowRows(
    list: *DisplayList,
    allocator: std.mem.Allocator,
    content_width: i32,
    text_align: []const u8,
    base_x: i32,
) !void {
    const centered = std.ascii.eqlIgnoreCase(text_align, "center");
    const right_aligned = std.ascii.eqlIgnoreCase(text_align, "right") or std.ascii.eqlIgnoreCase(text_align, "end");
    if (!centered and !right_aligned) return;

    var fragments = try collectCommandRowFragments(allocator, list.commands.items);
    defer fragments.deinit(allocator);
    if (fragments.items.len == 0) return;

    sortCommandRowFragments(fragments.items);
    for (fragments.items) |fragment| {
        const normalized_x = fragment.x - base_x;
        const target_x = if (centered)
            @max(@as(i32, 0), @divTrunc(content_width - fragment.width, 2))
        else
            @max(@as(i32, 0), content_width - fragment.width);
        const delta = target_x - normalized_x;
        if (delta == 0) continue;
        translateDisplayListRow(list, fragment, delta);
    }
}

fn alignRecentOutputRows(
    self: *Painter,
    command_start: usize,
    link_start: usize,
    control_start: usize,
    content_left: i32,
    content_width: i32,
) !void {
    var fragments = try collectCommandRowFragments(self.allocator, self.list.commands.items[command_start..]);
    defer fragments.deinit(self.allocator);
    if (fragments.items.len == 0) return;

    sortCommandRowFragments(fragments.items);
    for (fragments.items) |fragment| {
        const target_x = content_left + @max(@as(i32, 0), @divTrunc(content_width - fragment.width, 2));
        const delta = target_x - fragment.x;
        if (delta == 0) continue;
        translateRecentOutputRow(self, command_start, link_start, control_start, fragment, delta);
    }
}

fn translateDisplayListRow(list: *DisplayList, row: CommandBounds, dx: i32) void {
    for (list.commands.items) |*command| {
        const bounds = commandBounds(command.*) orelse continue;
        if (!commandBoundsShareInlineRow(bounds, row)) continue;
        switch (command.*) {
            .fill_rect => |*rect| rect.x += dx,
            .stroke_rect => |*rect| rect.x += dx,
            .text => |*text| text.x += dx,
            .image => |*image| image.x += dx,
            .canvas => |*canvas| canvas.x += dx,
        }
    }

    for (list.link_regions.items) |*region| {
        if (!commandBoundsShareInlineRow(.{
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
        }, row)) continue;
        region.x += dx;
    }

    for (list.control_regions.items) |*region| {
        if (!commandBoundsShareInlineRow(.{
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
        }, row)) continue;
        region.x += dx;
    }
}

fn translateRecentOutputRow(
    self: *Painter,
    command_start: usize,
    link_start: usize,
    control_start: usize,
    row: CommandBounds,
    dx: i32,
) void {
    for (self.list.commands.items[command_start..]) |*command| {
        const bounds = commandBounds(command.*) orelse continue;
        if (!commandBoundsShareInlineRow(bounds, row)) continue;
        switch (command.*) {
            .fill_rect => |*rect| rect.x += dx,
            .stroke_rect => |*rect| rect.x += dx,
            .text => |*text| text.x += dx,
            .image => |*image| image.x += dx,
            .canvas => |*canvas| canvas.x += dx,
        }
    }

    for (self.list.link_regions.items[link_start..]) |*region| {
        if (!commandBoundsShareInlineRow(.{
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
        }, row)) continue;
        region.x += dx;
    }

    for (self.list.control_regions.items[control_start..]) |*region| {
        if (!commandBoundsShareInlineRow(.{
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
        }, row)) continue;
        region.x += dx;
    }
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
    opacity: u8,
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
    const object_position = resolveObjectPosition(
        element,
        page,
        width,
        height,
        @as(i32, @intCast(page.window.getInnerWidth())),
        @as(i32, @intCast(page.window.getInnerHeight())),
    );
    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .z_index = z_index,
        .opacity = opacity,
        .url = @constCast(resolved),
        .alt = @constCast(alt),
        .object_fit = resolveObjectFit(element, page),
        .object_position_x_mode = object_position.x_mode,
        .object_position_y_mode = object_position.y_mode,
        .object_position_x_percent_bp = object_position.x_percent_bp,
        .object_position_y_percent_bp = object_position.y_percent_bp,
        .object_position_x_offset = object_position.x,
        .object_position_y_offset = object_position.y,
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
    opacity: u8,
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
        .opacity = opacity,
    };
}

const ImageRequestContext = struct {
    cookie_value: []u8 = &.{},
    referer_value: []u8 = &.{},
    authorization_value: []u8 = &.{},
};

const BackgroundPosition = struct {
    x: i32 = 0,
    y: i32 = 0,
    x_mode: ImageCommand.BackgroundPositionMode = .offset,
    y_mode: ImageCommand.BackgroundPositionMode = .offset,
    x_percent_bp: i32 = 0,
    y_percent_bp: i32 = 0,
};

const BackgroundSize = struct {
    mode: ImageCommand.BackgroundSizeMode = .natural,
    width_mode: ImageCommand.BackgroundSizeComponentMode = .auto,
    height_mode: ImageCommand.BackgroundSizeComponentMode = .auto,
    width: i32 = 0,
    height: i32 = 0,
    width_percent_bp: i32 = 0,
    height_percent_bp: i32 = 0,
};

const BackgroundRepeat = struct {
    x: bool = true,
    y: bool = true,
};

const ObjectFit = ImageCommand.ObjectFitMode;

const ObjectPosition = struct {
    x: i32 = 0,
    y: i32 = 0,
    x_mode: ImageCommand.BackgroundPositionMode = .center,
    y_mode: ImageCommand.BackgroundPositionMode = .center,
    x_percent_bp: i32 = 0,
    y_percent_bp: i32 = 0,
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

fn appendResolvedBackgroundImage(
    self: *Painter,
    decl: anytype,
    rect: anytype,
    z_index: i32,
    opacity: u8,
) !void {
    const raw_background_image = std.mem.trim(u8, decl.getPropertyValue("background-image", self.page), &std.ascii.whitespace);
    if (raw_background_image.len == 0 or std.ascii.eqlIgnoreCase(raw_background_image, "none")) {
        return;
    }

    const image_url = extractBackgroundImageUrl(raw_background_image) orelse return;
    const resolved = try URL.resolve(self.page.call_arena, self.page.base(), image_url, .{ .encode = true });
    const resolved_z = try self.page.call_arena.dupeZ(u8, resolved);
    const request_context = try resolveImageRequestContext(self.page, resolved_z);
    const repeat = resolveBackgroundRepeat(decl, self.page);
    const position = resolveBackgroundPosition(
        decl,
        self.page,
        rect.width,
        rect.height,
        self.opts.viewport_width,
        self.opts.viewport_height,
    );
    const size = resolveBackgroundSize(
        decl,
        self.page,
        rect.width,
        rect.height,
        self.opts.viewport_width,
        self.opts.viewport_height,
    );

    try self.list.addImage(self.allocator, .{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
        .z_index = z_index,
        .draw_mode = .background,
        .opacity = opacity,
        .background_offset_x = position.x,
        .background_offset_y = position.y,
        .background_position_x_mode = position.x_mode,
        .background_position_y_mode = position.y_mode,
        .background_position_x_percent_bp = position.x_percent_bp,
        .background_position_y_percent_bp = position.y_percent_bp,
        .background_size_mode = size.mode,
        .background_size_width_mode = size.width_mode,
        .background_size_height_mode = size.height_mode,
        .background_size_width = size.width,
        .background_size_height = size.height,
        .background_size_width_percent_bp = size.width_percent_bp,
        .background_size_height_percent_bp = size.height_percent_bp,
        .repeat_x = repeat.x,
        .repeat_y = repeat.y,
        .url = @constCast(resolved),
        .alt = @constCast(""),
        .request_include_credentials = true,
        .request_cookie_value = request_context.cookie_value,
        .request_referer_value = request_context.referer_value,
        .request_authorization_value = request_context.authorization_value,
    });
}

const BoxShadow = struct {
    offset_x: i32,
    offset_y: i32,
    blur: i32,
    spread: i32,
    color: Color,
};

fn appendResolvedBoxShadow(
    self: *Painter,
    decl: anytype,
    rect: Bounds,
    z_index: i32,
    opacity: u8,
    corner_radius: i32,
    clip_rect: ?ClipRect,
) !void {
    const raw_box_shadow = std.mem.trim(u8, decl.getPropertyValue("box-shadow", self.page), &std.ascii.whitespace);
    if (raw_box_shadow.len == 0 or std.ascii.eqlIgnoreCase(raw_box_shadow, "none")) {
        return;
    }

    const layer = firstBoxShadowLayer(raw_box_shadow);
    const shadow = parseBoxShadowLayer(layer) orelse return;
    const expansion = @max(@as(i32, 0), shadow.blur + shadow.spread);
    const width = rect.width + expansion * 2;
    const height = rect.height + expansion * 2;
    if (width <= 0 or height <= 0) {
        return;
    }

    if (shadow.color.a == 0) {
        return;
    }

    const shadow_opacity = shadow.color.a;
    const shadow_radius = @max(@as(i32, 0), corner_radius + shadow.spread + shadow.blur);
    try self.list.addFillRect(self.allocator, .{
        .x = rect.x + shadow.offset_x - expansion,
        .y = rect.y + shadow.offset_y - expansion,
        .width = width,
        .height = height,
        .z_index = z_index,
        .corner_radius = shadow_radius,
        .clip_rect = clip_rect,
        .opacity = @min(opacity, shadow_opacity),
        .color = shadow.color,
    });
}

fn firstBoxShadowLayer(raw_box_shadow: []const u8) []const u8 {
    var depth: i32 = 0;
    var quote: ?u8 = null;
    for (raw_box_shadow, 0..) |c, i| {
        if (quote) |q| {
            if (c == q and (i == 0 or raw_box_shadow[i - 1] != '\\')) {
                quote = null;
            }
            continue;
        }

        switch (c) {
            '"', '\'' => quote = c,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) return std.mem.trim(u8, raw_box_shadow[0..i], &std.ascii.whitespace);
            },
            else => {},
        }
    }
    return std.mem.trim(u8, raw_box_shadow, &std.ascii.whitespace);
}

fn parseBoxShadowLayer(raw_layer: []const u8) ?BoxShadow {
    const trimmed = std.mem.trim(u8, raw_layer, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "none")) {
        return null;
    }

    var terms: [8][]const u8 = undefined;
    var term_count: usize = 0;
    var start: ?usize = null;
    var depth: i32 = 0;
    var quote: ?u8 = null;

    for (trimmed, 0..) |c, i| {
        if (quote) |q| {
            if (c == q and (i == 0 or trimmed[i - 1] != '\\')) {
                quote = null;
            }
            if (start == null) start = i;
            continue;
        }

        switch (c) {
            '"', '\'' => {
                if (start == null) start = i;
                quote = c;
            },
            '(' => {
                if (start == null) start = i;
                depth += 1;
            },
            ')' => {
                if (start == null) start = i;
                if (depth > 0) depth -= 1;
            },
            ' ', '\t', '\r', '\n' => {
                if (depth == 0) {
                    if (start) |term_start| {
                        if (term_count == terms.len) return null;
                        const term = std.mem.trim(u8, trimmed[term_start..i], &std.ascii.whitespace);
                        if (term.len > 0) {
                            terms[term_count] = term;
                            term_count += 1;
                        }
                        start = null;
                    }
                }
            },
            else => {
                if (start == null) start = i;
            },
        }
    }

    if (start) |term_start| {
        if (term_count == terms.len) return null;
        const term = std.mem.trim(u8, trimmed[term_start..], &std.ascii.whitespace);
        if (term.len > 0) {
            terms[term_count] = term;
            term_count += 1;
        }
    }

    if (term_count < 2) {
        return null;
    }

    var inset = false;
    var color: ?Color = null;
    var lengths: [4]i32 = undefined;
    var length_count: usize = 0;

    for (terms[0..term_count]) |term| {
        if (std.ascii.eqlIgnoreCase(term, "inset")) {
            inset = true;
            continue;
        }
        if (color == null) {
            if (parseCssColor(term)) |parsed_color| {
                color = parsed_color;
                continue;
            }
        }
        if (length_count < lengths.len) {
            if (parseCssLengthPx(term)) |length| {
                lengths[length_count] = length;
                length_count += 1;
                continue;
            }
        }
        return null;
    }

    if (inset or length_count < 2) {
        return null;
    }

    return .{
        .offset_x = lengths[0],
        .offset_y = lengths[1],
        .blur = if (length_count >= 3) @max(@as(i32, 0), lengths[2]) else 0,
        .spread = if (length_count >= 4) lengths[3] else 0,
        .color = color orelse .{ .r = 0, .g = 0, .b = 0, .a = 96 },
    };
}

fn extractBackgroundImageUrl(raw_background_image: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_background_image, &std.ascii.whitespace);
    if (!std.ascii.startsWithIgnoreCase(trimmed, "url(") or trimmed.len < 5 or trimmed[trimmed.len - 1] != ')') {
        return null;
    }

    var inner = std.mem.trim(u8, trimmed[4 .. trimmed.len - 1], &std.ascii.whitespace);
    if (inner.len >= 2 and ((inner[0] == '"' and inner[inner.len - 1] == '"') or (inner[0] == '\'' and inner[inner.len - 1] == '\''))) {
        inner = inner[1 .. inner.len - 1];
    }
    return if (inner.len > 0) inner else null;
}

fn resolveBackgroundRepeat(decl: anytype, page: *Page) BackgroundRepeat {
    const raw = std.mem.trim(u8, decl.getPropertyValue("background-repeat", page), &std.ascii.whitespace);
    if (raw.len == 0) return .{};
    if (std.ascii.eqlIgnoreCase(raw, "no-repeat")) return .{ .x = false, .y = false };
    if (std.ascii.eqlIgnoreCase(raw, "repeat-x")) return .{ .x = true, .y = false };
    if (std.ascii.eqlIgnoreCase(raw, "repeat-y")) return .{ .x = false, .y = true };
    return .{};
}

fn resolveBackgroundPosition(
    decl: anytype,
    page: *Page,
    reference_width: i32,
    reference_height: i32,
    viewport_width: i32,
    viewport_height: i32,
) BackgroundPosition {
    const raw = std.mem.trim(u8, decl.getPropertyValue("background-position", page), &std.ascii.whitespace);
    if (raw.len == 0) return .{};

    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    const first = tokens.next() orelse return .{};
    const second = tokens.next();
    const first_axis = parseBackgroundPositionAxis(first, reference_width, reference_height, viewport_width, viewport_height) orelse return .{};
    const second_axis = if (second) |token|
        parseBackgroundPositionAxis(token, reference_width, reference_height, viewport_width, viewport_height)
    else
        null;

    var x_axis = BackgroundAxisPosition{};
    var y_axis = BackgroundAxisPosition{ .mode = .center };

    if (second_axis == null) {
        if (first_axis.prefers_y and !first_axis.prefers_x) {
            x_axis = .{ .mode = .center };
            y_axis = first_axis;
        } else if (first_axis.mode == .center) {
            x_axis = first_axis;
            y_axis = first_axis;
        } else {
            x_axis = first_axis;
        }
    } else {
        const second_value = second_axis.?;
        if ((first_axis.prefers_y and !first_axis.prefers_x) or (second_value.prefers_x and !second_value.prefers_y)) {
            x_axis = second_value;
            y_axis = first_axis;
        } else {
            x_axis = first_axis;
            y_axis = second_value;
        }
    }

    return .{
        .x = x_axis.offset,
        .y = y_axis.offset,
        .x_mode = x_axis.mode,
        .y_mode = y_axis.mode,
        .x_percent_bp = x_axis.percent_bp,
        .y_percent_bp = y_axis.percent_bp,
    };
}

fn resolveBackgroundSize(
    decl: anytype,
    page: *Page,
    reference_width: i32,
    reference_height: i32,
    viewport_width: i32,
    viewport_height: i32,
) BackgroundSize {
    const raw = std.mem.trim(u8, decl.getPropertyValue("background-size", page), &std.ascii.whitespace);
    if (raw.len == 0) return .{};
    if (std.ascii.eqlIgnoreCase(raw, "contain")) return .{ .mode = .contain };
    if (std.ascii.eqlIgnoreCase(raw, "cover")) return .{ .mode = .cover };

    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    const first = tokens.next() orelse return .{};
    const second = tokens.next();
    const width = parseBackgroundSizeComponent(first, reference_width, viewport_width) orelse return .{};
    const height = if (second) |token|
        parseBackgroundSizeComponent(token, reference_height, viewport_height)
    else
        null;

    return .{
        .mode = .explicit,
        .width_mode = width.mode,
        .height_mode = if (height) |value| value.mode else .auto,
        .width = width.value,
        .height = if (height) |value| value.value else 0,
        .width_percent_bp = width.percent_bp,
        .height_percent_bp = if (height) |value| value.percent_bp else 0,
    };
}

fn resolveObjectFit(element: *Element, page: *Page) ObjectFit {
    const raw = std.mem.trim(u8, resolveImageStyleValue(element, page, "object-fit"), &std.ascii.whitespace);
    if (raw.len == 0) return .fill;
    if (std.ascii.eqlIgnoreCase(raw, "contain")) return .contain;
    if (std.ascii.eqlIgnoreCase(raw, "cover")) return .cover;
    if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(raw, "scale-down") or std.ascii.eqlIgnoreCase(raw, "scaledown")) return .scale_down;
    return .fill;
}

fn resolveObjectPosition(
    element: *Element,
    page: *Page,
    reference_width: i32,
    reference_height: i32,
    viewport_width: i32,
    viewport_height: i32,
) ObjectPosition {
    const raw = std.mem.trim(u8, resolveImageStyleValue(element, page, "object-position"), &std.ascii.whitespace);
    if (raw.len == 0) return .{};

    var tokens = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    const first = tokens.next() orelse return .{};
    const second = tokens.next();
    const first_axis = parseBackgroundPositionAxis(first, reference_width, reference_height, viewport_width, viewport_height) orelse return .{};
    const second_axis = if (second) |token|
        parseBackgroundPositionAxis(token, reference_width, reference_height, viewport_width, viewport_height)
    else
        null;

    var x_axis = BackgroundAxisPosition{ .mode = .center };
    var y_axis = BackgroundAxisPosition{ .mode = .center };

    if (second_axis == null) {
        if (first_axis.prefers_y and !first_axis.prefers_x) {
            y_axis = first_axis;
        } else if (first_axis.mode == .center) {
            x_axis = first_axis;
            y_axis = first_axis;
        } else {
            x_axis = first_axis;
        }
    } else {
        const second_value = second_axis.?;
        if ((first_axis.prefers_y and !first_axis.prefers_x) or (second_value.prefers_x and !second_value.prefers_y)) {
            x_axis = second_value;
            y_axis = first_axis;
        } else {
            x_axis = first_axis;
            y_axis = second_value;
        }
    }

    return .{
        .x = x_axis.offset,
        .y = y_axis.offset,
        .x_mode = x_axis.mode,
        .y_mode = y_axis.mode,
        .x_percent_bp = x_axis.percent_bp,
        .y_percent_bp = y_axis.percent_bp,
    };
}

fn resolveImageStyleValue(element: *Element, page: *Page, property: []const u8) []const u8 {
    if (element.getAttributeSafe(comptime .wrap("style"))) |style_attr| {
        if (inlineStyleAttributeValue(style_attr, property)) |value| {
            return value;
        }
    }
    if (element.getOrCreateStyle(page)) |style| {
        const specified = style.asCSSStyleDeclaration().getSpecifiedPropertyValue(property, page);
        if (specified.len > 0) {
            return specified;
        }
    } else |_| {}

    const computed = page.window.getComputedStyle(element, null, page) catch return "";
    return computed.asCSSStyleDeclaration().getPropertyValue(property, page);
}

fn inlineStyleAttributeValue(style_attr: []const u8, property: []const u8) ?[]const u8 {
    var declarations = std.mem.tokenizeScalar(u8, style_attr, ';');
    while (declarations.next()) |declaration| {
        const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
        const name = std.mem.trim(u8, declaration[0..colon], &std.ascii.whitespace);
        if (!std.ascii.eqlIgnoreCase(name, property)) {
            continue;
        }
        return std.mem.trim(u8, declaration[colon + 1 ..], &std.ascii.whitespace);
    }
    return null;
}

fn parseAspectRatioValue(raw_value: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, raw_value, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "auto")) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash_index| {
        const left = std.mem.trim(u8, trimmed[0..slash_index], &std.ascii.whitespace);
        const right = std.mem.trim(u8, trimmed[slash_index + 1 ..], &std.ascii.whitespace);
        if (left.len == 0 or right.len == 0) return null;
        const numerator = std.fmt.parseFloat(f64, left) catch return null;
        const denominator = std.fmt.parseFloat(f64, right) catch return null;
        if (denominator == 0) return null;
        return numerator / denominator;
    }
    return std.fmt.parseFloat(f64, trimmed) catch null;
}

const BackgroundAxisPosition = struct {
    mode: ImageCommand.BackgroundPositionMode = .offset,
    offset: i32 = 0,
    percent_bp: i32 = 0,
    prefers_x: bool = true,
    prefers_y: bool = true,
};

fn parseBackgroundPositionAxis(
    token: []const u8,
    reference_width: i32,
    reference_height: i32,
    viewport_width: i32,
    viewport_height: i32,
) ?BackgroundAxisPosition {
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "left")) return .{ .mode = .offset, .offset = 0, .prefers_x = true, .prefers_y = false };
    if (std.ascii.eqlIgnoreCase(trimmed, "right")) return .{ .mode = .far, .prefers_x = true, .prefers_y = false };
    if (std.ascii.eqlIgnoreCase(trimmed, "top")) return .{ .mode = .offset, .offset = 0, .prefers_x = false, .prefers_y = true };
    if (std.ascii.eqlIgnoreCase(trimmed, "bottom")) return .{ .mode = .far, .prefers_x = false, .prefers_y = true };
    if (std.ascii.eqlIgnoreCase(trimmed, "center")) return .{ .mode = .center };
    if (std.mem.endsWith(u8, trimmed, "%")) {
        const raw = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], &std.ascii.whitespace);
        const percent = std.fmt.parseFloat(f64, raw) catch return null;
        return .{
            .mode = .percent,
            .percent_bp = @as(i32, @intFromFloat(@round(percent * 100.0))),
        };
    }
    return .{
        .mode = .offset,
        .offset = parseCssLengthPxWithContext(trimmed, reference_width, viewport_width) orelse
            parseCssLengthPxWithContext(trimmed, reference_height, viewport_height) orelse return null,
    };
}

const BackgroundSizeComponent = struct {
    mode: ImageCommand.BackgroundSizeComponentMode = .auto,
    value: i32 = 0,
    percent_bp: i32 = 0,
};

fn parseBackgroundSizeComponent(
    token: []const u8,
    reference: i32,
    viewport: i32,
) ?BackgroundSizeComponent {
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return .{ .mode = .auto };
    if (std.mem.endsWith(u8, trimmed, "%")) {
        const raw = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], &std.ascii.whitespace);
        const percent = std.fmt.parseFloat(f64, raw) catch return null;
        return .{
            .mode = .percent,
            .percent_bp = @as(i32, @intFromFloat(@round(percent * 100.0))),
        };
    }
    return .{
        .mode = .px,
        .value = parseCssLengthPxWithContext(trimmed, reference, viewport) orelse return null,
    };
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

fn resolveBorderRadiusPx(
    decl: anytype,
    page: *Page,
    box_width: i32,
    box_height: i32,
    viewport_width: i32,
    viewport_height: i32,
) i32 {
    const candidates = [_][]const u8{
        decl.getPropertyValue("border-radius", page),
        decl.getPropertyValue("border-top-left-radius", page),
        decl.getPropertyValue("border-top-right-radius", page),
        decl.getPropertyValue("border-bottom-right-radius", page),
        decl.getPropertyValue("border-bottom-left-radius", page),
    };
    const reference = @max(@as(i32, 1), @min(box_width, box_height));
    for (candidates) |candidate| {
        if (parseBorderRadiusPx(candidate, reference, viewport_width, viewport_height)) |radius| {
            return std.math.clamp(radius, 0, @divTrunc(reference, 2));
        }
    }
    return 0;
}

fn parseBorderRadiusPx(
    raw_value: []const u8,
    reference: i32,
    viewport_width: i32,
    viewport_height: i32,
) ?i32 {
    const trimmed = std.mem.trim(u8, raw_value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    const first_component = std.mem.trim(
        u8,
        if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash_index|
            trimmed[0..slash_index]
        else
            trimmed,
        &std.ascii.whitespace,
    );
    if (first_component.len == 0) return null;
    var tokens = std.mem.tokenizeAny(u8, first_component, " \t\r\n");
    const first_token = std.mem.trim(u8, tokens.next() orelse return null, &std.ascii.whitespace);
    if (first_token.len == 0) return null;
    return parseCssLengthPxWithContext(first_token, reference, viewport_width) orelse
        parseCssLengthPxWithContext(first_token, reference, viewport_height);
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

fn resolveBorderHorizontalPx(decl: anytype, page: *Page) i32 {
    const shorthand = parseBorderWidthPx(decl.getPropertyValue("border-width", page)) orelse 0;
    const left = parseBorderWidthPx(decl.getPropertyValue("border-left-width", page)) orelse shorthand;
    const right = parseBorderWidthPx(decl.getPropertyValue("border-right-width", page)) orelse shorthand;
    return left + right;
}

fn isContentBoxSizing(decl: anytype, page: *Page) bool {
    const box_sizing = std.mem.trim(u8, decl.getPropertyValue("box-sizing", page), &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(box_sizing, "content-box");
}

fn hasExplicitDimensionValue(decl: anytype, page: *Page, property_name: []const u8) bool {
    const logical_name = if (std.mem.eql(u8, property_name, "width"))
        "inline-size"
    else if (std.mem.eql(u8, property_name, "height"))
        "block-size"
    else
        property_name;
    const raw_value = std.mem.trim(u8, firstNonEmpty(&.{
        decl.getPropertyValue(property_name, page),
        decl.getPropertyValue(logical_name, page),
    }), &std.ascii.whitespace);
    return raw_value.len > 0 and !std.ascii.eqlIgnoreCase(raw_value, "auto");
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

fn isPureInlineDisplay(display: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, display, &std.ascii.whitespace), "inline");
}

fn isAtomicInlineDisplay(display: []const u8) bool {
    const trimmed = std.mem.trim(u8, display, &std.ascii.whitespace);
    return std.ascii.eqlIgnoreCase(trimmed, "inline-block") or
        std.ascii.eqlIgnoreCase(trimmed, "inline-flex") or
        std.ascii.eqlIgnoreCase(trimmed, "inline-table");
}

fn isLegacyCenterElement(element: *Element) bool {
    return std.ascii.eqlIgnoreCase(element.getTagNameLower(), "center");
}

fn isInlineFlowDisplayForElement(element: *Element, display: []const u8) bool {
    const trimmed = std.mem.trim(u8, display, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return isInlineDisplay(defaultDisplayForTag(element.getTag()));
    }
    return isInlineDisplay(trimmed);
}

fn hasRenderableChildElements(element: *Element) bool {
    if (element.getTag() == .select) {
        return false;
    }
    var it = element.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |child_el| {
            if (isNonRenderedTag(child_el.getTag())) continue;
            if (isHiddenFormControl(child_el)) continue;
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
            if (isNonRenderedTag(child_el.getTag())) continue;
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
    if (isPureInlineDisplay(trimmed)) {
        return has_child_elements;
    }
    if (isAtomicInlineDisplay(trimmed)) {
        return false;
    }
    if (std.mem.startsWith(u8, trimmed, "inline-")) {
        return false;
    }
    if (trimmed.len > 0) {
        return true;
    }

    return switch (tag) {
        .span, .anchor, .strong, .em, .code, .label, .option => false,
        else => true,
    };
}

test "paintDocument keeps inline-block tabs on one row when they contain block children" {
    var page = try testing.pageTest("page/inline_block_tabs_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    var search_text: ?TextCommand = null;
    var images_text: ?TextCommand = null;
    var maps_text: ?TextCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Search")) {
                    search_text = text;
                } else if (std.mem.eql(u8, text.text, "Images")) {
                    images_text = text;
                } else if (std.mem.eql(u8, text.text, "Maps")) {
                    maps_text = text;
                }
            },
            else => {},
        }
    }

    const search = search_text orelse return error.InlineBlockTabsSearchMissing;
    const images = images_text orelse return error.InlineBlockTabsImagesMissing;
    const maps = maps_text orelse return error.InlineBlockTabsMapsMissing;

    const search_images_dy = if (search.y > images.y) search.y - images.y else images.y - search.y;
    const images_maps_dy = if (images.y > maps.y) images.y - maps.y else maps.y - images.y;
    try std.testing.expect(search_images_dy <= 4);
    try std.testing.expect(images_maps_dy <= 4);
    try std.testing.expect(images.x > search.x + 40);
    try std.testing.expect(maps.x > images.x + 40);
}

test "paintDocument keeps inline-block wrappers on one row with nested block children" {
    var page = try testing.pageTest("page/inline_block_wrapper_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    var alpha_text: ?TextCommand = null;
    var beta_text: ?TextCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Alpha")) {
                    alpha_text = text;
                } else if (std.mem.eql(u8, text.text, "Beta")) {
                    beta_text = text;
                }
            },
            else => {},
        }
    }

    const alpha = alpha_text orelse return error.InlineBlockWrapperAlphaMissing;
    const beta = beta_text orelse return error.InlineBlockWrapperBetaMissing;

    const alpha_beta_dy = if (alpha.y > beta.y) alpha.y - beta.y else beta.y - alpha.y;
    try std.testing.expect(alpha_beta_dy <= 4);
    try std.testing.expect(beta.x > alpha.x + 40);
}

test "paintDocument shrink-wraps inline-block wrappers with nested block children" {
    var page = try testing.pageTest("page/inline_block_wrapper_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    var pill_rects = std.ArrayList(Bounds){};
    defer pill_rects.deinit(std.testing.allocator);
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r >= 210 and rect.color.r <= 220 and
                    rect.color.g >= 210 and rect.color.g <= 220 and
                    rect.color.b >= 210 and rect.color.b <= 220)
                {
                    try pill_rects.append(std.testing.allocator, .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                    });
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), pill_rects.items.len);
    try std.testing.expect(pill_rects.items[0].width >= 60);
    try std.testing.expect(pill_rects.items[0].width <= 120);
    try std.testing.expect(pill_rects.items[1].width >= 60);
    try std.testing.expect(pill_rects.items[1].width <= 120);
    try std.testing.expect(pill_rects.items[1].x >= pill_rects.items[0].x + pill_rects.items[0].width + 8);
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

    const insets = resolveInsetEdges(
        decl,
        self.page,
        context_width,
        self.opts.viewport_width,
        positioningContextHeight(
            self,
            element,
            positioningContextTop(element, cursor, resolveCssPropertyValue(decl, self.page, element, "position")),
            resolveCssPropertyValue(decl, self.page, element, "position"),
        ),
        self.opts.viewport_height,
    );
    if (insets.left != null and insets.right != null and resolveWidthPropertyValue(decl, self.page).len == 0) {
        return @max(@as(i32, 80), context_width - insets.left.? - insets.right.? - margins.horizontal());
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
    const insets = resolveInsetEdges(
        decl,
        self.page,
        context_width,
        self.opts.viewport_width,
        context_height,
        self.opts.viewport_height,
    );

    const x = if (insets.left) |value|
        context_left + value + margins.left
    else if (insets.right) |value|
        context_left + @max(@as(i32, 0), context_width - value - width - margins.right)
    else
        context_left + margins.left;

    const y = if (insets.top) |value|
        context_top + value + margins.top
    else if (insets.bottom) |value|
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

fn resolvePaintOpacity(decl: anytype, page: *Page, element: *Element) u8 {
    return parseCssOpacityByte(resolveCssPropertyValue(decl, page, element, "opacity")) orelse 255;
}

fn multiplyOpacity(base: u8, factor: u8) u8 {
    return @as(u8, @intCast((@as(u16, base) * @as(u16, factor) + 127) / 255));
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

fn flexDirectionValue(decl: anytype, page: *Page) []const u8 {
    return std.mem.trim(u8, decl.getPropertyValue("flex-direction", page), &std.ascii.whitespace);
}

fn flexDirectionIsReverse(decl: anytype, page: *Page) bool {
    const direction = flexDirectionValue(decl, page);
    return std.ascii.eqlIgnoreCase(direction, "row-reverse") or std.ascii.eqlIgnoreCase(direction, "column-reverse");
}

fn resolveFlexOrder(decl: anytype, page: *Page) i32 {
    if (parseCssIntegerValue(decl.getPropertyValue("order", page))) |value| {
        return value;
    }
    return 0;
}

fn resolveFlexShrink(decl: anytype, page: *Page) f32 {
    if (parseCssFloatValue(decl.getPropertyValue("flex-shrink", page))) |value| {
        return @max(@as(f32, 0), value);
    }

    const shorthand = std.mem.trim(u8, decl.getPropertyValue("flex", page), &std.ascii.whitespace);
    if (shorthand.len == 0) return 1;
    if (std.ascii.eqlIgnoreCase(shorthand, "none")) return 0;
    if (std.ascii.eqlIgnoreCase(shorthand, "auto") or std.ascii.eqlIgnoreCase(shorthand, "initial")) return 1;

    var it = std.mem.tokenizeAny(u8, shorthand, &std.ascii.whitespace);
    _ = it.next() orelse return 1;
    if (it.next()) |maybe_shrink| {
        if (parseCssFloatValue(maybe_shrink)) |value| {
            return @max(@as(f32, 0), value);
        }
    }
    return 1;
}

fn flexChildMeasureLessThan(_: void, lhs: FlexChildMeasure, rhs: FlexChildMeasure) bool {
    if (lhs.order != rhs.order) return lhs.order < rhs.order;
    return lhs.source_index < rhs.source_index;
}

fn resolveFlexAlignContent(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return "stretch";
    return trimmed;
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
        return !isNonRenderedTag(element.getTag());
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

fn hasSpecifiedDimensionValue(decl: anytype, page: *Page, property_name: []const u8) bool {
    const logical_name = if (std.mem.eql(u8, property_name, "width"))
        "inline-size"
    else if (std.mem.eql(u8, property_name, "height"))
        "block-size"
    else
        property_name;
    const raw_value = std.mem.trim(u8, firstNonEmpty(&.{
        decl.getSpecifiedPropertyValue(property_name, page),
        decl.getSpecifiedPropertyValue(logical_name, page),
    }), &std.ascii.whitespace);
    return raw_value.len > 0 and !std.ascii.eqlIgnoreCase(raw_value, "auto");
}

fn resolveFlexBasisPx(self: *const Painter, element: *Element, decl: anytype, available_width: i32) ?i32 {
    if (parseCssLengthPxWithContext(decl.getSpecifiedPropertyValue("flex-basis", self.page), available_width, self.opts.viewport_width)) |value| {
        return value;
    }

    const shorthand = std.mem.trim(u8, decl.getSpecifiedPropertyValue("flex", self.page), &std.ascii.whitespace);
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

    if (parseCssLengthPxWithContext(
        firstNonEmpty(&.{
            decl.getSpecifiedPropertyValue("width", self.page),
            decl.getSpecifiedPropertyValue("inline-size", self.page),
        }),
        available_width,
        self.opts.viewport_width,
    )) |value| {
        return value;
    }
    _ = element;
    return null;
}

fn resolveFlexBasisHeightPx(self: *const Painter, element: *Element, decl: anytype, available_height: i32) ?i32 {
    if (parseCssLengthPxWithContext(decl.getSpecifiedPropertyValue("flex-basis", self.page), available_height, self.opts.viewport_height)) |value| {
        return value;
    }

    const shorthand = std.mem.trim(u8, decl.getSpecifiedPropertyValue("flex", self.page), &std.ascii.whitespace);
    if (shorthand.len != 0 and !std.ascii.eqlIgnoreCase(shorthand, "none") and !std.ascii.eqlIgnoreCase(shorthand, "auto")) {
        var parts = std.mem.tokenizeAny(u8, shorthand, &std.ascii.whitespace);
        _ = parts.next();
        if (parts.next()) |maybe_shrink| {
            _ = maybe_shrink;
            if (parts.next()) |basis_token| {
                if (parseCssLengthPxWithContext(basis_token, available_height, self.opts.viewport_height)) |value| {
                    return value;
                }
            }
        }
    }

    if (parseCssLengthPxWithContext(
        firstNonEmpty(&.{
            decl.getSpecifiedPropertyValue("height", self.page),
            decl.getSpecifiedPropertyValue("block-size", self.page),
        }),
        available_height,
        self.opts.viewport_height,
    )) |value| {
        return value;
    }
    _ = element;
    return null;
}

fn resolveFlexCrossAlignment(value: []const u8) FlexCrossAlignment {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(trimmed, "center")) return .center;
    if (std.ascii.eqlIgnoreCase(trimmed, "flex-end") or std.ascii.eqlIgnoreCase(trimmed, "end")) return .end;
    if (std.ascii.eqlIgnoreCase(trimmed, "flex-start") or std.ascii.eqlIgnoreCase(trimmed, "start")) return .start;
    if (std.ascii.eqlIgnoreCase(trimmed, "stretch")) return .stretch;
    return .auto;
}

fn effectiveFlexCrossAlignment(container_align_items: []const u8, align_self: FlexCrossAlignment) FlexCrossAlignment {
    if (align_self != .auto) return align_self;
    return resolveFlexCrossAlignment(container_align_items);
}

fn resolveAutoMarginAlignedX(cursor: FlowCursor, decl: anytype, page: *Page, width: i32, margins: EdgeSizes, default_x: i32) i32 {
    const margin_left = firstNonEmpty(&.{
        decl.getPropertyValue("margin-left", page),
        decl.getPropertyValue("margin-inline-start", page),
    });
    const margin_right = firstNonEmpty(&.{
        decl.getPropertyValue("margin-right", page),
        decl.getPropertyValue("margin-inline-end", page),
    });
    const margin_shorthand = decl.getPropertyValue("margin", page);
    const margin_inline_shorthand = decl.getPropertyValue("margin-inline", page);
    const auto_left = isCssAuto(margin_left) or (margin_left.len == 0 and (edgeShorthandContainsAuto(margin_shorthand, .left) or axisPairShorthandContainsAuto(margin_inline_shorthand, .start)));
    const auto_right = isCssAuto(margin_right) or (margin_right.len == 0 and (edgeShorthandContainsAuto(margin_shorthand, .right) or axisPairShorthandContainsAuto(margin_inline_shorthand, .end)));
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
    var resolved = parseCssEdgeShorthand(shorthand);
    const block_pair = parseCssAxisPairShorthand(decl.getPropertyValue(prefix ++ "-block", page));
    const inline_pair = parseCssAxisPairShorthand(decl.getPropertyValue(prefix ++ "-inline", page));
    if (block_pair.specified) {
        resolved.top = block_pair.start;
        resolved.bottom = block_pair.end;
    }
    if (inline_pair.specified) {
        resolved.left = inline_pair.start;
        resolved.right = inline_pair.end;
    }
    return .{
        .top = parseCssLengthPx(firstNonEmpty(&.{
            decl.getPropertyValue(prefix ++ "-top", page),
            decl.getPropertyValue(prefix ++ "-block-start", page),
        })) orelse resolved.top,
        .right = parseCssLengthPx(firstNonEmpty(&.{
            decl.getPropertyValue(prefix ++ "-right", page),
            decl.getPropertyValue(prefix ++ "-inline-end", page),
        })) orelse resolved.right,
        .bottom = parseCssLengthPx(firstNonEmpty(&.{
            decl.getPropertyValue(prefix ++ "-bottom", page),
            decl.getPropertyValue(prefix ++ "-block-end", page),
        })) orelse resolved.bottom,
        .left = parseCssLengthPx(firstNonEmpty(&.{
            decl.getPropertyValue(prefix ++ "-left", page),
            decl.getPropertyValue(prefix ++ "-inline-start", page),
        })) orelse resolved.left,
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
    self: *Painter,
    element: *Element,
    decl: anytype,
    page: *Page,
    tag: Element.Tag,
    block_like: bool,
    inline_atomic_box: bool,
    has_child_elements: bool,
    available_width: i32,
    label: []const u8,
    text_style: PaintTextStyle,
) !i32 {
    const font_size = text_style.font_size;
    const font_family = text_style.font_family;
    const font_weight = text_style.font_weight;
    const italic = text_style.italic;
    const painted_label = if (text_style.text_transform == .none) label else blk: {
        const transformed = try transformTextForPaint(self.allocator, label, text_style.text_transform);
        break :blk transformed;
    };
    defer if (text_style.text_transform != .none) self.allocator.free(painted_label);
    const explicit_width = resolveExplicitWidth(self, element, decl, page, tag, available_width);
    const explicit_height = resolveExplicitHeight(self, element, decl, page, tag, self.opts.viewport_height);
    const intrinsic_image = if (tag == .img) resolveIntrinsicImageDimensions(element, page) else null;
    const aspect_ratio = parseAspectRatioValue(resolveImageStyleValue(element, page, "aspect-ratio"));
    const min_width = resolveWidthConstraintPx(decl, page, "min-width", "min-inline-size", available_width, self.opts.viewport_width) orelse 0;
    const max_width = resolveWidthConstraintPx(decl, page, "max-width", "max-inline-size", available_width, self.opts.viewport_width);
    if (self.forced_item_node == element.asNode() and self.forced_item_width > 0) {
        var forced = std.math.clamp(self.forced_item_width, 60, available_width);
        forced = @max(forced, min_width);
        if (max_width) |limit| forced = @min(forced, limit);
        return forced;
    }

    if (tag == .img) {
        var resolved_image_width = explicit_width;
        if (resolved_image_width <= 0) {
            if (explicit_height > 0) {
                if (aspect_ratio) |ratio| {
                    resolved_image_width = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(explicit_height)) * ratio))));
                } else if (intrinsic_image) |dims| {
                    resolved_image_width = if (dims.height > 0)
                        @max(1, @divTrunc(dims.width * explicit_height, dims.height))
                    else
                        dims.width;
                } else {
                    resolved_image_width = 180;
                }
            } else if (intrinsic_image) |dims| {
                resolved_image_width = dims.width;
            } else {
                resolved_image_width = 180;
            }
        }
        resolved_image_width = @max(resolved_image_width, min_width);
        if (max_width) |limit| resolved_image_width = @min(resolved_image_width, limit);
        return std.math.clamp(resolved_image_width, 1, available_width);
    }

    const position_value = resolveCssPropertyValue(decl, page, element, "position");
    const out_of_flow_positioned = isOutOfFlowPositioned(position_value);
    const insets = resolveInsetEdges(
        decl,
        page,
        available_width,
        self.opts.viewport_width,
        self.opts.viewport_height,
        self.opts.viewport_height,
    );
    const has_left_constraint = insets.left != null;
    const has_right_constraint = insets.right != null;
    if (block_like) {
        const shrink_to_fit_out_of_flow = out_of_flow_positioned and explicit_width <= 0 and !(has_left_constraint and has_right_constraint);
        var measured_auto_width: i32 = 0;
        if (shrink_to_fit_out_of_flow) {
            if (rendererDiagnosticsEnabled(self.page)) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "before_measure_out_of_flow|tag={any}|id={s}|class={s}|available_width={d}|position={s}",
                    .{
                        tag,
                        element.getAttributeSafe(comptime .wrap("id")) orelse "",
                        element.getAttributeSafe(comptime .wrap("class")) orelse "",
                        available_width,
                        position_value,
                    },
                ) catch "";
                defer if (msg.len > 0) self.allocator.free(msg);
                appendRendererDiagnosticsLine("resolve_layout_width", msg);
            }
            const measured = try self.measureElementChildrenPaintedBox(element, available_width);
            measured_auto_width = measured.width;
            if (rendererDiagnosticsEnabled(self.page)) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "after_measure_out_of_flow|tag={any}|id={s}|class={s}|measured_width={d}|measured_height={d}",
                    .{
                        tag,
                        element.getAttributeSafe(comptime .wrap("id")) orelse "",
                        element.getAttributeSafe(comptime .wrap("class")) orelse "",
                        measured.width,
                        measured.height,
                    },
                ) catch "";
                defer if (msg.len > 0) self.allocator.free(msg);
                appendRendererDiagnosticsLine("resolve_layout_width", msg);
            }
        }
        var resolved = std.math.clamp(
            if (explicit_width > 0)
                explicit_width
            else if (measured_auto_width > 0)
                measured_auto_width
            else
                available_width,
            80,
            available_width,
        );
        resolved = @max(resolved, min_width);
        if (max_width) |limit| resolved = @min(resolved, limit);
        return resolved;
    }

    var preferred = explicit_width;
    if (preferred <= 0) {
        if (inline_atomic_box and has_child_elements) {
            preferred = try estimateInlineAtomicDescendantWidth(self, element, available_width);
        }
    }
    if (preferred <= 0) {
        preferred = switch (tag) {
            .img => if (intrinsic_image) |dims|
                if (explicit_height > 0 and dims.height > 0)
                    @max(1, @divTrunc(dims.width * explicit_height, dims.height))
                else
                    dims.width
            else
                180,
            .textarea => 240,
            .input => blk: {
                const input = element.as(Element.Html.Input);
                break :blk switch (input._input_type) {
                    .submit, .reset, .button => @max(
                        self.opts.inline_min_width,
                        estimateStyledTextWidth(painted_label, font_size, font_family, font_weight, italic, text_style.letter_spacing, text_style.word_spacing) + 24,
                    ),
                    else => 180,
                };
            },
            .select => 180,
            else => @max(self.opts.inline_min_width, estimateStyledTextWidth(painted_label, font_size, font_family, font_weight, italic, text_style.letter_spacing, text_style.word_spacing) + 16),
        };
    }
    preferred = @max(preferred, min_width);
    if (max_width) |limit| preferred = @min(preferred, limit);
    return std.math.clamp(preferred, 60, available_width);
}

fn measureFlexAutoMainWidth(
    self: *Painter,
    element: *Element,
    decl: anytype,
    available_width: i32,
) !i32 {
    const display = resolvedDisplayValue(decl, self.page, element);
    const padding = resolveEdgeSizes(decl, self.page, "padding");
    const border_horizontal = resolveBorderHorizontalPx(decl, self.page);
    const content_width = @max(@as(i32, 40), available_width - padding.left - padding.right - border_horizontal);
    const row_direction = !isFlexColumnContainer(display, decl, self.page);
    const gap = if (row_direction) resolveFlexRowMainGapPx(decl, self.page) else 0;

    var total_width: i32 = 0;
    var max_width: i32 = 0;
    var child_count: i32 = 0;
    var it = element.asNode().childrenIterator();
    while (it.next()) |child| {
        if (!isFlexRenderableChild(child)) continue;

        var child_width = (try self.measureNodePaintedBox(child, content_width)).width;
        if (child.is(Element)) |child_el| {
            const child_style = try self.computedStyle(child_el);
            const child_decl = child_style.asCSSStyleDeclaration();
            const child_margins = resolveEdgeSizes(child_decl, self.page, "margin");
            child_width += child_margins.left + child_margins.right;
        }
        if (child_width <= 0) continue;

        if (row_direction) {
            if (child_count > 0) total_width += gap;
            total_width += child_width;
        } else {
            max_width = @max(max_width, child_width);
        }
        child_count += 1;
    }

    const content_measure = if (row_direction) total_width else max_width;
    if (content_measure <= 0) return 0;
    return std.math.clamp(padding.left + content_measure + padding.right + border_horizontal, 0, available_width);
}

fn estimateInlineAtomicDescendantWidth(
    self: *Painter,
    element: *Element,
    available_width: i32,
) !i32 {
    var best: i32 = 0;
    const tag = element.getTag();
    const outer_padding: i32 = switch (tag) {
        .input, .button, .select, .textarea => 24,
        else => 16,
    };
    const style = try self.computedStyle(element);
    const decl = style.asCSSStyleDeclaration();
    const text_style = try self.resolvePaintTextStyle(element, decl, element.getTag());
    const font_size = text_style.font_size;
    const font_family = text_style.font_family;
    const font_weight = text_style.font_weight;
    const italic = text_style.italic;

    if (try hasOnlyInlineFlowChildren(element, self.page)) {
        const inline_children = try self.measureElementChildrenPaintedBox(element, available_width);
        if (inline_children.width > 0) {
            best = @max(best, inline_children.width + outer_padding);
        }
    }

    var inline_run_width: i32 = 0;
    var it = element.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Node.CData.Text)) |text| {
            const normalized = try normalizeInlineText(self.allocator, text.getWholeText());
            defer self.allocator.free(normalized);
            const trimmed = std.mem.trim(u8, normalized, " ");
            if (trimmed.len == 0) continue;
            const painted = if (text_style.text_transform == .none) trimmed else blk: {
                const transformed = try transformTextForPaint(self.allocator, trimmed, text_style.text_transform);
                break :blk transformed;
            };
            defer if (text_style.text_transform != .none) self.allocator.free(painted);
            inline_run_width += estimateStyledTextWidth(
                painted,
                font_size,
                font_family,
                font_weight,
                italic,
                text_style.letter_spacing,
                text_style.word_spacing,
            ) + 8;
            best = @max(best, inline_run_width + outer_padding);
            continue;
        }
        if (child.is(Element)) |child_el| {
            const child_tag = child_el.getTag();
            if (isNonRenderedTag(child_tag)) continue;
            if (isHiddenFormControl(child_el)) continue;

            const child_style = try self.computedStyle(child_el);
            const child_decl = child_style.asCSSStyleDeclaration();
            const child_display = resolvedDisplayValue(child_decl, self.page, child_el);
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, child_display, &std.ascii.whitespace), "none")) continue;
            const child_padding = resolveEdgeSizes(child_decl, self.page, "padding");
            const child_margins = resolveEdgeSizes(child_decl, self.page, "margin");
            const child_extra = child_padding.left +
                child_padding.right +
                child_margins.left +
                child_margins.right +
                resolveBorderHorizontalPx(child_decl, self.page);

            const explicit_child_width = resolveExplicitWidth(self, child_el, child_decl, self.page, child_tag, available_width);
            var child_best = if (explicit_child_width > 0) explicit_child_width + child_extra else 0;
            const shrink_auto_block_child = !isInlineFlowDisplayForElement(child_el, child_display) and explicit_child_width <= 0 and
                !isOutOfFlowPositioned(resolveCssPropertyValue(child_decl, self.page, child_el, "position"));
            if (shrink_auto_block_child) {
                const child_children = try self.measureElementChildrenPaintedBox(child_el, available_width);
                if (child_children.width > 0) {
                    child_best = @max(child_best, child_children.width + child_extra);
                }
            } else {
                const child_measurement = try self.measureNodePaintedBox(child, available_width);
                if (child_measurement.width > 0) {
                    child_best = @max(child_best, child_measurement.width + child_margins.left + child_margins.right);
                }
            }

            const child_label = try self.elementLabel(child_el);
            defer self.allocator.free(child_label);
            const trimmed_label = std.mem.trim(u8, child_label, &std.ascii.whitespace);
            if (trimmed_label.len > 0 and trimmed_label[0] != '[') {
                const child_text_style = try self.resolvePaintTextStyle(child_el, child_decl, child_tag);
                const painted_label = if (child_text_style.text_transform == .none) trimmed_label else blk: {
                    const transformed = try transformTextForPaint(self.allocator, trimmed_label, child_text_style.text_transform);
                    break :blk transformed;
                };
                defer if (child_text_style.text_transform != .none) self.allocator.free(painted_label);
                best = @max(best, estimateStyledTextWidth(
                    painted_label,
                    child_text_style.font_size,
                    child_text_style.font_family,
                    child_text_style.font_weight,
                    child_text_style.italic,
                    child_text_style.letter_spacing,
                    child_text_style.word_spacing,
                ) + 24 + child_extra);
            }

            child_best = @max(child_best, (try estimateInlineAtomicDescendantWidth(self, child_el, available_width)) + child_extra);
            if (isInlineFlowDisplayForElement(child_el, child_display)) {
                inline_run_width += child_best;
                best = @max(best, inline_run_width + outer_padding);
            } else {
                inline_run_width = 0;
                best = @max(best, child_best);
            }
        }
    }

    return std.math.clamp(best, 0, available_width);
}

fn resolveOwnContentHeight(
    self: *const Painter,
    element: *Element,
    decl: anytype,
    tag: Element.Tag,
    content_width: i32,
    label: []const u8,
    text_style: PaintTextStyle,
) i32 {
    const font_size = text_style.font_size;
    const font_family = text_style.font_family;
    const font_weight = text_style.font_weight;
    const italic = text_style.italic;
    const painted_label = if (text_style.text_transform == .none) label else transformTextForPaint(self.allocator, label, text_style.text_transform) catch return 0;
    defer if (text_style.text_transform != .none) self.allocator.free(painted_label);
    var height: i32 = 0;

    if (tag == .img) {
        const aspect_ratio = parseAspectRatioValue(resolveImageStyleValue(element, self.page, "aspect-ratio"));
        const explicit_height = resolveExplicitHeight(self, element, decl, self.page, tag, self.opts.viewport_height);
        if (explicit_height > 0) {
            height = @max(height, explicit_height);
        } else if (aspect_ratio) |ratio| {
            if (content_width > 0) {
                height = @max(height, @max(@as(i32, 1), @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(content_width)) / ratio)))));
            }
        } else if (resolveIntrinsicImageDimensions(element, self.page)) |dims| {
            height = @max(height, @max(@as(i32, 1), @divTrunc(content_width * dims.height, dims.width)));
        } else {
            height = @max(height, 120);
        }
    } else if (tag == .textarea) {
        height = @max(height, 100);
    } else if (tag == .input or tag == .button or tag == .select) {
        height = @max(height, 30);
    } else if (label.len > 0 and shouldPaintText(tag)) {
        height = @max(height, estimateStyledTextHeight(
            painted_label,
            @max(40, content_width - 12),
            font_size,
            font_family,
            font_weight,
            italic,
            text_style.line_height,
        ));
    }

    return height;
}

fn resolveExplicitWidth(self: *const Painter, element: *Element, decl: anytype, page: *Page, tag: Element.Tag, available_width: i32) i32 {
    if (parseCssLengthPxWithContext(resolveWidthPropertyValue(decl, page), available_width, self.opts.viewport_width)) |width| {
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
    if (self.forced_item_node == element.asNode() and self.forced_item_height > 0) {
        return @min(@max(self.forced_item_height, 1), @max(@as(i32, 1), available_height));
    }
    const raw_height = resolveHeightPropertyValue(decl, page);
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

fn resolvedIFrameContentDisplayList(
    allocator: std.mem.Allocator,
    element: *Element,
    parent_page: *Page,
    opts: PaintOpts,
    width: i32,
    height: i32,
) !?DisplayList {
    const iframe = element.is(Element.Html.IFrame) orelse return null;
    const frame_window = iframe.getContentWindow() orelse return null;
    const frame_page = frame_window._page;
    if (frame_page == parent_page) {
        return null;
    }

    return try paintDocument(allocator, frame_page, .{
        .viewport_width = @max(@as(i32, 1), width),
        .viewport_height = @max(@as(i32, 1), height),
        .layout_scale = opts.layout_scale,
        .page_margin = 0,
        .block_min_width = @max(@as(i32, 1), @min(opts.block_min_width, width)),
        .inline_min_width = @max(@as(i32, 1), @min(opts.inline_min_width, width)),
        .min_height = opts.min_height,
    });
}

fn resolveCssHeightConstraint(
    self: *const Painter,
    element: *Element,
    decl: anytype,
    page: *Page,
    property_name: []const u8,
    available_height: i32,
) ?i32 {
    const logical_name = if (std.mem.eql(u8, property_name, "min-height"))
        "min-block-size"
    else if (std.mem.eql(u8, property_name, "max-height"))
        "max-block-size"
    else
        property_name;
    const raw_value = firstNonEmpty(&.{
        decl.getPropertyValue(property_name, page),
        decl.getPropertyValue(logical_name, page),
    });
    if (raw_value.len == 0) return null;
    const height_basis = if (std.mem.indexOfScalar(u8, raw_value, '%') != null)
        resolveAncestorExplicitHeight(self, element, page, available_height)
    else
        available_height;
    return parseCssLengthPxWithContext(raw_value, height_basis, self.opts.viewport_height);
}

fn resolveCssMinHeightPx(
    self: *const Painter,
    element: *Element,
    decl: anytype,
    page: *Page,
    available_height: i32,
) i32 {
    return resolveCssHeightConstraint(self, element, decl, page, "min-height", available_height) orelse 0;
}

fn resolveCssMaxHeightPx(
    self: *const Painter,
    element: *Element,
    decl: anytype,
    page: *Page,
    available_height: i32,
) ?i32 {
    return resolveCssHeightConstraint(self, element, decl, page, "max-height", available_height);
}

fn clampBoxHeight(min_required: i32, max_allowed: ?i32, requested: i32) i32 {
    var resolved = @max(requested, min_required);
    if (max_allowed) |max_height| {
        resolved = @min(resolved, max_height);
        resolved = @max(resolved, min_required);
    }
    return @max(@as(i32, 1), resolved);
}

const IntrinsicImageDimensions = struct {
    width: i32,
    height: i32,
};

fn resolveIntrinsicImageDimensions(element: *Element, page: *Page) ?IntrinsicImageDimensions {
    const image = element.is(Element.Html.Image) orelse return null;
    const width: i32 = @intCast(image.getNaturalWidth(page));
    const height: i32 = @intCast(image.getNaturalHeight(page));
    if (width <= 0 or height <= 0) return null;
    return .{ .width = width, .height = height };
}

fn resolveAncestorExplicitHeight(self: *const Painter, element: *Element, page: *Page, fallback_height: i32) i32 {
    var parent = element.asNode().parentElement();
    while (parent) |candidate| {
        const style = page.window.getComputedStyle(candidate, null, page) catch break;
        const decl = style.asCSSStyleDeclaration();
        const raw_height = resolveHeightPropertyValue(decl, page);
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

fn clipsOverflowContents(decl: anytype, page: *Page) bool {
    const overflow = std.mem.trim(u8, decl.getPropertyValue("overflow", page), &std.ascii.whitespace);
    if (overflowValueCreatesViewport(overflow)) {
        return true;
    }

    const overflow_x = std.mem.trim(u8, decl.getPropertyValue("overflow-x", page), &std.ascii.whitespace);
    const overflow_y = std.mem.trim(u8, decl.getPropertyValue("overflow-y", page), &std.ascii.whitespace);
    return overflowValueCreatesViewport(overflow_x) or overflowValueCreatesViewport(overflow_y);
}

fn overflowValueCreatesViewport(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "hidden") or
        std.ascii.eqlIgnoreCase(value, "clip") or
        std.ascii.eqlIgnoreCase(value, "auto") or
        std.ascii.eqlIgnoreCase(value, "scroll");
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
        else => 0,
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
        .html, .body, .img => false,
        else => !isNonRenderedTag(tag),
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

fn estimateStyledTextWidth(
    text: []const u8,
    font_size: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
    letter_spacing: i32,
    word_spacing: i32,
) i32 {
    var width = estimateTextWidth(text, font_size, font_family, font_weight, italic);
    if (text.len > 1 and letter_spacing != 0) {
        width += letter_spacing * @as(i32, @intCast(text.len - 1));
    }
    if (word_spacing != 0) {
        width += word_spacing * countAsciiSpaces(text);
    }
    return @max(@as(i32, 0), width);
}

fn estimateStyledTextHeight(
    text: []const u8,
    width: i32,
    font_size: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
    line_height: TextLineHeight,
) i32 {
    const measured = @max(font_size + 8, estimateTextHeight(text, width, font_size, font_family, font_weight, italic) + 8);
    if (resolveTextLineHeightPx(line_height, font_size)) |line_height_px| {
        return @max(measured, line_height_px);
    }
    return measured;
}

fn resolveStyledTextGap(style: PaintTextStyle) i32 {
    return 2 + style.word_spacing + (style.letter_spacing * 2);
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

const TextMetricsCacheKey = struct {
    text_hash: u64,
    text_len: u32,
    wrap_width: i32,
    font_size: i32,
    font_family_hash: u64,
    font_family_len: u32,
    font_weight: i32,
    italic: bool,
};

const TextMeasureFontKey = struct {
    face_hash: u64,
    face_len: u32,
    pitch_family: u32,
    font_size: i32,
    font_weight: i32,
    italic: bool,
};

const TextMeasureFontHandle = struct {
    handle: win.HFONT,
    owned_temp: bool,
};

var text_metrics_cache_mutex: std.Thread.Mutex = .{};
var text_metrics_cache: std.AutoHashMapUnmanaged(TextMetricsCacheKey, MeasuredTextMetrics) = .empty;
const text_metrics_cache_max_entries: usize = 32768;
var text_measure_dc: ?win.HDC = null;
var text_measure_font_cache: std.AutoHashMapUnmanaged(TextMeasureFontKey, win.HFONT) = .empty;
const text_measure_font_cache_max_entries: usize = 256;

fn textMetricsCacheKey(
    text: []const u8,
    wrap_width: ?i32,
    font_size: i32,
    font_family: []const u8,
    font_weight: i32,
    italic: bool,
) TextMetricsCacheKey {
    var text_hasher = std.hash.Wyhash.init(0);
    text_hasher.update(text);

    var family_hasher = std.hash.Wyhash.init(0);
    family_hasher.update(font_family);

    return .{
        .text_hash = text_hasher.final(),
        .text_len = @intCast(@min(text.len, std.math.maxInt(u32))),
        .wrap_width = wrap_width orelse 0,
        .font_size = font_size,
        .font_family_hash = family_hasher.final(),
        .font_family_len = @intCast(@min(font_family.len, std.math.maxInt(u32))),
        .font_weight = font_weight,
        .italic = italic,
    };
}

fn getCachedTextMetricsWin32(key: TextMetricsCacheKey) ?MeasuredTextMetrics {
    text_metrics_cache_mutex.lock();
    defer text_metrics_cache_mutex.unlock();
    return text_metrics_cache.get(key);
}

fn putCachedTextMetricsWin32(key: TextMetricsCacheKey, metrics: MeasuredTextMetrics) void {
    text_metrics_cache_mutex.lock();
    defer text_metrics_cache_mutex.unlock();
    if (text_metrics_cache.count() >= text_metrics_cache_max_entries) {
        return;
    }
    text_metrics_cache.put(std.heap.c_allocator, key, metrics) catch {};
}

fn textMeasureFontKey(font_spec: MeasuredFontSpec, font_size: i32, font_weight: i32, italic: bool) TextMeasureFontKey {
    var face_hasher = std.hash.Wyhash.init(0);
    face_hasher.update(font_spec.face_name);
    return .{
        .face_hash = face_hasher.final(),
        .face_len = @intCast(@min(font_spec.face_name.len, std.math.maxInt(u32))),
        .pitch_family = font_spec.pitch_family,
        .font_size = font_size,
        .font_weight = font_weight,
        .italic = italic,
    };
}

fn ensureTextMeasureDcWin32() !win.HDC {
    if (text_measure_dc == null) {
        text_measure_dc = win.CreateCompatibleDC(null) orelse return error.TextMeasureDcFailed;
    }
    return text_measure_dc.?;
}

fn getOrCreateCachedTextMeasureFontWin32(
    font_spec: MeasuredFontSpec,
    font_size: i32,
    font_weight: i32,
    italic: bool,
) !TextMeasureFontHandle {
    const key = textMeasureFontKey(font_spec, font_size, font_weight, italic);
    if (text_measure_font_cache.get(key)) |font| {
        return .{
            .handle = font,
            .owned_temp = false,
        };
    }

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
    if (font == null) {
        return error.TextMeasureFontFailed;
    }

    if (text_measure_font_cache.count() >= text_measure_font_cache_max_entries) {
        return .{
            .handle = font,
            .owned_temp = true,
        };
    }

    text_measure_font_cache.put(std.heap.c_allocator, key, font) catch {
        return .{
            .handle = font,
            .owned_temp = true,
        };
    };
    return .{
        .handle = font,
        .owned_temp = false,
    };
}

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

    const cache_key = textMetricsCacheKey(text, wrap_width, font_size, font_family, font_weight, italic);
    if (getCachedTextMetricsWin32(cache_key)) |cached| {
        return cached;
    }

    const font_spec = resolveMeasuredFontSpec(font_family);
    text_metrics_cache_mutex.lock();
    defer text_metrics_cache_mutex.unlock();

    if (text_metrics_cache.get(cache_key)) |cached| {
        return cached;
    }

    const hdc = try ensureTextMeasureDcWin32();
    const font_handle = try getOrCreateCachedTextMeasureFontWin32(font_spec, font_size, font_weight, italic);
    defer if (font_handle.owned_temp) {
        _ = win.DeleteObject(font_handle.handle);
    };

    const previous_font = win.SelectObject(hdc, font_handle.handle);
    defer {
        _ = win.SelectObject(hdc, previous_font);
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

    const measured = MeasuredTextMetrics{
        .width = @max(@as(i32, 0), rect.right - rect.left),
        .height = @max(@as(i32, 0), rect.bottom - rect.top),
    };
    if (text_metrics_cache.count() < text_metrics_cache_max_entries) {
        text_metrics_cache.put(std.heap.c_allocator, cache_key, measured) catch {};
    }
    return measured;
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

const AxisPairSide = enum {
    start,
    end,
};

const AxisPair = struct {
    start: i32 = 0,
    end: i32 = 0,
    specified: bool = false,
};

const InsetEdges = struct {
    top: ?i32 = null,
    right: ?i32 = null,
    bottom: ?i32 = null,
    left: ?i32 = null,
};

fn axisPairShorthandContainsAuto(value: []const u8, side: AxisPairSide) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;

    var values: [2][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |part| {
        if (count == values.len) break;
        values[count] = std.mem.trim(u8, part, &std.ascii.whitespace);
        count += 1;
    }

    return switch (count) {
        0 => false,
        1 => isCssAuto(values[0]),
        else => isCssAuto(values[
            switch (side) {
                .start => 0,
                .end => 1,
            }
        ]),
    };
}

fn parseCssAxisPairShorthand(value: []const u8) AxisPair {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return .{};
    }

    var values: [2]i32 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |part| {
        if (count == values.len) break;
        values[count] = parseCssLengthPx(part) orelse 0;
        count += 1;
    }

    return switch (count) {
        0 => .{},
        1 => .{ .start = values[0], .end = values[0], .specified = true },
        else => .{ .start = values[0], .end = values[1], .specified = true },
    };
}

fn parseCssAxisPairShorthandWithContext(value: []const u8, reference: i32, viewport: i32) InsetEdges {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return .{};
    }

    var values: [2]?i32 = .{ null, null };
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |part| {
        if (count == values.len) break;
        values[count] = parseCssLengthPxWithContext(part, reference, viewport);
        count += 1;
    }

    return switch (count) {
        0 => .{},
        1 => .{ .left = values[0], .right = values[0], .top = values[0], .bottom = values[0] },
        else => .{ .left = values[0], .right = values[1], .top = values[0], .bottom = values[1] },
    };
}

fn parseCssInsetShorthand(value: []const u8, horizontal_reference: i32, horizontal_viewport: i32, vertical_reference: i32, vertical_viewport: i32) InsetEdges {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return .{};
    }

    var values: [4]?i32 = .{ null, null, null, null };
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |part| {
        if (count == values.len) break;
        values[count] = parseCssLengthPxWithContext(
            part,
            switch (count) {
                0, 2 => vertical_reference,
                else => horizontal_reference,
            },
            switch (count) {
                0, 2 => vertical_viewport,
                else => horizontal_viewport,
            },
        );
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

fn resolveInsetEdges(
    decl: anytype,
    page: *Page,
    horizontal_reference: i32,
    horizontal_viewport: i32,
    vertical_reference: i32,
    vertical_viewport: i32,
) InsetEdges {
    var resolved = parseCssInsetShorthand(
        decl.getPropertyValue("inset", page),
        horizontal_reference,
        horizontal_viewport,
        vertical_reference,
        vertical_viewport,
    );
    const block_pair = parseCssAxisPairShorthandWithContext(
        decl.getPropertyValue("inset-block", page),
        vertical_reference,
        vertical_viewport,
    );
    const inline_pair = parseCssAxisPairShorthandWithContext(
        decl.getPropertyValue("inset-inline", page),
        horizontal_reference,
        horizontal_viewport,
    );
    if (block_pair.top != null or block_pair.bottom != null) {
        resolved.top = block_pair.top;
        resolved.bottom = block_pair.bottom;
    }
    if (inline_pair.left != null or inline_pair.right != null) {
        resolved.left = inline_pair.left;
        resolved.right = inline_pair.right;
    }
    resolved.top = parseCssLengthPxWithContext(
        firstNonEmpty(&.{
            decl.getPropertyValue("top", page),
            decl.getPropertyValue("inset-block-start", page),
        }),
        vertical_reference,
        vertical_viewport,
    ) orelse resolved.top;
    resolved.right = parseCssLengthPxWithContext(
        firstNonEmpty(&.{
            decl.getPropertyValue("right", page),
            decl.getPropertyValue("inset-inline-end", page),
        }),
        horizontal_reference,
        horizontal_viewport,
    ) orelse resolved.right;
    resolved.bottom = parseCssLengthPxWithContext(
        firstNonEmpty(&.{
            decl.getPropertyValue("bottom", page),
            decl.getPropertyValue("inset-block-end", page),
        }),
        vertical_reference,
        vertical_viewport,
    ) orelse resolved.bottom;
    resolved.left = parseCssLengthPxWithContext(
        firstNonEmpty(&.{
            decl.getPropertyValue("left", page),
            decl.getPropertyValue("inset-inline-start", page),
        }),
        horizontal_reference,
        horizontal_viewport,
    ) orelse resolved.left;
    return resolved;
}

fn resolveWidthPropertyValue(decl: anytype, page: *Page) []const u8 {
    return firstNonEmpty(&.{
        decl.getPropertyValue("width", page),
        decl.getPropertyValue("inline-size", page),
    });
}

fn resolveHeightPropertyValue(decl: anytype, page: *Page) []const u8 {
    return firstNonEmpty(&.{
        decl.getPropertyValue("height", page),
        decl.getPropertyValue("block-size", page),
    });
}

fn resolveWidthConstraintPx(
    decl: anytype,
    page: *Page,
    physical_name: []const u8,
    logical_name: []const u8,
    reference: i32,
    viewport: i32,
) ?i32 {
    return parseCssLengthPxWithContext(
        firstNonEmpty(&.{
            decl.getPropertyValue(physical_name, page),
            decl.getPropertyValue(logical_name, page),
        }),
        reference,
        viewport,
    );
}

fn parseCssFloatValue(value: []const u8) ?f32 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return std.fmt.parseFloat(f32, trimmed) catch null;
}

fn parseCssOpacityByte(value: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.mem.endsWith(u8, trimmed, "%")) {
        const raw = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], &std.ascii.whitespace);
        const percent = std.fmt.parseFloat(f64, raw) catch return null;
        return @as(u8, @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(percent * 2.55))), 0, 255)));
    }
    const fraction = std.fmt.parseFloat(f64, trimmed) catch return null;
    if (!(fraction >= 0.0)) return 0;
    return @as(u8, @intFromFloat(@round(std.math.clamp(fraction, 0.0, 1.0) * 255.0)));
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
    const pos = cursor.beginInlineLeaf(80, .{}, 0);
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

test "paintDocument orders flex row items by order before painting" {
    var page = try testing.pageTest("page/flex_order_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var red_rect: ?Bounds = null;
    var blue_rect: ?Bounds = null;
    var green_rect: ?Bounds = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r >= 180 and rect.color.g <= 90 and rect.color.b <= 90) {
                    red_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.b >= 180 and rect.color.r <= 90 and rect.color.g <= 150) {
                    blue_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.g >= 140 and rect.color.r <= 100 and rect.color.b <= 140) {
                    green_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                }
            },
            else => {},
        }
    }

    const red = red_rect orelse return error.RedChipMissing;
    const blue = blue_rect orelse return error.BlueChipMissing;
    const green = green_rect orelse return error.GreenChipMissing;

    try std.testing.expectEqual(@as(i32, 88), red.width);
    try std.testing.expectEqual(@as(i32, 88), blue.width);
    try std.testing.expectEqual(@as(i32, 88), green.width);
    try std.testing.expect(blue.x < green.x);
    try std.testing.expect(green.x < red.x);
}

test "paintDocument shrinks flex row items with flex-shrink under overflow" {
    var page = try testing.pageTest("page/flex_shrink_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
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

    const red = red_rect orelse return error.ShrinkRedMissing;
    const gray = gray_rect orelse return error.ShrinkGrayMissing;
    const blue = blue_rect orelse return error.ShrinkBlueMissing;

    try std.testing.expectEqual(@as(i32, 120), red.width);
    try std.testing.expectEqual(@as(i32, 90), gray.width);
    try std.testing.expectEqual(@as(i32, 90), blue.width);
    try std.testing.expect(red.x < gray.x);
    try std.testing.expect(gray.x < blue.x);
}

test "paintDocument applies align-content space-between across wrapped flex rows" {
    var page = try testing.pageTest("page/flex_align_content_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    var red_rect: ?Bounds = null;
    var blue_rect: ?Bounds = null;
    var green_rect: ?Bounds = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r >= 180 and rect.color.g <= 90 and rect.color.b <= 90) {
                    red_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.b >= 180 and rect.color.r <= 90 and rect.color.g <= 150) {
                    blue_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.g >= 140 and rect.color.r <= 100 and rect.color.b <= 140) {
                    green_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                }
            },
            else => {},
        }
    }

    const red = red_rect orelse return error.AlignContentRedMissing;
    const blue = blue_rect orelse return error.AlignContentBlueMissing;
    const green = green_rect orelse return error.AlignContentGreenMissing;

    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(red.y)), @as(f64, @floatFromInt(blue.y)), 4.0);
    try std.testing.expect(green.y >= red.y + red.height + 80);
    try std.testing.expect(green.x >= 110);
    try std.testing.expect(green.x <= 180);
}

test "paintDocument honors align-self on flex row items" {
    var page = try testing.pageTest("page/flex_align_self_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
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

    const red = red_rect orelse return error.AlignSelfRedMissing;
    const gray = gray_rect orelse return error.AlignSelfGrayMissing;
    const blue = blue_rect orelse return error.AlignSelfBlueMissing;

    try std.testing.expect(red.y < gray.y);
    try std.testing.expect(gray.y < blue.y);
    try std.testing.expect(red.width < gray.width);
    try std.testing.expect(blue.x > gray.x);
}

test "paintDocument stretches flex row items on the cross axis" {
    var page = try testing.pageTest("page/flex_row_stretch_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 240,
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

    const red = red_rect orelse return error.RowStretchRedMissing;
    const gray = gray_rect orelse return error.RowStretchGrayMissing;
    const blue = blue_rect orelse return error.RowStretchBlueMissing;

    try std.testing.expectEqual(@as(i32, 70), red.height);
    try std.testing.expectEqual(@as(i32, 70), gray.height);
    try std.testing.expectEqual(@as(i32, 70), blue.height);
    try std.testing.expect(red.x < gray.x);
    try std.testing.expect(gray.x < blue.x);
}

test "paintDocument distributes flex column items with flex-grow" {
    var page = try testing.pageTest("page/flex_column_grow_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 320,
        .viewport_height = 320,
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

    const red = red_rect orelse return error.ColumnGrowRedMissing;
    const gray = gray_rect orelse return error.ColumnGrowGrayMissing;
    const blue = blue_rect orelse return error.ColumnGrowBlueMissing;

    try std.testing.expectEqual(@as(i32, 80), red.height);
    try std.testing.expectEqual(@as(i32, 80), gray.height);
    try std.testing.expectEqual(@as(i32, 80), blue.height);
    try std.testing.expectEqual(@as(i32, 180), red.width);
    try std.testing.expectEqual(@as(i32, 180), gray.width);
    try std.testing.expectEqual(@as(i32, 180), blue.width);
    try std.testing.expect(red.y < gray.y);
    try std.testing.expect(gray.y < blue.y);
}

test "paintDocument shrinks flex column items with flex-shrink under overflow" {
    var page = try testing.pageTest("page/flex_column_shrink_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 320,
        .viewport_height = 320,
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

    const red = red_rect orelse return error.ColumnShrinkRedMissing;
    const gray = gray_rect orelse return error.ColumnShrinkGrayMissing;
    const blue = blue_rect orelse return error.ColumnShrinkBlueMissing;

    try std.testing.expectEqual(@as(i32, 60), red.height);
    try std.testing.expectEqual(@as(i32, 60), gray.height);
    try std.testing.expectEqual(@as(i32, 60), blue.height);
    try std.testing.expectEqual(@as(i32, 180), red.width);
    try std.testing.expectEqual(@as(i32, 180), gray.width);
    try std.testing.expectEqual(@as(i32, 180), blue.width);
}

test "paintDocument applies justify-content space-between across flex columns" {
    var page = try testing.pageTest("page/flex_column_justify_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 320,
        .viewport_height = 320,
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

    const red = red_rect orelse return error.ColumnJustifyRedMissing;
    const gray = gray_rect orelse return error.ColumnJustifyGrayMissing;
    const blue = blue_rect orelse return error.ColumnJustifyBlueMissing;

    try std.testing.expectEqual(@as(i32, 40), red.height);
    try std.testing.expectEqual(@as(i32, 40), gray.height);
    try std.testing.expectEqual(@as(i32, 40), blue.height);
    try std.testing.expect(gray.y >= red.y + red.height + 50);
    try std.testing.expect(blue.y >= gray.y + gray.height + 50);
}

test "paintDocument honors column-reverse order on flex columns" {
    var page = try testing.pageTest("page/flex_column_reverse_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 320,
        .viewport_height = 240,
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

    const red = red_rect orelse return error.ColumnReverseRedMissing;
    const gray = gray_rect orelse return error.ColumnReverseGrayMissing;
    const blue = blue_rect orelse return error.ColumnReverseBlueMissing;

    try std.testing.expectEqual(@as(i32, 40), red.height);
    try std.testing.expectEqual(@as(i32, 40), gray.height);
    try std.testing.expectEqual(@as(i32, 40), blue.height);
    try std.testing.expect(blue.y < gray.y);
    try std.testing.expect(gray.y < red.y);
}

test "paintDocument lays out legacy centered table search form" {
    var page = try testing.pageTest("page/legacy_table_layout.html");
    defer page._session.removePage();

    const table = (try page.window._document.querySelector(.wrap("#search-table"), page)).?;
    const row = (try page.window._document.querySelector(.wrap("#search-row"), page)).?;
    const main_cell = (try page.window._document.querySelector(.wrap("#main-cell"), page)).?;
    const side_cell = (try page.window._document.querySelector(.wrap("#side-cell"), page)).?;
    const side_pill = (try page.window._document.querySelector(.wrap(".side-pill"), page)).?;
    const center = (try page.window._document.querySelector(.wrap("center"), page)).?;
    const logo = (try page.window._document.querySelector(.wrap(".logo"), page)).?;
    const shell = (try page.window._document.querySelector(.wrap(".search-shell"), page)).?;

    const table_style = try page.window.getComputedStyle(table, null, page);
    const row_style = try page.window.getComputedStyle(row, null, page);
    const main_style = try page.window.getComputedStyle(main_cell, null, page);
    const side_style = try page.window.getComputedStyle(side_cell, null, page);
    const side_pill_style = try page.window.getComputedStyle(side_pill, null, page);
    const center_style = try page.window.getComputedStyle(center, null, page);
    const logo_style = try page.window.getComputedStyle(logo, null, page);
    const shell_style = try page.window.getComputedStyle(shell, null, page);

    try std.testing.expectEqualStrings("block", center_style.asCSSStyleDeclaration().getPropertyValue("display", page));
    try std.testing.expectEqualStrings("center", center_style.asCSSStyleDeclaration().getPropertyValue("text-align", page));
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

test "elementFromPoint sees legacy centered search input region" {
    var page = try testing.pageTest("page/legacy_table_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 1280,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    const input = (try page.window._document.querySelector(.wrap(".search-shell input"), page)).?;
    const shell = (try page.window._document.querySelector(.wrap(".search-shell"), page)).?;
    const input_region = blk: {
        for (display_list.control_regions.items) |control| {
            if (control.width > 300) break :blk control;
        }
        return error.LegacyTableInputMissing;
    };
    _ = page._element_layout_boxes.get(shell) orelse return error.LegacyTableShellLayoutBoxMissing;
    const input_layout_box = page._element_layout_boxes.get(input) orelse return error.LegacyTableInputLayoutBoxMissing;
    try std.testing.expectEqual(input_region.x, input_layout_box.x);
    try std.testing.expectEqual(input_region.y, input_layout_box.y);

    const hit = (try page.window._document.elementFromPoint(
        @as(f64, @floatFromInt(input_region.x)) + @as(f64, @floatFromInt(input_region.width)) / 2.0,
        @as(f64, @floatFromInt(input_region.y)) + @as(f64, @floatFromInt(input_region.height)) / 2.0,
        page,
    )).?;
    try std.testing.expect(hit == input);
}

test "patchTextControlDisplayList updates legacy centered search input text incrementally" {
    var page = try testing.pageTest("page/legacy_table_layout.html");
    defer page._session.removePage();

    const input = (try page.window._document.querySelector(.wrap(".search-shell input"), page)).?;
    const input_html = input.is(Element.Html.Input) orelse return error.LegacyTableInputMissing;

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 1280,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    const control_count = display_list.control_regions.items.len;
    try input_html.setValue("brass otter lantern", page);
    try std.testing.expect(try patchTextControlDisplayList(
        std.testing.allocator,
        page,
        &display_list,
        input,
        .{
            .viewport_width = 1280,
            .viewport_height = 720,
        },
    ));
    try std.testing.expectEqual(control_count, display_list.control_regions.items.len);

    var found_value = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "brass otter lantern")) {
                    found_value = true;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found_value);

    try input_html.setValue("", page);
    try std.testing.expect(try patchTextControlDisplayList(
        std.testing.allocator,
        page,
        &display_list,
        input,
        .{
            .viewport_width = 1280,
            .viewport_height = 720,
        },
    ));

    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| if (std.mem.eql(u8, text.text, "brass otter lantern")) {
                return error.LegacyTableIncrementalInputTextStillPresent;
            },
            else => {},
        }
    }
}

test "patchTextControlDisplayList repaints full input visuals for paint-only style changes" {
    var page = try testing.pageTest("page/legacy_table_layout.html");
    defer page._session.removePage();

    const input = (try page.window._document.querySelector(.wrap(".search-shell input"), page)).?;
    const input_html = input.is(Element.Html.Input) orelse return error.LegacyTableInputMissing;

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 1280,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    try input_html.setValue("renderer path", page);
    try input.setAttributeSafe(
        comptime .wrap("style"),
        .wrap("color: rgb(210, 40, 30); background-color: rgb(12, 34, 56); border-color: rgb(200, 210, 220);"),
        page,
    );

    switch (page.presentationHint()) {
        .text_control => |hint_element| try std.testing.expectEqual(input, hint_element),
        else => return error.ExpectedTextControlPresentationHint,
    }

    try std.testing.expect(try patchTextControlDisplayList(
        std.testing.allocator,
        page,
        &display_list,
        input,
        .{
            .viewport_width = 1280,
            .viewport_height = 720,
        },
    ));

    var saw_fill = false;
    var saw_stroke = false;
    var saw_text = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r == 12 and rect.color.g == 34 and rect.color.b == 56) {
                    saw_fill = true;
                }
            },
            .stroke_rect => |rect| {
                if (rect.x >= 0 and rect.y >= 0 and rect.width > 0 and rect.height > 0) {
                    saw_stroke = true;
                }
            },
            .text => |text| {
                if (text.color.r == 210 and text.color.g == 40 and text.color.b == 30) {
                    saw_text = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_fill);
    try std.testing.expect(saw_stroke);
    try std.testing.expect(saw_text);
}

test "patchTextControlDisplayList preserves sibling control command spans in flex layout" {
    var page = try testing.pageTest("page/flex_two_text_inputs_layout.html");
    defer page._session.removePage();

    const first = (try page.window._document.querySelector(.wrap("#first"), page)).?;
    const second = (try page.window._document.querySelector(.wrap("#second"), page)).?;
    const first_html = first.is(Element.Html.Input) orelse return error.FirstFlexInputMissing;

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 320,
    });
    defer display_list.deinit(std.testing.allocator);

    const first_path = try encodeNodePath(page.call_arena, first.asNode());
    const second_path = try encodeNodePath(page.call_arena, second.asNode());
    const first_region_index = findControlRegionIndexForNodePath(&display_list, first_path) orelse return error.FirstFlexInputControlRegionMissing;
    const second_region_index = findControlRegionIndexForNodePath(&display_list, second_path) orelse return error.SecondFlexInputControlRegionMissing;

    const second_region_before = display_list.control_regions.items[second_region_index];
    try std.testing.expect(second_region_before.hasCommandSpan(display_list.commands.items.len));

    var saw_second_value_before = false;
    for (display_list.commands.items[second_region_before.command_start..second_region_before.command_end]) |command| {
        switch (command) {
            .text => |text| if (std.mem.eql(u8, text.text, "bravo field")) {
                saw_second_value_before = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_second_value_before);

    try first_html.setValue("delta forge", page);
    try std.testing.expect(try patchTextControlDisplayList(
        std.testing.allocator,
        page,
        &display_list,
        first,
        .{
            .viewport_width = 960,
            .viewport_height = 320,
        },
    ));

    const first_region_after = display_list.control_regions.items[first_region_index];
    const second_region_after = display_list.control_regions.items[second_region_index];
    try std.testing.expect(first_region_after.hasCommandSpan(display_list.commands.items.len));
    try std.testing.expect(second_region_after.hasCommandSpan(display_list.commands.items.len));

    var saw_first_value_after = false;
    for (display_list.commands.items[first_region_after.command_start..first_region_after.command_end]) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "delta forge")) {
                    saw_first_value_after = true;
                }
                if (std.mem.eql(u8, text.text, "alpha lane")) {
                    return error.FirstFlexInputRetainedOldCommandSpanText;
                }
            },
            else => {},
        }
    }

    var saw_second_value_after = false;
    for (display_list.commands.items[second_region_after.command_start..second_region_after.command_end]) |command| {
        switch (command) {
            .text => |text| if (std.mem.eql(u8, text.text, "bravo field")) {
                saw_second_value_after = true;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_first_value_after);
    try std.testing.expect(saw_second_value_after);
}

test "patchTextControlDisplayList repaints button visuals for paint-only style changes" {
    var page = try testing.pageTest("page/button_incremental_layout.html");
    defer page._session.removePage();

    const button = (try page.window._document.querySelector(.wrap("#action"), page)).?;

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 720,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    try button.setAttributeSafe(
        comptime .wrap("style"),
        .wrap("color: rgb(244, 248, 252); background-color: rgb(28, 44, 96); border-color: rgb(196, 204, 214);"),
        page,
    );

    switch (page.presentationHint()) {
        .text_control => |hint_element| try std.testing.expectEqual(button, hint_element),
        else => return error.ExpectedButtonTextControlPresentationHint,
    }

    try std.testing.expect(try patchTextControlDisplayList(
        std.testing.allocator,
        page,
        &display_list,
        button,
        .{
            .viewport_width = 720,
            .viewport_height = 240,
        },
    ));

    var saw_fill = false;
    var saw_stroke = false;
    var saw_text = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r == 28 and rect.color.g == 44 and rect.color.b == 96) {
                    saw_fill = true;
                }
            },
            .stroke_rect => |rect| {
                if (rect.color.r == 196 and rect.color.g == 204 and rect.color.b == 214) {
                    saw_stroke = true;
                }
            },
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Run Slice") and
                    text.color.r == 244 and text.color.g == 248 and text.color.b == 252)
                {
                    saw_text = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_fill);
    try std.testing.expect(saw_stroke);
    try std.testing.expect(saw_text);
}

test "paintDocument renders select using displayed option label" {
    var page = try testing.pageTest("page/select_incremental_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 720,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    var saw_selected_label = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| if (std.mem.eql(u8, text.text, "Bravo Two")) {
                saw_selected_label = true;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_selected_label);
}

test "paintDocument treats closed select as one control without painting option descendants" {
    var page = try testing.pageTest("page/select_incremental_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 720,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.control_regions.items.len);

    var saw_selected_label = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Bravo Two")) {
                    saw_selected_label = true;
                } else if (std.mem.eql(u8, text.text, "Alpha One") or std.mem.eql(u8, text.text, "Charlie Three")) {
                    return error.SelectPaintedHiddenOptionLabel;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_selected_label);
}

test "paintDocument keeps inline-flex select on the control renderer path" {
    var page = try testing.pageTest("page/select_inline_flex_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 720,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.control_regions.items.len);

    const control = display_list.control_regions.items[0];
    try std.testing.expect(control.width >= 180);
    try std.testing.expect(control.height >= 30);

    var saw_selected_label = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Bravo Two")) {
                    saw_selected_label = true;
                } else if (std.mem.eql(u8, text.text, "Alpha One") or std.mem.eql(u8, text.text, "Charlie Three")) {
                    return error.InlineFlexSelectPaintedHiddenOptionLabel;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_selected_label);
}

test "patchTextControlDisplayList updates select label incrementally after selectedIndex change" {
    var page = try testing.pageTest("page/select_incremental_layout.html");
    defer page._session.removePage();

    const select = (try page.window._document.querySelector(.wrap("#chooser"), page)).?;
    const select_html = select.is(Element.Html.Select) orelse return error.SelectIncrementalControlMissing;

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 720,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    try select_html.setSelectedIndex(2, page);
    switch (page.presentationHint()) {
        .text_control => |hint_element| try std.testing.expectEqual(select, hint_element),
        else => return error.ExpectedSelectTextControlPresentationHint,
    }

    try std.testing.expect(try patchTextControlDisplayList(
        std.testing.allocator,
        page,
        &display_list,
        select,
        .{
            .viewport_width = 720,
            .viewport_height = 240,
        },
    ));

    var saw_new_label = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Charlie Three")) {
                    saw_new_label = true;
                }
                if (std.mem.eql(u8, text.text, "Bravo Two")) {
                    return error.SelectIncrementalLabelRetainedOldText;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_new_label);
}

test "paintDocument renders textarea using live runtime value" {
    var page = try testing.pageTest("page/textarea_incremental_layout.html");
    defer page._session.removePage();

    const textarea = (try page.window._document.querySelector(.wrap("#notes"), page)).?;
    const textarea_html = textarea.is(Element.Html.TextArea) orelse return error.TextAreaIncrementalControlMissing;
    try textarea_html.setValue("Bravo runtime note", page);

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 720,
        .viewport_height = 260,
    });
    defer display_list.deinit(std.testing.allocator);

    var saw_runtime_value = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Bravo runtime note")) {
                    saw_runtime_value = true;
                }
                if (std.mem.eql(u8, text.text, "Alpha draft")) {
                    return error.TextAreaPaintRetainedDefaultDomText;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_runtime_value);
}

test "patchTextControlDisplayList updates textarea value incrementally" {
    var page = try testing.pageTest("page/textarea_incremental_layout.html");
    defer page._session.removePage();

    const textarea = (try page.window._document.querySelector(.wrap("#notes"), page)).?;
    const textarea_html = textarea.is(Element.Html.TextArea) orelse return error.TextAreaIncrementalControlMissing;

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 720,
        .viewport_height = 260,
    });
    defer display_list.deinit(std.testing.allocator);

    try textarea_html.setValue("Charlie runtime note", page);
    switch (page.presentationHint()) {
        .text_control => |hint_element| try std.testing.expectEqual(textarea, hint_element),
        else => return error.ExpectedTextAreaTextControlPresentationHint,
    }

    try std.testing.expect(try patchTextControlDisplayList(
        std.testing.allocator,
        page,
        &display_list,
        textarea,
        .{
            .viewport_width = 720,
            .viewport_height = 260,
        },
    ));

    var saw_runtime_value = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Charlie runtime note")) {
                    saw_runtime_value = true;
                }
                if (std.mem.eql(u8, text.text, "Alpha draft")) {
                    return error.TextAreaIncrementalPatchRetainedOldText;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_runtime_value);
}

test "paintDocument emits tiled and non-repeated background image commands" {
    var page = try testing.pageTest("page/background_image_layout.html");
    defer page._session.removePage();

    const band = (try page.window._document.querySelector(.wrap("#band"), page)).?;
    const badge = (try page.window._document.querySelector(.wrap("#badge"), page)).?;
    const band_style = try page.window.getComputedStyle(band, null, page);
    const badge_style = try page.window.getComputedStyle(badge, null, page);

    try std.testing.expect(std.mem.indexOf(u8, band_style.asCSSStyleDeclaration().getPropertyValue("background-image", page), "background_sprite.png") != null);
    try std.testing.expectEqualStrings("repeat-x", band_style.asCSSStyleDeclaration().getPropertyValue("background-repeat", page));
    try std.testing.expectEqualStrings("0 -40px", band_style.asCSSStyleDeclaration().getPropertyValue("background-position", page));
    try std.testing.expect(std.mem.indexOf(u8, badge_style.asCSSStyleDeclaration().getPropertyValue("background-image", page), "background_sprite.png") != null);
    try std.testing.expectEqualStrings("no-repeat", badge_style.asCSSStyleDeclaration().getPropertyValue("background-repeat", page));

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var repeated: ?ImageCommand = null;
    var single: ?ImageCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| {
                if (image.draw_mode != .background) continue;
                if (std.mem.indexOf(u8, image.url, "background_sprite.png") == null) continue;
                if (image.repeat_x and !image.repeat_y) {
                    repeated = image;
                } else if (!image.repeat_x and !image.repeat_y) {
                    single = image;
                }
            },
            else => {},
        }
    }

    const repeated_image = repeated orelse return error.BackgroundRepeatImageMissing;
    const single_image = single orelse return error.BackgroundSingleImageMissing;

    try std.testing.expectEqual(ImageCommand.DrawMode.background, repeated_image.draw_mode);
    try std.testing.expectEqual(@as(i32, -40), repeated_image.background_offset_y);
    try std.testing.expectEqual(@as(i32, 0), repeated_image.background_offset_x);
    try std.testing.expectEqual(@as(i32, 240), repeated_image.width);
    try std.testing.expectEqual(@as(i32, 32), repeated_image.height);
    try std.testing.expectEqual(ImageCommand.DrawMode.background, single_image.draw_mode);
    try std.testing.expectEqual(@as(i32, 0), single_image.background_offset_x);
    try std.testing.expectEqual(@as(i32, 0), single_image.background_offset_y);
    try std.testing.expectEqual(@as(i32, 240), single_image.width);
    try std.testing.expectEqual(@as(i32, 40), single_image.height);
}

test "paintDocument carries border radius on box commands" {
    var page = try testing.pageTest("page/border_radius_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var rounded_fill: ?Command = null;
    var rounded_stroke: ?Command = null;
    var square_fill: ?Command = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.b >= 180 and rect.color.r <= 90 and rect.color.g >= 80) {
                    rounded_fill = command;
                } else if (rect.color.r >= 180 and rect.color.g <= 90 and rect.color.b <= 90) {
                    square_fill = command;
                }
            },
            .stroke_rect => |rect| {
                if (rect.color.b >= 120 and rect.color.r <= 60 and rect.color.g <= 100) {
                    rounded_stroke = command;
                }
            },
            else => {},
        }
    }

    switch (rounded_fill orelse return error.RoundedFillMissing) {
        .fill_rect => |rect| {
            try std.testing.expectEqual(@as(i32, 26), rect.corner_radius);
            try std.testing.expectEqual(@as(i32, 220), rect.width);
            try std.testing.expectEqual(@as(i32, 52), rect.height);
        },
        else => return error.RoundedFillWrongCommand,
    }
    switch (rounded_stroke orelse return error.RoundedStrokeMissing) {
        .stroke_rect => |rect| {
            try std.testing.expectEqual(@as(i32, 26), rect.corner_radius);
        },
        else => return error.RoundedStrokeWrongCommand,
    }
    switch (square_fill orelse return error.SquareFillMissing) {
        .fill_rect => |rect| {
            try std.testing.expectEqual(@as(i32, 0), rect.corner_radius);
        },
        else => return error.SquareFillWrongCommand,
    }
}

test "paintDocument emits box shadow commands for headed boxes" {
    var page = try testing.pageTest("page/box_shadow_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 320,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    var card_fill: ?RectCommand = null;
    var shadow_fill: ?RectCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.width == 140 and rect.height == 90 and rect.x == 40 and rect.y == 30 and rect.color.r == 255 and rect.color.g == 255 and rect.color.b == 255) {
                    card_fill = rect;
                } else if (rect.width == 140 and rect.height == 90 and rect.x == 70 and rect.y == 50 and rect.color.r == 0 and rect.color.g == 0 and rect.color.b == 0) {
                    shadow_fill = rect;
                }
            },
            else => {},
        }
    }

    const card = card_fill orelse return error.BoxShadowCardMissing;
    const shadow = shadow_fill orelse return error.BoxShadowShadowMissing;

    try std.testing.expectEqual(@as(u8, 255), card.opacity);
    try std.testing.expect(shadow.opacity < 255);
    try std.testing.expectEqual(@as(i32, 40), card.x);
    try std.testing.expectEqual(@as(i32, 30), card.y);
    try std.testing.expectEqual(@as(i32, 70), shadow.x);
    try std.testing.expectEqual(@as(i32, 50), shadow.y);
}

test "paintDocument expands content-box dimensions from explicit size" {
    var page = try testing.pageTest("page/box_sizing_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var border_box: ?Bounds = null;
    var content_box: ?Bounds = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.b >= 180 and rect.color.r <= 80 and rect.color.g >= 80 and rect.color.g <= 120) {
                    border_box = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.r >= 170 and rect.color.g <= 100 and rect.color.b <= 120) {
                    content_box = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                }
            },
            else => {},
        }
    }

    const border = border_box orelse return error.BorderBoxMissing;
    const content = content_box orelse return error.ContentBoxMissing;

    try std.testing.expectEqual(@as(i32, 160), border.width);
    try std.testing.expectEqual(@as(i32, 40), border.height);
    try std.testing.expectEqual(@as(i32, 200), content.width);
    try std.testing.expectEqual(@as(i32, 80), content.height);
    try std.testing.expectEqual(border.x, content.x);
}

test "paintDocument uses intrinsic image dimensions and aspect ratio" {
    var page = try testing.pageTest("page/intrinsic_image_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var images: std.ArrayList(ImageCommand) = .empty;
    defer images.deinit(std.testing.allocator);
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| if (std.mem.indexOf(u8, image.url, "layout_tall_blue.png") != null) {
                try images.append(std.testing.allocator, image);
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), images.items.len);
    std.mem.sort(ImageCommand, images.items, {}, struct {
        fn lessThan(_: void, lhs: ImageCommand, rhs: ImageCommand) bool {
            return lhs.y < rhs.y;
        }
    }.lessThan);

    try std.testing.expectEqual(@as(i32, 40), images.items[0].width);
    try std.testing.expectEqual(@as(i32, 80), images.items[0].height);
    try std.testing.expectEqual(@as(i32, 20), images.items[1].width);
    try std.testing.expectEqual(@as(i32, 40), images.items[1].height);
    try std.testing.expectEqual(@as(i32, 20), images.items[2].width);
    try std.testing.expectEqual(@as(i32, 40), images.items[2].height);
}

test "paintDocument emits image object-fit and object-position commands" {
    var page = try testing.pageTest("page/image_layout_fidelity.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var fill: ?ImageCommand = null;
    var contain: ?ImageCommand = null;
    var cover: ?ImageCommand = null;
    var none: ?ImageCommand = null;
    var scale_down: ?ImageCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| {
                if (std.mem.indexOf(u8, image.url, "data:image/png;base64") == null) continue;
                switch (image.object_fit) {
                    .fill => fill = image,
                    .contain => contain = image,
                    .cover => cover = image,
                    .none => none = image,
                    .scale_down => scale_down = image,
                }
            },
            else => {},
        }
    }

    const fill_image = fill orelse return error.ObjectFitFillMissing;
    const contain_image = contain orelse return error.ObjectFitContainMissing;
    const cover_image = cover orelse return error.ObjectFitCoverMissing;
    const none_image = none orelse return error.ObjectFitNoneMissing;
    const scale_down_image = scale_down orelse return error.ObjectFitScaleDownMissing;

    try std.testing.expectEqual(ImageCommand.ObjectFitMode.fill, fill_image.object_fit);
    try std.testing.expectEqual(ImageCommand.ObjectFitMode.contain, contain_image.object_fit);
    try std.testing.expectEqual(ImageCommand.ObjectFitMode.cover, cover_image.object_fit);
    try std.testing.expectEqual(ImageCommand.ObjectFitMode.none, none_image.object_fit);
    try std.testing.expectEqual(ImageCommand.ObjectFitMode.scale_down, scale_down_image.object_fit);

    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.percent, fill_image.object_position_x_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.percent, fill_image.object_position_y_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.percent, contain_image.object_position_x_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.percent, contain_image.object_position_y_mode);
    try std.testing.expectEqual(@as(i32, 5000), fill_image.object_position_x_percent_bp);
    try std.testing.expectEqual(@as(i32, 5000), fill_image.object_position_y_percent_bp);
    try std.testing.expectEqual(@as(i32, 5000), contain_image.object_position_x_percent_bp);
    try std.testing.expectEqual(@as(i32, 5000), contain_image.object_position_y_percent_bp);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.offset, cover_image.object_position_x_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.offset, cover_image.object_position_y_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.offset, none_image.object_position_x_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.offset, none_image.object_position_y_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.offset, scale_down_image.object_position_x_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.offset, scale_down_image.object_position_y_mode);

    try std.testing.expectEqual(@as(i32, 80), fill_image.width);
    try std.testing.expectEqual(@as(i32, 80), fill_image.height);
    try std.testing.expectEqual(@as(i32, 80), contain_image.width);
    try std.testing.expectEqual(@as(i32, 80), contain_image.height);
    try std.testing.expectEqual(@as(i32, 80), cover_image.width);
    try std.testing.expectEqual(@as(i32, 80), cover_image.height);
    try std.testing.expectEqual(@as(i32, 80), none_image.width);
    try std.testing.expectEqual(@as(i32, 80), none_image.height);
    try std.testing.expectEqual(@as(i32, 40), scale_down_image.width);
    try std.testing.expectEqual(@as(i32, 40), scale_down_image.height);
}

test "paintDocument applies image aspect ratio with explicit width and height" {
    var page = try testing.pageTest("page/image_layout_fidelity.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 960,
    });
    defer display_list.deinit(std.testing.allocator);

    var ratio_images: std.ArrayList(ImageCommand) = .empty;
    defer ratio_images.deinit(std.testing.allocator);
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| {
                if (std.mem.indexOf(u8, image.url, "layout_tall_blue.png") == null) continue;
                try ratio_images.append(std.testing.allocator, image);
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), ratio_images.items.len);
    std.mem.sort(ImageCommand, ratio_images.items, {}, struct {
        fn lessThan(_: void, lhs: ImageCommand, rhs: ImageCommand) bool {
            return lhs.y < rhs.y;
        }
    }.lessThan);
    const width_image = ratio_images.items[0];
    const height_image = ratio_images.items[1];

    try std.testing.expectEqual(@as(i32, 60), width_image.width);
    try std.testing.expectEqual(@as(i32, 30), width_image.height);
    try std.testing.expectEqual(@as(i32, 60), height_image.width);
    try std.testing.expectEqual(@as(i32, 30), height_image.height);
}

test "paintDocument emits semantic background-position modes" {
    var page = try testing.pageTest("page/background_position_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 520,
    });
    defer display_list.deinit(std.testing.allocator);

    var backgrounds: std.ArrayList(ImageCommand) = .empty;
    defer backgrounds.deinit(std.testing.allocator);
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| {
                if (image.draw_mode == .background and std.mem.indexOf(u8, image.url, "layout_tall_blue.png") != null) {
                    try backgrounds.append(std.testing.allocator, image);
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), backgrounds.items.len);
    std.mem.sort(ImageCommand, backgrounds.items, {}, struct {
        fn lessThan(_: void, lhs: ImageCommand, rhs: ImageCommand) bool {
            return lhs.y < rhs.y;
        }
    }.lessThan);

    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.percent, backgrounds.items[0].background_position_x_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.percent, backgrounds.items[0].background_position_y_mode);
    try std.testing.expectEqual(@as(i32, 2500), backgrounds.items[0].background_position_x_percent_bp);
    try std.testing.expectEqual(@as(i32, 5000), backgrounds.items[0].background_position_y_percent_bp);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.center, backgrounds.items[1].background_position_x_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.center, backgrounds.items[1].background_position_y_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.far, backgrounds.items[2].background_position_x_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundPositionMode.far, backgrounds.items[2].background_position_y_mode);
}

test "paintDocument clamps responsive images with max-width and preserves aspect ratio" {
    var page = try testing.pageTest("page/responsive_image_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var responsive: ?ImageCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| {
                if (std.mem.indexOf(u8, image.url, "layout_tall_blue.png") != null) {
                    responsive = image;
                    break;
                }
            },
            else => {},
        }
    }

    const image = responsive orelse return error.ResponsiveImageMissing;
    try std.testing.expectEqual(@as(i32, 120), image.width);
    try std.testing.expectEqual(@as(i32, 240), image.height);
}

test "paintDocument emits semantic background-size modes" {
    var page = try testing.pageTest("page/background_size_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 700,
    });
    defer display_list.deinit(std.testing.allocator);

    var backgrounds: std.ArrayList(ImageCommand) = .empty;
    defer backgrounds.deinit(std.testing.allocator);
    for (display_list.commands.items) |command| {
        switch (command) {
            .image => |image| {
                if (image.draw_mode == .background and std.mem.indexOf(u8, image.url, "layout_tall_blue.png") != null) {
                    try backgrounds.append(std.testing.allocator, image);
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), backgrounds.items.len);
    std.mem.sort(ImageCommand, backgrounds.items, {}, struct {
        fn lessThan(_: void, lhs: ImageCommand, rhs: ImageCommand) bool {
            return lhs.y < rhs.y;
        }
    }.lessThan);

    try std.testing.expectEqual(ImageCommand.BackgroundSizeMode.contain, backgrounds.items[0].background_size_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundSizeMode.cover, backgrounds.items[1].background_size_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundSizeMode.explicit, backgrounds.items[2].background_size_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundSizeComponentMode.px, backgrounds.items[2].background_size_width_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundSizeComponentMode.auto, backgrounds.items[2].background_size_height_mode);
    try std.testing.expectEqual(@as(i32, 80), backgrounds.items[2].background_size_width);
    try std.testing.expectEqual(ImageCommand.BackgroundSizeMode.explicit, backgrounds.items[3].background_size_mode);
    try std.testing.expectEqual(ImageCommand.BackgroundSizeComponentMode.percent, backgrounds.items[3].background_size_width_mode);
    try std.testing.expectEqual(@as(i32, 7500), backgrounds.items[3].background_size_width_percent_bp);
}

test "paintDocument clips block descendants when overflow hidden" {
    var page = try testing.pageTest("page/overflow_hidden_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var blue_fill: ?RectCommand = null;
    var red_fill: ?RectCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.b >= 180 and rect.color.r <= 80 and rect.color.g <= 150) {
                    blue_fill = rect;
                } else if (rect.color.r >= 180 and rect.color.g <= 100 and rect.color.b <= 100) {
                    red_fill = rect;
                }
            },
            else => {},
        }
    }

    const blue = blue_fill orelse return error.OverflowBlueFillMissing;
    const red = red_fill orelse return error.OverflowRedFillMissing;
    const clip = blue.clip_rect orelse return error.OverflowBlueClipMissing;

    try std.testing.expectEqual(@as(i32, 120), clip.width);
    try std.testing.expectEqual(@as(i32, 80), clip.height);
    try std.testing.expect(red.y >= clip.y + clip.height + 14);
    try std.testing.expect(display_list.content_height <= red.y + red.height);
}

test "paintDocument clips flex descendants when overflow hidden" {
    var page = try testing.pageTest("page/flex_overflow_hidden_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var blue_fill: ?RectCommand = null;
    var green_fill: ?RectCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.b >= 180 and rect.color.r <= 80 and rect.color.g <= 150) {
                    blue_fill = rect;
                } else if (rect.color.g >= 130 and rect.color.r <= 100 and rect.color.b <= 120) {
                    green_fill = rect;
                }
            },
            else => {},
        }
    }

    const blue = blue_fill orelse return error.FlexOverflowBlueFillMissing;
    const green = green_fill orelse return error.FlexOverflowGreenFillMissing;
    const clip = blue.clip_rect orelse return error.FlexOverflowBlueClipMissing;

    try std.testing.expectEqual(@as(i32, 140), clip.width);
    try std.testing.expectEqual(@as(i32, 80), clip.height);
    try std.testing.expect(green.y >= clip.y + clip.height + 14);
}

test "paintDocument honors generic block min-height and max-height" {
    var page = try testing.pageTest("page/min_max_height_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 520,
    });
    defer display_list.deinit(std.testing.allocator);

    var red_fill: ?RectCommand = null;
    var blue_fill: ?RectCommand = null;
    var green_fill: ?RectCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r >= 180 and rect.color.g <= 100 and rect.color.b <= 100) {
                    red_fill = rect;
                } else if (rect.color.b >= 180 and rect.color.r <= 80 and rect.color.g <= 150) {
                    blue_fill = rect;
                } else if (rect.color.g >= 130 and rect.color.r <= 100 and rect.color.b <= 120) {
                    green_fill = rect;
                }
            },
            else => {},
        }
    }

    const red = red_fill orelse return error.MinHeightFillMissing;
    const blue = blue_fill orelse return error.MaxHeightFillMissing;
    const green = green_fill orelse return error.MaxHeightFooterMissing;
    const clip = blue.clip_rect orelse return error.MaxHeightClipMissing;

    try std.testing.expectEqual(@as(i32, 90), red.height);
    try std.testing.expectEqual(@as(i32, 120), clip.width);
    try std.testing.expectEqual(@as(i32, 80), clip.height);
    try std.testing.expect(green.y >= clip.y + clip.height + 14);
}

test "paintDocument honors logical edge, size, and inset properties" {
    var page = try testing.pageTest("page/logical_properties_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 320,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    var red_fill: ?RectCommand = null;
    var gray_fill: ?RectCommand = null;
    var blue_fill: ?RectCommand = null;
    var green_fill: ?RectCommand = null;
    var yellow_fill: ?RectCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r >= 180 and rect.color.g <= 100 and rect.color.b <= 100) {
                    red_fill = rect;
                } else if (rect.color.r >= 220 and rect.color.g >= 220 and rect.color.b >= 220) {
                    gray_fill = rect;
                } else if (rect.color.b >= 180 and rect.color.r <= 80 and rect.color.g <= 120) {
                    blue_fill = rect;
                } else if (rect.color.g >= 130 and rect.color.r <= 100 and rect.color.b <= 120) {
                    green_fill = rect;
                } else if (rect.color.r >= 220 and rect.color.g >= 160 and rect.color.b <= 80) {
                    yellow_fill = rect;
                }
            },
            else => {},
        }
    }

    const red = red_fill orelse return error.LogicalContainerMissing;
    const gray = gray_fill orelse return error.LogicalPaddingContainerMissing;
    const blue = blue_fill orelse return error.LogicalInnerMissing;
    const green = green_fill orelse return error.LogicalFooterMissing;
    const yellow = yellow_fill orelse return error.LogicalInsetMissing;

    try std.testing.expectEqual(@as(i32, 64), red.x);
    try std.testing.expectEqual(@as(i32, 40), red.y);
    try std.testing.expectEqual(@as(i32, 140), red.width);
    try std.testing.expectEqual(@as(i32, 70), red.height);

    try std.testing.expectEqual(@as(i32, 40), gray.x);
    try std.testing.expectEqual(@as(i32, 120), gray.y);
    try std.testing.expectEqual(@as(i32, 80), gray.width);
    try std.testing.expectEqual(@as(i32, 50), gray.height);

    try std.testing.expectEqual(@as(i32, gray.x + 16), blue.x);
    try std.testing.expectEqual(@as(i32, gray.y + 10), blue.y);
    try std.testing.expectEqual(@as(i32, 80), blue.width);
    try std.testing.expectEqual(@as(i32, 24), blue.height);

    try std.testing.expectEqual(@as(i32, 40), green.x);
    try std.testing.expectEqual(@as(i32, 180), green.y);
    try std.testing.expectEqual(@as(i32, 80), green.width);
    try std.testing.expectEqual(@as(i32, 24), green.height);

    try std.testing.expectEqual(@as(i32, 210), yellow.x);
    try std.testing.expectEqual(@as(i32, 26), yellow.y);
    try std.testing.expectEqual(@as(i32, 80), yellow.width);
    try std.testing.expectEqual(@as(i32, 24), yellow.height);
}

test "paintDocument scrolls generic block overflow auto content" {
    var page = try testing.pageTest("page/overflow_auto_scroll_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    const box = page.window._document.getElementById("box", page) orelse return error.OverflowAutoBoxMissing;
    try std.testing.expectEqual(@as(f64, 80), box.getClientHeight(page));
    try std.testing.expectEqual(@as(f64, 144), box.getScrollHeight(page));
    try std.testing.expectEqual(@as(u32, 40), box.getScrollTop(page));

    var blue_fill: ?RectCommand = null;
    var red_fill: ?RectCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.b >= 180 and rect.color.r <= 80 and rect.color.g <= 120 and rect.width == 120 and rect.height == 40) {
                    blue_fill = rect;
                } else if (rect.color.r >= 180 and rect.color.g <= 100 and rect.color.b <= 100 and rect.width == 120 and rect.height == 40) {
                    red_fill = rect;
                }
            },
            else => {},
        }
    }

    const blue = blue_fill orelse return error.OverflowAutoBlueFillMissing;
    const red = red_fill orelse return error.OverflowAutoRedFillMissing;
    const blue_clip = blue.clip_rect orelse return error.OverflowAutoBlueClipMissing;
    const red_clip = red.clip_rect orelse return error.OverflowAutoRedClipMissing;

    try std.testing.expect(blue.y < blue_clip.y);
    try std.testing.expectEqual(@as(i32, 80), blue_clip.height);
    try std.testing.expect(red.y >= blue_clip.y);
    try std.testing.expect(red.y < red_clip.y + red_clip.height);
}

test "paintDocument scrolls flex overflow auto content" {
    var page = try testing.pageTest("page/flex_overflow_auto_scroll_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    const box = page.window._document.getElementById("box", page) orelse return error.FlexOverflowAutoBoxMissing;
    try std.testing.expectEqual(@as(f64, 80), box.getClientHeight(page));
    try std.testing.expectEqual(@as(f64, 120), box.getScrollHeight(page));
    try std.testing.expectEqual(@as(u32, 40), box.getScrollTop(page));

    var blue_fill: ?RectCommand = null;
    var red_fill: ?RectCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.b >= 180 and rect.color.r <= 80 and rect.color.g <= 120 and rect.width == 140 and rect.height == 40) {
                    blue_fill = rect;
                } else if (rect.color.r >= 180 and rect.color.g <= 100 and rect.color.b <= 100 and rect.width == 140 and rect.height == 40) {
                    red_fill = rect;
                }
            },
            else => {},
        }
    }

    const blue = blue_fill orelse return error.FlexOverflowAutoBlueFillMissing;
    const red = red_fill orelse return error.FlexOverflowAutoRedFillMissing;
    const blue_clip = blue.clip_rect orelse return error.FlexOverflowAutoBlueClipMissing;
    const red_clip = red.clip_rect orelse return error.FlexOverflowAutoRedClipMissing;

    try std.testing.expect(blue.y < blue_clip.y);
    try std.testing.expectEqual(@as(i32, 80), blue_clip.height);
    try std.testing.expect(red.y >= blue_clip.y);
    try std.testing.expect(red.y < red_clip.y + red_clip.height);
}

test "paintDocument scrolls overflow auto link regions with scrollTop" {
    var page = try testing.pageTest("page/overflow_auto_link_scroll_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.link_regions.items.len);
    const region = display_list.link_regions.items[0];
    try std.testing.expectEqual(@as(i32, 120), region.width);
    try std.testing.expect(region.y >= 20);
    try std.testing.expect(region.y < 20 + 80);
}

test "paintDocument clips hidden link regions to overflow containers" {
    var page = try testing.pageTest("page/overflow_hidden_link_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.link_regions.items.len);
    const region = display_list.link_regions.items[0];
    try std.testing.expectEqual(@as(i32, 120), region.width);
    try std.testing.expectEqual(@as(i32, 80), region.height);
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

test "paintDocument applies translate transforms to centered interactive boxes" {
    var page = try testing.pageTest("page/transform_translate_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.control_regions.items.len);

    const button = display_list.control_regions.items[0];
    try std.testing.expect(button.x > 130);
    try std.testing.expect(button.x < 280);
    try std.testing.expect(button.y > 50);
    try std.testing.expect(button.y < 100);

    var centered_chunk: ?TextCommand = null;
    var translate_chunk: ?TextCommand = null;
    var shell_chunk: ?TextCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                const piece = std.mem.trim(u8, text.text, &std.ascii.whitespace);
                if (std.mem.eql(u8, piece, "Centered")) {
                    centered_chunk = text;
                } else if (std.mem.eql(u8, piece, "Translate")) {
                    translate_chunk = text;
                } else if (std.mem.eql(u8, piece, "Shell")) {
                    shell_chunk = text;
                }
            },
            else => {},
        }
    }

    const centered = centered_chunk orelse return error.CenteredTranslateShellTextMissing;
    const translated = translate_chunk orelse return error.TranslatedChunkMissing;
    const shell = shell_chunk orelse return error.ShellChunkMissing;

    try std.testing.expect(centered.x > 170);
    try std.testing.expect(centered.x < 220);
    try std.testing.expect(centered.y > 150);
    try std.testing.expect(centered.y < 180);
    try std.testing.expect(translated.x > 250);
    try std.testing.expect(translated.x < 340);
    try std.testing.expect(translated.y > 150);
    try std.testing.expect(translated.y < 180);
    try std.testing.expect(shell.x > 170);
    try std.testing.expect(shell.x < 220);
    try std.testing.expect(shell.y > 185);
    try std.testing.expect(shell.y < 215);
    try std.testing.expectEqual(@as(usize, 0), display_list.link_regions.items.len);
}

test "paintDocument translates centered link regions" {
    var page = try testing.pageTest("page/transform_translate_link_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 420,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.link_regions.items.len);

    const link = display_list.link_regions.items[0];
    try std.testing.expect(link.x > 180);
    try std.testing.expect(link.x < 320);
    try std.testing.expect(link.y > 250);
    try std.testing.expect(link.y < 340);

    var centered_chunk: ?TextCommand = null;
    var translated_chunk: ?TextCommand = null;
    var link_chunk: ?TextCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                const piece = std.mem.trim(u8, text.text, &std.ascii.whitespace);
                if (std.mem.eql(u8, piece, "Centered")) {
                    centered_chunk = text;
                } else if (std.mem.eql(u8, piece, "Translate")) {
                    translated_chunk = text;
                } else if (std.mem.eql(u8, piece, "Link")) {
                    link_chunk = text;
                }
            },
            else => {},
        }
    }

    const centered = centered_chunk orelse return error.CenteredTranslateLinkTextMissing;
    const translated = translated_chunk orelse return error.TranslatedChunkMissing;
    const link_text = link_chunk orelse return error.LinkChunkMissing;
    try std.testing.expect(centered.x > 170);
    try std.testing.expect(centered.x < 220);
    try std.testing.expect(centered.y > 150);
    try std.testing.expect(centered.y < 180);
    try std.testing.expect(translated.x > 250);
    try std.testing.expect(translated.x < 340);
    try std.testing.expect(translated.y > 150);
    try std.testing.expect(translated.y < 180);
    try std.testing.expect(link_text.x > 170);
    try std.testing.expect(link_text.x < 220);
    try std.testing.expect(link_text.y > 185);
    try std.testing.expect(link_text.y < 215);
}

test "getComputedStyle exposes translate transforms and default none" {
    {
        var translated_page = try testing.pageTest("page/transform_translate_layout.html");
        defer translated_page._session.removePage();

        const translated_shell = (try translated_page.window._document.querySelector(.wrap(".center-shell"), translated_page)).?;
        const translated_style = try translated_page.window.getComputedStyle(translated_shell, null, translated_page);
        try std.testing.expectEqualStrings("translate(-50%, -50%)", translated_style.asCSSStyleDeclaration().getPropertyValue("transform", translated_page));
    }

    var plain_page = try testing.pageTest("page/transform_default_layout.html");
    defer plain_page._session.removePage();

    const plain_box = (try plain_page.window._document.querySelector(.wrap(".plain"), plain_page)).?;
    const plain_style = try plain_page.window.getComputedStyle(plain_box, null, plain_page);
    try std.testing.expectEqualStrings("none", plain_style.asCSSStyleDeclaration().getPropertyValue("transform", plain_page));
}

test "elementFromPoint sees translated button region" {
    {
        var button_page = try testing.pageTest("page/transform_translate_layout.html");
        defer button_page._session.removePage();

        const button = (try button_page.window._document.querySelector(.wrap(".offset-pill button"), button_page)).?;
        const button_rect = button.getBoundingClientRect(button_page);
        const button_hit = (try button_page.window._document.elementFromPoint(
            button_rect.getLeft() + button_rect.getWidth() / 2,
            button_rect.getTop() + button_rect.getHeight() / 2,
            button_page,
        )).?;
        try std.testing.expect(button_hit == button);
    }
}

test "paintDocument keeps inline phrase width close to measured text width" {
    var page = try testing.pageTest("page/inline_phrase_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var min_x: ?i32 = null;
    var max_x: i32 = 0;
    var text_count: usize = 0;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                text_count += 1;
                min_x = if (min_x) |current| @min(current, text.x) else text.x;
                max_x = @max(max_x, text.x + text.width);
            },
            else => {},
        }
    }

    try std.testing.expect(text_count >= 4);
    const actual_width = max_x - (min_x orelse return error.PhraseTextMissing);
    const expected_width = estimateStyledTextWidth("Deliver and maintain Google services", 16, "", 400, false, 0, 0);
    try std.testing.expect(actual_width <= expected_width + 20);
}

test "paintDocument draws unordered list markers" {
    var page = try testing.pageTest("page/unordered_list_marker_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var marker_count: usize = 0;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.width <= 8 and rect.height <= 8 and rect.corner_radius >= 2) {
                    marker_count += 1;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(marker_count >= 2);
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

test "paintDocument centers each wrapped inline row when text-align is center" {
    var page = try testing.pageTest("page/centered_mixed_inline_wrap_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 520,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var row_y = std.ArrayList(i32){};
    defer row_y.deinit(std.testing.allocator);
    var row_min_x = std.ArrayList(i32){};
    defer row_min_x.deinit(std.testing.allocator);
    var below_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Below ")) {
                    below_y = text.y;
                    continue;
                }
                if (below_y == null) {
                    var matched_row = false;
                    for (row_y.items, row_min_x.items, 0..) |baseline_y, *min_x, idx| {
                        _ = idx;
                        if (@abs(text.y - baseline_y) <= 8) {
                            min_x.* = @min(min_x.*, text.x);
                            matched_row = true;
                            break;
                        }
                    }
                    if (!matched_row) {
                        try row_y.append(std.testing.allocator, text.y);
                        try row_min_x.append(std.testing.allocator, text.x);
                    }
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), row_y.items.len);
    try std.testing.expect(row_min_x.items[2] > row_min_x.items[0] + 40);
    try std.testing.expect(below_y != null);
    try std.testing.expect(below_y.? > row_y.items[row_y.items.len - 1] + 24);
}

test "paintDocument centers each wrapped row for legacy center children" {
    var page = try testing.pageTest("page/legacy_center_mixed_inline_wrap_flow.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 520,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var row_y = std.ArrayList(i32){};
    defer row_y.deinit(std.testing.allocator);
    var row_min_x = std.ArrayList(i32){};
    defer row_min_x.deinit(std.testing.allocator);

    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                var matched_row = false;
                for (row_y.items, row_min_x.items) |baseline_y, *min_x| {
                    if (@abs(text.y - baseline_y) <= 8) {
                        min_x.* = @min(min_x.*, text.x);
                        matched_row = true;
                        break;
                    }
                }
                if (!matched_row) {
                    try row_y.append(std.testing.allocator, text.y);
                    try row_min_x.append(std.testing.allocator, text.x);
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 3), row_y.items.len);
    try std.testing.expect(row_min_x.items[0] > 110);
    try std.testing.expect(row_min_x.items[2] > row_min_x.items[0] + 40);
}

test "paintDocument centers block heading labels using text-align center" {
    var page = try testing.pageTest("page/centered_inline_heading_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 900,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var min_x: ?i32 = null;
    var max_right: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                min_x = if (min_x) |current| @min(current, text.x) else text.x;
                max_right = if (max_right) |current| @max(current, text.x + text.width) else (text.x + text.width);
            },
            else => {},
        }
    }

    try std.testing.expect(min_x != null);
    try std.testing.expect(max_right != null);
    const span_center = @divTrunc(min_x.? + max_right.?, 2);
    try std.testing.expect(span_center > 280);
    try std.testing.expect(span_center < 340);
}

test "paintDocument keeps centered consent-card sections stacked and de-duplicated" {
    var page = try testing.pageTest("page/consent_card_center_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 1280,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var logo_bottom: ?i32 = null;
    var heading_min_y: ?i32 = null;
    var heading_max_bottom: ?i32 = null;
    var copy_min_y: ?i32 = null;
    var copy_max_bottom: ?i32 = null;
    var buttons_min_y: ?i32 = null;
    var footer_min_y: ?i32 = null;
    var cookies_count: usize = 0;
    var cookies_y: ?i32 = null;
    var and_y: ?i32 = null;
    var language_x: ?i32 = null;
    var privacy_x: ?i32 = null;
    var terms_x: ?i32 = null;

    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r == 66 and rect.color.g == 133 and rect.color.b == 244 and rect.width <= 90 and rect.height <= 40) {
                    logo_bottom = rect.y + rect.height;
                }
            },
            .text => |text| {
                if (std.mem.eql(u8, std.mem.trim(u8, text.text, " "), "cookies")) {
                    cookies_count += 1;
                    cookies_y = text.y;
                    copy_min_y = if (copy_min_y) |current| @min(current, text.y) else text.y;
                    copy_max_bottom = if (copy_max_bottom) |current| @max(current, text.y + text.height) else (text.y + text.height);
                    continue;
                }
                if (std.mem.eql(u8, std.mem.trim(u8, text.text, " "), "and")) {
                    and_y = text.y;
                }
                if (std.mem.indexOf(u8, text.text, "English") != null) {
                    language_x = text.x;
                    footer_min_y = if (footer_min_y) |current| @min(current, text.y) else text.y;
                }
                if (std.mem.indexOf(u8, text.text, "Privacy") != null) {
                    privacy_x = text.x;
                    footer_min_y = if (footer_min_y) |current| @min(current, text.y) else text.y;
                }
                if (std.mem.indexOf(u8, text.text, "Terms") != null) {
                    terms_x = text.x;
                    footer_min_y = if (footer_min_y) |current| @min(current, text.y) else text.y;
                }
                if (std.mem.indexOf(u8, text.text, "Before") != null or
                    std.mem.indexOf(u8, text.text, "continue") != null or
                    std.mem.indexOf(u8, text.text, "Google") != null or
                    std.mem.indexOf(u8, text.text, "Search") != null)
                {
                    heading_min_y = if (heading_min_y) |current| @min(current, text.y) else text.y;
                    heading_max_bottom = if (heading_max_bottom) |current| @max(current, text.y + text.height) else (text.y + text.height);
                } else if (std.mem.indexOf(u8, text.text, "We") != null or
                    std.mem.indexOf(u8, text.text, "data") != null or
                    std.mem.indexOf(u8, text.text, "deliver") != null or
                    std.mem.indexOf(u8, text.text, "maintain") != null or
                    std.mem.indexOf(u8, text.text, "services") != null)
                {
                    copy_min_y = if (copy_min_y) |current| @min(current, text.y) else text.y;
                    copy_max_bottom = if (copy_max_bottom) |current| @max(current, text.y + text.height) else (text.y + text.height);
                }
            },
            else => {},
        }
    }
    for (display_list.control_regions.items) |region| {
        buttons_min_y = if (buttons_min_y) |current| @min(current, region.y) else region.y;
    }

    try std.testing.expectEqual(@as(usize, 1), cookies_count);
    try std.testing.expect(cookies_y != null);
    try std.testing.expect(and_y != null);
    try std.testing.expect(logo_bottom != null);
    try std.testing.expect(heading_min_y != null);
    try std.testing.expect(heading_max_bottom != null);
    try std.testing.expect(copy_min_y != null);
    try std.testing.expect(copy_max_bottom != null);
    try std.testing.expect(buttons_min_y != null);
    try std.testing.expect(footer_min_y != null);
    try std.testing.expect(language_x != null);
    try std.testing.expect(privacy_x != null);
    try std.testing.expect(terms_x != null);
    const copy_line_delta = if (and_y.? >= cookies_y.?) and_y.? - cookies_y.? else cookies_y.? - and_y.?;
    try std.testing.expect(copy_line_delta <= 8);
    try std.testing.expect(heading_min_y.? > logo_bottom.? + 12);
    try std.testing.expect(copy_min_y.? > heading_max_bottom.? + 12);
    try std.testing.expect(buttons_min_y.? > copy_max_bottom.? + 16);
    try std.testing.expect(footer_min_y.? > buttons_min_y.? + 40);
    try std.testing.expect(privacy_x.? > language_x.? + 120);
    try std.testing.expect(terms_x.? > privacy_x.? + 80);
}

test "paintDocument renders one wide consent submit row with visible filled labels" {
    var page = try testing.pageTest("page/consent_submit_responsive_layout.html");
    defer page._session.removePage();

    page.window._visual_viewport.setMetrics(1280, 720, 1.0);

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 1280,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), display_list.control_regions.items.len);

    var reject_count: usize = 0;
    var accept_count: usize = 0;
    var reject_text: ?TextCommand = null;
    var accept_text: ?TextCommand = null;
    var more_text: ?TextCommand = null;

    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                const trimmed = std.mem.trim(u8, text.text, " ");
                if (std.mem.eql(u8, trimmed, "Reject all")) {
                    reject_count += 1;
                    reject_text = text;
                } else if (std.mem.eql(u8, trimmed, "Accept all")) {
                    accept_count += 1;
                    accept_text = text;
                } else if (std.mem.eql(u8, trimmed, "More options")) {
                    more_text = text;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), reject_count);
    try std.testing.expectEqual(@as(usize, 1), accept_count);

    const reject = reject_text orelse return error.ConsentRejectLabelMissing;
    const accept = accept_text orelse return error.ConsentAcceptLabelMissing;
    _ = more_text orelse return error.ConsentMoreOptionsLabelMissing;

    try std.testing.expectEqual(@as(u8, 255), reject.color.r);
    try std.testing.expectEqual(@as(u8, 255), reject.color.g);
    try std.testing.expectEqual(@as(u8, 255), reject.color.b);
    try std.testing.expectEqual(@as(u8, 255), accept.color.r);
    try std.testing.expectEqual(@as(u8, 255), accept.color.g);
    try std.testing.expectEqual(@as(u8, 255), accept.color.b);
    try std.testing.expect(reject.y >= 250);
    try std.testing.expectEqual(reject.y, accept.y);
    try std.testing.expect(reject.x + reject.width < accept.x + accept.width);
}

test "paintDocument keeps width 100 inline-block row wide inside centered flex column" {
    var page = try testing.pageTest("page/consent_submit_column_flex_layout.html");
    defer page._session.removePage();

    page.window._visual_viewport.setMetrics(1280, 720, 1.0);

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 1280,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    const card = page.window._document.getElementById("card", page) orelse return error.ConsentColumnCardMissing;
    const action_row = page.window._document.getElementById("action-row", page) orelse return error.ConsentColumnActionRowMissing;
    const more_options = page.window._document.getElementById("more-options", page) orelse return error.ConsentColumnMoreOptionsMissing;
    const card_box = page._element_layout_boxes.get(card) orelse return error.ConsentColumnCardLayoutBoxMissing;
    const action_row_box = page._element_layout_boxes.get(action_row) orelse return error.ConsentColumnActionRowLayoutBoxMissing;
    const more_options_box = page._element_layout_boxes.get(more_options) orelse return error.ConsentColumnMoreOptionsLayoutBoxMissing;

    try std.testing.expect(action_row_box.width >= card_box.width - 4);
    try std.testing.expect(more_options_box.y >= action_row_box.y + action_row_box.height + 8);

    try std.testing.expectEqual(@as(usize, 2), display_list.control_regions.items.len);
    const reject_region = display_list.control_regions.items[0];
    const accept_region = display_list.control_regions.items[1];
    try std.testing.expectEqual(reject_region.y, accept_region.y);
    try std.testing.expect(accept_region.x > reject_region.x + reject_region.width);
}

test "paintDocument sizes submit inputs from label instead of generic text-input width" {
    var page = try testing.pageTest("page/input_submit_sizing_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), display_list.control_regions.items.len);

    const text_input = display_list.control_regions.items[0];
    const submit_input = display_list.control_regions.items[1];

    try std.testing.expect(text_input.width >= 160);
    try std.testing.expect(submit_input.width <= 100);
    try std.testing.expect(submit_input.width < text_input.width);
}

test "paintDocument keeps inline footer select controls and later links on the footer row" {
    var page = try testing.pageTest("page/consent_footer_inline_controls_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 1280,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    var buttons_min_y: ?i32 = null;
    for (display_list.control_regions.items) |region| {
        if (region.width >= 100 and region.height >= 30) {
            buttons_min_y = if (buttons_min_y) |current| @min(current, region.y) else region.y;
        }
    }

    const footer = page.window._document.getElementById("footer", page);
    const language_form = page.window._document.getElementById("language-form", page);
    const language_select = page.window._document.getElementById("language-select", page);
    const privacy = page.window._document.getElementById("privacy", page);
    const terms = page.window._document.getElementById("terms", page);

    try std.testing.expect(footer != null);
    try std.testing.expect(language_form != null);
    try std.testing.expect(language_select != null);
    try std.testing.expect(privacy != null);
    try std.testing.expect(terms != null);
    try std.testing.expect(buttons_min_y != null);

    const footer_rect = footer.?.getBoundingClientRect(page);
    const form_rect = language_form.?.getBoundingClientRect(page);
    const select_rect = language_select.?.getBoundingClientRect(page);
    const privacy_rect = privacy.?.getBoundingClientRect(page);
    const terms_rect = terms.?.getBoundingClientRect(page);

    try std.testing.expect(footer_rect._y > @as(f64, @floatFromInt(buttons_min_y.? + 12)));
    try std.testing.expect(form_rect._y > @as(f64, @floatFromInt(buttons_min_y.? + 12)));
    try std.testing.expect(select_rect._y > @as(f64, @floatFromInt(buttons_min_y.? + 12)));
    try std.testing.expect(privacy_rect._y > @as(f64, @floatFromInt(buttons_min_y.? + 12)));
    try std.testing.expect(terms_rect._y > @as(f64, @floatFromInt(buttons_min_y.? + 12)));

    try std.testing.expect(select_rect._width >= 120);
    try std.testing.expect(privacy_rect._x > select_rect._x + select_rect._width + 12);
    try std.testing.expect(terms_rect._x > privacy_rect._x + privacy_rect._width + 12);
}

test "paintDocument ignores hidden and script descendants when sizing inline submit wrappers" {
    var page = try testing.pageTest("page/input_submit_wrapper_hidden_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 720,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), display_list.control_regions.items.len);

    const submit_input = display_list.control_regions.items[0];
    try std.testing.expect(submit_input.width <= 160);

    var widest_wrapper_rect: i32 = 0;
    for (display_list.commands.items) |command| {
        const rect = switch (command) {
            .fill_rect => |value| value,
            .stroke_rect => |value| value,
            else => continue,
        };
        if (rect.color.a == 0) continue;
        if (rect.color.r == 255 and rect.color.g == 255 and rect.color.b == 255) continue;
        if (rect.x > submit_input.x or rect.x + rect.width < submit_input.x + submit_input.width) continue;
        if (rect.y > submit_input.y + submit_input.height or rect.y + rect.height < submit_input.y) continue;
        widest_wrapper_rect = @max(widest_wrapper_rect, rect.width);
    }

    try std.testing.expect(widest_wrapper_rect > 0);
    try std.testing.expect(widest_wrapper_rect <= submit_input.width + 24);
}

test "paintDocument composites iframe child content into the iframe box without exposing child hit regions" {
    var page = try testing.pageTest("page/iframe_paint_layout.html");
    defer page._session.removePage();

    const iframe = (try page.window._document.querySelector(.wrap("#embed"), page)).?;
    const iframe_html = iframe.is(Element.Html.IFrame) orelse return error.IFramePaintElementMissing;
    const frame_window = iframe_html.getContentWindow() orelse return error.IFramePaintWindowMissing;
    try std.testing.expect(std.mem.indexOf(u8, frame_window._page.url, "iframe_paint_child.html") != null);

    var frame_doc_text: ?[:0]const u8 = null;
    defer if (frame_doc_text) |text| std.testing.allocator.free(text);
    var settle_timer = try std.time.Timer.start();
    while (settle_timer.read() < (std.time.ns_per_ms * 2000)) {
        _ = page._session.wait(50);
        testing.test_browser.runMicrotasks();
        const frame_doc = iframe_html.getContentDocument() orelse continue;
        const html_doc = frame_doc.is(HTMLDocument) orelse continue;
        const body = html_doc.getBody() orelse continue;
        const text = try body.asNode().getTextContentAlloc(std.testing.allocator);
        if (std.mem.indexOf(u8, text, "Frame hello") != null) {
            frame_doc_text = text;
            break;
        }
        std.testing.allocator.free(text);
        std.Thread.sleep(std.time.ns_per_ms * 10);
    }
    try std.testing.expect(frame_doc_text != null);

    const frame_doc = iframe_html.getContentDocument() orelse return error.IFramePaintDocumentMissing;
    const frame_html_doc = frame_doc.is(HTMLDocument) orelse return error.IFramePaintHtmlDocumentMissing;
    _ = frame_html_doc.getBody() orelse return error.IFramePaintBodyMissing;

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 320,
    });
    defer display_list.deinit(std.testing.allocator);

    const iframe_rect = iframe.getBoundingClientRect(page);
    var iframe_inner_list = (try resolvedIFrameContentDisplayList(
        std.testing.allocator,
        iframe,
        page,
        .{
            .viewport_width = 640,
            .viewport_height = 320,
        },
        @as(i32, @intFromFloat(@round(iframe_rect._width))),
        @as(i32, @intFromFloat(@round(iframe_rect._height))),
    )).?;
    defer iframe_inner_list.deinit(std.testing.allocator);

    var iframe_inner_text = std.ArrayList(u8){};
    defer iframe_inner_text.deinit(std.testing.allocator);
    for (iframe_inner_list.commands.items) |command| {
        const text = switch (command) {
            .text => |value| value,
            else => continue,
        };
        try iframe_inner_text.appendSlice(std.testing.allocator, text.text);
        try iframe_inner_text.append(std.testing.allocator, ' ');
    }
    try std.testing.expect(std.mem.indexOf(u8, iframe_inner_text.items, "Frame") != null);
    try std.testing.expect(std.mem.indexOf(u8, iframe_inner_text.items, "hello") != null);

    var composited_text = std.ArrayList(u8){};
    defer composited_text.deinit(std.testing.allocator);
    var saw_iframe_text_clip = false;
    for (display_list.commands.items) |command| {
        const text = switch (command) {
            .text => |value| value,
            else => continue,
        };
        try composited_text.appendSlice(std.testing.allocator, text.text);
        try composited_text.append(std.testing.allocator, ' ');
        if (std.mem.indexOf(u8, text.text, "Frame") == null and std.mem.indexOf(u8, text.text, "hello") == null) {
            continue;
        }
        if (text.clip_rect) |clip| {
            try std.testing.expectEqual(@as(i32, @intFromFloat(@round(iframe_rect._x))), clip.x);
            try std.testing.expectEqual(@as(i32, @intFromFloat(@round(iframe_rect._y))), clip.y);
            try std.testing.expectEqual(@as(i32, @intFromFloat(@round(iframe_rect._width))), clip.width);
            try std.testing.expectEqual(@as(i32, @intFromFloat(@round(iframe_rect._height))), clip.height);
            saw_iframe_text_clip = true;
        }
    }

    try std.testing.expect(std.mem.indexOf(u8, composited_text.items, "Frame") != null);
    try std.testing.expect(std.mem.indexOf(u8, composited_text.items, "hello") != null);
    try std.testing.expect(saw_iframe_text_clip);
    try std.testing.expectEqual(@as(usize, 0), display_list.control_regions.items.len);
}

test "paintDocument ignores noscript fallback text when scripting is enabled" {
    var page = try testing.pageTest("page/noscript_render_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    var saw_visible = false;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                try std.testing.expect(!std.mem.containsAtLeast(u8, text.text, 1, "Enable javascript"));
                if (std.mem.containsAtLeast(u8, text.text, 1, "Visible") or
                    std.mem.containsAtLeast(u8, text.text, 1, "content"))
                {
                    saw_visible = true;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(saw_visible);
}

test "paintDocument shrink-wraps auto-width absolute nav bars when only one edge is pinned" {
    var page = try testing.pageTest("page/absolute_auto_width_nav_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    var search_x: ?i32 = null;
    var sign_in_x: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Search")) search_x = text.x;
                if (std.mem.eql(u8, text.text, "Sign in")) sign_in_x = text.x;
            },
            else => {},
        }
    }

    const search = search_x orelse return error.AbsoluteAutoWidthSearchMissing;
    const sign_in = sign_in_x orelse return error.AbsoluteAutoWidthSignInMissing;

    try std.testing.expect(search < 60);
    try std.testing.expect(sign_in > 760);
}

test "paintDocument inherits google-tab text styles into nested span labels" {
    var page = try testing.pageTest("page/google_tab_text_inheritance_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    var search_text: ?TextCommand = null;
    var images_text: ?TextCommand = null;
    var sign_in_text: ?TextCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Search")) {
                    search_text = text;
                } else if (std.mem.eql(u8, text.text, "Images")) {
                    images_text = text;
                } else if (std.mem.eql(u8, text.text, "Sign in")) {
                    sign_in_text = text;
                }
            },
            else => {},
        }
    }

    const search = search_text orelse return error.GoogleTabSearchMissing;
    const images = images_text orelse return error.GoogleTabImagesMissing;
    const sign_in = sign_in_text orelse return error.GoogleTabSignInMissing;

    try std.testing.expectEqual(@as(i32, 13), search.font_size);
    try std.testing.expectEqual(@as(i32, 13), images.font_size);
    try std.testing.expectEqual(@as(i32, 27), search.height);
    try std.testing.expectEqual(@as(i32, 27), images.height);
    try std.testing.expect(sign_in.nowrap);
    try std.testing.expect(search.font_weight >= 700);
    try std.testing.expect(search.color.r >= 240);
    try std.testing.expect(search.color.g >= 240);
    try std.testing.expect(search.color.b >= 240);
    try std.testing.expect(images.color.r >= 190 and images.color.r <= 210);
    try std.testing.expect(images.color.g >= 190 and images.color.g <= 210);
    try std.testing.expect(images.color.b >= 190 and images.color.b <= 210);
    try std.testing.expect(sign_in.color.r >= 190 and sign_in.color.r <= 210);
    try std.testing.expect(sign_in.color.g >= 190 and sign_in.color.g <= 210);
    try std.testing.expect(sign_in.color.b >= 190 and sign_in.color.b <= 210);
}

test "paintDocument sizes split-word pill controls to the full inline label" {
    var page = try testing.pageTest("page/pill_split_word_controls_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 480,
        .viewport_height = 240,
    });
    defer display_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), display_list.control_regions.items.len);
    const left_button = display_list.control_regions.items[0];
    const right_button = display_list.control_regions.items[1];
    const more_button = if (left_button.x <= right_button.x) left_button else right_button;
    const sign_button = if (left_button.x <= right_button.x) right_button else left_button;

    var more_text: ?TextCommand = null;
    var options_text: ?TextCommand = null;
    var sign_text: ?TextCommand = null;
    var in_text: ?TextCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                const trimmed = std.mem.trim(u8, text.text, " ");
                if (std.mem.eql(u8, trimmed, "More")) {
                    more_text = text;
                } else if (std.mem.eql(u8, trimmed, "options")) {
                    options_text = text;
                } else if (std.mem.eql(u8, trimmed, "Sign")) {
                    sign_text = text;
                } else if (std.mem.eql(u8, trimmed, "in")) {
                    in_text = text;
                }
            },
            else => {},
        }
    }

    const more = more_text orelse return error.SplitWordMoreMissing;
    const options = options_text orelse return error.SplitWordOptionsMissing;
    const sign = sign_text orelse return error.SplitWordSignMissing;
    const in_word = in_text orelse return error.SplitWordInMissing;

    try std.testing.expect(more_button.width >= more.width + options.width + 12);
    try std.testing.expect(sign_button.width >= sign.width + in_word.width + 12);
    try std.testing.expectEqual(more.y, options.y);
    try std.testing.expectEqual(sign.y, in_word.y);
}

test "paintDocument honors custom properties for block layout and paint" {
    var page = try testing.pageTest("page/custom_property_layout.html");
    defer page._session.removePage();

    const theme_element = (try page.window._document.querySelector(.wrap(".theme"), page)).?;
    const card_element = (try page.window._document.querySelector(.wrap(".card"), page)).?;
    const chip_element = (try page.window._document.querySelector(.wrap(".chip"), page)).?;
    const theme_style = try page.window.getComputedStyle(theme_element, null, page);
    const card_style = try page.window.getComputedStyle(card_element, null, page);
    const chip_style = try page.window.getComputedStyle(chip_element, null, page);
    try std.testing.expectEqualStrings("#1a73e8", theme_style.asCSSStyleDeclaration().getPropertyValue("--chip-color", page));
    try std.testing.expectEqualStrings("#1a73e8", card_style.asCSSStyleDeclaration().getPropertyValue("--chip-color", page));
    try std.testing.expectEqualStrings("#1a73e8", chip_style.asCSSStyleDeclaration().getPropertyValue("--chip-color", page));
    try std.testing.expectEqualStrings("#1a73e8", chip_style.asCSSStyleDeclaration().getPropertyValue("background-color", page));

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 640,
        .viewport_height = 320,
    });
    defer display_list.deinit(std.testing.allocator);

    var card_rect: ?Bounds = null;
    var chip_rect: ?Bounds = null;
    var chip_text: ?TextCommand = null;
    var copy_y: ?i32 = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r >= 230 and rect.color.g >= 235 and rect.color.b >= 238) {
                    card_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                } else if (rect.color.r <= 40 and rect.color.g >= 100 and rect.color.b >= 200) {
                    chip_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
                }
            },
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Accept all")) {
                    chip_text = text;
                } else if (std.mem.indexOf(u8, text.text, "Cookies") != null or std.mem.indexOf(u8, text.text, "data") != null) {
                    copy_y = if (copy_y) |existing| @min(existing, text.y) else text.y;
                }
            },
            else => {},
        }
    }

    const card = card_rect orelse return error.CustomPropertyCardMissing;
    const chip = chip_rect orelse return error.CustomPropertyChipMissing;
    const chip_label = chip_text orelse return error.CustomPropertyChipLabelMissing;
    const copy = copy_y orelse return error.CustomPropertyCopyMissing;

    try std.testing.expectEqual(@as(i32, 240), card.width);
    try std.testing.expect(chip.width >= chip_label.width + 30);
    try std.testing.expect(copy >= chip.y + chip.height + 10);
}

test "paintDocument marks white-space nowrap text commands and keeps them single-line" {
    var page = try testing.pageTest("page/nowrap_text_layout.html");
    defer page._session.removePage();

    const cta = (try page.window._document.querySelector(.wrap(".cta"), page)).?;
    const cta_style = try page.window.getComputedStyle(cta, null, page);
    try std.testing.expectEqualStrings("nowrap", cta_style.asCSSStyleDeclaration().getPropertyValue("white-space", page));

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 320,
        .viewport_height = 180,
    });
    defer display_list.deinit(std.testing.allocator);

    var cta_text: ?TextCommand = null;
    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Sign in")) {
                    cta_text = text;
                }
            },
            else => {},
        }
    }

    const text = cta_text orelse return error.NowrapTextMissing;
    try std.testing.expect(text.nowrap);
    try std.testing.expect(text.height <= text.font_size + 16);
}

test "paintDocument applies text spacing and transform styles to inline text" {
    var page = try testing.pageTest("page/text_style_rendering_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var mono_texts: [2]TextCommand = undefined;
    var mono_count: usize = 0;
    var alpha_texts: [2]TextCommand = undefined;
    var alpha_count: usize = 0;
    var beta_texts: [2]TextCommand = undefined;
    var beta_count: usize = 0;
    var caps_text: ?TextCommand = null;

    for (display_list.commands.items) |command| {
        switch (command) {
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Mono") and mono_count < mono_texts.len) {
                    mono_texts[mono_count] = text;
                    mono_count += 1;
                } else if (std.mem.startsWith(u8, text.text, "Alpha") and alpha_count < alpha_texts.len) {
                    alpha_texts[alpha_count] = text;
                    alpha_count += 1;
                } else if (std.mem.startsWith(u8, text.text, "Beta") and beta_count < beta_texts.len) {
                    beta_texts[beta_count] = text;
                    beta_count += 1;
                } else if (std.mem.eql(u8, text.text, "GOOGLE")) {
                    caps_text = text;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 2), mono_count);
    try std.testing.expectEqual(@as(usize, 2), alpha_count);
    try std.testing.expectEqual(@as(usize, 2), beta_count);

    const mono_base = if (mono_texts[0].y <= mono_texts[1].y) mono_texts[0] else mono_texts[1];
    const mono_spaced = if (mono_texts[0].y <= mono_texts[1].y) mono_texts[1] else mono_texts[0];
    try std.testing.expect(mono_base.x >= mono_spaced.x + 4);

    const alpha_base = if (alpha_texts[0].y <= alpha_texts[1].y) alpha_texts[0] else alpha_texts[1];
    const alpha_spaced = if (alpha_texts[0].y <= alpha_texts[1].y) alpha_texts[1] else alpha_texts[0];
    const beta_base = if (beta_texts[0].y <= beta_texts[1].y) beta_texts[0] else beta_texts[1];
    const beta_spaced = if (beta_texts[0].y <= beta_texts[1].y) beta_texts[1] else beta_texts[0];
    const base_gap = beta_base.x - (alpha_base.x + alpha_base.width);
    const spaced_gap = beta_spaced.x - (alpha_spaced.x + alpha_spaced.width);
    try std.testing.expect(spaced_gap >= base_gap + 8);

    const caps = caps_text orelse return error.TransformTextMissing;
    try std.testing.expectEqualStrings("GOOGLE", caps.text);
    try std.testing.expectEqual(@as(i32, 30), caps.height);
}

test "paintDocument threads nested opacity through painted commands" {
    var page = try testing.pageTest("page/opacity_rendering_layout.html");
    defer page._session.removePage();

    var display_list = try paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 360,
    });
    defer display_list.deinit(std.testing.allocator);

    var outer_fill: ?RectCommand = null;
    var inner_fill: ?RectCommand = null;
    var outer_text: ?TextCommand = null;
    var inner_text: ?TextCommand = null;

    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                if (rect.color.r == 0 and rect.color.g == 0 and rect.color.b == 255) {
                    outer_fill = rect;
                } else if (rect.color.r == 255 and rect.color.g == 0 and rect.color.b == 0) {
                    inner_fill = rect;
                }
            },
            .text => |text| {
                if (std.mem.eql(u8, text.text, "Outer")) {
                    outer_text = text;
                } else if (std.mem.eql(u8, text.text, "Inner")) {
                    inner_text = text;
                }
            },
            else => {},
        }
    }

    const outer_box = outer_fill orelse return error.OuterOpacityFillMissing;
    const inner_box = inner_fill orelse return error.InnerOpacityFillMissing;
    const outer_label = outer_text orelse return error.OuterOpacityTextMissing;
    const inner_label = inner_text orelse return error.InnerOpacityTextMissing;

    try std.testing.expectEqual(@as(u8, 128), outer_box.opacity);
    try std.testing.expectEqual(@as(u8, 64), inner_box.opacity);
    try std.testing.expectEqual(@as(u8, 128), outer_label.opacity);
    try std.testing.expectEqual(@as(u8, 64), inner_label.opacity);
}
