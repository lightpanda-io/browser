// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const color = @import("../../color.zig");
const CssParser = @import("../../css/Parser.zig");
const Tokenizer = @import("../../css/Tokenizer.zig");
const escape = @import("../../css/escape.zig");
const properties = @import("../../css/properties.zig");
const DeclarationBlock = @import("../../css/DeclarationBlock.zig");
const StyleManager = @import("../../StyleManager.zig");

const Element = @import("../Element.zig");
const DOMMatrixReadOnly = @import("../DOMMatrixReadOnly.zig");

const CSSStyleRule = @import("CSSStyleRule.zig");

const Allocator = std.mem.Allocator;

const CSSStyleDeclaration = @This();

_owner: Owner = .none,
// On the factory's storage allocator. Unused for a rule's style.
_declarations: DeclarationBlock = .{},
_syncing: bool = false,

/// Who the declarations bleong to
pub const Owner = union(enum) {
    // A bare block: parseBlock/formatBlock scratch, tests
    none,

    // el.style: writes sync the element's style attribute
    inline_style: *Element,

    // getComputedStyle(el): read-only
    computed: *Element,

    // rule.style: the declarations are the rule's
    rule: *CSSStyleRule,
};

const Entry = DeclarationBlock.Entry;

// Parse the element's existing style attribute into _declarations so that
// subsequent JS reads and writes see all CSS properties, not just newly
// added ones.  Computed styles have no inline attribute to parse.
pub fn parseInlineStyle(self: *CSSStyleDeclaration, frame: *Frame) !void {
    const el = switch (self._owner) {
        .inline_style => |el| el,
        else => return,
    };
    const attr_value = el.getAttributeInterned("style") orelse return;
    try self.applyDeclarations(CssParser.parseDeclarationsList(attr_value), frame);
}

fn applyDeclarations(self: *CSSStyleDeclaration, declarations: CssParser.DeclarationsIterator, frame: *Frame) !void {
    var it = declarations;
    while (it.next()) |declaration| {
        try self.applyParsedDeclaration(declaration, frame);
    }
    try self.storage().trim(frame._factory.storageAllocator());
}

pub fn length(self: *const CSSStyleDeclaration) u32 {
    return self.storage().length();
}

pub fn item(self: *const CSSStyleDeclaration, index: u32, frame: *const Frame) []const u8 {
    const all = self.storage().entries();
    if (index >= all.len) {
        return "";
    }
    return all[index].name(&frame.page.css_custom_names);
}

pub fn getPropertyValue(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    const normalized = normalizePropertyName(frame.local_arena, property_name);
    if (lookupId(normalized, frame)) |id| {
        return self.getKnownPropertyValue(id, frame);
    }
    if (self._owner != .computed or isCustomProperty(normalized) == false) {
        return "";
    }

    // A custom name the page hasn't numbered yet can still be declared in a
    // sheet not yet rebuilt or a style attribute not yet parsed.
    const element = self._owner.computed;
    const owner = element.ownerFrame(frame) orelse return "";
    const style_manager = &owner._style_manager;
    const id = style_manager.customPropertyId(element, normalized) orelse return "";
    return style_manager.customPropertyValue(element, id) orelse "";
}

pub fn getKnownPropertyValue(self: *const CSSStyleDeclaration, id: properties.Id, frame: *Frame) []const u8 {
    const value = self.cascadedValue(id, frame);

    if (self._owner != .computed) {
        return value;
    }

    if (id == .transform) {
        // The resolved transform is always a matrix: animation libraries
        // (popmotion) regex it as matrix()/matrix3d() and crash on anything
        // else.
        return resolvedTransform(value, frame);
    }

    if (isColorProperty(id)) {
        return computedColor(value, frame);
    }

    return value;
}

/// `content` serialized as Chrome computes it: strings in double quotes, one
/// space between components and none inside parentheses, keywords and
/// function names in lowercase.
fn computedContent(value: []const u8, frame: *Frame) []const u8 {
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    writeComputedContent(&buf.writer, value) catch return value;
    return buf.written();
}

fn writeComputedContent(writer: *std.Io.Writer, value: []const u8) !void {
    var tokenizer: Tokenizer = .{ .input = value };
    var start: usize = 0;
    var depth: usize = 0;
    var spaced = false;
    while (tokenizer.next()) |token| : (start = tokenizer.position) {
        switch (token) {
            .white_space, .comment => continue,
            .bad_string, .bad_url => return error.Invalid,
            .close_parenthesis => {
                depth -|= 1;
                try writer.writeByte(')');
                spaced = true;
                continue;
            },
            .comma => {
                try writer.writeByte(',');
                spaced = true;
                continue;
            },
            else => {},
        }
        if (spaced) {
            try writer.writeByte(' ');
        }
        spaced = true;
        switch (token) {
            .string => |raw| try escape.writeString(writer, raw),
            .function => |name| {
                try writeLowercase(writer, name);
                try writer.writeByte('(');
                depth += 1;
                spaced = false;
            },
            .parenthesis_block => {
                try writer.writeByte('(');
                depth += 1;
                spaced = false;
            },
            // A counter's name keeps its case.
            .ident => |name| if (depth == 0) try writeLowercase(writer, name) else try writer.writeAll(name),
            else => try writer.writeAll(tokenizer.input[start..tokenizer.position]),
        }
    }
}

fn writeLowercase(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        try writer.writeByte(std.ascii.toLower(c));
    }
}

fn computedColor(value: []const u8, frame: *Frame) []const u8 {
    const parsed = switch (color.parse(value)) {
        .value => |v| v,
        .invalid, .unsupported => return value,
    };
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    parsed.writeComputed(&buf.writer) catch return value;
    return buf.written();
}

fn cascadedValue(self: *const CSSStyleDeclaration, id: properties.Id, frame: *Frame) []const u8 {

    // Computed styles must reflect stylesheet rules, not just the element's
    // inline `style=` attribute. Limited to display/visibility — what aria
    // tree builders (Playwright ariaSnapshot) consult on every element —
    // pointer-events and text-transform, which innerText applies, and
    // position, which offsetParent consults.
    if (self._owner == .computed) computed: {
        const element = self._owner.computed;
        const owner = element.ownerFrame(frame) orelse break :computed;
        const style_manager = &owner._style_manager;
        switch (id) {
            .display => {
                if (style_manager.hasDisplayNone(element)) {
                    return "none";
                }
                if (style_manager.hasDisplayContents(element)) {
                    return "contents";
                }
            },
            .visibility => if (style_manager.hasVisibilityHiddenInherited(element)) {
                return "hidden";
            },
            .@"pointer-events" => if (style_manager.hasPointerEventsNone(element)) {
                return "none";
            },
            // Inherited: the nearest declaration up the tree wins.
            .@"text-transform" => return style_manager.textTransform(element).keyword(),
            .position => return style_manager.position(element).keyword(),
            else => {},
        }
    }

    if (self.declaredValue(id, frame)) |value| {
        return value;
    }

    // Only return default values for computed styles
    if (self._owner != .computed) {
        return "";
    }
    const element = self._owner.computed;
    const owner = element.ownerFrame(frame) orelse {
        return uaDefaultValue(element, id) orelse initialValue(id);
    };
    const style_manager = &owner._style_manager;

    if (properties.knownName(id) == null) {
        return style_manager.customPropertyValue(element, id) orelse "";
    }

    switch (id) {
        .content => return cascadedContent(style_manager, element, owner, frame),
        // Resolved in pixels, as the synthetic text metrics measure it.
        .@"font-size" => return frame.local_arena.print("{d}px", .{style_manager.computedFontSize(element)}) catch "16px",
        else => {},
    }

    // Resolve inline `style=` declarations through the element's parsed
    // inline style, so computed values match `el.style`. One an !important
    // rule beats falls through to the values below.
    if (style_manager.inlineStyleValue(element, id)) |value| {
        if (CssWideKeyword.parse(value) == null) {
            return value;
        }
    }

    // Computed width/height must agree with the synthetic layout metrics.
    // Returning "" makes measurement code see contradictory sizes — jQuery's
    // "shrink text until it fits" loops then never terminate. jQuery's
    // .width() reads this value, so it must also carry clientWidth's content
    // fallback or append-until-wide marquee loops never terminate.
    return switch (id) {
        .width => resolvedDimension(element, .width, frame),
        .height => resolvedDimension(element, .height, frame),
        else => inlineCascadedValue(style_manager, element, id, owner),
    };
}

