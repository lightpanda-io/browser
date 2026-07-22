// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

const std = @import("std");

const Allocator = std.mem.Allocator;
const tau = 2.0 * std.math.pi;

pub const Point = struct {
    x: f64,
    y: f64,

    fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    fn midpoint(a: Point, b: Point) Point {
        return .{ .x = (a.x + b.x) / 2.0, .y = (a.y + b.y) / 2.0 };
    }
};

pub const Matrix = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub fn apply(self: Matrix, point: Point) Point {
        return .{
            .x = self.a * point.x + self.c * point.y + self.e,
            .y = self.b * point.x + self.d * point.y + self.f,
        };
    }

    pub fn multiply(self: Matrix, child: Matrix) Matrix {
        return .{
            .a = self.a * child.a + self.c * child.b,
            .b = self.b * child.a + self.d * child.b,
            .c = self.a * child.c + self.c * child.d,
            .d = self.b * child.c + self.d * child.d,
            .e = self.a * child.e + self.c * child.f + self.e,
            .f = self.b * child.e + self.d * child.f + self.f,
        };
    }
};

pub const Bounds = struct {
    min_x: f64 = std.math.inf(f64),
    min_y: f64 = std.math.inf(f64),
    max_x: f64 = -std.math.inf(f64),
    max_y: f64 = -std.math.inf(f64),

    pub fn include(self: *Bounds, point: Point) void {
        self.min_x = @min(self.min_x, point.x);
        self.min_y = @min(self.min_y, point.y);
        self.max_x = @max(self.max_x, point.x);
        self.max_y = @max(self.max_y, point.y);
    }

    pub fn merge(self: *Bounds, other: Bounds) void {
        if (other.isEmpty()) return;
        self.include(.{ .x = other.min_x, .y = other.min_y });
        self.include(.{ .x = other.max_x, .y = other.max_y });
    }

    pub fn isEmpty(self: Bounds) bool {
        return self.min_x > self.max_x or self.min_y > self.max_y;
    }

    pub fn width(self: Bounds) f64 {
        return if (self.isEmpty()) 0 else self.max_x - self.min_x;
    }

    pub fn height(self: Bounds) f64 {
        return if (self.isEmpty()) 0 else self.max_y - self.min_y;
    }
};

pub const Line = struct { start: Point, end: Point };
pub const Quadratic = struct { start: Point, control: Point, end: Point };
pub const Cubic = struct { start: Point, control1: Point, control2: Point, end: Point };
pub const Arc = struct {
    start: Point,
    end: Point,
    center: Point,
    rx: f64,
    ry: f64,
    rotation: f64,
    theta: f64,
    delta: f64,
};

pub const Segment = union(enum) {
    line: Line,
    quadratic: Quadratic,
    cubic: Cubic,
    arc: Arc,

    fn start(self: Segment) Point {
        return switch (self) {
            inline else => |segment| segment.start,
        };
    }

    fn end(self: Segment) Point {
        return switch (self) {
            inline else => |segment| segment.end,
        };
    }
};

