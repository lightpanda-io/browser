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

const js = @import("../../../js/js.zig");

const Allocator = std.mem.Allocator;
const Local = js.Local;

const Key = @This();

const NUMBER_TAG: u8 = 10;
const DATE_TAG: u8 = 20;
const STRING_TAG: u8 = 30;
const BINARY_TAG: u8 = 40;
const ARRAY_TAG: u8 = 50;

// Guards against unbounded recursion / cyclic arrays when validating a JS value.
const MAX_DEPTH = 32;

value: Value,

pub const Value = union(enum) {
    number: f64,
    date: f64,
    string: []const u8,
    binary: []const u8,
    array: []const Value,
};

// A key path is either a single string path or, for a compound key, a list of
// string paths. An out-of-line store has no key path at all (represented as an
// optional KeyPath by its holders).
pub const KeyPath = union(enum) {
    string: []const u8,
    list: []const []const u8,
};

pub fn number(n: f64) Key {
    return .{ .value = .{ .number = n } };
}

pub fn string(s: []const u8) Key {
    return .{ .value = .{ .string = s } };
}

pub fn binary(s: []const u8) Key {
    return .{ .value = .{ .binary = s } };
}

pub fn array(items: []const Value) Key {
    return .{ .value = .{ .array = items } };
}

// Encode into an order-preserving byte slice, allocated by `allocator`.
// Caller owns the returned memory.
pub fn encode(self: Key, allocator: Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try encodeInto(allocator, self.value, &list);
    return list.toOwnedSlice(allocator);
}

fn encodeInto(allocator: Allocator, value: Value, list: *std.ArrayList(u8)) !void {
    switch (value) {
        .number => |n| try encodeF64(allocator, list, NUMBER_TAG, n),
        .date => |n| try encodeF64(allocator, list, DATE_TAG, n),
        .string => |s| try encodeBytes(allocator, list, STRING_TAG, s),
        .binary => |s| try encodeBytes(allocator, list, BINARY_TAG, s),
        .array => |items| {
            try list.append(allocator, ARRAY_TAG);
            for (items) |item| {
                try encodeInto(allocator, item, list);
            }
            try list.append(allocator, 0x00); // array terminator
        },
    }
}

fn encodeF64(allocator: Allocator, list: *std.ArrayList(u8), tag: u8, n: f64) !void {
    try list.append(allocator, tag);
    var buf: [8]u8 = undefined;
    writeOrderedF64(&buf, n);
    try list.appendSlice(allocator, &buf);
}

fn encodeBytes(allocator: Allocator, list: *std.ArrayList(u8), tag: u8, data: []const u8) !void {
    try list.append(allocator, tag);
    for (data) |b| {
        if (b == 0x00) {
            try list.appendSlice(allocator, &.{ 0x00, 0xFF });
        } else {
            try list.append(allocator, b);
        }
    }
    try list.append(allocator, 0x00); // field terminator
}

// Decode an encoded key back into a Key.Value. All sub-allocations (strings,
// binary, array backing) come from `allocator` — use an arena and free as a unit.
pub fn decode(allocator: Allocator, bytes: []const u8) !Value {
    var pos: usize = 0;
    const value = try decodeOne(allocator, bytes, &pos);
    return value;
}

fn decodeOne(allocator: Allocator, bytes: []const u8, pos: *usize) !Value {
    if (pos.* >= bytes.len) return error.InvalidKeyEncoding;
    const tag = bytes[pos.*];
    pos.* += 1;
    switch (tag) {
        NUMBER_TAG, DATE_TAG => {
            if (pos.* + 8 > bytes.len) return error.InvalidKeyEncoding;
            const n = readOrderedF64(bytes[pos.*..][0..8]);
            pos.* += 8;
            return if (tag == NUMBER_TAG) .{ .number = n } else .{ .date = n };
        },
        STRING_TAG => return .{ .string = try decodeBytes(allocator, bytes, pos) },
        BINARY_TAG => return .{ .binary = try decodeBytes(allocator, bytes, pos) },
        ARRAY_TAG => {
            var items: std.ArrayList(Value) = .empty;
            while (pos.* < bytes.len and bytes[pos.*] != 0x00) {
                try items.append(allocator, try decodeOne(allocator, bytes, pos));
            }
            if (pos.* >= bytes.len) return error.InvalidKeyEncoding;
            pos.* += 1; // consume array terminator
            return .{ .array = try items.toOwnedSlice(allocator) };
        },
        else => return error.InvalidKeyEncoding,
    }
}

fn decodeBytes(allocator: Allocator, bytes: []const u8, pos: *usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        if (pos.* >= bytes.len) return error.InvalidKeyEncoding;
        const b = bytes[pos.*];
        pos.* += 1;
        if (b != 0x00) {
            try out.append(allocator, b);
            continue;
        }
        // 0x00: an escaped content byte (0x00 0xFF) or the field terminator.
        if (pos.* < bytes.len and bytes[pos.*] == 0xFF) {
            pos.* += 1;
            try out.append(allocator, 0x00);
        } else {
            break; // terminator
        }
    }
    return out.toOwnedSlice(allocator);
}