const CssWideKeyword = enum {
    initial,
    inherit,
    unset,
    revert,

    fn parse(value: []const u8) ?CssWideKeyword {
        const map = std.StaticStringMap(CssWideKeyword).initComptime(.{
            .{ "initial", .initial },
            .{ "inherit", .inherit },
            .{ "unset", .unset },
            .{ "revert", .revert },
            .{ "revert-layer", .revert },
        });
        var buf: [16]u8 = undefined;
        if (value.len > buf.len) {
            return null;
        }
        return map.get(std.ascii.lowerString(&buf, value));
    }
};

/// The computed `content`. It doesn't inherit, so only an explicit `inherit`
/// reads the parent's. No UA style sets it on an element, so `revert` reads
/// like `unset`: the initial `normal`.
fn cascadedContent(style_manager: *StyleManager, element: *Element, owner: *Frame, frame: *Frame) []const u8 {
    var current = element;
    while (true) {
        const value = style_manager.contentValue(current) orelse return "normal";
        // On an element, `none` computes to `normal`.
        if (std.ascii.eqlIgnoreCase(value, "none")) {
            return "normal";
        }
        const keyword = CssWideKeyword.parse(value) orelse return computedContent(value, frame);
        switch (keyword) {
            .initial, .unset, .revert => return "normal",
            .inherit => current = current.asNode().flatTreeParentElement(owner) orelse return "normal",
        }
    }
}

/// The computed value inline styles
fn inlineCascadedValue(style_manager: *StyleManager, element: *Element, id: properties.Id, frame: *Frame) []const u8 {
    const inherited = if (properties.propertyOf(id)) |p| p.inherited else false;
    var current = element;
    while (true) {
        // Nothing declared reads like `revert`: the UA default, or else what
        // the property does by default.
        const keyword: CssWideKeyword = blk: {
            const value = style_manager.inlineStyleValue(current, id) orelse break :blk .revert;
            break :blk CssWideKeyword.parse(value) orelse return value;
        };
        switch (keyword) {
            .initial => return initialValue(id),
            .inherit => {},
            .unset => if (inherited == false) return initialValue(id),
            .revert => {
                if (uaDefaultValue(current, id)) |value| {
                    return value;
                }
                if (inherited == false) {
                    return initialValue(id);
                }
            },
        }
        current = current.asNode().flatTreeParentElement(frame) orelse return initialValue(id);
    }
}

/// The value of a declared property, or null when it isn't declared. An axis
/// or four-side shorthand reads as its longhands when all are present with the
/// same priority, the way the CSSOM serializes a shorthand.
pub fn declaredValue(self: *const CSSStyleDeclaration, id: properties.Id, frame: *Frame) ?[]const u8 {
    if (properties.boxShorthand(id)) |shorthand| {
        if (self.storedBox(shorthand)) |stored| {
            return stored.value();
        }
        return self.boxValue(shorthand, frame);
    }
    if (properties.axisShorthand(id)) |shorthand| {
        const x = self.findProperty(shorthand.x) orelse return null;
        const pair = self.axisPair(x) orelse return null;
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        pair.formatValue(&buf.writer) catch return null;
        return buf.written();
    }
    const prop = self.findProperty(id) orelse return null;
    return prop.value();
}

pub const Declared = struct {
    value: []const u8,
    important: bool,
};

/// The declaration stored under `id`. A shorthand only has one when kept as
/// written, see declaredValue; a custom property or `content` always does.
pub fn storedDeclaration(self: *const CSSStyleDeclaration, id: properties.Id) ?Declared {
    const entry = self.findProperty(id) orelse return null;
    return .{ .value = entry.value(), .important = entry._important };
}

/// A four-side shorthand kept as written because its value uses var(), while
/// none of its sides has been declared since.
fn storedBox(self: *const CSSStyleDeclaration, shorthand: properties.BoxShorthand) ?*const Entry {
    const stored = self.findProperty(shorthand.name) orelse return null;
    for (shorthand.sides) |side| {
        if (self.findProperty(side) != null) {
            return null;
        }
    }
    return stored;
}

/// Whether any side of a four-side shorthand is declared !important.
fn boxSideImportant(self: *const CSSStyleDeclaration, shorthand: properties.BoxShorthand) bool {
    for (shorthand.sides) |side| {
        if (self.findProperty(side)) |prop| {
            if (prop._important) {
                return true;
            }
        }
    }
    return false;
}

/// The four longhands of a four-side shorthand, when all are declared with the
/// same priority.
fn boxSides(self: *const CSSStyleDeclaration, shorthand: properties.BoxShorthand) ?[4]*const Entry {
    var sides: [4]*const Entry = undefined;
    for (shorthand.sides, &sides) |side, *entry| {
        entry.* = self.findProperty(side) orelse return null;
        if (entry.*._important != sides[0]._important) {
            return null;
        }
    }
    return sides;
}

/// The side values of a four-side shorthand, or null if any is invalid: an
/// invalid declaration writes none of them.
fn boxSideValues(shorthand: properties.BoxShorthand, value: []const u8) ?[4][]const u8 {
    const values = CssParser.splitBoxSides(value) orelse return null;
    for (shorthand.sides, values) |side, side_value| {
        if (isColorProperty(side) and color.parse(side_value) == .invalid) {
            return null;
        }
    }
    return values;
}

/// A four-side shorthand in its shortest form: "1px", "1px 2px", "1px 2px 3px"
/// or all four.
fn formatBoxValue(sides: [4]*const Entry, writer: *std.Io.Writer) !void {
    const count: usize = if (!std.mem.eql(u8, sides[3].value(), sides[1].value()))
        4
    else if (!std.mem.eql(u8, sides[2].value(), sides[0].value()))
        3
    else if (!std.mem.eql(u8, sides[1].value(), sides[0].value()))
        2
    else
        1;
    for (sides[0..count], 0..) |side, i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.writeAll(side.value());
    }
}

fn boxValue(self: *const CSSStyleDeclaration, shorthand: properties.BoxShorthand, frame: *Frame) ?[]const u8 {
    const sides = self.boxSides(shorthand) orelse return null;
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    formatBoxValue(sides, &buf.writer) catch return null;
    return buf.written();
}

/// Both longhands of an axis shorthand, declared with the same priority: the
/// pair reads and serializes as the shorthand.
const AxisPair = struct {
    name: []const u8,
    x: *const Entry,
    y: *const Entry,

    fn formatValue(self: AxisPair, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.x.value());
        if (!std.mem.eql(u8, self.x.value(), self.y.value())) {
            try writer.writeByte(' ');
            try writer.writeAll(self.y.value());
        }
    }

    fn format(self: AxisPair, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.name);
        try writer.writeAll(": ");
        try self.formatValue(writer);
        try formatDeclarationEnd(self.x._important, writer);
    }
};