pub const Path = struct {
    segments: std.ArrayList(Segment) = .empty,
    first_point: ?Point = null,

    pub fn deinit(self: *Path, allocator: Allocator) void {
        self.segments.deinit(allocator);
    }

    pub fn appendLine(self: *Path, start: Point, end: Point, allocator: Allocator) !void {
        if (self.first_point == null) self.first_point = start;
        try self.segments.append(allocator, .{ .line = .{ .start = start, .end = end } });
    }

    pub fn appendQuadratic(self: *Path, segment: Quadratic, allocator: Allocator) !void {
        if (self.first_point == null) self.first_point = segment.start;
        try self.segments.append(allocator, .{ .quadratic = segment });
    }

    pub fn appendCubic(self: *Path, segment: Cubic, allocator: Allocator) !void {
        if (self.first_point == null) self.first_point = segment.start;
        try self.segments.append(allocator, .{ .cubic = segment });
    }

    pub fn appendArc(self: *Path, start: Point, rx: f64, ry: f64, rotation: f64, large: bool, sweep: bool, end: Point, allocator: Allocator) !void {
        if (self.first_point == null) self.first_point = start;
        if (pointsEqual(start, end)) return;
        if (rx == 0 or ry == 0) return self.appendLine(start, end, allocator);
        const arc = endpointArc(start, rx, ry, rotation, large, sweep, end) orelse
            return self.appendLine(start, end, allocator);
        try self.segments.append(allocator, .{ .arc = arc });
    }

    pub fn bounds(self: *const Path, matrix: Matrix) Bounds {
        var result: Bounds = .{};
        for (self.segments.items) |segment| includeSegmentBounds(&result, segment, matrix);
        return result;
    }

    pub fn totalLength(self: *const Path, allocator: Allocator) !f64 {
        var total: f64 = 0;
        for (self.segments.items) |segment| total += try segmentLength(segment, allocator);
        return total;
    }

    pub fn pointAtLength(self: *const Path, requested: f64, allocator: Allocator) !Point {
        if (self.segments.items.len == 0) return self.first_point orelse .{ .x = 0, .y = 0 };

        var remaining = @max(requested, 0);
        for (self.segments.items, 0..) |segment, segment_index| {
            var points: std.ArrayList(Point) = .empty;
            defer points.deinit(allocator);
            try flatten(segment, &points, allocator);

            for (points.items[0 .. points.items.len - 1], points.items[1..]) |a, b| {
                const length = distance(a, b);
                if (remaining <= length) {
                    if (length == 0) return b;
                    const ratio = remaining / length;
                    return .{
                        .x = a.x + (b.x - a.x) * ratio,
                        .y = a.y + (b.y - a.y) * ratio,
                    };
                }
                remaining -= length;
            }

            if (segment_index + 1 == self.segments.items.len) return segment.end();
        }
        unreachable;
    }
};

const Previous = enum { other, cubic, quadratic };

