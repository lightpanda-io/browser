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
const IncomingMessage = @import("msg.zig").IncomingMessage;

const log_cdp = std.log.scoped(.cdp);

pub const Error = error{
    UnknonwDomain,
    UnknownMethod,
    NoResponse,
    RequestWithoutID,
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

    // incoming message parser
    var msg = IncomingMessage.init(alloc, s);
    defer msg.deinit();

    const method = try msg.getMethod();

    // retrieve domain from method
    var iter = std.mem.splitScalar(u8, method, '.');
    const domain = std.meta.stringToEnum(Domains, iter.first()) orelse
        return error.UnknonwDomain;

    // select corresponding domain
    const action = iter.next() orelse return error.BadMethod;
    return switch (domain) {
        .Browser => browser(alloc, &msg, action, ctx),
        .Target => target(alloc, &msg, action, ctx),
        .Page => page(alloc, &msg, action, ctx),
        .Log => log(alloc, &msg, action, ctx),
        .Runtime => runtime(alloc, &msg, action, ctx),
        .Network => network(alloc, &msg, action, ctx),
        .Emulation => emulation(alloc, &msg, action, ctx),
        .Fetch => fetch(alloc, &msg, action, ctx),
        .Performance => performance(alloc, &msg, action, ctx),
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

pub fn dumpFile(
    alloc: std.mem.Allocator,
    id: u16,
    script: []const u8,
) !void {
    const name = try std.fmt.allocPrint(alloc, "id_{d}.js", .{id});
    defer alloc.free(name);
    var dir = try std.fs.cwd().makeOpenPath("zig-cache/tmp", .{});
    defer dir.close();
    const f = try dir.createFile(name, .{});
    defer f.close();
    const nb = try f.write(script);
    std.debug.assert(nb == script.len);
    const p = try dir.realpathAlloc(alloc, name);
    defer alloc.free(p);
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
    log_cdp.debug(
        "Res > id {d}, sessionID {?s}, result {any}",
        .{ id, sessionID, res },
    );
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
    log_cdp.debug("Event > method {s}, sessionID {?s}", .{ name, sessionID });
    const Resp = struct {
        method: []const u8,
        params: T,
        sessionId: ?[]const u8,
    };
    const resp = Resp{ .method = name, .params = params, .sessionId = sessionID };

    const event_msg = try stringify(alloc, resp);
    defer alloc.free(event_msg);
    try server.sendSync(ctx, event_msg);
}

// Common
// ------

// TODO: hard coded IDs
pub const BrowserSessionID = "BROWSERSESSIONID597D9875C664CAC0";
pub const ContextSessionID = "CONTEXTSESSIONID0497A05C95417CF4";
pub const URLBase = "chrome://newtab/";
pub const LoaderID = "LOADERID24DD2FD56CF1EF33C965C79C";
pub const FrameID = "FRAMEIDD8AED408A0467AC93100BCDBE";

pub const TimestampEvent = struct {
    timestamp: f64,
};
