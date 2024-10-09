// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const server = @import("../server.zig");
const Ctx = server.Ctx;

const browser = @import("browser.zig").browser;
const target = @import("target.zig").target;
const page = @import("page.zig").page;
const log = @import("log.zig").log;
const runtime = @import("runtime.zig").runtime;
const network = @import("network.zig").network;
const emulation = @import("emulation.zig").emulation;
const fetch = @import("fetch.zig").fetch;
const performance = @import("performance.zig").performance;

pub const Error = error{
    UnknonwDomain,
    UnknownMethod,
    NoResponse,
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
    Fetch,
    Performance,
};

// The caller is responsible for calling `free` on the returned slice.
pub fn do(
    alloc: std.mem.Allocator,
    s: []const u8,
    ctx: *Ctx,
) ![]const u8 {

    // JSON scanner
    var scanner = std.json.Scanner.initCompleteInput(alloc, s);
    defer scanner.deinit();

    std.debug.assert(try scanner.next() == .object_begin);

    // handle 2 possible orders:
    // - id, method <...>
    // - method, id <...>
    var method_key = try nextString(&scanner);
    var method_token: std.json.Token = undefined;
    var id: ?u16 = null;
    // check swap order
    if (std.mem.eql(u8, method_key, "id")) {
        id = try getId(&scanner, method_key);
        method_key = try nextString(&scanner);
        method_token = try scanner.next();
    } else {
        method_token = try scanner.next();
    }
    try checkKey(method_key, "method");

    // retrieve method
    if (method_token != .string) {
        return error.WrongTokenType;
    }
    const method_name = method_token.string;
    std.log.debug("cmd: method {s}, id {any}", .{ method_name, id });

    // retrieve domain from method
    var iter = std.mem.splitScalar(u8, method_name, '.');
    const domain = std.meta.stringToEnum(Domains, iter.first()) orelse
        return error.UnknonwDomain;

    // select corresponding domain
    return switch (domain) {
        .Browser => browser(alloc, id, iter.next().?, &scanner, ctx),
        .Target => target(alloc, id, iter.next().?, &scanner, ctx),
        .Page => page(alloc, id, iter.next().?, &scanner, ctx),
        .Log => log(alloc, id, iter.next().?, &scanner, ctx),
        .Runtime => runtime(alloc, id, iter.next().?, &scanner, s, ctx),
        .Network => network(alloc, id, iter.next().?, &scanner, ctx),
        .Emulation => emulation(alloc, id, iter.next().?, &scanner, ctx),
        .Fetch => fetch(alloc, id, iter.next().?, &scanner, ctx),
        .Performance => performance(alloc, id, iter.next().?, &scanner, ctx),
    };
}

pub const State = struct {
    executionContextId: u8 = 0,
    contextID: ?[]const u8 = null,
    frameID: []const u8 = FrameID,
    url: []const u8 = URLBase,
    securityOrigin: []const u8 = URLBase,
    secureContextType: []const u8 = "Secure", // TODO: enum
    loaderID: []const u8 = LoaderID,

    page_life_cycle_events: bool = false, // TODO; Target based value
};

// Utils
// -----

fn nextString(scanner: *std.json.Scanner) ![]const u8 {
    const token = try scanner.next();
    if (token != .string) {
        return error.WrongTokenType;
    }
    return token.string;
}

pub fn dumpFile(
    alloc: std.mem.Allocator,
    id: u16,
    script: []const u8,
) !void {
    const name = try std.fmt.allocPrint(alloc, "id_{d}.js", .{id});
    defer alloc.free(name);
    const dir = try std.fs.cwd().makeOpenPath("zig-cache/tmp", .{});
    const f = try dir.createFile(name, .{});
    defer f.close();
    const nb = try f.write(script);
    std.debug.assert(nb == script.len);
    const p = try dir.realpathAlloc(alloc, name);
    defer alloc.free(p);
    std.log.debug("Script {d} saved at {s}", .{ id, p });
}

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
    id: u16,
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
        id: u16,
        result: T.?,
        sessionId: ?[]const u8,
    };
    const resp = Resp{ .id = id, .result = res, .sessionId = sessionID };

    return stringify(alloc, resp);
}