pub fn parse(input: []const u8, allocator: Allocator) !Path {
    var path: Path = .{};
    errdefer path.deinit(allocator);

    var parser = Parser{ .input = input };
    var command: ?u8 = null;
    var command_fresh = false;
    var current = Point{ .x = 0, .y = 0 };
    var subpath_start = current;
    var last_control = current;
    var previous: Previous = .other;
    var saw_moveto = false;

    while (true) {
        parser.skipWhitespace();
        if (parser.atEnd()) break;

        const byte = parser.peek();
        if (isCommand(byte)) {
            parser.index += 1;
            command = byte;
            command_fresh = true;

            if (upper(byte) == 'Z') {
                if (!saw_moveto) break;
                try path.appendLine(current, subpath_start, allocator);
                current = subpath_start;
                previous = .other;
                command = null;
                continue;
            }
        } else if (std.ascii.isAlphabetic(byte) or command == null) {
            break;
        }

        const cmd = command.?;
        const kind = upper(cmd);
        if (!saw_moveto and kind != 'M') break;
        const relative = std.ascii.isLower(cmd);
        const allow_first_comma = !command_fresh;

        switch (kind) {
            'M', 'L' => {
                const x = parser.number(allow_first_comma) orelse break;
                const y = parser.number(true) orelse break;
                const end = absolutePoint(current, x, y, relative);
                if (kind == 'M') {
                    current = end;
                    subpath_start = end;
                    if (path.first_point == null) path.first_point = end;
                    saw_moveto = true;
                    command = if (relative) 'l' else 'L';
                } else {
                    try path.appendLine(current, end, allocator);
                    current = end;
                }
                previous = .other;
            },
            'H' => {
                const x = parser.number(allow_first_comma) orelse break;
                const end = Point{ .x = if (relative) current.x + x else x, .y = current.y };
                try path.appendLine(current, end, allocator);
                current = end;
                previous = .other;
            },
            'V' => {
                const y = parser.number(allow_first_comma) orelse break;
                const end = Point{ .x = current.x, .y = if (relative) current.y + y else y };
                try path.appendLine(current, end, allocator);
                current = end;
                previous = .other;
            },
            'C' => {
                const x1 = parser.number(allow_first_comma) orelse break;
                const y1 = parser.number(true) orelse break;
                const x2 = parser.number(true) orelse break;
                const y2 = parser.number(true) orelse break;
                const x = parser.number(true) orelse break;
                const y = parser.number(true) orelse break;
                const control1 = absolutePoint(current, x1, y1, relative);
                const control2 = absolutePoint(current, x2, y2, relative);
                const end = absolutePoint(current, x, y, relative);
                try path.appendCubic(.{ .start = current, .control1 = control1, .control2 = control2, .end = end }, allocator);
                current = end;
                last_control = control2;
                previous = .cubic;
            },
            'S' => {
                const x2 = parser.number(allow_first_comma) orelse break;
                const y2 = parser.number(true) orelse break;
                const x = parser.number(true) orelse break;
                const y = parser.number(true) orelse break;
                const control1 = if (previous == .cubic) reflect(last_control, current) else current;
                const control2 = absolutePoint(current, x2, y2, relative);
                const end = absolutePoint(current, x, y, relative);
                try path.appendCubic(.{ .start = current, .control1 = control1, .control2 = control2, .end = end }, allocator);
                current = end;
                last_control = control2;
                previous = .cubic;
            },
            'Q' => {
                const x1 = parser.number(allow_first_comma) orelse break;
                const y1 = parser.number(true) orelse break;
                const x = parser.number(true) orelse break;
                const y = parser.number(true) orelse break;
                const control = absolutePoint(current, x1, y1, relative);
                const end = absolutePoint(current, x, y, relative);
                try path.appendQuadratic(.{ .start = current, .control = control, .end = end }, allocator);
                current = end;
                last_control = control;
                previous = .quadratic;
            },
            'T' => {
                const x = parser.number(allow_first_comma) orelse break;
                const y = parser.number(true) orelse break;
                const control = if (previous == .quadratic) reflect(last_control, current) else current;
                const end = absolutePoint(current, x, y, relative);
                try path.appendQuadratic(.{ .start = current, .control = control, .end = end }, allocator);
                current = end;
                last_control = control;
                previous = .quadratic;
            },
            'A' => {
                const rx = parser.number(allow_first_comma) orelse break;
                const ry = parser.number(true) orelse break;
                const rotation = parser.number(true) orelse break;
                const large = parser.flag(true) orelse break;
                const sweep = parser.flag(true) orelse break;
                const x = parser.number(true) orelse break;
                const y = parser.number(true) orelse break;
                const end = absolutePoint(current, x, y, relative);
                try path.appendArc(current, rx, ry, rotation, large, sweep, end, allocator);
                current = end;
                previous = .other;
            },
            else => break,
        }
        command_fresh = false;
    }

    return path;
}

