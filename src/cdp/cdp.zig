const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.CmdContext;
const SendFn = server.SendFn;
const browser = @import("browser.zig").browser;
const target = @import("target.zig").target;

const Domains = enum {
    Browser,
    Target,
};

// The caller is responsible for calling `free` on the returned slice.
pub fn do(
    alloc: std.mem.Allocator,
    s: []const u8,
    ctx: *Ctx,
    comptime sendFn: SendFn,
) ![]const u8 {
    var scanner = std.json.Scanner.initCompleteInput(alloc, s);
    defer scanner.deinit();

    std.debug.assert(try scanner.next() == .object_begin);

    try checkKey("id", (try scanner.next()).string);
    const id = try std.fmt.parseUnsigned(u64, (try scanner.next()).number, 10);

    try checkKey("method", (try scanner.next()).string);
    const method = (try scanner.next()).string;

    std.log.debug("cmd: id {any}, method {s}\n", .{ id, method });

    var iter = std.mem.splitScalar(u8, method, '.');
    const domain = std.meta.stringToEnum(Domains, iter.first()) orelse
        return error.UnknonwDomain;

    return switch (domain) {
        .Browser => browser(alloc, id, iter.next().?, &scanner, ctx, sendFn),
        .Target => target(alloc, id, iter.next().?, &scanner, ctx, sendFn),
    };
}

// Utils
// -----

fn checkKey(key: []const u8, token: []const u8) !void {
    if (!std.mem.eql(u8, key, token)) return error.WrongToken;
}

const resultNull = "{{\"id\": {d}, \"result\": {{}}}}";

pub fn result(
    alloc: std.mem.Allocator,
    id: u64,
    comptime T: ?type,
    res: anytype,
) ![]const u8 {
    if (T == null) return try std.fmt.allocPrint(alloc, resultNull, .{id});

    const Resp = struct {
        id: u64,
        result: T.?,
    };
    const resp = Resp{ .id = id, .result = res };

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try std.json.stringify(resp, .{}, out.writer());
    const ret = try alloc.alloc(u8, out.items.len);
    @memcpy(ret, out.items);
    return ret;
}

pub fn getParams(
    alloc: std.mem.Allocator,
    comptime T: type,
    scanner: *std.json.Scanner,
) !T {
    try checkKey("params", (try scanner.next()).string);
    const options = std.json.ParseOptions{
        .max_value_len = scanner.input.len,
        .allocate = .alloc_if_needed,
    };
    return std.json.innerParse(T, alloc, scanner, options);
}