/// The pair `prop` belongs to, when it is an axis longhand and the other is
/// declared with the same priority.
fn axisPair(self: *const CSSStyleDeclaration, prop: *const Entry) ?AxisPair {
    const longhand = properties.axisLonghand(prop._id) orelse return null;
    const partner = self.findProperty(longhand.partner()) orelse return null;
    if (partner._important != prop._important) {
        return null;
    }
    const name = properties.knownName(longhand.shorthand.name).?;
    return if (longhand.is_x) .{ .name = name, .x = prop, .y = partner } else .{ .name = name, .x = partner, .y = prop };
}

// "none", or the transform list collapsed into one matrix() / matrix3d(),
// like Chrome. A value that doesn't parse resolves to "none", as an invalid
// declaration never applies.
fn resolvedTransform(value: []const u8, frame: *Frame) []const u8 {
    var m = DOMMatrixReadOnly.identity();
    var is_2d = true;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) {
        return "none";
    }
    DOMMatrixReadOnly.parseTransformList(trimmed, &m, &is_2d) catch return "none";

    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    const writer = &buf.writer;
    const components: []const usize = if (is_2d) &.{ 0, 1, 4, 5, 12, 13 } else &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    writer.writeAll(if (is_2d) "matrix(" else "matrix3d(") catch return "none";
    for (components, 0..) |c, i| {
        if (i > 0) writer.writeAll(", ") catch return "none";
        writeCssNumber(writer, m[c]) catch return "none";
    }
    writer.writeByte(')') catch return "none";
    return buf.written();
}

// Six significant digits with trailing zeros dropped, as Chrome serializes
// computed numbers (JS toPrecision(6), trimmed): 0.707107, 6.12323e-17.
fn writeCssNumber(writer: *std.Io.Writer, value: f64) !void {
    if (value == 0 or !std.math.isFinite(value)) {
        return writer.writeAll("0");
    }
    const exponent: i32 = @intFromFloat(@floor(std.math.log10(@abs(value))));
    var tmp: [64]u8 = undefined;
    if (exponent < -6 or exponent >= 6) {
        const str = try std.fmt.bufPrint(&tmp, "{e:.5}", .{value});
        const e_index = std.mem.indexOfScalar(u8, str, 'e').?;
        try writer.writeAll(trimFraction(str[0..e_index]));
        try writer.writeByte('e');
        const exp_str = str[e_index + 1 ..];
        if (exp_str[0] != '-') try writer.writeByte('+');
        return writer.writeAll(exp_str);
    }
    const decimals: usize = @intCast(5 - exponent);
    const str = try std.fmt.bufPrint(&tmp, "{d:.[1]}", .{ value, decimals });
    const trimmed = trimFraction(str);
    // a value that rounds to zero at this precision has no sign
    try writer.writeAll(if (std.mem.eql(u8, trimmed, "-0")) "0" else trimmed);
}

fn trimFraction(str: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, str, '.') == null) return str;
    return std.mem.trimEnd(u8, std.mem.trimEnd(u8, str, "0"), ".");
}

fn resolvedDimension(element: *Element, dimension: enum { width, height }, frame: *Frame) []const u8 {
    if (!element.isVisible(frame)) {
        return "auto";
    }
    const value = switch (dimension) {
        .width => element.boxAxis(frame, .width),
        .height => element.boxAxis(frame, .height),
    };
    return frame.local_arena.print("{d}px", .{value}) catch "auto";
}

pub fn getPropertyPriority(self: *const CSSStyleDeclaration, property_name: []const u8, frame: *Frame) []const u8 {
    const normalized = normalizePropertyName(frame.local_arena, property_name);
    const id = lookupId(normalized, frame) orelse return "";
    return if (self.declaredImportant(id)) "important" else "";
}

/// Whether a declared property is !important; false when it isn't declared.
pub fn declaredImportant(self: *const CSSStyleDeclaration, id: properties.Id) bool {
    if (properties.boxShorthand(id)) |shorthand| {
        if (self.storedBox(shorthand)) |stored| {
            return stored._important;
        }
        const sides = self.boxSides(shorthand) orelse return false;
        return sides[0]._important;
    }
    if (properties.axisShorthand(id)) |shorthand| {
        const x = self.findProperty(shorthand.x) orelse return false;
        const pair = self.axisPair(x) orelse return false;
        return pair.x._important;
    }
    const prop = self.findProperty(id) orelse return false;
    return prop._important;
}

pub fn setProperty(self: *CSSStyleDeclaration, property_name: []const u8, value: []const u8, priority_: ?[]const u8, frame: *Frame) !void {
    if (self._owner == .computed) {
        return error.NoModificationAllowed;
    }

    // Validate priority
    const priority = priority_ orelse "";
    const important = if (priority.len > 0) blk: {
        if (!std.ascii.eqlIgnoreCase(priority, "important")) {
            return;
        }
        break :blk true;
    } else false;

    const normalized = normalizePropertyName(frame.local_arena, property_name);
    const id = (try writeId(normalized, value, frame)) orelse return;
    if (try self.setPropertyImpl(id, value, important, frame)) {
        try self.syncStyleAttribute(id, frame);
    }
}

/// Apply one declaration parsed from a `style=` block. Unlike the imperative
/// setProperty path, within a single declaration block a normal declaration must
/// not override an earlier !important one (CSS cascade precedence).
fn applyParsedDeclaration(self: *CSSStyleDeclaration, declaration: CssParser.Declaration, frame: *Frame) !void {
    const normalized = normalizePropertyName(frame.local_arena, declaration.name);
    const id = (try writeId(normalized, declaration.value, frame)) orelse return;
    try self.applyParsed(id, declaration.value, declaration.important, frame);
}

fn applyParsed(self: *CSSStyleDeclaration, id: properties.Id, value: []const u8, important: bool, frame: *Frame) !void {
    if (properties.boxShorthand(id)) |shorthand| {
        if (!important) {
            if (self.findProperty(shorthand.name)) |stored| {
                if (stored._important) return;
            }
        }
        if (color.usesSubstitution(value)) {
            // Its sides aren't known, so an !important side keeps it out whole
            if (!important and self.boxSideImportant(shorthand)) return;
        } else {
            const values = boxSideValues(shorthand, value) orelse return;
            _ = try self.removeDeclared(shorthand.name, frame);
            for (shorthand.sides, values) |side, side_value| {
                try self.applyParsed(side, side_value, important, frame);
            }
            return;
        }
    }
    if (properties.axisShorthand(id)) |shorthand| {
        const values = CssParser.splitAxisPair(value) orelse return;
        try self.applyParsed(shorthand.x, values.x, important, frame);
        try self.applyParsed(shorthand.y, values.y, important, frame);
        return;
    }
    if (!important) {
        if (self.findProperty(id)) |existing| {
            if (existing._important) return;
        }
    }
    _ = try self.setPropertyImpl(id, value, important, frame);
}

