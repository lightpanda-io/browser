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
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");

const Element = @import("../Element.zig");

const String = lp.String;

const max_long: i64 = 2147483647;

pub const UnsignedLongOpts = struct {
    default: u32 = 0,
    // limited to only non-negative numbers greater than zero: 0 is
    // IndexSizeError on setting; with `fallback`, 0 becomes the default.
    positive: bool = false,
    fallback: bool = false,
    // clamped to the range [min, max]
    clamp: ?struct { min: u32, max: u32 } = null,
};

pub const EnumOpts = struct {
    // missing value default; null means the attribute reflects as null
    missing: ?[]const u8 = "",
    // invalid value default; defaults to `missing`
    invalid: ?[]const u8 = null,
    // IDL attribute is nullable (setting null removes the attribute)
    nullable: bool = false,
};

pub fn Reflect(comptime T: type) type {
    return struct {
        const bridge = js.Bridge(T);

        pub fn string(comptime attr: []const u8) js.bridge.Accessor {
            const R = struct {
                fn get(self: *const T) []const u8 {
                    return element(self).getAttributeSafe(.wrap(attr)) orelse "";
                }
                fn set(self: *T, value: []const u8, frame: *Frame) !void {
                    try element(self).setAttributeSafe(.wrap(attr), .wrap(value), frame);
                }
            };
            return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
        }

        pub fn stringNullToEmpty(comptime attr: []const u8) js.bridge.Accessor {
            const R = struct {
                fn get(self: *const T) []const u8 {
                    return element(self).getAttributeSafe(.wrap(attr)) orelse "";
                }
                fn set(self: *T, value: js.Value, frame: *Frame) !void {
                    const str = if (value.isNull()) "" else try value.toStringSlice();
                    try element(self).setAttributeSafe(.wrap(attr), .wrap(str), frame);
                }
            };
            return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
        }

        pub fn url(comptime attr: []const u8) js.bridge.Accessor {
            const R = struct {
                fn get(self: *const T, frame: *Frame) ![]const u8 {
                    const el = element(self);
                    const value = el.getAttributeSafe(.wrap(attr)) orelse return "";
                    return el.asConstNode().resolveURLReflect(value, frame, .{});
                }
                fn set(self: *T, value: []const u8, frame: *Frame) !void {
                    try element(self).setAttributeSafe(.wrap(attr), .wrap(value), frame);
                }
            };
            return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
        }

        pub fn boolean(comptime attr: []const u8) js.bridge.Accessor {
            const R = struct {
                fn get(self: *const T) bool {
                    return element(self).hasAttributeSafe(.wrap(attr));
                }
                fn set(self: *T, value: bool, frame: *Frame) !void {
                    const el = element(self);
                    if (value) {
                        try el.setAttributeSafe(.wrap(attr), String.empty, frame);
                    } else {
                        try el.removeAttribute(.wrap(attr), frame);
                    }
                }
            };
            return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
        }

        pub fn enumerated(comptime attr: []const u8, comptime keywords: []const []const u8, comptime opts: EnumOpts) js.bridge.Accessor {
            const invalid = opts.invalid orelse opts.missing;
            const R = struct {
                fn get(self: *const T) ?[]const u8 {
                    return enumeratedValue(element(self).getAttributeSafe(.wrap(attr)), keywords, opts.missing, invalid);
                }
                fn set(self: *T, value: []const u8, frame: *Frame) !void {
                    try element(self).setAttributeSafe(.wrap(attr), .wrap(value), frame);
                }
                fn setNullable(self: *T, value: ?[]const u8, frame: *Frame) !void {
                    const el = element(self);
                    if (value) |v| {
                        try el.setAttributeSafe(.wrap(attr), .wrap(v), frame);
                    } else {
                        try el.removeAttribute(.wrap(attr), frame);
                    }
                }
            };
            if (opts.nullable) {
                return bridge.accessor(R.get, R.setNullable, .{ .ce_reactions = true });
            }
            return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
        }

        pub fn referrerPolicy() js.bridge.Accessor {
            const referrer_policies = [_][]const u8{
                "",
                "no-referrer",
                "no-referrer-when-downgrade",
                "same-origin",
                "origin",
                "strict-origin",
                "origin-when-cross-origin",
                "strict-origin-when-cross-origin",
                "unsafe-url",
            };
            return enumerated("referrerpolicy", &referrer_policies, .{});
        }

        pub fn long(comptime attr: []const u8, comptime default: i32) js.bridge.Accessor {
            const R = struct {
                fn get(self: *const T) i32 {
                    const value = element(self).getAttributeSafe(.wrap(attr)) orelse return default;
                    const parsed = parseInteger(value) orelse return default;
                    if (parsed < -max_long - 1 or parsed > max_long) {
                        return default;
                    }
                    return @intCast(parsed);
                }
                fn set(self: *T, value: i32, frame: *Frame) !void {
                    try setInteger(element(self), attr, value, frame);
                }
            };
            return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
        }

        // unsigned, but -1 is used to signal no limit
        pub fn limitedLong(comptime attr: []const u8) js.bridge.Accessor {
            const R = struct {
                fn get(self: *const T) i32 {
                    return getLimitedLong(element(self), .wrap(attr));
                }
                fn set(self: *T, value: i32, frame: *Frame) !void {
                    if (value < 0) {
                        return error.IndexSizeError;
                    }
                    try setInteger(element(self), attr, value, frame);
                }
            };
            return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
        }

        pub fn unsignedLong(comptime attr: []const u8, comptime opts: UnsignedLongOpts) js.bridge.Accessor {
            const min: i64 = if (opts.clamp) |c| c.min else if (opts.positive) 1 else 0;
            const max: i64 = if (opts.clamp) |c| c.max else max_long;
            const R = struct {
                fn get(self: *const T) u32 {
                    const value = element(self).getAttributeSafe(.wrap(attr)) orelse return opts.default;
                    const parsed = parseInteger(value) orelse return opts.default;
                    if (parsed < 0) {
                        return opts.default;
                    }
                    if (opts.clamp != null) {
                        return @intCast(std.math.clamp(parsed, min, max));
                    }
                    if (parsed < min or parsed > max) {
                        return opts.default;
                    }
                    return @intCast(parsed);
                }
                fn set(self: *T, value: u32, frame: *Frame) !void {
                    if (opts.positive and !opts.fallback and value == 0) {
                        return error.IndexSizeError;
                    }
                    // clamping is a getter rule; setting is a plain unsigned long
                    const set_min: i64 = if (opts.positive) 1 else 0;
                    var n: i64 = value;
                    if (n < set_min or n > max_long) {
                        n = if (opts.fallback or opts.default != 0) opts.default else 0;
                    }
                    try setInteger(element(self), attr, n, frame);
                }
            };
            return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
        }

        pub fn double(comptime attr: []const u8, comptime default: f64, comptime positive: bool) js.bridge.Accessor {
            const R = struct {
                fn get(self: *const T) f64 {
                    const value = element(self).getAttributeSafe(.wrap(attr)) orelse return default;
                    const parsed = parseFloat(value) orelse return default;
                    if (positive and parsed <= 0) {
                        return default;
                    }
                    return parsed;
                }
                fn set(self: *T, value: f64, frame: *Frame) !void {
                    if (!std.math.isFinite(value)) {
                        return error.TypeError;
                    }
                    if (positive and value <= 0) {
                        return;
                    }
                    // JS's Number-to-string is the "best representation"
                    const str = try (try frame.js.local.?.newNumber(value)).toStringSlice();
                    try element(self).setAttributeSafe(.wrap(attr), .wrap(str), frame);
                }
            };
            return bridge.accessor(R.get, R.set, .{ .ce_reactions = true });
        }

        fn element(self: anytype) *Element {
            const proto = Factory.protoOf(self);
            if (@TypeOf(proto) == *Element) {
                return proto;
            }
            return proto.asElement();
        }

        // comptime SSO when the name fits (fast compare), a plain slice String otherwise
        fn name(comptime attr: []const u8) String {
            if (comptime attr.len <= 12) {
                return comptime .wrap(attr);
            }
            return .wrap(attr);
        }
    };
}