const Parser = struct {
    input: []const u8,
    index: usize = 0,

    fn atEnd(self: Parser) bool {
        return self.index >= self.input.len;
    }

    fn peek(self: Parser) u8 {
        return self.input[self.index];
    }

    fn skipWhitespace(self: *Parser) void {
        while (!self.atEnd() and isWhitespace(self.peek())) self.index += 1;
    }

    fn separator(self: *Parser, allow_comma: bool) bool {
        self.skipWhitespace();
        if (!self.atEnd() and self.peek() == ',') {
            if (!allow_comma) return false;
            self.index += 1;
            self.skipWhitespace();
            if (self.atEnd() or self.peek() == ',') return false;
        }
        return true;
    }

    fn number(self: *Parser, allow_comma: bool) ?f64 {
        if (!self.separator(allow_comma)) return null;
        const start = self.index;
        if (self.atEnd()) return null;

        if (self.peek() == '+' or self.peek() == '-') self.index += 1;
        var digits: usize = 0;
        while (!self.atEnd() and std.ascii.isDigit(self.peek())) : (self.index += 1) digits += 1;
        if (!self.atEnd() and self.peek() == '.') {
            self.index += 1;
            while (!self.atEnd() and std.ascii.isDigit(self.peek())) : (self.index += 1) digits += 1;
        }
        if (digits == 0) {
            self.index = start;
            return null;
        }

        if (!self.atEnd() and (self.peek() == 'e' or self.peek() == 'E')) {
            self.index += 1;
            if (!self.atEnd() and (self.peek() == '+' or self.peek() == '-')) self.index += 1;
            const exponent_start = self.index;
            while (!self.atEnd() and std.ascii.isDigit(self.peek())) self.index += 1;
            if (self.index == exponent_start) {
                self.index = start;
                return null;
            }
        }

        const value = std.fmt.parseFloat(f64, self.input[start..self.index]) catch {
            self.index = start;
            return null;
        };
        if (!std.math.isFinite(value)) {
            self.index = start;
            return null;
        }
        return value;
    }

    fn flag(self: *Parser, allow_comma: bool) ?bool {
        if (!self.separator(allow_comma) or self.atEnd()) return null;
        return switch (self.peek()) {
            '0' => blk: {
                self.index += 1;
                break :blk false;
            },
            '1' => blk: {
                self.index += 1;
                break :blk true;
            },
            else => null,
        };
    }
};

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '\x0c';
}

fn isCommand(byte: u8) bool {
    return switch (upper(byte)) {
        'M', 'Z', 'L', 'H', 'V', 'C', 'S', 'Q', 'T', 'A' => true,
        else => false,
    };
}

fn upper(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'z') byte - ('a' - 'A') else byte;
}

fn absolutePoint(origin: Point, x: f64, y: f64, relative: bool) Point {
    return if (relative) Point.add(origin, .{ .x = x, .y = y }) else .{ .x = x, .y = y };
}

fn reflect(control: Point, around: Point) Point {
    return .{ .x = 2.0 * around.x - control.x, .y = 2.0 * around.y - control.y };
}

fn pointsEqual(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn distance(a: Point, b: Point) f64 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}

fn endpointArc(start: Point, rx_input: f64, ry_input: f64, rotation_degrees: f64, large: bool, sweep: bool, end: Point) ?Arc {
    var rx = @abs(rx_input);
    var ry = @abs(ry_input);
    if (rx == 0 or ry == 0 or pointsEqual(start, end)) return null;

    const rotation = @mod(rotation_degrees, 360.0) * std.math.pi / 180.0;
    const cosine = @cos(rotation);
    const sine = @sin(rotation);
    const dx = (start.x - end.x) / 2.0;
    const dy = (start.y - end.y) / 2.0;
    const x_prime = cosine * dx + sine * dy;
    const y_prime = -sine * dx + cosine * dy;

    const radii_scale = x_prime * x_prime / (rx * rx) + y_prime * y_prime / (ry * ry);
    if (radii_scale > 1) {
        const scale = @sqrt(radii_scale);
        rx *= scale;
        ry *= scale;
    }

    const rx2 = rx * rx;
    const ry2 = ry * ry;
    const numerator = @max(0, rx2 * ry2 - rx2 * y_prime * y_prime - ry2 * x_prime * x_prime);
    const denominator = rx2 * y_prime * y_prime + ry2 * x_prime * x_prime;
    if (denominator == 0) return null;
    var coefficient = @sqrt(numerator / denominator);
    if (large == sweep) coefficient = -coefficient;

    const center_prime = Point{
        .x = coefficient * rx * y_prime / ry,
        .y = -coefficient * ry * x_prime / rx,
    };
    const center = Point{
        .x = cosine * center_prime.x - sine * center_prime.y + (start.x + end.x) / 2.0,
        .y = sine * center_prime.x + cosine * center_prime.y + (start.y + end.y) / 2.0,
    };

    const first = Point{
        .x = (x_prime - center_prime.x) / rx,
        .y = (y_prime - center_prime.y) / ry,
    };
    const second = Point{
        .x = (-x_prime - center_prime.x) / rx,
        .y = (-y_prime - center_prime.y) / ry,
    };
    const theta = std.math.atan2(first.y, first.x);
    var delta = std.math.atan2(first.x * second.y - first.y * second.x, first.x * second.x + first.y * second.y);
    if (sweep and delta < 0) delta += tau;
    if (!sweep and delta > 0) delta -= tau;

    return .{
        .start = start,
        .end = end,
        .center = center,
        .rx = rx,
        .ry = ry,
        .rotation = rotation,
        .theta = theta,
        .delta = delta,
    };
}