fn setPropertyImpl(self: *CSSStyleDeclaration, id: properties.Id, value: []const u8, important: bool, frame: *Frame) !bool {
    if (value.len == 0) {
        return (try self.removePropertyImpl(id, frame)) != null;
    }

    if (properties.boxShorthand(id)) |shorthand| {
        if (color.usesSubstitution(value)) {
            // Stored as written, below: its sides aren't known yet.
            for (shorthand.sides) |side| {
                _ = try self.removeDeclared(side, frame);
            }
        } else {
            const values = boxSideValues(shorthand, value) orelse return false;
            var changed = (try self.removeDeclared(shorthand.name, frame)) != null;
            for (shorthand.sides, values) |side, side_value| {
                changed = try self.setPropertyImpl(side, side_value, important, frame) or changed;
            }
            return changed;
        }
    }
    if (properties.axisShorthand(id)) |shorthand| {
        const values = CssParser.splitAxisPair(value) orelse return false;
        const x = try self.setPropertyImpl(shorthand.x, values.x, important, frame);
        const y = try self.setPropertyImpl(shorthand.y, values.y, important, frame);
        return x or y;
    }

    // Normalize the value for canonical serialization
    const normalized_value = blk: {
        if (isColorProperty(id)) {
            switch (color.parse(value)) {
                // An invalid value leaves the declaration as it was.
                .invalid => return false,
                .value => |parsed| {
                    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
                    try parsed.writeSpecified(&buf.writer);
                    break :blk buf.written();
                },
                .unsupported => {},
            }
        }
        break :blk try normalizePropertyValue(frame.local_arena, id, value);
    };

    const allocator = frame._factory.storageAllocator();
    if (self.findProperty(id)) |existing| {
        if (!std.mem.eql(u8, existing.value(), normalized_value)) {
            try existing.setValue(allocator, normalized_value);
        } else if (existing._important == important) {
            return false;
        }
        existing._important = important;
        return true;
    }

    try self.storage().append(allocator, id, normalized_value, important);
    return true;
}

pub fn removeProperty(self: *CSSStyleDeclaration, property_name: []const u8, frame: *Frame) ![]const u8 {
    if (self._owner == .computed) {
        return error.NoModificationAllowed;
    }
    const normalized = normalizePropertyName(frame.local_arena, property_name);
    const id = lookupId(normalized, frame) orelse return "";
    const result = (try self.removePropertyImpl(id, frame)) orelse return "";
    try self.syncStyleAttribute(id, frame);
    return result;
}

fn removePropertyImpl(self: *CSSStyleDeclaration, id: properties.Id, frame: *Frame) !?[]const u8 {
    if (properties.boxShorthand(id)) |shorthand| {
        const declared = self.declaredValue(shorthand.name, frame) orelse "";
        // the stored shorthand's value is freed with it
        const old_value = try frame.call_arena.dupe(u8, declared);
        var removed = (try self.removeDeclared(shorthand.name, frame)) != null;
        for (shorthand.sides) |side| {
            removed = (try self.removePropertyImpl(side, frame)) != null or removed;
        }
        return if (removed) old_value else null;
    }
    if (properties.axisShorthand(id)) |shorthand| {
        const old_value = self.declaredValue(shorthand.name, frame) orelse "";
        const x = try self.removePropertyImpl(shorthand.x, frame);
        const y = try self.removePropertyImpl(shorthand.y, frame);
        if (x == null and y == null) {
            return null;
        }
        return old_value;
    }
    return self.removeDeclared(id, frame);
}

/// Removes the declaration of exactly `id`, without expanding a shorthand.
fn removeDeclared(self: *CSSStyleDeclaration, id: properties.Id, frame: *Frame) !?[]const u8 {
    const index = self.storage().findIndex(id) orelse return null;
    // freed with the entry
    const old_value = try frame.call_arena.dupe(u8, self.storage().entries()[index].value());
    self.storage().removeAt(frame._factory.storageAllocator(), index);
    return old_value;
}

// Serialize current properties back to the element's style attribute so that
// DOM serialization (outerHTML, getAttribute) reflects JS-modified styles.
// `changed` is the one property written, when that's all that changed.
fn syncStyleAttribute(self: *CSSStyleDeclaration, changed: ?properties.Id, frame: *Frame) !void {
    const element = switch (self._owner) {
        .inline_style => |el| el,
        .rule => |rule| {
            const css_rule = rule.asCSSRule();
            if (changed) |id| {
                return css_rule.declarationChanged(id, frame);
            }
            return css_rule.changed(frame);
        },
        .none, .computed => return,
    };
    const css_text = try self.getCssText(frame);
    self._syncing = true;
    defer self._syncing = false;
    if (changed) |id| {
        // Carousels write a transform or an opacity on every slide each
        // frame: one doesn't need every cached style and width recomputed.
        const style_manager = &(element.ownerFrame(frame) orelse frame)._style_manager;
        if (style_manager.inlineStyleWritten(element, id)) {
            return element._attributes.putInertStyle(.wrap(css_text), element, frame);
        }
    }
    try element.setAttributeSafe(comptime .wrap("style"), .wrap(css_text), frame);
}

// The element's style attribute changed (null: removed)
pub fn styleAttributeChanged(self: *CSSStyleDeclaration, text: ?[]const u8, frame: *Frame) !void {
    if (self._syncing) {
        // this was us making the change internally, automatically in-sync
        return;
    }
    // ok, this change was from the outside, e.g. via setAttribute('style', ....)
    // we need to get this declaration back in sync
    self.clearProperties(frame);
    if (text) |t| {
        try self.applyDeclarations(CssParser.parseDeclarationsList(t), frame);
    }
}

// Keeps the capacity: a new set of declarations usually follows.
fn clearProperties(self: *CSSStyleDeclaration, frame: *Frame) void {
    self.storage().clear(frame._factory.storageAllocator());
}

fn getFloat(self: *const CSSStyleDeclaration, frame: *Frame) []const u8 {
    return self.getKnownPropertyValue(.float, frame);
}

fn setFloat(self: *CSSStyleDeclaration, value: js.Value, frame: *Frame) !void {
    if (self._owner == .computed) {
        return error.NoModificationAllowed;
    }
    // `[LegacyNullToEmptyString] CSSOMString`: null becomes "", undefined becomes "undefined".
    const str = if (value.isNull()) "" else try value.toZig([]const u8);
    if (try self.setPropertyImpl(.float, str, false, frame)) {
        try self.syncStyleAttribute(null, frame);
    }
}

fn getCssText(self: *const CSSStyleDeclaration, frame: *Frame) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(frame.local_arena);
    try self.format(&buf.writer, frame);
    return buf.written();
}

pub fn setCssText(self: *CSSStyleDeclaration, text: []const u8, frame: *Frame) !void {
    if (self._owner == .computed) {
        return error.NoModificationAllowed;
    }
    try self.replaceDeclarations(CssParser.parseDeclarationsList(text), frame);
}

fn replaceDeclarations(self: *CSSStyleDeclaration, declarations: CssParser.DeclarationsIterator, frame: *Frame) !void {
    self.clearProperties(frame);

    try self.applyDeclarations(declarations, frame);
    try self.syncStyleAttribute(null, frame);
}

