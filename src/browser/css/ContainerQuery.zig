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

//! `@container` preludes (css-conditional-5 §6). Size features only; writing
//! modes aren't modelled, so the inline axis is the width. `style()`,
//! `scroll-state()` and anything else invalidate the prelude: like Chrome with
//! a feature it doesn't know, the rule never applies.

const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const units = @import("units.zig");

const Allocator = std.mem.Allocator;

pub const Query = struct {
    name: ?[]const u8,
    // Empty for a name-only query
    condition: []const u8,
    axes: Axes,
};

pub const Axes = packed struct(u2) {
    width: bool = false,
    height: bool = false,
};

pub const Context = struct {
    width: f64,
    height: f64,
    viewport_width: f64,
    viewport_height: f64,
    // The container's, for em
    font_size: f64,
    root_font_size: f64,
};

/// Null when invalid.
pub fn parseList(allocator: Allocator, prelude: []const u8) Allocator.Error!?[]const Query {
    var queries: std.ArrayList(Query) = .empty;
    defer queries.deinit(allocator);
    var rest = prelude;
    while (true) {
        const comma = nextTopLevelComma(rest);
        const query = parseQuery(rest[0..comma]) orelse return null;
        try queries.append(allocator, query);
        if (comma == rest.len) {
            break;
        }
        rest = rest[comma + 1 ..];
    }
    return try queries.toOwnedSlice(allocator);
}

fn parseQuery(text: []const u8) ?Query {
    var parser: Parser = .{ .tokenizer = .{ .input = text } };
    var name: ?[]const u8 = null;
    const before_name = parser.tokenizer;
    if (parser.nextSignificant()) |token| {
        if (token == .ident and isContainerName(token.ident)) {
            name = token.ident;
        } else {
            parser.tokenizer = before_name;
        }
    }

    const condition_start = parser.tokenizer.position;
    if (parser.atEnd()) {
        if (name == null) {
            return null;
        }
        return .{ .name = name, .condition = "", .axes = .{} };
    }
    if (parser.condition() == null or parser.atEnd() == false) {
        return null;
    }
    return .{
        .name = name,
        .condition = std.mem.trim(u8, text[condition_start..], &std.ascii.whitespace),
        .axes = parser.axes,
    };
}

/// `condition` was validated by parseList.
pub fn matches(condition: []const u8, context: Context) bool {
    var parser: Parser = .{ .tokenizer = .{ .input = condition }, .context = context };
    return parser.condition() orelse false;
}

pub fn isContainerName(ident: []const u8) bool {
    for ([_][]const u8{ "none", "and", "not", "or", "initial", "inherit", "unset", "revert", "revert-layer", "default" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(ident, reserved)) {
            return false;
        }
    }
    return true;
}