// Build a Key.Value from a JS value, validating that it is a structurally valid
// IDB key. Invalid keys (booleans, null/undefined, plain objects, NaN, and
// invalid Dates) produce error.DataError.
pub fn fromJs(value: js.Value, allocator: Allocator) !Value {
    return fromJsDepth(value, allocator, 0);
}

fn fromJsDepth(value: js.Value, allocator: Allocator, depth: usize) !Value {
    if (depth > MAX_DEPTH) return error.DataError;

    if (value.isString()) |s| {
        return .{ .string = try s.toSliceWithAlloc(allocator) };
    }
    if (value.isNumber()) {
        var n = try value.toF64();
        // NaN is not a valid key; ±Infinity is (it sorts at the numeric extremes).
        if (std.math.isNan(n)) return error.DataError;
        if (n == 0) n = 0; // normalize -0 to +0
        return .{ .number = n };
    }
    if (value.isDate()) {
        // A Date coerces to its time value; an invalid Date (NaN) is not a key.
        const n = try value.toF64();
        if (std.math.isNan(n)) return error.DataError;
        return .{ .date = n };
    }
    if (value.isArrayBuffer() or value.isArrayBufferView()) {
        // toStringSmart returns the raw bytes for a confirmed binary value.
        const bytes = try value.toStringSmart();
        return .{ .binary = try allocator.dupe(u8, bytes) };
    }
    if (value.isArray()) {
        const arr = value.toArray();
        const len = arr.len();
        const items = try allocator.alloc(Value, len);
        for (0..len) |i| {
            const element = arr.get(@intCast(i)) catch return error.TryCatchRethrow;
            items[i] = try fromJsDepth(element, allocator, depth + 1);
        }
        return .{ .array = items };
    }
    return error.DataError;
}

// Build a JS value (in `local`) from a decoded Key.Value. Binary keys surface as
// ArrayBuffer, arrays as Array, matching the spec's key-to-value conversion.
pub fn toJs(value: Value, local: *const Local) !js.Value {
    switch (value) {
        .number => |n| return local.zigValueToJs(n, .{}),
        .date => |n| return local.newDate(n),
        .string => |s| return local.newString(s).toValue(),
        .binary => |s| return local.zigValueToJs(js.ArrayBuffer{ .values = s }, .{}),
        .array => |items| {
            const arr = local.newArray(@intCast(items.len));
            for (items, 0..) |item, i| {
                _ = try arr.set(@intCast(i), try toJs(item, local), .{});
            }
            return arr.toValue();
        },
    }
}

pub fn isValidKeyPath(path: []const u8) bool {
    if (path.len == 0) {
        // empty is valid
        return true;
    }

    // if not empty, must be one or more "identifiers" split by '.'
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |component| {
        if (isIdentifier(component) == false) {
            return false;
        }
    }
    return true;
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) {
        return false;
    }

    // leading 0-9 not allowed
    const first_ok = switch (s[0]) {
        'a'...'z', 'A'...'Z', '_', '$' => true,
        else => |c| c >= 0x80,
    };
    if (first_ok == false) {
        return false;
    }

    for (s[1..]) |c| {
        const ok = switch (c) {
            'a'...'z', 'A'...'Z', '_', '$', '0'...'9' => true,
            else => c >= 0x80,
        };
        if (ok == false) {
            return false;
        }
    }
    return true;
}

// Validate the spec's (DOMString or sequence<DOMString>) key path form. A
// compound path must be a non-empty list of valid, non-empty string paths.
pub fn isValidKeyPathSpec(kp: KeyPath) bool {
    switch (kp) {
        .string => |s| return isValidKeyPath(s),
        .list => |items| {
            if (items.len == 0) {
                return false;
            }
            for (items) |item| {
                if (item.len == 0 or isValidKeyPath(item) == false) {
                    return false;
                }
            }
            return true;
        },
    }
}

pub fn dupeKeyPath(arena: Allocator, kp: KeyPath) !KeyPath {
    switch (kp) {
        .string => |s| return .{ .string = try arena.dupe(u8, s) },
        .list => |items| {
            const copy = try arena.alloc([]const u8, items.len);
            for (items, 0..) |item, i| {
                copy[i] = try arena.dupe(u8, item);
            }
            return .{ .list = copy };
        },
    }
}