pub fn format(self: *const CSSStyleDeclaration, writer: *std.Io.Writer, frame: *const Frame) !void {
    var first = true;
    // An axis pair serializes once, where its first longhand sits.
    var skip: ?*const Entry = null;
    // As does a four-side shorthand with all four sides declared.
    var boxes_written: std.StaticBitSet(properties.box_shorthands.len) = .empty;
    for (self.storage().entries()) |*prop| {
        if (prop == skip) {
            continue;
        }
        // A shorthand kept as written is overridden once all four sides are set.
        if (properties.boxShorthand(prop._id)) |shorthand| {
            if (self.boxSides(shorthand) != null) continue;
        }
        const box = if (properties.boxLonghandIndex(prop._id)) |i| blk: {
            const sides = self.boxSides(properties.box_shorthands[i]) orelse break :blk null;
            if (boxes_written.isSet(i)) continue;
            boxes_written.set(i);
            break :blk .{ .index = i, .sides = sides };
        } else null;
        if (!first) {
            try writer.writeByte(' ');
        }
        first = false;
        if (box) |b| {
            try writer.writeAll(properties.knownName(properties.box_shorthands[b.index].name).?);
            try writer.writeAll(": ");
            try formatBoxValue(b.sides, writer);
            try formatDeclarationEnd(b.sides[0]._important, writer);
        } else if (self.axisPair(prop)) |pair| {
            try pair.format(writer);
            skip = if (pair.x == prop) pair.y else pair.x;
        } else {
            try formatEntry(prop, writer, frame);
        }
    }
}

pub fn declarationBlock(self: *const CSSStyleDeclaration) *const DeclarationBlock {
    return self.storage();
}

// A rule's block is only valid until its sheet's rules next change.
fn storage(self: *const CSSStyleDeclaration) *DeclarationBlock {
    return switch (self._owner) {
        .rule => |rule| &rule.asCSSRule().entry()._block,
        .none, .inline_style, .computed => @constCast(&self._declarations),
    };
}

/// A style rule's block as a sheet stores it.
pub fn parseBlock(text: []const u8, frame: *Frame) !DeclarationBlock {
    var parsed: CSSStyleDeclaration = .{};
    errdefer parsed._declarations.deinit(frame._factory.storageAllocator());
    try parsed.applyDeclarations(CssParser.parseStyleBlock(text), frame);
    return parsed._declarations;
}

pub fn formatBlock(declarations: *const DeclarationBlock, writer: *std.Io.Writer, frame: *const Frame) !void {
    const view: CSSStyleDeclaration = .{ ._declarations = declarations.* };
    return view.format(writer, frame);
}

fn findProperty(self: *const CSSStyleDeclaration, id: properties.Id) ?*Entry {
    return self.storage().find(id);
}

/// The id of a known or custom property, null when no declaration can have it.
fn lookupId(name: []const u8, frame: *const Frame) ?properties.Id {
    // Most names are known ones
    if (properties.idOf(name)) |id| {
        return id;
    }
    if (isCustomProperty(name) == false) {
        return null;
    }
    return frame.page.css_custom_names.lookup(name);
}

/// The id a write of `value` to `name` goes to, null when it can't apply.
/// Removing (an empty value) never numbers a custom name.
fn writeId(name: []const u8, value: []const u8, frame: *Frame) !?properties.Id {
    if (value.len == 0) {
        return lookupId(name, frame);
    }
    // A declaration of a property we don't know is dropped, as in Chrome.
    return declarationId(name, frame);
}

/// The id a declaration of `name` is stored under, null when it's dropped: an
/// unknown property, or a custom one past what the page can number.
fn declarationId(name: []const u8, frame: *Frame) !?properties.Id {
    if (properties.idOf(name)) |id| {
        return id;
    }
    if (isCustomProperty(name) == false) {
        return null;
    }
    const page = frame.page;
    return page.css_custom_names.intern(page.arena, name);
}

fn normalizePropertyName(allocator: Allocator, name: []const u8) []const u8 {
    if (isCustomProperty(name)) {
        // Custom properties are case-sensitive
        return name;
    }

    // Internal lookups (layout, CDP) pass lowercase names, often outside of a
    // JS call where nothing resets local_arena.
    if (!Element.Attribute.needsLowerCasing(name)) {
        return name;
    }
    return std.ascii.allocLowerString(allocator, name) catch name;
}

fn isColorProperty(id: properties.Id) bool {
    return switch (id) {
        .@"background-color", .@"border-block-end-color", .@"border-block-start-color", .@"border-bottom-color", .@"border-inline-end-color", .@"border-inline-start-color", .@"border-left-color", .@"border-right-color", .@"border-top-color", .color, .@"column-rule-color", .@"flood-color", .@"lighting-color", .@"outline-color", .@"stop-color", .@"text-decoration-color", .@"text-emphasis-color" => true,
        else => false,
    };
}

fn isCustomProperty(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "--");
}

// Normalize CSS property values for canonical serialization
fn normalizePropertyValue(arena: Allocator, id: properties.Id, raw_value: []const u8) ![]const u8 {
    const value = try normalizeLeadingZeros(arena, raw_value);

    // Per CSSOM spec, unitless zero in length properties should serialize as "0px"
    if (std.mem.eql(u8, value, "0") and isLengthProperty(id)) {
        return "0px";
    }

    // "first baseline" serializes canonically as "baseline" (first is the default)
    if (std.ascii.startsWithIgnoreCase(value, "first baseline")) {
        if (value.len == 14) {
            // Exact match "first baseline"
            return "baseline";
        }
        if (value.len > 14 and value[14] == ' ') {
            // "first baseline X" -> "baseline X"
            return try std.mem.concat(arena, u8, &.{ "baseline", value[14..] });
        }
    }

    // For 2-value shorthand properties, collapse "X X" to "X"
    if (isTwoValueShorthand(id)) {
        if (collapseDuplicateValue(value)) |single| {
            return single;
        }
    }

    // Canonicalize anchor-size() function: anchor name (dashed ident) comes before size keyword
    if (std.mem.find(u8, value, "anchor-size(")) |idx| {
        return canonicalizeAnchorSize(arena, value, idx);
    }

    // Canonicalize anchor() function: anchor name (dashed ident) comes before position keyword
    // Note: indexOf finds first occurrence, so we check it's not part of "anchor-size("
    if (std.mem.find(u8, value, "anchor(")) |idx| {
        if (idx == 0 or value[idx - 1] != '-') {
            return canonicalizeAnchor(arena, value, idx);
        }
    }

    return value;
}

// Insert a leading "0" before any bare ".<digit>". A value might have multiple
// such bare digits
fn normalizeLeadingZeros(arena: Allocator, value: []const u8) ![]const u8 {
    // A bare ".<digit>" needs at least 2 chars, and a trailing "." can never be
    // followed by a digit. So we only ever scan up to value.len - 1, which lets
    // us index value[i + 1] without a bounds check.
    if (value.len < 2) {
        return value;
    }

    var inserts: usize = 0;
    for (value[0 .. value.len - 1], 0..) |c, i| {
        if (c != '.') {
            continue;
        }
        if (!std.ascii.isDigit(value[i + 1])) {
            // next value isn't a digit
            continue;
        }
        if (i > 0 and std.ascii.isDigit(value[i - 1])) {
            // previous value is a digit
            continue;
        }
        inserts += 1;
    }
    if (inserts == 0) {
        return value;
    }

    const buf = try arena.alloc(u8, value.len + inserts);
    var w: usize = 0;
    for (value[0 .. value.len - 1], 0..) |c, i| {
        if (c == '.' and std.ascii.isDigit(value[i + 1]) and (i == 0 or !std.ascii.isDigit(value[i - 1]))) {
            buf[w] = '0';
            w += 1;
        }
        buf[w] = c;
        w += 1;
    }
    // The last char is copied unconditionally: it can't start a bare ".<digit>".
    buf[w] = value[value.len - 1];
    w += 1;
    return buf[0..w];
}