// Enumerated attribute limited to only known values: the canonical keyword,
// or the missing/invalid default. Shared with elements that read one internally.
pub fn enumeratedValue(
    value: ?[]const u8,
    keywords: []const []const u8,
    missing: ?[]const u8,
    invalid: ?[]const u8,
) ?[]const u8 {
    const v = value orelse return missing;
    for (keywords) |keyword| {
        if (std.ascii.eqlIgnoreCase(v, keyword)) return keyword;
    }
    return invalid;
}

// unsigned, but returns -1 for no limit.
pub fn getLimitedLong(el: *const Element, attr: String) i32 {
    const value = el.getAttributeSafe(attr) orelse return -1;
    const parsed = parseInteger(value) orelse return -1;
    if (parsed < 0 or parsed > max_long) {
        return -1;
    }
    return @intCast(parsed);
}

fn setInteger(el: *Element, comptime attr: []const u8, value: i64, frame: *Frame) !void {
    var buf: [24]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try el.setAttributeSafe(.wrap(attr), .wrap(str), frame);
}

// HTML "rules for parsing integers". Saturates instead of failing on
// absurdly long digit runs so the clamped reflections still see "too big".
pub fn parseInteger(input: []const u8) ?i64 {
    var s = std.mem.trimStart(u8, input, "\t\n\x0c\r ");
    if (s.len == 0) {
        return null;
    }

    var negative = false;
    if (s[0] == '-') {
        negative = true;
        s = s[1..];
    } else if (s[0] == '+') {
        s = s[1..];
    }
    if (s.len == 0 or !std.ascii.isDigit(s[0])) {
        return null;
    }

    var value: i64 = 0;
    for (s) |c| {
        if (std.ascii.isDigit(c) == false) {
            break;
        }
        if (value < (1 << 53)) {
            value = value * 10 + (c - '0');
        }
    }
    return if (negative) -value else value;
}

