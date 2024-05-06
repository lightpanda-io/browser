const std = @import("std");

const Reader = @import("../str/parser.zig").Reader;

// Values is a map with string key of string values.
pub const Values = struct {
    alloc: std.mem.Allocator,
    map: std.StringArrayHashMapUnmanaged(List),

    const List = std.ArrayListUnmanaged([]const u8);

    pub fn init(alloc: std.mem.Allocator) Values {
        return .{
            .alloc = alloc,
            .map = .{},
        };
    }

    pub fn deinit(self: *Values) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |v| self.alloc.free(v);
            entry.value_ptr.deinit(self.alloc);
            self.alloc.free(entry.key_ptr.*);
        }
        self.map.deinit(self.alloc);
    }

    // add the key value couple to the values.
    // the key and the value are duplicated.
    pub fn append(self: *Values, k: []const u8, v: []const u8) !void {
        const vv = try self.alloc.dupe(u8, v);

        if (self.map.getPtr(k)) |list| {
            return try list.append(self.alloc, vv);
        }

        const kk = try self.alloc.dupe(u8, k);
        var list = List{};
        try list.append(self.alloc, vv);
        try self.map.put(self.alloc, kk, list);
    }

    pub fn get(self: *Values, k: []const u8) [][]const u8 {
        if (self.map.get(k)) |list| {
            return list.items;
        }

        return &[_][]const u8{};
    }

    pub fn first(self: *Values, k: []const u8) []const u8 {
        if (self.map.getPtr(k)) |list| {
            if (list.items.len == 0) return "";
            return list.items[0];
        }

        return "";
    }

    pub fn delete(self: *Values, k: []const u8) void {
        if (self.map.getPtr(k)) |list| {
            list.deinit(self.alloc);
            _ = self.map.fetchSwapRemove(k);
        }
    }

    pub fn deleteValue(self: *Values, k: []const u8, v: []const u8) void {
        const list = self.map.getPtr(k) orelse return;

        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, v, list.items[i])) {
                _ = list.swapRemove(i);
                return;
            }
            i += 1;
        }
    }

    pub fn count(self: *Values) usize {
        return self.map.count();
    }
};

// Parse the given query.
pub fn parseQuery(alloc: std.mem.Allocator, s: []const u8) !Values {
    var values = Values.init(alloc);
    errdefer values.deinit();

    const ln = s.len;
    if (ln == 0) return values;

    var r = Reader{ .s = s };
    while (true) {
        const param = r.until('&');
        if (param.len == 0) break;

        var rr = Reader{ .s = param };
        const k = rr.until('=');
        if (k.len == 0) continue;

        _ = rr.skip();
        const v = rr.tail();

        // TODO decode k and v

        try values.append(k, v);

        if (!r.skip()) break;
    }

    return values;
}

test "parse empty query" {
    var values = try parseQuery(std.testing.allocator, "");
    defer values.deinit();

    try std.testing.expect(values.count() == 0);
}

test "parse empty query &" {
    var values = try parseQuery(std.testing.allocator, "&");
    defer values.deinit();

    try std.testing.expect(values.count() == 0);
}

test "parse query" {
    var values = try parseQuery(std.testing.allocator, "a=b&b=c");
    defer values.deinit();

    try std.testing.expect(values.count() == 2);
    try std.testing.expect(values.get("a").len == 1);
    try std.testing.expect(std.mem.eql(u8, values.get("a")[0], "b"));
    try std.testing.expect(std.mem.eql(u8, values.first("a"), "b"));

    try std.testing.expect(values.get("b").len == 1);
    try std.testing.expect(std.mem.eql(u8, values.get("b")[0], "c"));
    try std.testing.expect(std.mem.eql(u8, values.first("b"), "c"));
}

test "parse query no value" {
    var values = try parseQuery(std.testing.allocator, "a");
    defer values.deinit();

    try std.testing.expect(values.count() == 1);
    try std.testing.expect(std.mem.eql(u8, values.first("a"), ""));
}

test "parse query dup" {
    var values = try parseQuery(std.testing.allocator, "a=b&a=c");
    defer values.deinit();

    try std.testing.expect(values.count() == 1);
    try std.testing.expect(std.mem.eql(u8, values.first("a"), "b"));
    try std.testing.expect(values.get("a").len == 2);
}