// Canonicalize anchor-size() so that the dashed ident (anchor name) comes before the size keyword.
// e.g. "anchor-size(width --foo)" -> "anchor-size(--foo width)"
fn canonicalizeAnchorSize(arena: Allocator, value: []const u8, start_index: usize) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);

    // Copy everything before the first anchor-size(
    try buf.writer.writeAll(value[0..start_index]);

    var i: usize = start_index;

    while (i < value.len) {
        // Look for "anchor-size("
        if (std.mem.startsWith(u8, value[i..], "anchor-size(")) {
            try buf.writer.writeAll("anchor-size(");
            i += "anchor-size(".len;

            // Parse and canonicalize the arguments
            i = try canonicalizeAnchorFnArgs(value, i, &buf.writer, .anchor_size);
        } else {
            try buf.writer.writeByte(value[i]);
            i += 1;
        }
    }

    return buf.written();
}

const AnchorFnKind = enum { anchor, anchor_size };

// Parse anchor/anchor-size arguments and write them in canonical order
fn canonicalizeAnchorFnArgs(value: []const u8, start: usize, writer: *std.Io.Writer, kind: AnchorFnKind) !usize {
    var i = start;
    var depth: usize = 1;

    // Skip leading whitespace
    while (i < value.len and value[i] == ' ') : (i += 1) {}

    var token_count: usize = 0;
    var comma_pos: ?usize = null;

    var first_token_end: usize = 0;
    var first_token_start: ?usize = null;

    var second_token_end: usize = 0;
    var second_token_start: ?usize = null;

    const args_start = i;
    var in_token = false;

    // First pass: find the structure of arguments before comma/closing paren at depth 1
    while (i < value.len and depth > 0) {
        const c = value[i];

        if (c == '(') {
            depth += 1;
            in_token = true;
            i += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                if (in_token) {
                    if (token_count == 0) {
                        first_token_end = i;
                    } else if (token_count == 1) {
                        second_token_end = i;
                    }
                }
                break;
            }
            i += 1;
        } else if (c == ',' and depth == 1) {
            if (in_token) {
                if (token_count == 0) {
                    first_token_end = i;
                } else if (token_count == 1) {
                    second_token_end = i;
                }
            }
            comma_pos = i;
            break;
        } else if (c == ' ') {
            if (in_token and depth == 1) {
                if (token_count == 0) {
                    first_token_end = i;
                    token_count = 1;
                } else if (token_count == 1 and second_token_start != null) {
                    second_token_end = i;
                    token_count = 2;
                }
                in_token = false;
            }
            i += 1;
        } else {
            if (!in_token and depth == 1) {
                if (token_count == 0) {
                    first_token_start = i;
                } else if (token_count == 1) {
                    second_token_start = i;
                }
                in_token = true;
            }
            i += 1;
        }
    }

    // Handle end of tokens
    if (in_token and token_count == 1 and second_token_start != null) {
        second_token_end = i;
        token_count = 2;
    } else if (in_token and token_count == 0) {
        first_token_end = i;
        token_count = 1;
    }

    // Check if we have exactly two tokens that need reordering
    if (token_count == 2) {
        const first_start = first_token_start orelse args_start;
        const second_start = second_token_start orelse first_token_end;

        const first_token = value[first_start..first_token_end];
        const second_token = value[second_start..second_token_end];

        // If second token is a dashed ident, it should come first
        // For anchor-size, also check that first token is a size keyword
        const should_swap = std.mem.startsWith(u8, second_token, "--") and
            (kind == .anchor or isAnchorSizeKeyword(first_token));

        if (should_swap) {
            try writer.writeAll(second_token);
            try writer.writeByte(' ');
            try writer.writeAll(first_token);
        } else {
            try writer.writeAll(first_token);
            try writer.writeByte(' ');
            try writer.writeAll(second_token);
        }
    } else if (first_token_start) |fts| {
        // Single token, just copy it
        try writer.writeAll(value[fts..first_token_end]);
    }

    // Handle comma and fallback value (may contain nested functions)
    if (comma_pos) |cp| {
        try writer.writeAll(", ");
        i = cp + 1;
        // Skip whitespace after comma
        while (i < value.len and value[i] == ' ') : (i += 1) {}

        // Copy the fallback, recursively handling nested anchor/anchor-size
        while (i < value.len and depth > 0) {
            if (std.mem.startsWith(u8, value[i..], "anchor-size(")) {
                try writer.writeAll("anchor-size(");
                i += "anchor-size(".len;
                depth += 1;
                i = try canonicalizeAnchorFnArgs(value, i, writer, .anchor_size);
                depth -= 1;
            } else if (std.mem.startsWith(u8, value[i..], "anchor(")) {
                try writer.writeAll("anchor(");
                i += "anchor(".len;
                depth += 1;
                i = try canonicalizeAnchorFnArgs(value, i, writer, .anchor);
                depth -= 1;
            } else if (value[i] == '(') {
                depth += 1;
                try writer.writeByte(value[i]);
                i += 1;
            } else if (value[i] == ')') {
                depth -= 1;
                if (depth == 0) break;
                try writer.writeByte(value[i]);
                i += 1;
            } else {
                try writer.writeByte(value[i]);
                i += 1;
            }
        }
    }

    // Write closing paren
    try writer.writeByte(')');

    return i + 1; // Skip past the closing paren
}

fn isAnchorSizeKeyword(token: []const u8) bool {
    const keywords = std.StaticStringMap(void).initComptime(.{
        .{ "width", {} },
        .{ "height", {} },
        .{ "block", {} },
        .{ "inline", {} },
        .{ "self-block", {} },
        .{ "self-inline", {} },
    });
    return keywords.has(token);
}

// Canonicalize anchor() so that the dashed ident (anchor name) comes before the position keyword.
// e.g. "anchor(left --foo)" -> "anchor(--foo left)"
fn canonicalizeAnchor(arena: Allocator, value: []const u8, start_index: usize) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(arena);

    // Copy everything before the first anchor(
    try buf.writer.writeAll(value[0..start_index]);

    var i: usize = start_index;

    while (i < value.len) {
        // Look for "anchor(" but not "anchor-size("
        if (std.mem.startsWith(u8, value[i..], "anchor(") and (i == 0 or value[i - 1] != '-')) {
            try buf.writer.writeAll("anchor(");
            i += "anchor(".len;

            // Parse and canonicalize the arguments
            i = try canonicalizeAnchorFnArgs(value, i, &buf.writer, .anchor);
        } else {
            try buf.writer.writeByte(value[i]);
            i += 1;
        }
    }

    return buf.written();
}

// Check if a value is "X X" (duplicate) and return just "X"
fn collapseDuplicateValue(value: []const u8) ?[]const u8 {
    const space_idx = std.mem.findScalar(u8, value, ' ') orelse return null;
    if (space_idx == 0 or space_idx >= value.len - 1) return null;

    const first = value[0..space_idx];
    const rest = std.mem.trimStart(u8, value[space_idx + 1 ..], " ");

    // Check if there's only one more value (no additional spaces)
    if (std.mem.findScalar(u8, rest, ' ') != null) return null;

    if (std.mem.eql(u8, first, rest)) {
        return first;
    }
    return null;
}

fn isTwoValueShorthand(id: properties.Id) bool {
    return switch (id) {
        .@"place-content",
        .@"place-items",
        .@"place-self",
        .@"margin-block",
        .@"margin-inline",
        .@"padding-block",
        .@"padding-inline",
        .@"inset-block",
        .@"inset-inline",
        .@"border-block-style",
        .@"border-inline-style",
        .@"border-block-width",
        .@"border-inline-width",
        .@"border-block-color",
        .@"border-inline-color",
        .@"overscroll-behavior",
        .gap,
        .@"grid-gap",
        // Scroll
        .@"scroll-padding-block",
        .@"scroll-padding-inline",
        .@"scroll-snap-align",
        // Background/Mask
        .@"background-size",
        .@"border-image-repeat",
        .@"mask-repeat",
        .@"mask-size",
        => true,
        else => false,
    };
}