fn includeSegmentBounds(bounds: *Bounds, segment: Segment, matrix: Matrix) void {
    bounds.include(matrix.apply(segment.start()));
    bounds.include(matrix.apply(segment.end()));

    switch (segment) {
        .line => {},
        .quadratic => |quadratic| {
            includeQuadraticExtremum(bounds, quadratic.start.x, quadratic.control.x, quadratic.end.x, quadratic, matrix);
            includeQuadraticExtremum(bounds, quadratic.start.y, quadratic.control.y, quadratic.end.y, quadratic, matrix);
            includeTransformedQuadraticExtrema(bounds, quadratic, matrix);
        },
        .cubic => |cubic| includeTransformedCubicExtrema(bounds, cubic, matrix),
        .arc => |arc| includeArcExtrema(bounds, arc, matrix),
    }
}

// The direct-axis roots help the identity case and are harmless duplicates for
// transformed paths. The transformed roots below are authoritative.
fn includeQuadraticExtremum(bounds: *Bounds, p0: f64, p1: f64, p2: f64, quadratic: Quadratic, matrix: Matrix) void {
    const denominator = p0 - 2.0 * p1 + p2;
    if (@abs(denominator) < 1e-14) return;
    const t = (p0 - p1) / denominator;
    if (t > 0 and t < 1) bounds.include(matrix.apply(evalQuadratic(quadratic, t)));
}

fn includeTransformedQuadraticExtrema(bounds: *Bounds, quadratic: Quadratic, matrix: Matrix) void {
    const p0 = matrix.apply(quadratic.start);
    const p1 = matrix.apply(quadratic.control);
    const p2 = matrix.apply(quadratic.end);
    for ([_][3]f64{ .{ p0.x, p1.x, p2.x }, .{ p0.y, p1.y, p2.y } }) |values| {
        const denominator = values[0] - 2.0 * values[1] + values[2];
        if (@abs(denominator) < 1e-14) continue;
        const t = (values[0] - values[1]) / denominator;
        if (t > 0 and t < 1) bounds.include(matrix.apply(evalQuadratic(quadratic, t)));
    }
}

fn includeTransformedCubicExtrema(bounds: *Bounds, cubic: Cubic, matrix: Matrix) void {
    const p0 = matrix.apply(cubic.start);
    const p1 = matrix.apply(cubic.control1);
    const p2 = matrix.apply(cubic.control2);
    const p3 = matrix.apply(cubic.end);
    for ([_][4]f64{ .{ p0.x, p1.x, p2.x, p3.x }, .{ p0.y, p1.y, p2.y, p3.y } }) |values| {
        const a = -values[0] + 3.0 * values[1] - 3.0 * values[2] + values[3];
        const b = 2.0 * (values[0] - 2.0 * values[1] + values[2]);
        const c = values[1] - values[0];
        for (quadraticRoots(a, b, c)) |root| {
            const t = root orelse continue;
            if (t > 0 and t < 1) bounds.include(matrix.apply(evalCubic(cubic, t)));
        }
    }
}