const Parser = struct {
    tokenizer: Tokenizer,
    // Null while parseList validates: every feature is then false
    context: ?Context = null,
    // The axes the features read
    axes: Axes = .{},
    // Parentheses nest by recursion: cap them for the stack
    depth: u8 = 0,

    fn atEnd(self: *Parser) bool {
        return self.peekSignificant() == null;
    }

    fn nextSignificant(self: *Parser) ?Tokenizer.Token {
        while (self.tokenizer.next()) |token| {
            switch (token) {
                .white_space, .comment => continue,
                else => return token,
            }
        }
        return null;
    }

    fn peekSignificant(self: *Parser) ?Tokenizer.Token {
        var probe = self.*;
        return probe.nextSignificant();
    }

    // <container-condition> = not <query-in-parens>
    //     | <query-in-parens> [ [ and <query-in-parens> ]* | [ or <query-in-parens> ]* ]
    fn condition(self: *Parser) ?bool {
        const first = self.nextSignificant() orelse return null;
        if (first == .ident and std.ascii.eqlIgnoreCase(first.ident, "not")) {
            return !(self.inParens(self.nextSignificant() orelse return null) orelse return null);
        }
        var result = self.inParens(first) orelse return null;
        var combinator: ?enum { @"and", @"or" } = null;
        while (self.peekSignificant()) |token| {
            if (token != .ident) {
                break;
            }
            const this: @TypeOf(combinator.?) = if (std.ascii.eqlIgnoreCase(token.ident, "and"))
                .@"and"
            else if (std.ascii.eqlIgnoreCase(token.ident, "or"))
                .@"or"
            else
                return null;
            // `and` and `or` don't mix without parentheses
            if (combinator != null and combinator.? != this) {
                return null;
            }
            combinator = this;
            _ = self.nextSignificant();
            const next = self.inParens(self.nextSignificant() orelse return null) orelse return null;
            result = switch (this) {
                .@"and" => result and next,
                .@"or" => result or next,
            };
        }
        return result;
    }

    // <query-in-parens> = ( <container-condition> ) | ( <size-feature> )
    fn inParens(self: *Parser, first: Tokenizer.Token) ?bool {
        if (first != .parenthesis_block or self.depth == 32) {
            return null;
        }
        self.depth += 1;
        defer self.depth -= 1;
        const start = self.*;
        if (self.feature()) |result| {
            if (self.nextSignificant()) |close| {
                if (close == .close_parenthesis) {
                    return result;
                }
            }
        }
        self.* = start;
        const result = self.condition() orelse return null;
        const close = self.nextSignificant() orelse return null;
        return if (close == .close_parenthesis) result else null;
    }

    // `name`, `name: value`, `name op value`, `value op name` or
    // `value op name op value`. Orientation only takes `name: value`.
    fn feature(self: *Parser) ?bool {
        const first = self.nextSignificant() orelse return null;
        if (first == .ident) {
            const next = self.peekSignificant() orelse return null;
            if (next == .colon) {
                _ = self.nextSignificant();
                const prefixed = Prefixed.parse(first.ident) orelse return null;
                const value = self.featureValue(prefixed.feature) orelse return null;
                return self.compare(prefixed.feature, prefixed.op, value);
            }
            const f = Feature.parse(first.ident) orelse return null;
            if (next == .close_parenthesis) {
                return self.holds(f);
            }
            if (f == .orientation) {
                return null;
            }
            const op = self.operator() orelse return null;
            return self.compare(f, op, self.featureValue(f) orelse return null);
        }

        const left_value = self.valueFrom(first) orelse return null;
        const left_op = self.operator() orelse return null;
        const ident = self.nextSignificant() orelse return null;
        if (ident != .ident) {
            return null;
        }
        const f = Feature.parse(ident.ident) orelse return null;
        if (f == .orientation or left_value.isCompatible(f) == false) {
            return null;
        }
        const left = self.compare(f, left_op.flip(), left_value);
        const next = self.peekSignificant() orelse return null;
        if (next == .close_parenthesis) {
            return left;
        }
        const right_op = self.operator() orelse return null;
        // Both point the same way: `a < x <= b`, never `a < x > b`
        if (left_op.isLess() != right_op.isLess() or left_op == .eq or right_op == .eq) {
            return null;
        }
        const right = self.compare(f, right_op, self.featureValue(f) orelse return null);
        return left and right;
    }

    fn read(self: *Parser, f: Feature) void {
        switch (f) {
            .width => self.axes.width = true,
            .height => self.axes.height = true,
            .aspect_ratio, .orientation => {
                self.axes.width = true;
                self.axes.height = true;
            },
        }
    }

    // `(width)`: whether the feature isn't 0 (orientation always is something)
    fn holds(self: *Parser, f: Feature) bool {
        self.read(f);
        const context = self.context orelse return false;
        return switch (f) {
            .width => context.width != 0,
            .height => context.height != 0,
            .aspect_ratio => context.width != 0 and context.height != 0,
            .orientation => true,
        };
    }

    fn compare(self: *Parser, f: Feature, op: Op, v: Value) bool {
        self.read(f);
        const context = self.context orelse return false;
        return switch (f) {
            .width => op.compare(context.width, v.px(context)),
            .height => op.compare(context.height, v.px(context)),
            // `w/h op a/b`, cross-multiplied
            .aspect_ratio => switch (v) {
                .ratio => |r| op.compare(context.width * r.denominator, r.numerator * context.height),
                .number => |n| op.compare(context.width, n * context.height),
                else => unreachable,
            },
            .orientation => switch (v.orientation) {
                .portrait => context.height >= context.width,
                .landscape => context.width > context.height,
            },
        };
    }

    fn operator(self: *Parser) ?Op {
        const token = self.nextSignificant() orelse return null;
        if (token != .delim) {
            return null;
        }
        const c = token.delim;
        if (c == '=') {
            return .eq;
        }
        if (c != '<' and c != '>') {
            return null;
        }
        // `<=` is two tokens, with nothing between them
        var probe = self.tokenizer;
        if (probe.next()) |after| {
            if (after == .delim and after.delim == '=') {
                self.tokenizer = probe;
                return if (c == '<') .le else .ge;
            }
        }
        return if (c == '<') .lt else .gt;
    }

    fn featureValue(self: *Parser, f: Feature) ?Value {
        const token = self.nextSignificant() orelse return null;
        const v = self.valueFrom(token) orelse return null;
        return if (v.isCompatible(f)) v else null;
    }

    fn valueFrom(self: *Parser, token: Tokenizer.Token) ?Value {
        switch (token) {
            .dimension => |d| {
                if (d.value < 0) {
                    return null;
                }
                return .{ .dimension = .{ .value = d.value, .unit = units.lookup(d.unit) orelse return null } };
            },
            .number => |n| {
                if (n.value < 0) {
                    return null;
                }
                var probe = self.*;
                if (probe.nextSignificant()) |slash| {
                    if (slash == .delim and slash.delim == '/') {
                        const denominator = probe.nextSignificant() orelse return null;
                        if (denominator != .number or denominator.number.value < 0) {
                            return null;
                        }
                        self.* = probe;
                        return .{ .ratio = .{ .numerator = n.value, .denominator = denominator.number.value } };
                    }
                }
                return .{ .number = n.value };
            },
            .ident => |ident| {
                if (std.ascii.eqlIgnoreCase(ident, "portrait")) return .{ .orientation = .portrait };
                if (std.ascii.eqlIgnoreCase(ident, "landscape")) return .{ .orientation = .landscape };
                return null;
            },
            else => return null,
        }
    }
};