fn isLengthProperty(id: properties.Id) bool {
    // Properties that accept <length> or <length-percentage> values
    return switch (id) {
        // Sizing
        .width,
        .height,
        .@"min-width",
        .@"min-height",
        .@"max-width",
        .@"max-height",
        // Margins
        .margin,
        .@"margin-top",
        .@"margin-right",
        .@"margin-bottom",
        .@"margin-left",
        .@"margin-block",
        .@"margin-block-start",
        .@"margin-block-end",
        .@"margin-inline",
        .@"margin-inline-start",
        .@"margin-inline-end",
        // Padding
        .padding,
        .@"padding-top",
        .@"padding-right",
        .@"padding-bottom",
        .@"padding-left",
        .@"padding-block",
        .@"padding-block-start",
        .@"padding-block-end",
        .@"padding-inline",
        .@"padding-inline-start",
        .@"padding-inline-end",
        // Positioning
        .top,
        .right,
        .bottom,
        .left,
        .inset,
        .@"inset-block",
        .@"inset-block-start",
        .@"inset-block-end",
        .@"inset-inline",
        .@"inset-inline-start",
        .@"inset-inline-end",
        // Border
        .@"border-width",
        .@"border-top-width",
        .@"border-right-width",
        .@"border-bottom-width",
        .@"border-left-width",
        .@"border-block-width",
        .@"border-block-start-width",
        .@"border-block-end-width",
        .@"border-inline-width",
        .@"border-inline-start-width",
        .@"border-inline-end-width",
        .@"border-radius",
        .@"border-top-left-radius",
        .@"border-top-right-radius",
        .@"border-bottom-left-radius",
        .@"border-bottom-right-radius",
        // Text
        .@"font-size",
        .@"letter-spacing",
        .@"word-spacing",
        .@"text-indent",
        // Flexbox/Grid
        .gap,
        .@"row-gap",
        .@"column-gap",
        .@"flex-basis",
        // Legacy grid aliases
        .@"grid-column-gap",
        .@"grid-row-gap",
        // Outline
        .outline,
        .@"outline-width",
        .@"outline-offset",
        // Multi-column
        .@"column-rule-width",
        .@"column-width",
        // Scroll
        .@"scroll-margin",
        .@"scroll-margin-top",
        .@"scroll-margin-right",
        .@"scroll-margin-bottom",
        .@"scroll-margin-left",
        .@"scroll-padding",
        .@"scroll-padding-top",
        .@"scroll-padding-right",
        .@"scroll-padding-bottom",
        .@"scroll-padding-left",
        // Shapes
        .@"shape-margin",
        // Motion path
        .@"offset-distance",
        // Transforms
        .translate,
        // Animations
        .@"animation-range-end",
        .@"animation-range-start",
        // Other
        .@"border-spacing",
        .@"text-shadow",
        .@"box-shadow",
        .@"baseline-shift",
        .@"vertical-align",
        => true,
        else => false,
    };
}

/// Computed value of `initial`, '' for a custom property
fn initialValue(id: properties.Id) []const u8 {
    if (properties.propertyOf(id)) |property| {
        if (property.initial) |value| {
            return value;
        }
    }

    // shorthand initial value
    return switch (id) {
        .margin, .padding, .@"border-width", .@"border-radius" => "0px",
        .@"border-style" => "none",
        .gap => "normal",
        else => "",
    };
}

/// The UA stylesheet's value for `element`, when it isn't the initial value.
fn uaDefaultValue(element: *const Element, id: properties.Id) ?[]const u8 {
    return switch (id) {
        .display => getDefaultDisplay(element),
        .color => getDefaultColor(element),
        else => null,
    };
}

fn getDefaultDisplay(element: *const Element) []const u8 {
    switch (element._type) {
        .html => {
            return switch (element.subtype(Element.Html)._type) {
                .anchor, .br, .span, .label, .time, .font, .mod, .quote, .source, .track => "inline",
                .body, .div, .dl, .p, .heading, .form, .button, .canvas, .details, .dialog, .embed, .head, .html, .hr, .iframe, .img, .input, .li, .link, .meta, .ol, .option, .script, .select, .slot, .style, .template, .textarea, .title, .ul, .media, .area, .base, .datalist, .directory, .fieldset, .frame, .frameset, .legend, .map, .marquee, .meter, .object, .optgroup, .output, .param, .picture, .pre, .progress, .table, .table_caption, .table_cell, .table_col, .table_row, .table_section => "block",
                .generic, .custom, .unknown, .data => blk: {
                    const tag = element.getTagNameLower();
                    if (isInlineTag(tag)) break :blk "inline";
                    break :blk "block";
                },
            };
        },
        .svg => return "inline",
    }
}

fn isInlineTag(tag_name: []const u8) bool {
    const inline_tags = [_][]const u8{
        "abbr",  "b",    "bdi",    "bdo",  "cite", "code", "dfn",
        "em",    "i",    "kbd",    "mark", "q",    "s",    "samp",
        "small", "span", "strong", "sub",  "sup",  "time", "u",
        "var",   "wbr",
    };

    for (inline_tags) |inline_tag| {
        if (std.mem.eql(u8, tag_name, inline_tag)) {
            return true;
        }
    }
    return false;
}

fn getDefaultColor(element: *const Element) ?[]const u8 {
    switch (element._type) {
        .html => {
            return switch (element.subtype(Element.Html)._type) {
                // a:link, blue; an anchor without href isn't a link
                .anchor => if (element.hasAttributeInterned("href")) "rgb(0, 0, 238)" else null,
                else => null,
            };
        },
        .svg => return null,
    }
}

fn formatEntry(entry: *const Entry, writer: *std.Io.Writer, frame: *const Frame) !void {
    try writer.writeAll(entry.name(&frame.page.css_custom_names));
    try writer.writeAll(": ");
    try writer.writeAll(entry.value());
    try formatDeclarationEnd(entry._important, writer);
}