fn includeArcExtrema(bounds: *Bounds, arc: Arc, matrix: Matrix) void {
    const cosine = @cos(arc.rotation);
    const sine = @sin(arc.rotation);

    const x_cos = arc.rx * cosine;
    const x_sin = -arc.ry * sine;
    const y_cos = arc.rx * sine;
    const y_sin = arc.ry * cosine;

    const transformed = [_][2]f64{
        .{ matrix.a * x_cos + matrix.c * y_cos, matrix.a * x_sin + matrix.c * y_sin },
        .{ matrix.b * x_cos + matrix.d * y_cos, matrix.b * x_sin + matrix.d * y_sin },
    };
    for (transformed) |coefficients| {
        const candidate = std.math.atan2(coefficients[1], coefficients[0]);
        for ([_]f64{ candidate, candidate + std.math.pi }) |angle| {
            if (angleInSweep(angle, arc.theta, arc.delta)) bounds.include(matrix.apply(evalArc(arc, angle)));
        }
    }
}

fn quadraticRoots(a: f64, b: f64, c: f64) [2]?f64 {
    if (@abs(a) < 1e-14) {
        if (@abs(b) < 1e-14) return .{ null, null };
        return .{ -c / b, null };
    }
    const discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0) return .{ null, null };
    const root = @sqrt(discriminant);
    return .{ (-b + root) / (2.0 * a), (-b - root) / (2.0 * a) };
}

fn angleInSweep(angle: f64, start: f64, delta: f64) bool {
    if (delta >= 0) return positiveAngle(angle - start) <= delta + 1e-12;
    return positiveAngle(start - angle) <= -delta + 1e-12;
}

fn positiveAngle(angle: f64) f64 {
    var result = @mod(angle, tau);
    if (result < 0) result += tau;
    return result;
}

fn evalQuadratic(segment: Quadratic, t: f64) Point {
    const inverse = 1.0 - t;
    return .{
        .x = inverse * inverse * segment.start.x + 2.0 * inverse * t * segment.control.x + t * t * segment.end.x,
        .y = inverse * inverse * segment.start.y + 2.0 * inverse * t * segment.control.y + t * t * segment.end.y,
    };
}

fn evalCubic(segment: Cubic, t: f64) Point {
    const inverse = 1.0 - t;
    return .{
        .x = inverse * inverse * inverse * segment.start.x + 3.0 * inverse * inverse * t * segment.control1.x + 3.0 * inverse * t * t * segment.control2.x + t * t * t * segment.end.x,
        .y = inverse * inverse * inverse * segment.start.y + 3.0 * inverse * inverse * t * segment.control1.y + 3.0 * inverse * t * t * segment.control2.y + t * t * t * segment.end.y,
    };
}

fn evalArc(arc: Arc, angle: f64) Point {
    const cosine = @cos(arc.rotation);
    const sine = @sin(arc.rotation);
    const x = arc.rx * @cos(angle);
    const y = arc.ry * @sin(angle);
    return .{
        .x = arc.center.x + cosine * x - sine * y,
        .y = arc.center.y + sine * x + cosine * y,
    };
}

fn segmentLength(segment: Segment, allocator: Allocator) !f64 {
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(allocator);
    try flatten(segment, &points, allocator);

    var total: f64 = 0;
    for (points.items[0 .. points.items.len - 1], points.items[1..]) |a, b| total += distance(a, b);
    return total;
}

const flatten_tolerance = 0.001;
const flatten_depth = 18;

fn flatten(segment: Segment, points: *std.ArrayList(Point), allocator: Allocator) !void {
    try points.append(allocator, segment.start());
    switch (segment) {
        .line => |line| try points.append(allocator, line.end),
        .quadratic => |quadratic| try flattenQuadratic(quadratic, points, allocator, 0),
        .cubic => |cubic| try flattenCubic(cubic, points, allocator, 0),
        .arc => |arc| try flattenArc(arc, arc.theta, arc.theta + arc.delta, arc.start, arc.end, points, allocator, 0),
    }
}