pub fn sendEvent(
    alloc: std.mem.Allocator,
    ctx: *Ctx,
    name: []const u8,
    comptime T: type,
    params: T,
    sessionID: ?[]const u8,
) !void {
    const Resp = struct {
        method: []const u8,
        params: T,
        sessionId: ?[]const u8,
    };
    const resp = Resp{ .method = name, .params = params, .sessionId = sessionID };

    const event_msg = try stringify(alloc, resp);
    defer alloc.free(event_msg);
    std.log.debug("event {s}", .{event_msg});
    try server.sendSync(ctx, event_msg);
}

fn getParams(
    alloc: std.mem.Allocator,
    comptime T: type,
    scanner: *std.json.Scanner,
    key: []const u8,
) !?T {

    // check key is "params"
    if (!std.mem.eql(u8, "params", key)) return null;

    // skip "params" if not requested
    if (T == void) {
        var finished: usize = 0;
        while (true) {
            switch (try scanner.next()) {
                .object_begin => finished += 1,
                .object_end => finished -= 1,
                else => continue,
            }
            if (finished == 0) break;
        }
        return void{};
    }

    // parse "params"
    const options = std.json.ParseOptions{
        .max_value_len = scanner.input.len,
        .allocate = .alloc_if_needed,
    };
    return try std.json.innerParse(T, alloc, scanner, options);
}

fn getId(scanner: *std.json.Scanner, key: []const u8) !?u16 {

    // check key is "id"
    if (!std.mem.eql(u8, "id", key)) return null;

    // parse "id"
    return try std.fmt.parseUnsigned(u16, (try scanner.next()).number, 10);
}

fn getSessionId(scanner: *std.json.Scanner, key: []const u8) !?[]const u8 {

    // check key is "sessionId"
    if (!std.mem.eql(u8, "sessionId", key)) return null;

    // parse "sessionId"
    return try nextString(scanner);
}

pub fn getMsg(
    alloc: std.mem.Allocator,
    comptime params_T: type,
    scanner: *std.json.Scanner,
) !struct { id: ?u16, params: ?params_T, sessionID: ?[]const u8 } {
    var id: ?u16 = null;
    var params: ?params_T = null;
    var sessionID: ?[]const u8 = null;

    var t: std.json.Token = undefined;

    while (true) {
        t = try scanner.next();
        if (t == .object_end) break;
        if (t != .string) {
            return error.WrongTokenType;
        }
        if (id == null) {
            id = try getId(scanner, t.string);
            if (id != null) continue;
        }
        if (params == null) {
            params = try getParams(alloc, params_T, scanner, t.string);
            if (params != null) continue;
        }
        if (sessionID == null) {
            sessionID = try getSessionId(scanner, t.string);
        }
    }

    // end
    std.log.debug(
        "id {any}, params {any}, sessionID: {any}, token {any}",
        .{ id, params, sessionID, t },
    );
    t = try scanner.next();
    if (t != .end_of_document) return error.CDPMsgEnd;
    return .{ .id = id, .params = params, .sessionID = sessionID };
}

// Common
// ------

// TODO: hard coded IDs
pub const BrowserSessionID = "9559320D92474062597D9875C664CAC0";
pub const ContextSessionID = "4FDC2CB760A23A220497A05C95417CF4";
pub const URLBase = "chrome://newtab/";
pub const FrameID = "90D14BBD8AED408A0467AC93100BCDBE";
pub const LoaderID = "CFC8BED824DD2FD56CF1EF33C965C79C";

pub const TimestampEvent = struct {
    timestamp: f64,
};