fn formatDeclarationEnd(important: bool, writer: *std.Io.Writer) !void {
    if (important) {
        try writer.writeAll(" !important");
    }
    try writer.writeByte(';');
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleDeclaration);

    pub const Meta = struct {
        pub const name = "CSSStyleDeclaration";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const cssText = bridge.accessor(CSSStyleDeclaration.getCssText, CSSStyleDeclaration.setCssText, .{ .ce_reactions = true });
    pub const length = bridge.fastAccessor(CSSStyleDeclaration.length, null, .{ .getter = .unsafe });
    pub const item = bridge.function(_item, .{});

    fn _item(self: *const CSSStyleDeclaration, index: i32, frame: *Frame) []const u8 {
        if (index < 0) {
            return "";
        }
        return self.item(@intCast(index), frame);
    }

    pub const getPropertyValue = bridge.function(CSSStyleDeclaration.getPropertyValue, .{});
    pub const getPropertyPriority = bridge.function(CSSStyleDeclaration.getPropertyPriority, .{});
    pub const setProperty = bridge.function(_setProperty, .{ .ce_reactions = true });
    fn _setProperty(self: *CSSStyleDeclaration, property_name: []const u8, value: js.Value, priority_: ?[]const u8, frame: *Frame) !void {
        // `[LegacyNullToEmptyString] CSSOMString value`: a JS null becomes "", not "null".
        return self.setProperty(property_name, if (value.isNull()) "" else try value.toZig([]const u8), priority_, frame);
    }
    pub const removeProperty = bridge.function(CSSStyleDeclaration.removeProperty, .{ .ce_reactions = true });
    pub const cssFloat = bridge.accessor(CSSStyleDeclaration.getFloat, CSSStyleDeclaration.setFloat, .{ .ce_reactions = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: CSSStyleDeclaration computed transform" {
    try testing.htmlRunner("css/computed_transform.html", .{});
}

test "WebApi: CSSStyleDeclaration computed content" {
    try testing.htmlRunner("css/computed_content.html", .{});
}

test "WebApi: CSSStyleDeclaration computed inheritance" {
    try testing.htmlRunner("css/computed_inheritance.html", .{});
}

test "writeCssNumber: six significant digits" {
    const cases = [_]struct { f64, []const u8 }{
        .{ 0, "0" },
        .{ -0.0, "0" },
        .{ 1, "1" },
        .{ 10, "10" },
        .{ -2.5, "-2.5" },
        .{ 0.7071067811865476, "0.707107" },
        .{ -0.7071067811865476, "-0.707107" },
        .{ 6.123233995736766e-17, "6.12323e-17" },
        .{ 123456.7, "123457" },
        .{ 1234567, "1.23457e+6" },
        .{ 0.0001, "0.0001" },
        .{ 0.000001, "0.000001" },
        .{ -1e-7, "-1e-7" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writeCssNumber(&writer, c[0]);
        try testing.expectEqual(c[1], writer.buffered());
    }
}

test "CSS property value storage is reused" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var style = CSSStyleDeclaration{};
    defer style.clearProperties(frame);

    try testing.expect(try style.setPropertyImpl(.transform, "translate3d(1px,0,0)", false, frame));
    const first_ptr = style.findProperty(.transform).?._value_ptr;
    try testing.expect(try style.setPropertyImpl(.transform, "translate3d(2px,0,0)", false, frame));
    try testing.expect(try style.setPropertyImpl(.transform, "translate3d(3px,0,0)", false, frame));

    const property = style.findProperty(.transform).?;
    try std.testing.expectEqual(first_ptr, property._value_ptr);
    try std.testing.expectEqualStrings("translate3d(3px,0,0)", property.value());
}

test "CSS declarations: order, names and value storage" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var style = CSSStyleDeclaration{};
    defer style.clearProperties(frame);

    // A parsed block is sized exactly: grown to 10, trimmed to 5.
    try style.setCssText("color: red; --gap: 4px; display: none; width: 123px; opacity: 0.5", frame);
    try testing.expectEqual(5, style._declarations._len);
    try testing.expectEqual(5, style._declarations._cap);

    // A known property has the table's id, a custom one the page's.
    try testing.expectEqual(.display, style._declarations._entries[2]._id);
    try testing.expectEqual(null, properties.knownName(style._declarations._entries[1]._id));
    try testing.expectEqual("--gap", style.item(1, frame));

    // A custom name has one id across the page's declarations.
    var other = CSSStyleDeclaration{};
    defer other.clearProperties(frame);
    try other.setCssText("--gap: 8px", frame);
    try testing.expectEqual(style._declarations._entries[1]._id, other._declarations._entries[0]._id);

    // Reading one the page never declared doesn't number it.
    const custom_count = frame.page.css_custom_names._names.count();
    try testing.expectEqual("", style.getPropertyValue("--never-declared", frame));
    try testing.expectEqual("", try style.removeProperty("--never-declared", frame));
    try testing.expectEqual(custom_count, frame.page.css_custom_names._names.count());

    // A common value is static, any other ours to free.
    try testing.expectEqual(false, style.findProperty(.display).?._value_owned);
    try testing.expectEqual(true, style.findProperty(.width).?._value_owned);

    // Removing keeps the others in order; setting again appends.
    try testing.expectEqual("red", try style.removeProperty("color", frame));
    try style.setProperty("color", "blue", null, frame);
    try testing.expectEqual("--gap: 4px; display: none; width: 123px; opacity: 0.5; color: blue;", try style.getCssText(frame));

    // A custom property declared later keeps its place too.
    try style.setProperty("--Pad", "1px", null, frame);
    try testing.expectEqual("--gap: 4px; display: none; width: 123px; opacity: 0.5; color: blue; --Pad: 1px;", try style.getCssText(frame));
    try testing.expectEqual("1px", style.getPropertyValue("--Pad", frame));
    try testing.expectEqual("", style.getPropertyValue("--pad", frame));
    try testing.expectEqual("1px", try style.removeProperty("--Pad", frame));

    // An unknown property is dropped.
    try style.setProperty("not-a-property", "1", null, frame);
    try testing.expectEqual(5, style.length());
}

test "normalizePropertyValue: unitless zero to 0px" {
    const cases = .{
        .{ "width", "0", "0px" },
        .{ "height", "0", "0px" },
        .{ "scroll-margin-top", "0", "0px" },
        .{ "scroll-padding-bottom", "0", "0px" },
        .{ "column-width", "0", "0px" },
        .{ "column-rule-width", "0", "0px" },
        .{ "outline", "0", "0px" },
        .{ "shape-margin", "0", "0px" },
        .{ "offset-distance", "0", "0px" },
        .{ "translate", "0", "0px" },
        .{ "grid-column-gap", "0", "0px" },
        .{ "grid-row-gap", "0", "0px" },
        // Non-length properties should NOT normalize
        .{ "opacity", "0", "0" },
        .{ "z-index", "0", "0" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.allocator, @field(properties.Id, case[0]), case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: first baseline to baseline" {
    const result = try normalizePropertyValue(testing.allocator, .@"align-items", "first baseline");
    try testing.expectEqual("baseline", result);

    const result2 = try normalizePropertyValue(testing.allocator, .@"align-self", "last baseline");
    try testing.expectEqual("last baseline", result2);
}

test "normalizePropertyValue: collapse duplicate two-value shorthands" {
    const cases = .{
        .{ "gap", "10px 10px", "10px" },
        .{ "scroll-snap-align", "start start", "start" },
        .{ "scroll-padding-block", "5px 5px", "5px" },
        .{ "background-size", "auto auto", "auto" },
        .{ "overscroll-behavior", "auto auto", "auto" },
        // Different values should NOT collapse
        .{ "gap", "10px 20px", "10px 20px" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.allocator, @field(properties.Id, case[0]), case[1]);
        try testing.expectEqual(case[2], result);
    }
}

test "normalizePropertyValue: anchor() canonical order" {
    const cases = .{
        // Dashed ident should come before keyword
        .{ "left", "anchor(left --foo)", "anchor(--foo left)" },
        .{ "left", "anchor(inside --foo)", "anchor(--foo inside)" },
        .{ "left", "anchor(50% --foo)", "anchor(--foo 50%)" },
        // Already canonical order - keep as-is
        .{ "left", "anchor(--foo left)", "anchor(--foo left)" },
        .{ "left", "anchor(left)", "anchor(left)" },
        // With fallback
        .{ "left", "anchor(left --foo, 1px)", "anchor(--foo left, 1px)" },
        // Nested anchor in fallback
        .{ "left", "anchor(left --foo, anchor(right --bar))", "anchor(--foo left, anchor(--bar right))" },
    };
    inline for (cases) |case| {
        const result = try normalizePropertyValue(testing.arena_allocator, @field(properties.Id, case[0]), case[1]);
        try testing.expectEqual(case[2], result);
    }
}
