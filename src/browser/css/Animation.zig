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

//! The animation longhands that decide when the animation events fire, each as
//! the value that declared it.

const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const properties = @import("properties.zig");

const Animation = @This();

sources: std.enums.EnumArray(Longhand, ?Source) = .initFill(null),

pub const Longhand = enum { name, duration, delay, iteration_count };

pub const Source = union(enum) {
    list: []const u8,
    // `animation`, whose items set every longhand at once
    shorthand: []const u8,
};

pub const Timing = struct {
    name: []const u8,
    // milliseconds
    delay: f64,
    duration: f64,
    // inf for `infinite`
    iterations: f64,
};

/// The animation-name list's length.
pub fn count(self: Animation) usize {
    return switch (self.sources.get(.name) orelse return 0) {
        .list, .shorthand => |list| listCount(list),
    };
}

/// The `index`th animation, or null when its name is `none`.
pub fn timing(self: Animation, index: usize) ?Timing {
    const name = switch (self.sources.get(.name) orelse return null) {
        .list => |list| std.mem.trim(u8, listItem(list, index), "\"'"),
        .shorthand => |list| parseItem(listItem(list, index)).name,
    };
    if (name.len == 0 or std.ascii.eqlIgnoreCase(name, "none")) {
        return null;
    }
    const delay: f64 = switch (self.sources.get(.delay) orelse Source{ .list = "0s" }) {
        // A longhand's list holds nothing but delays
        .list => |list| parseItem(listItem(list, index)).duration,
        .shorthand => |list| parseItem(listItem(list, index)).delay,
    };
    const duration: f64 = switch (self.sources.get(.duration) orelse Source{ .list = "0s" }) {
        .list, .shorthand => |list| parseItem(listItem(list, index)).duration,
    };
    const iterations: f64 = switch (self.sources.get(.iteration_count) orelse Source{ .list = "1" }) {
        .list, .shorthand => |list| parseItem(listItem(list, index)).iterations,
    };
    return .{ .name = name, .delay = delay, .duration = @max(duration, 0), .iterations = @max(iterations, 0) };
}

const Item = struct {
    name: []const u8 = "",
    duration: f64 = 0,
    delay: f64 = 0,
    iterations: f64 = 1,
};

/// One item of the shorthand, or of a longhand list. The first time is the
/// duration and the second the delay; an ident no other longhand takes is
/// the name.
fn parseItem(text: []const u8) Item {
    var item: Item = .{};
    var times: u8 = 0;
    var depth: usize = 0;
    var tokenizer: Tokenizer = .{ .input = text };
    while (true) {
        const start = tokenizer.position;
        const token = tokenizer.next() orelse break;
        if (depth > 0) {
            switch (token) {
                .function, .parenthesis_block => depth += 1,
                .close_parenthesis => depth -= 1,
                else => {},
            }
            continue;
        }
        switch (token) {
            // cubic-bezier(…), steps(…)
            .function, .parenthesis_block => depth = 1,
            .dimension => |d| {
                // The token's f32 would give an elapsedTime of 0.30000001
                const value = std.fmt.parseFloat(f64, text[start .. tokenizer.position - d.unit.len]) catch d.value;
                const ms = if (std.ascii.eqlIgnoreCase(d.unit, "s")) value * 1000 else if (std.ascii.eqlIgnoreCase(d.unit, "ms")) value else continue;
                switch (times) {
                    0 => item.duration = ms,
                    1 => item.delay = ms,
                    else => {},
                }
                times +|= 1;
            },
            .number => |n| item.iterations = std.fmt.parseFloat(f64, text[start..tokenizer.position]) catch n.value,
            .ident => |ident| {
                if (std.ascii.eqlIgnoreCase(ident, "infinite")) {
                    item.iterations = std.math.inf(f64);
                } else if (isAnimationKeyword(ident) == false) {
                    item.name = ident;
                }
            },
            .string => |s| item.name = s,
            else => {},
        }
    }
    return item;
}

// `none` included: in the shorthand it is the fill mode's before the name's
fn isAnimationKeyword(ident: []const u8) bool {
    const keywords = [_][]const u8{
        "linear", "ease",    "ease-in",   "ease-out",          "ease-in-out", "step-start", "step-end",
        "normal", "reverse", "alternate", "alternate-reverse", "none",        "forwards",   "backwards",
        "both",   "running", "paused",
    };
    for (keywords) |keyword| {
        if (std.ascii.eqlIgnoreCase(ident, keyword)) {
            return true;
        }
    }
    return false;
}

fn listCount(list: []const u8) usize {
    var it: ListIterator = .{ .list = list };
    var n: usize = 0;
    while (it.next()) |_| {
        n += 1;
    }
    return n;
}

/// A shorter list repeats, as the animation longhands do.
fn listItem(list: []const u8, index: usize) []const u8 {
    const wanted = index % listCount(list);
    var it: ListIterator = .{ .list = list };
    var i: usize = 0;
    while (it.next()) |item| : (i += 1) {
        if (i == wanted) {
            return item;
        }
    }
    unreachable;
}

/// The items of a comma-separated list, outside parentheses.
const ListIterator = struct {
    list: []const u8,
    pos: usize = 0,
    done: bool = false,

    fn next(self: *ListIterator) ?[]const u8 {
        if (self.done) {
            return null;
        }
        const start = self.pos;
        var depth: usize = 0;
        while (self.pos < self.list.len) : (self.pos += 1) {
            switch (self.list[self.pos]) {
                '(' => depth += 1,
                ')' => depth -|= 1,
                ',' => if (depth == 0) {
                    const item = self.list[start..self.pos];
                    self.pos += 1;
                    return std.mem.trim(u8, item, &std.ascii.whitespace);
                },
                else => {},
            }
        }
        self.done = true;
        return std.mem.trim(u8, self.list[start..], &std.ascii.whitespace);
    }
};

/// The animation properties a rule can declare: the shorthand and the
/// longhands the events depend on.
pub const Property = enum {
    shorthand,
    name,
    duration,
    delay,
    iteration_count,

    /// The property a declaration sets. Browsers alias the -webkit- names.
    pub fn fromId(id: properties.Id) ?Property {
        return switch (id) {
            .animation, .@"-webkit-animation" => .shorthand,
            .@"animation-name", .@"-webkit-animation-name" => .name,
            .@"animation-duration", .@"-webkit-animation-duration" => .duration,
            .@"animation-delay", .@"-webkit-animation-delay" => .delay,
            .@"animation-iteration-count", .@"-webkit-animation-iteration-count" => .iteration_count,
            else => null,
        };
    }

    /// The standard property's id, which cssName names.
    pub fn standardId(self: Property) properties.Id {
        return switch (self) {
            .shorthand => .animation,
            .name => .@"animation-name",
            .duration => .@"animation-duration",
            .delay => .@"animation-delay",
            .iteration_count => .@"animation-iteration-count",
        };
    }

    pub fn cssName(self: Property) []const u8 {
        return switch (self) {
            .shorthand => "animation",
            .name => "animation-name",
            .duration => "animation-duration",
            .delay => "animation-delay",
            .iteration_count => "animation-iteration-count",
        };
    }
};