fn flattenQuadratic(segment: Quadratic, points: *std.ArrayList(Point), allocator: Allocator, depth: usize) !void {
    if (depth >= flatten_depth or pointLineDistance(segment.control, segment.start, segment.end) <= flatten_tolerance) {
        return points.append(allocator, segment.end);
    }
    const a = Point.midpoint(segment.start, segment.control);
    const b = Point.midpoint(segment.control, segment.end);
    const middle = Point.midpoint(a, b);
    try flattenQuadratic(.{ .start = segment.start, .control = a, .end = middle }, points, allocator, depth + 1);
    try flattenQuadratic(.{ .start = middle, .control = b, .end = segment.end }, points, allocator, depth + 1);
}

fn flattenCubic(segment: Cubic, points: *std.ArrayList(Point), allocator: Allocator, depth: usize) !void {
    const flatness = @max(
        pointLineDistance(segment.control1, segment.start, segment.end),
        pointLineDistance(segment.control2, segment.start, segment.end),
    );
    if (depth >= flatten_depth or flatness <= flatten_tolerance) return points.append(allocator, segment.end);

    const a = Point.midpoint(segment.start, segment.control1);
    const b = Point.midpoint(segment.control1, segment.control2);
    const c = Point.midpoint(segment.control2, segment.end);
    const d = Point.midpoint(a, b);
    const e = Point.midpoint(b, c);
    const middle = Point.midpoint(d, e);
    try flattenCubic(.{ .start = segment.start, .control1 = a, .control2 = d, .end = middle }, points, allocator, depth + 1);
    try flattenCubic(.{ .start = middle, .control1 = e, .control2 = c, .end = segment.end }, points, allocator, depth + 1);
}

fn flattenArc(arc: Arc, start_angle: f64, end_angle: f64, start: Point, end: Point, points: *std.ArrayList(Point), allocator: Allocator, depth: usize) !void {
    const middle_angle = (start_angle + end_angle) / 2.0;
    const middle = evalArc(arc, middle_angle);
    if (depth >= flatten_depth or pointLineDistance(middle, start, end) <= flatten_tolerance) {
        return points.append(allocator, end);
    }
    try flattenArc(arc, start_angle, middle_angle, start, middle, points, allocator, depth + 1);
    try flattenArc(arc, middle_angle, end_angle, middle, end, points, allocator, depth + 1);
}

fn pointLineDistance(point: Point, start: Point, end: Point) f64 {
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const denominator = std.math.hypot(dx, dy);
    if (denominator == 0) return distance(point, start);
    return @abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x) / denominator;
}

test "path parser preserves complete packs before an error" {
    var path = try parse("M10 10 L20 20 30", std.testing.allocator);
    defer path.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), path.segments.items.len);
    const bounds = path.bounds(.{});
    try std.testing.expectEqual(@as(f64, 10), bounds.min_x);
    try std.testing.expectEqual(@as(f64, 20), bounds.max_x);
}

test "moveto coordinate pairs become lines and malformed exponents stop" {
    var path = try parse("M0 0 10 10 20 1e L99 99", std.testing.allocator);
    defer path.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), path.segments.items.len);
    try std.testing.expectEqual(Point{ .x = 10, .y = 10 }, path.segments.items[0].end());
}

test "rotated arc bounds use ellipse derivative extrema" {
    var path = try parse("M0 0 A80 20 45 1 1 100 100", std.testing.allocator);
    defer path.deinit(std.testing.allocator);
    const bounds = path.bounds(.{});
    try std.testing.expect(bounds.min_x < 0);
    try std.testing.expect(bounds.max_y >= 100);
}

test "length and point lookup share adaptive geometry" {
    var path = try parse("M0 0 C0 100 100 100 100 0", std.testing.allocator);
    defer path.deinit(std.testing.allocator);
    const length = try path.totalLength(std.testing.allocator);
    const middle = try path.pointAtLength(length / 2.0, std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 50), middle.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 75), middle.y, 0.01);
}
