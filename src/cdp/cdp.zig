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
const Allocator = std.mem.Allocator;
const json = std.json;

const Loop = @import("jsruntime").Loop;
const Client = @import("../server.zig").Client;
const asUint = @import("../str/parser.zig").asUint;
const Browser = @import("../browser/browser.zig").Browser;
const Session = @import("../browser/browser.zig").Session;

const log = std.log.scoped(.cdp);

pub const URL_BASE = "chrome://newtab/";
pub const LOADER_ID = "LOADERID24DD2FD56CF1EF33C965C79C";
pub const FRAME_ID = "FRAMEIDD8AED408A0467AC93100BCDBE";
pub const BROWSER_SESSION_ID = @tagName(SessionID.BROWSERSESSIONID597D9875C664CAC0);
pub const CONTEXT_SESSION_ID = @tagName(SessionID.CONTEXTSESSIONID0497A05C95417CF4);

pub const TimestampEvent = struct {
    timestamp: f64,
};

pub const CDP = struct {
    // Used for sending message to the client and closing on error
    client: *Client,

    // The active browser
    browser: Browser,

    // The active browser session
    session: ?*Session,

    allocator: Allocator,

    // Re-used arena for processing a message. We're assuming that we're getting
    // 1 message at a time.
    message_arena: std.heap.ArenaAllocator,

    // State
    url: []const u8,
    frame_id: []const u8,
    loader_id: []const u8,
    session_id: SessionID,
    context_id: ?[]const u8,
    execution_context_id: u32,
    security_origin: []const u8,
    page_life_cycle_events: bool,
    secure_context_type: []const u8,

    pub fn init(allocator: Allocator, client: *Client, loop: *Loop) CDP {
        return .{
            .client = client,
            .browser = Browser.init(allocator, loop),
            .session = null,
            .allocator = allocator,
            .url = URL_BASE,
            .execution_context_id = 0,
            .context_id = null,
            .frame_id = FRAME_ID,
            .session_id = .CONTEXTSESSIONID0497A05C95417CF4,
            .security_origin = URL_BASE,
            .secure_context_type = "Secure", // TODO = enum
            .loader_id = LOADER_ID,
            .message_arena = std.heap.ArenaAllocator.init(allocator),
            .page_life_cycle_events = false, // TODO; Target based value
        };
    }

    pub fn deinit(self: *CDP) void {
        self.browser.deinit();
        self.message_arena.deinit();
    }

    pub fn newSession(self: *CDP) !void {
        self.session = try self.browser.newSession(self);
    }

    pub fn processMessage(self: *CDP, msg: []const u8) void {
        const arena = &self.message_arena;
        defer _ = arena.reset(.{ .retain_with_limit = 1024 * 16 });

        self.dispatch(arena.allocator(), self, msg) catch |err| {
            log.err("failed to process message: {}\n{s}", .{ err, msg });
            self.client.close(null);
            return;
        };
    }

    // Called from above, in processMessage which handles client messages
    // but can also be called internally. For example, Target.sendMessageToTarget
    // calls back into dispatch.
    pub fn dispatch(
        self: *CDP,
        arena: Allocator,
        sender: anytype,
        str: []const u8,
    ) anyerror!void {
        const input = try json.parseFromSliceLeaky(InputMessage, arena, str, .{
            .ignore_unknown_fields = true,
        });

        const domain, const action = blk: {
            const method = input.method;
            const i = std.mem.indexOfScalarPos(u8, method, 0, '.') orelse {
                return error.InvalidMethod;
            };
            break :blk .{ method[0..i], method[i + 1 ..] };
        };

        var command = Command(@TypeOf(sender)){
            .json = str,
            .cdp = self,
            .id = input.id,
            .arena = arena,
            .action = action,
            ._params = input.params,
            .session_id = input.sessionId,
            .sender = sender,
            .session = self.session orelse blk: {
                try self.newSession();
                break :blk self.session.?;
            },
        };

        switch (domain.len) {
            3 => switch (@as(u24, @bitCast(domain[0..3].*))) {
                asUint("DOM") => return @import("dom.zig").processMessage(&command),
                asUint("Log") => return @import("log.zig").processMessage(&command),
                asUint("CSS") => return @import("css.zig").processMessage(&command),
                else => {},
            },
            4 => switch (@as(u32, @bitCast(domain[0..4].*))) {
                asUint("Page") => return @import("page.zig").processMessage(&command),
                else => {},
            },
            5 => switch (@as(u40, @bitCast(domain[0..5].*))) {
                asUint("Fetch") => return @import("fetch.zig").processMessage(&command),
                else => {},
            },
            6 => switch (@as(u48, @bitCast(domain[0..6].*))) {
                asUint("Target") => return @import("target.zig").processMessage(&command),
                else => {},
            },
            7 => switch (@as(u56, @bitCast(domain[0..7].*))) {
                asUint("Browser") => return @import("browser.zig").processMessage(&command),
                asUint("Runtime") => return @import("runtime.zig").processMessage(&command),
                asUint("Network") => return @import("network.zig").processMessage(&command),
                else => {},
            },
            8 => switch (@as(u64, @bitCast(domain[0..8].*))) {
                asUint("Security") => return @import("security.zig").processMessage(&command),
                else => {},
            },
            9 => switch (@as(u72, @bitCast(domain[0..9].*))) {
                asUint("Emulation") => return @import("emulation.zig").processMessage(&command),
                asUint("Inspector") => return @import("inspector.zig").processMessage(&command),
                else => {},
            },
            11 => switch (@as(u88, @bitCast(domain[0..11].*))) {
                asUint("Performance") => return @import("performance.zig").processMessage(&command),
                else => {},
            },
            else => {},
        }
        return error.UnknownDomain;
    }

    fn sendJSON(self: *CDP, message: anytype) !void {
        return self.client.sendJSON(message, .{
            .emit_null_optional_fields = false,
        });
    }

    pub fn onInspectorResponse(ctx: *anyopaque, _: u32, msg: []const u8) void {
        if (std.log.defaultLogEnabled(.debug)) {
            // msg should be {"id":<id>,...
            std.debug.assert(std.mem.startsWith(u8, msg, "{\"id\":"));

            const id_end = std.mem.indexOfScalar(u8, msg, ',') orelse {
                log.warn("invalid inspector response message: {s}", .{msg});
                return;
            };
            const id = msg[6..id_end];
            log.debug("Res (inspector) > id {s}", .{id});
        }
        sendInspectorMessage(@alignCast(@ptrCast(ctx)), msg) catch |err| {
            log.err("Failed to send inspector response: {any}", .{err});
        };
    }

    pub fn onInspectorEvent(ctx: *anyopaque, msg: []const u8) void {
        if (std.log.defaultLogEnabled(.debug)) {
            // msg should be {"method":<method>,...
            std.debug.assert(std.mem.startsWith(u8, msg, "{\"method\":"));
            const method_end = std.mem.indexOfScalar(u8, msg, ',') orelse {
                log.warn("invalid inspector event message: {s}", .{msg});
                return;
            };
            const method = msg[10..method_end];
            log.debug("Event (inspector) > method {s}", .{method});
        }

        sendInspectorMessage(@alignCast(@ptrCast(ctx)), msg) catch |err| {
            log.err("Failed to send inspector event: {any}", .{err});
        };
    }

    // This is hacky * 2. First, we have the JSON payload by gluing our
    // session_id onto it. Second, we're much more client/websocket aware than
    // we should be.
    fn sendInspectorMessage(self: *CDP, msg: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        const field = ",\"sessionId\":\"";
        const session_id = @tagName(self.session_id);

        // + 1 for the closing quote after the session id
        // + 10 for the max websocket header

        const message_len = msg.len + session_id.len + 1 + field.len + 10;

        var buf: std.ArrayListUnmanaged(u8) = .{};
        buf.ensureTotalCapacity(arena.allocator(), message_len) catch |err| {
            log.err("Failed to expand inspector buffer: {any}", .{err});
            return;
        };

        // reserve 10 bytes for websocket header
        buf.appendSliceAssumeCapacity(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

        // -1  because we dont' want the closing brace '}'
        buf.appendSliceAssumeCapacity(msg[0 .. msg.len - 1]);
        buf.appendSliceAssumeCapacity(field);
        buf.appendSliceAssumeCapacity(session_id);
        buf.appendSliceAssumeCapacity("\"}");
        std.debug.assert(buf.items.len == message_len);

        try self.client.sendJSONRaw(arena, buf);
    }
};

// This is a generic because when we send a result we have two different
// behaviors. Normally, we're sending the result to the client. But in some cases
// we want to capture the result. So we want the command.sendResult to be
// generic.
pub fn Command(comptime Sender: type) type {
    return struct {
        // refernece to our CDP instance
        cdp: *CDP,

        // Comes directly from the input.id field
        id: ?i64,

        // A misc arena that can be used for any allocation for processing
        // the message
        arena: Allocator,

        // the browser session
        session: *Session,

        // The "action" of the message.Given a method of "LOG.enable", the
        // action is "enable"
        action: []const u8,

        // Comes directly from the input.sessionId field
        session_id: ?[]const u8,

        // Unparsed / untyped input.params.
        _params: ?InputParams,

        // The full raw json input
        json: []const u8,

        sender: Sender,

        const Self = @This();

        pub fn params(self: *const Self, comptime T: type) !?T {
            if (self._params) |p| {
                return try json.parseFromSliceLeaky(
                    T,
                    self.arena,
                    p.raw,
                    .{ .ignore_unknown_fields = true },
                );
            }
            return null;
        }

        const SendResultOpts = struct {
            include_session_id: bool = true,
        };
        pub fn sendResult(self: *Self, result: anytype, opts: SendResultOpts) !void {
            return self.sender.sendJSON(.{
                .id = self.id,
                .result = if (comptime @typeInfo(@TypeOf(result)) == .Null) struct {}{} else result,
                .sessionId = if (opts.include_session_id) self.session_id else null,
            });
        }
        const SendEventOpts = struct {
            session_id: ?[]const u8 = null,
        };

        pub fn sendEvent(self: *Self, method: []const u8, p: anytype, opts: SendEventOpts) !void {
            // Events ALWAYS go to the client. self.sender should not be used
            return self.cdp.sendJSON(.{
                .method = method,
                .params = if (comptime @typeInfo(@TypeOf(p)) == .Null) struct {}{} else p,
                .sessionId = opts.session_id,
            });
        }
    };
}

// When we parse a JSON message from the client, this is the structure
// we always expect
const InputMessage = struct {
    id: ?i64,
    method: []const u8,
    params: ?InputParams = null,
    sessionId: ?[]const u8 = null,
};

// The JSON "params" field changes based on the "method". Initially, we just
// capture the raw json object (including the opening and closing braces).
// Then, when we're processing the message, and we know what type it is, we
// can parse it (in Disaptch(T).params).
const InputParams = struct {
    raw: []const u8,

    pub fn jsonParse(
        _: Allocator,
        scanner: *json.Scanner,
        _: json.ParseOptions,
    ) !InputParams {
        const height = scanner.stackHeight();

        const start = scanner.cursor;
        if (try scanner.next() != .object_begin) {
            return error.UnexpectedToken;
        }
        try scanner.skipUntilStackHeight(height);
        const end = scanner.cursor;

        return .{ .raw = scanner.input[start..end] };
    }
};

// Utils
// -----

// pub fn dumpFile(
//     alloc: std.mem.Allocator,
//     id: u16,
//     script: []const u8,
// ) !void {
//     const name = try std.fmt.allocPrint(alloc, "id_{d}.js", .{id});
//     defer alloc.free(name);
//     var dir = try std.fs.cwd().makeOpenPath("zig-cache/tmp", .{});
//     defer dir.close();
//     const f = try dir.createFile(name, .{});
//     defer f.close();
//     const nb = try f.write(script);
//     std.debug.assert(nb == script.len);
//     const p = try dir.realpathAlloc(alloc, name);
//     defer alloc.free(p);
// }

// // caller owns the slice returned
// pub fn stringify(alloc: std.mem.Allocator, res: anytype) ![]const u8 {
//     var out = std.ArrayList(u8).init(alloc);
//     defer out.deinit();

//     // Do not emit optional null fields
//     const options: std.json.StringifyOptions = .{ .emit_null_optional_fields = false };

//     try std.json.stringify(res, options, out.writer());
//     const ret = try alloc.alloc(u8, out.items.len);
//     @memcpy(ret, out.items);
//     return ret;
// }

// Common
// ------

// TODO: hard coded IDs
pub const SessionID = enum {
    BROWSERSESSIONID597D9875C664CAC0,
    CONTEXTSESSIONID0497A05C95417CF4,

    pub fn parse(str: []const u8) !SessionID {
        return std.meta.stringToEnum(SessionID, str) orelse {
            log.err("parse sessionID: {s}", .{str});
            return error.InvalidSessionID;
        };
    }
};