const Op = enum {
    eq,
    lt,
    le,
    gt,
    ge,

    fn isLess(self: Op) bool {
        return self == .lt or self == .le;
    }

    fn flip(self: Op) Op {
        return switch (self) {
            .lt => .gt,
            .le => .ge,
            .gt => .lt,
            .ge => .le,
            .eq => .eq,
        };
    }

    fn compare(self: Op, a: f64, b: f64) bool {
        return switch (self) {
            .eq => a == b,
            .lt => a < b,
            .le => a <= b,
            .gt => a > b,
            .ge => a >= b,
        };
    }
};

const Value = union(enum) {
    dimension: struct { value: f64, unit: units.Unit },
    number: f64,
    ratio: struct { numerator: f64, denominator: f64 },
    orientation: enum { portrait, landscape },

    fn isCompatible(self: Value, f: Feature) bool {
        return switch (f) {
            .width, .height => switch (self) {
                .dimension => |d| switch (d.unit) {
                    .em, .rem, .vw, .vh => true,
                    else => units.absoluteLengthFactor(d.unit) != null,
                },
                // Only 0 is a length without a unit
                .number => |n| n == 0,
                else => false,
            },
            .aspect_ratio => self == .ratio or self == .number,
            .orientation => self == .orientation,
        };
    }

    fn px(self: Value, context: Context) f64 {
        return switch (self) {
            .dimension => |d| switch (d.unit) {
                .em => d.value * context.font_size,
                .rem => d.value * context.root_font_size,
                .vw => d.value * context.viewport_width / 100,
                .vh => d.value * context.viewport_height / 100,
                else => d.value * (units.absoluteLengthFactor(d.unit) orelse 0),
            },
            .number => |n| n,
            .ratio, .orientation => unreachable,
        };
    }
};

