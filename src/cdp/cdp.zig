const std = @import("std");

const server = @import("../server.zig");
const Ctx = server.Cmd;

const browser = @import("browser.zig").browser;
const target = @import("target.zig").target;
const page = @import("page.zig").page;
const log = @import("log.zig").log;
const runtime = @import("runtime.zig").runtime;
const network = @import("network.zig").network;
const emulation = @import("emulation.zig").emulation;

pub const Error = error{
    UnknonwDomain,
    UnknownMethod,
};

pub fn isCdpError(err: anyerror) ?Error {
    // see https://github.com/ziglang/zig/issues/2473
    const errors = @typeInfo(Error).ErrorSet.?;
    inline for (errors) |e| {
        if (std.mem.eql(u8, e.name, @errorName(err))) {
            return @errorCast(err);
        }
    }
    return null;
}

const Domains = enum {
    Browser,
    Target,
    Page,
    Log,
    Runtime,
    Network,
    Emulation,
};

// The caller is responsible for calling `free` on the returned slice.
pub fn do(
    alloc: std.mem.Allocator,
    s: []const u8,
    ctx: *Ctx,
) ![]const u8 {
    var scanner = std.json.Scanner.initCompleteInput(alloc, s);
    defer scanner.deinit();

    std.debug.assert(try scanner.next() == .object_begin);

    try checkKey("id", (try scanner.next()).string);
    const id = try std.fmt.parseUnsigned(u64, (try scanner.next()).number, 10);

    try checkKey("method", (try scanner.next()).string);
    const method = (try scanner.next()).string;

    std.log.debug("cmd: id {any}, method {s}", .{ id, method });

    var iter = std.mem.splitScalar(u8, method, '.');
    const domain = std.meta.stringToEnum(Domains, iter.first()) orelse
        return error.UnknonwDomain;

    return switch (domain) {
        .Browser => browser(alloc, id, iter.next().?, &scanner, ctx),
        .Target => target(alloc, id, iter.next().?, &scanner, ctx),
        .Page => page(alloc, id, iter.next().?, &scanner, ctx),
        .Log => log(alloc, id, iter.next().?, &scanner, ctx),
        .Runtime => runtime(alloc, id, iter.next().?, &scanner, ctx),
        .Network => network(alloc, id, iter.next().?, &scanner, ctx),
        .Emulation => emulation(alloc, id, iter.next().?, &scanner, ctx),
    };
}

// Utils
// -----

fn checkKey(key: []const u8, token: []const u8) !void {
    if (!std.mem.eql(u8, key, token)) return error.WrongToken;
}

// caller owns the slice returned
pub fn stringify(alloc: std.mem.Allocator, res: anytype) ![]const u8 {
    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    // Do not emit optional null fields
    const options: std.json.StringifyOptions = .{ .emit_null_optional_fields = false };

    try std.json.stringify(res, options, out.writer());
    const ret = try alloc.alloc(u8, out.items.len);
    @memcpy(ret, out.items);
    return ret;
}

const resultNull = "{{\"id\": {d}, \"result\": {{}}}}";
const resultNullSession = "{{\"id\": {d}, \"result\": {{}}, \"sessionId\": \"{s}\"}}";

// caller owns the slice returned
pub fn result(
    alloc: std.mem.Allocator,
    id: u64,
    comptime T: ?type,
    res: anytype,
    sessionID: ?[]const u8,
) ![]const u8 {
    if (T == null) {
        // No need to stringify a custom JSON msg, just use string templates
        if (sessionID) |sID| {
            return try std.fmt.allocPrint(alloc, resultNullSession, .{ id, sID });
        }
        return try std.fmt.allocPrint(alloc, resultNull, .{id});
    }

    const Resp = struct {
        id: u64,
        result: T.?,
        sessionId: ?[]const u8,
    };
    const resp = Resp{ .id = id, .result = res, .sessionId = sessionID };

    return stringify(alloc, resp);
}

pub fn getParams(
    alloc: std.mem.Allocator,
    comptime T: type,
    scanner: *std.json.Scanner,
) !?T {

    // if next token is the end of the object, there is no "params"
    const t = try scanner.next();
    if (t == .object_end) return null;

    // if next token is not "params" there is no "params"
    if (!std.mem.eql(u8, "params", t.string)) return null;

    // parse "params"
    const options = std.json.ParseOptions{
        .max_value_len = scanner.input.len,
        .allocate = .alloc_if_needed,
    };
    const params = try std.json.innerParse(T, alloc, scanner, options);
    return params;
}

pub fn getSessionID(scanner: *std.json.Scanner) !?[]const u8 {

    // if next token is the end of the object, there is no "sessionId"
    const t = try scanner.next();
    if (t == .object_end) return null;

    var n = t.string;

    // if next token is "params" ignore them
    // NOTE: will panic if it's not an empty "params" object
    // TODO: maybe we should return a custom error here
    if (std.mem.eql(u8, n, "params")) {
        // ignore empty params
        _ = (try scanner.next()).object_begin;
        _ = (try scanner.next()).object_end;
        n = (try scanner.next()).string;
    }

    // if next token is not "sessionId" there is no "sessionId"
    if (!std.mem.eql(u8, n, "sessionId")) return null;

    // parse "sessionId"
    return (try scanner.next()).string;
}

// Common
// ------

pub const SessionID = "9559320D92474062597D9875C664CAC0";