pub fn extractKeyPath(local: *const Local, value: js.Value, kp: KeyPath) !?js.Value {
    switch (kp) {
        .string => |s| return evaluatePath(value, s),
        .list => |items| {
            const arr = local.newArray(@intCast(items.len));
            for (items, 0..) |item, i| {
                const component = evaluatePath(value, item) orelse return null;
                _ = try arr.set(@intCast(i), component, .{});
            }
            return arr.toValue();
        },
    }
}

pub fn keyPathToJs(local: *const Local, kp: ?KeyPath) !js.Value {
    const path = kp orelse return .{ .local = local, .handle = local.isolate.initNull() };
    switch (path) {
        .string => |s| return local.newString(s).toValue(),
        .list => |items| {
            const arr = local.newArray(@intCast(items.len));
            for (items, 0..) |item, i| {
                _ = try arr.set(@intCast(i), local.newString(item).toValue(), .{});
            }
            return arr.toValue();
        },
    }
}

// Storage form of a key path: the text column value and its component count. A
// count of 0 denotes a single string path; a positive count is a compound path
// of that many ','-joined components (a valid component can't contain a ',').
// The count both disambiguates a one-element list from a string and lets decode
// allocate the exact slice.
pub const ColumnKeyPath = struct { text: []const u8, component_length: usize };

pub fn encodeKeyPathColumn(arena: Allocator, kp: KeyPath) !ColumnKeyPath {
    return switch (kp) {
        .string => |s| .{ .text = s, .component_length = 0 },
        .list => |items| .{ .text = try std.mem.join(arena, ",", items), .component_length = items.len },
    };
}

pub fn decodeKeyPathColumn(arena: Allocator, text: []const u8, component_length: usize) !KeyPath {
    if (component_length == 0) {
        return .{ .string = try arena.dupe(u8, text) };
    }
    const items = try arena.alloc([]const u8, component_length);
    var it = std.mem.splitScalar(u8, text, ',');
    for (items) |*item| {
        item.* = try arena.dupe(u8, it.next() orelse return error.InvalidKeyEncoding);
    }
    return .{ .list = items };
}

// Given a key path , "manager.id", extract that from an object
pub fn evaluatePath(value: js.Value, key_path: []const u8) ?js.Value {
    if (key_path.len == 0) {
        return value;
    }

    var current = value;
    var it = std.mem.splitScalar(u8, key_path, '.');
    while (it.next()) |component| {
        if (!current.isObject()) {
            return null;
        }
        const next = current.toObject().get(component) catch return null;
        if (next.isUndefined()) {
            return null;
        }
        current = next;
    }
    return current;
}

// Whether a generated key can be injected at `key_path` (the spec's "check that
// a key could be injected into a value"). Each existing path segment must be an
// object; a missing segment is fine since injectKey creates it. Callers check
// this before consuming a generated key so a doomed write doesn't advance the
// key generator.
pub fn canInjectKey(value: js.Value, key_path: []const u8) bool {
    const last_dot = std.mem.lastIndexOfScalar(u8, key_path, '.') orelse return value.isObject();

    var current = value;
    var it = std.mem.splitScalar(u8, key_path[0..last_dot], '.');
    while (it.next()) |component| {
        if (!current.isObject()) {
            return false;
        }
        const next = current.toObject().get(component) catch return false;
        if (next.isUndefined()) {
            // injectKey will create the rest
            return true;
        }
        current = next;
    }
    return current.isObject();
}

// Inject a key into a value at a (non-empty) key path, creating intermediate
// objects as needed. Requires canInjectKey(value, key_path).
pub fn injectKey(local: *const Local, value: js.Value, key_path: []const u8, key: js.Value) !void {
    const last_dot = std.mem.lastIndexOfScalar(u8, key_path, '.');
    const final = if (last_dot) |i| key_path[i + 1 ..] else key_path;

    var current = value.toObject();
    if (last_dot) |i| {
        var it = std.mem.splitScalar(u8, key_path[0..i], '.');
        while (it.next()) |component| {
            const next = try current.get(component);
            if (next.isUndefined()) {
                const created = local.newObject();
                _ = try current.set(component, created.toValue(), .{});
                current = created;
            } else {
                current = next.toObject();
            }
        }
    }
    _ = try current.set(final, key, .{});
}

// Convenience: validate+encode a JS value straight to its byte key.
pub fn encodeValue(allocator: Allocator, value: js.Value) ![]u8 {
    const key: Key = .{ .value = try fromJs(value, allocator) };
    return key.encode(allocator);
}

// Convenience: decode a byte key straight to a JS value.
pub fn decodeToJs(allocator: Allocator, local: *const Local, bytes: []const u8) !js.Value {
    return toJs(try decode(allocator, bytes), local);
}

// Map an f64 to 8 big-endian bytes whose unsigned ordering matches IEEE-754
// numeric ordering. For positive numbers flip only the sign bit; for negative
// numbers flip every bit. NaN is not a valid IDB key, so it is not handled.
fn writeOrderedF64(out: *[8]u8, n: f64) void {
    var bits: u64 = @bitCast(n);
    if (bits & (1 << 63) != 0) {
        bits = ~bits;
    } else {
        bits |= (1 << 63);
    }
    std.mem.writeInt(u64, out, bits, .big);
}