const Feature = enum {
    width,
    height,
    aspect_ratio,
    orientation,

    fn parse(name: []const u8) ?Feature {
        const eql = std.ascii.eqlIgnoreCase;
        if (eql(name, "width") or eql(name, "inline-size")) return .width;
        if (eql(name, "height") or eql(name, "block-size")) return .height;
        if (eql(name, "aspect-ratio")) return .aspect_ratio;
        if (eql(name, "orientation")) return .orientation;
        return null;
    }
};

// `min-width: 1px` is `width >= 1px`
const Prefixed = struct {
    op: Op,
    feature: Feature,

    fn parse(name: []const u8) ?Prefixed {
        const op: Op, const rest = if (std.ascii.startsWithIgnoreCase(name, "min-"))
            .{ .ge, name[4..] }
        else if (std.ascii.startsWithIgnoreCase(name, "max-"))
            .{ .le, name[4..] }
        else
            .{ .eq, name };
        const f = Feature.parse(rest) orelse return null;
        if (f == .orientation and op != .eq) {
            return null;
        }
        return .{ .op = op, .feature = f };
    }
};

/// The first top-level comma, or the end.
fn nextTopLevelComma(text: []const u8) usize {
    var tokenizer: Tokenizer = .{ .input = text };
    var depth: usize = 0;
    var at: usize = 0;
    while (tokenizer.next()) |token| {
        switch (token) {
            .parenthesis_block, .function => depth += 1,
            .close_parenthesis => depth -|= 1,
            .comma => if (depth == 0) return at,
            else => {},
        }
        at = tokenizer.position;
    }
    return text.len;
}

const testing = std.testing;

fn expectMatch(expected: bool, prelude: []const u8, width: f64, height: f64) !void {
    const queries = (try parseList(testing.allocator, prelude)) orelse return error.Invalid;
    defer testing.allocator.free(queries);
    const context: Context = .{ .width = width, .height = height, .viewport_width = 1000, .viewport_height = 800, .font_size = 16, .root_font_size = 16 };
    var any = false;
    for (queries) |query| {
        if (query.condition.len == 0 or matches(query.condition, context)) {
            any = true;
        }
    }
    try testing.expectEqual(expected, any);
}

test "ContainerQuery: prefixed and range features" {
    try expectMatch(true, "(min-width: 400px)", 400, 0);
    try expectMatch(false, "(min-width: 400px)", 399, 0);
    try expectMatch(true, "(max-width: 25rem)", 400, 0);
    try expectMatch(true, "(width >= 400px)", 400, 0);
    try expectMatch(false, "(width > 400px)", 400, 0);
    try expectMatch(true, "(400px < width)", 401, 0);
    try expectMatch(true, "(400px <= width < 800px)", 400, 0);
    try expectMatch(false, "(400px <= width < 800px)", 800, 0);
    try expectMatch(true, "(width = 50vw)", 500, 0);
    try expectMatch(true, "(inline-size > 0)", 1, 0);
    try expectMatch(true, "(width)", 1, 0);
    try expectMatch(false, "(width)", 0, 0);
    try expectMatch(true, "(1in = width)", 96, 0);
    try expectMatch(true, "(MIN-WIDTH: 400PX)", 400, 0);
}

test "ContainerQuery: em is the container's font size, rem the root's" {
    const context: Context = .{ .width = 200, .height = 0, .viewport_width = 0, .viewport_height = 0, .font_size = 20, .root_font_size = 10 };
    try testing.expect(matches("(width = 10em)", context));
    try testing.expect(matches("(width = 20rem)", context));
}