// HTML "rules for parsing floating-point number values". The grammar isn't
// the same as Zig's, so we need to validate by hand, but can let std do some
// of the work
fn parseFloat(input: []const u8) ?f64 {
    const s = std.mem.trimStart(u8, input, "\t\n\x0c\r ");
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        i += 1;
    }

    var digits = false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        digits = true;
    }

    if (i < s.len and s[i] == '.' and i + 1 < s.len and std.ascii.isDigit(s[i + 1])) {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            digits = true;
        }
    }
    if (digits == false) {
        return null;
    }

    var end = i;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '-' or s[j] == '+')) {
            j += 1;
        }
        if (j < s.len and std.ascii.isDigit(s[j])) {
            while (j < s.len and std.ascii.isDigit(s[j])) {
                j += 1;
            }
            end = j;
        }
    }
    const value = std.fmt.parseFloat(f64, s[0..end]) catch return null;
    if (std.math.isFinite(value) == false) {
        return null;
    }
    return value;
}

const testing = @import("../../../testing.zig");
test "reflect: parseInteger" {
    try testing.expectEqual(7, parseInteger(" \t7"));
    try testing.expectEqual(-36, parseInteger("-36abc"));
    try testing.expectEqual(0, parseInteger("-0"));
    try testing.expectEqual(100, parseInteger("+100"));
    try testing.expectEqual(null, parseInteger(""));
    try testing.expectEqual(null, parseInteger("-"));
    try testing.expectEqual(null, parseInteger(".5"));
    try testing.expectEqual(null, parseInteger("\u{a0}7"));
    try testing.expect(parseInteger("99999999999999999999999999").? > max_long);
}

test "reflect: parseFloat" {
    try testing.expectEqual(1.5, parseFloat(" 1.5"));
    try testing.expectEqual(0.5, parseFloat(".5"));
    try testing.expectEqual(1, parseFloat("1."));
    try testing.expectEqual(100, parseFloat("1e2"));
    try testing.expectEqual(100, parseFloat("1E+2"));
    try testing.expectEqual(0.01, parseFloat("1e-2"));
    try testing.expectEqual(1, parseFloat("1.e2"));
    try testing.expectEqual(1, parseFloat("1e 2"));
    try testing.expectEqual(1, parseFloat("1 e2"));
    try testing.expectEqual(-1, parseFloat("-1"));
    try testing.expectEqual(null, parseFloat(""));
    try testing.expectEqual(null, parseFloat("-"));
    try testing.expectEqual(null, parseFloat("."));
    try testing.expectEqual(null, parseFloat("e5"));
    try testing.expectEqual(null, parseFloat("1.8e308"));
}