// Inverse of writeOrderedF64.
fn readOrderedF64(in: *const [8]u8) f64 {
    var bits = std.mem.readInt(u64, in, .big);
    if (bits & (1 << 63) != 0) {
        bits &= ~@as(u64, 1 << 63); // was positive: we set the sign bit
    } else {
        bits = ~bits; // was negative: we flipped every bit
    }
    return @bitCast(bits);
}

const testing = @import("../../../../testing.zig");

fn eql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .number => |n| n == b.number,
        .date => |n| n == b.date,
        .string => |s| std.mem.eql(u8, s, b.string),
        .binary => |s| std.mem.eql(u8, s, b.binary),
        .array => |items| blk: {
            if (items.len != b.array.len) break :blk false;
            for (items, b.array) |x, y| {
                if (!eql(x, y)) break :blk false;
            }
            break :blk true;
        },
    };
}

test "IDB - Key: number encoding round-trips ordering" {
    const cases = [_]f64{ -1e308, -100.5, -1, -0.0001, 0, 0.0001, 1, 100.5, 1e308 };
    var prev: ?[]u8 = null;
    defer if (prev) |p| testing.allocator.free(p);

    for (cases) |n| {
        const enc = try Key.number(n).encode(testing.allocator);
        if (prev) |p| {
            try testing.expect(std.mem.order(u8, p, enc) == .lt);
            testing.allocator.free(p);
        }
        prev = enc;
    }
}

test "IDB - Key: cross-type ordering number < date < string < binary < array" {
    const num = try Key.number(1e308).encode(testing.allocator);
    defer testing.allocator.free(num);
    const date = try (Key{ .value = .{ .date = -1e308 } }).encode(testing.allocator);
    defer testing.allocator.free(date);
    const str = try Key.string("zzz").encode(testing.allocator);
    defer testing.allocator.free(str);
    const bin = try Key.binary(&.{0xFF}).encode(testing.allocator);
    defer testing.allocator.free(bin);
    const arr = try Key.array(&.{.{ .number = 0 }}).encode(testing.allocator);
    defer testing.allocator.free(arr);

    try testing.expect(std.mem.order(u8, num, date) == .lt);
    try testing.expect(std.mem.order(u8, date, str) == .lt);
    try testing.expect(std.mem.order(u8, str, bin) == .lt);
    try testing.expect(std.mem.order(u8, bin, arr) == .lt);
}

test "IDB - Key: string encoding preserves byte order and handles NUL" {
    const a = try Key.string("apple").encode(testing.allocator);
    defer testing.allocator.free(a);
    const b = try Key.string("banana").encode(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expect(std.mem.order(u8, a, b) == .lt);

    // A prefix sorts before a longer string, and an embedded NUL sorts after.
    const empty = try Key.string("").encode(testing.allocator);
    defer testing.allocator.free(empty);
    const x = try Key.string("x").encode(testing.allocator);
    defer testing.allocator.free(x);
    const x_nul = try Key.string("x\x00").encode(testing.allocator);
    defer testing.allocator.free(x_nul);
    try testing.expect(std.mem.order(u8, empty, x) == .lt);
    try testing.expect(std.mem.order(u8, x, x_nul) == .lt);
}

test "IDB - Key: array ordering — shorter prefix sorts first, element order dominates" {
    const a1 = try Key.array(&.{.{ .number = 1 }}).encode(testing.allocator);
    defer testing.allocator.free(a1);
    const a12 = try Key.array(&.{ .{ .number = 1 }, .{ .number = 2 } }).encode(testing.allocator);
    defer testing.allocator.free(a12);
    const a2 = try Key.array(&.{.{ .number = 2 }}).encode(testing.allocator);
    defer testing.allocator.free(a2);

    try testing.expect(std.mem.order(u8, a1, a12) == .lt); // [1] < [1,2]
    try testing.expect(std.mem.order(u8, a12, a2) == .lt); // [1,2] < [2]
}

test "IDB - Key: encode/decode round-trip for every key type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]Value{
        .{ .number = -42.5 },
        .{ .number = 0 },
        .{ .date = 1_700_000_000_000 },
        .{ .string = "héllo\x00world" },
        .{ .binary = &.{ 0x00, 0x01, 0xFF, 0x00 } },
        .{ .array = &.{ .{ .number = 1 }, .{ .string = "a" }, .{ .array = &.{.{ .number = 2 }} } } },
    };

    for (cases) |case| {
        const enc = try (Key{ .value = case }).encode(arena);
        const dec = try Key.decode(arena, enc);
        try testing.expect(eql(case, dec));
    }
}