test "ContainerQuery: boolean logic" {
    try expectMatch(true, "not (min-width: 400px)", 300, 0);
    try expectMatch(false, "not (min-width: 400px)", 500, 0);
    try expectMatch(true, "(min-width: 100px) and (max-width: 200px)", 150, 0);
    try expectMatch(false, "(min-width: 100px) and (max-width: 200px)", 250, 0);
    try expectMatch(true, "(max-width: 100px) or (min-width: 200px)", 250, 0);
    try expectMatch(true, "((min-width: 100px) and (max-width: 200px)) or (width > 1000px)", 1500, 0);
    try expectMatch(true, "(width < 10px), (width > 100px)", 150, 0);
}

test "ContainerQuery: height, aspect-ratio and orientation" {
    try expectMatch(true, "(height > 100px)", 0, 150);
    try expectMatch(true, "(block-size <= 100px)", 0, 100);
    try expectMatch(true, "(aspect-ratio > 1/1)", 200, 100);
    try expectMatch(true, "(min-aspect-ratio: 16 / 9)", 1600, 900);
    try expectMatch(true, "(orientation: portrait)", 100, 200);
    try expectMatch(true, "(orientation: landscape)", 200, 100);
    // 0/0 compares equal to every ratio, like in Chrome and Firefox
    try expectMatch(true, "(min-aspect-ratio: 16/9)", 0, 0);
    try expectMatch(true, "(max-aspect-ratio: 1/1)", 0, 0);
}

fn nested(comptime depth: usize) []const u8 {
    const open: [depth]u8 = @splat('(');
    const close: [depth]u8 = @splat(')');
    return &open ++ "width > 1px" ++ &close;
}

test "ContainerQuery: nesting depth" {
    try expectMatch(true, comptime nested(32), 2, 0);
    try testing.expectEqual(null, try parseList(testing.allocator, comptime nested(33)));
}

test "ContainerQuery: names and axes" {
    const queries = (try parseList(testing.allocator, "card (min-width: 1px), sidebar, (height > 2px)")).?;
    defer testing.allocator.free(queries);
    try testing.expectEqual(3, queries.len);
    try testing.expectEqualStrings("card", queries[0].name.?);
    try testing.expectEqualStrings("(min-width: 1px)", queries[0].condition);
    try testing.expectEqual(Axes{ .width = true }, queries[0].axes);
    try testing.expectEqualStrings("sidebar", queries[1].name.?);
    try testing.expectEqualStrings("", queries[1].condition);
    try testing.expectEqual(null, queries[2].name);
    try testing.expectEqual(Axes{ .height = true }, queries[2].axes);

    const ratio = (try parseList(testing.allocator, "(orientation: portrait)")).?;
    defer testing.allocator.free(ratio);
    try testing.expectEqual(Axes{ .width = true, .height = true }, ratio[0].axes);
}

test "ContainerQuery: invalid preludes" {
    for ([_][]const u8{
        "",
        "none",
        "(min-width: 400px) and (max-width: 500px) or (width: 1px)",
        "(min-width > 400px)",
        "(400px < width > 800px)",
        "(min-orientation: portrait)",
        "(orientation = portrait)",
        "(width < $CONTAINER_WIDTH_SMALL)",
        "(width: 10%)",
        "(width: 10)",
        "(color)",
        "style(--x: y)",
        "scroll-state(stuck: top)",
        "card card (width > 1px)",
        "(width > 1px),",
        "(width > 1px",
        "(width: -1px)",
    }) |prelude| {
        const queries = try parseList(testing.allocator, prelude);
        if (queries) |q| {
            testing.allocator.free(q);
            std.debug.print("expected invalid: {s}\n", .{prelude});
            return error.TestUnexpectedResult;
        }
    }
}
