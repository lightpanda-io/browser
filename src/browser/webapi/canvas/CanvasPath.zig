const std = @import("std");

const color = @import("../../color.zig");
const CanvasSurface = @import("CanvasSurface.zig");

const CanvasPath = @This();

const Point = struct {
    x: f64,
    y: f64,
};

const Subpath = struct {
    start: usize,
    len: usize,
    closed: bool = false,
};

points: std.ArrayListUnmanaged(Point) = .{},
subpaths: std.ArrayListUnmanaged(Subpath) = .{},
current_subpath: ?usize = null,
current_point: ?Point = null,

pub fn deinit(self: *CanvasPath, allocator: std.mem.Allocator) void {
    self.points.deinit(allocator);
    self.subpaths.deinit(allocator);
    self.* = .{};
}

pub fn beginPath(self: *CanvasPath) void {
    self.points.clearRetainingCapacity();
    self.subpaths.clearRetainingCapacity();
    self.current_subpath = null;
    self.current_point = null;
}

pub fn moveTo(self: *CanvasPath, allocator: std.mem.Allocator, x: f64, y: f64) !void {
    const start = self.points.items.len;
    try self.points.append(allocator, .{ .x = x, .y = y });
    try self.subpaths.append(allocator, .{
        .start = start,
        .len = 1,
        .closed = false,
    });
    self.current_subpath = self.subpaths.items.len - 1;
    self.current_point = .{ .x = x, .y = y };
}

pub fn lineTo(self: *CanvasPath, allocator: std.mem.Allocator, x: f64, y: f64) !void {
    if (self.current_subpath == null) {
        return self.moveTo(allocator, x, y);
    }
    try self.points.append(allocator, .{ .x = x, .y = y });
    self.subpaths.items[self.current_subpath.?].len += 1;
    self.current_point = .{ .x = x, .y = y };
}

pub fn rect(self: *CanvasPath, allocator: std.mem.Allocator, x: f64, y: f64, width: f64, height: f64) !void {
    try self.moveTo(allocator, x, y);
    try self.lineTo(allocator, x + width, y);
    try self.lineTo(allocator, x + width, y + height);
    try self.lineTo(allocator, x, y + height);
    self.closePath();
}

pub fn closePath(self: *CanvasPath) void {
    if (self.current_subpath) |subpath_index| {
        self.subpaths.items[subpath_index].closed = true;
        const subpath = self.subpaths.items[subpath_index];
        if (subpath.len > 0) {
            self.current_point = self.points.items[subpath.start];
        }
    }
}

pub fn stroke(self: *const CanvasPath, surface: *CanvasSurface, stroke_color: color.RGBA) void {
    for (self.subpaths.items) |subpath| {
        if (subpath.len == 0) continue;

        const pts = self.points.items[subpath.start .. subpath.start + subpath.len];
        if (pts.len == 1) {
            surface.fillRect(stroke_color, pts[0].x, pts[0].y, 1, 1);
            continue;
        }

        var i: usize = 1;
        while (i < pts.len) : (i += 1) {
            surface.drawLine(stroke_color, pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y);
        }
        if (subpath.closed and pts.len >= 2) {
            surface.drawLine(stroke_color, pts[pts.len - 1].x, pts[pts.len - 1].y, pts[0].x, pts[0].y);
        }
    }
}

pub fn fill(self: *const CanvasPath, allocator: std.mem.Allocator, surface: *CanvasSurface, fill_color: color.RGBA) !void {
    var intersections = std.ArrayList(i32).empty;
    defer intersections.deinit(allocator);

    for (self.subpaths.items) |subpath| {
        if (subpath.len < 2) continue;
        const pts = self.points.items[subpath.start .. subpath.start + subpath.len];
        try fillPolygon(allocator, surface, fill_color, pts, &intersections);
    }
}

fn fillPolygon(
    allocator: std.mem.Allocator,
    surface: *CanvasSurface,
    fill_color: color.RGBA,
    points: []const Point,
    intersections: *std.ArrayList(i32),
) !void {
    if (points.len < 2) return;

    var min_y = points[0].y;
    var max_y = points[0].y;
    for (points[1..]) |point| {
        min_y = @min(min_y, point.y);
        max_y = @max(max_y, point.y);
    }

    var scan_y: i32 = @intFromFloat(@floor(min_y));
    const end_y: i32 = @intFromFloat(@ceil(max_y));
    while (scan_y <= end_y) : (scan_y += 1) {
        intersections.clearRetainingCapacity();
        const sample_y = @as(f64, @floatFromInt(scan_y)) + 0.5;

        var i: usize = 0;
        while (i < points.len) : (i += 1) {
            const a = points[i];
            const b = points[(i + 1) % points.len];
            if ((sample_y < @min(a.y, b.y)) or (sample_y >= @max(a.y, b.y)) or a.y == b.y) {
                continue;
            }

            const ratio = (sample_y - a.y) / (b.y - a.y);
            const x = a.x + (b.x - a.x) * ratio;
            try intersections.append(allocator, @intFromFloat(@floor(x)));
        }

        if (intersections.items.len < 2) continue;

        std.mem.sort(i32, intersections.items, {}, comptime std.sort.asc(i32));
        var idx: usize = 0;
        while (idx + 1 < intersections.items.len) : (idx += 2) {
            const start_x = intersections.items[idx];
            const end_x = intersections.items[idx + 1];
            surface.fillRect(fill_color, @floatFromInt(start_x), @floatFromInt(scan_y), @floatFromInt(end_x - start_x + 1), 1);
        }
    }
}
