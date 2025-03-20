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

const App = @import("../app.zig").App;
const asUint = @import("../str/parser.zig").asUint;
const Incrementing = @import("../id.zig").Incrementing;

const log = std.log.scoped(.cdp);

pub const URL_BASE = "chrome://newtab/";
pub const LOADER_ID = "LOADERID24DD2FD56CF1EF33C965C79C";

pub const TimestampEvent = struct {
    timestamp: f64,
};

pub const CDP = CDPT(struct {
    const Client = *@import("../server.zig").Client;
    const Browser = @import("../browser/browser.zig").Browser;
    const Session = @import("../browser/browser.zig").Session;
});

const SessionIdGen = Incrementing(u32, "SID");
const TargetIdGen = Incrementing(u32, "TID");
const BrowserContextIdGen = Incrementing(u32, "BID");

// Generic so that we can inject mocks into it.
pub fn CDPT(comptime TypeProvider: type) type {
    return struct {
        // Used for sending message to the client and closing on error
        client: TypeProvider.Client,

        allocator: Allocator,

        // The active browser
        browser: Browser,

        // when true, any target creation must be attached.
        target_auto_attach: bool = false,

        target_id_gen: TargetIdGen = .{},
        session_id_gen: SessionIdGen = .{},
        browser_context_id_gen: BrowserContextIdGen = .{},

        browser_context: ?*BrowserContext(Self),

        browser_context_pool: std.heap.MemoryPool(BrowserContext(Self)),

        // Re-used arena for processing a message. We're assuming that we're getting
        // 1 message at a time.
        message_arena: std.heap.ArenaAllocator,

        const Self = @This();
        pub const Browser = TypeProvider.Browser;
        pub const Session = TypeProvider.Session;

        pub fn init(app: *App, client: TypeProvider.Client) Self {
            const allocator = app.allocator;
            return .{
                .client = client,
                .allocator = allocator,
                .browser_context = null,
                .browser = Browser.init(app),
                .message_arena = std.heap.ArenaAllocator.init(allocator),
                .browser_context_pool = std.heap.MemoryPool(BrowserContext(Self)).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.browser_context) |bc| {
                bc.deinit();
            }
            self.browser.deinit();
            self.message_arena.deinit();
            self.browser_context_pool.deinit();
        }

        pub fn handleMessage(self: *Self, msg: []const u8) bool {
            // if there's an error, it's already been logged
            self.processMessage(msg) catch return false;
            return true;
        }

        pub fn processMessage(self: *Self, msg: []const u8) !void {
            const arena = &self.message_arena;
            defer _ = arena.reset(.{ .retain_with_limit = 1024 * 16 });
            return self.dispatch(arena.allocator(), self, msg);
        }

        // Called from above, in processMessage which handles client messages
        // but can also be called internally. For example, Target.sendMessageToTarget
        // calls back into dispatch to capture the response.
        pub fn dispatch(self: *Self, arena: Allocator, sender: anytype, str: []const u8) !void {
            const input = json.parseFromSliceLeaky(InputMessage, arena, str, .{
                .ignore_unknown_fields = true,
            }) catch return error.InvalidJSON;

            var command = Command(Self, @TypeOf(sender)){
                .input = .{
                    .json = str,
                    .id = input.id,
                    .action = "",
                    .params = input.params,
                    .session_id = input.sessionId,
                },
                .cdp = self,
                .arena = arena,
                .sender = sender,
                .browser_context = if (self.browser_context) |bc| bc else null,
            };

            // See dispatchStartupCommand for more info on this.
            var is_startup = false;
            if (input.sessionId) |input_session_id| {
                if (std.mem.eql(u8, input_session_id, "STARTUP")) {
                    is_startup = true;
                } else if (self.isValidSessionId(input_session_id) == false) {
                    return command.sendError(-32001, "Unknown sessionId");
                }
            }

            if (is_startup) {
                dispatchStartupCommand(&command) catch |err| {
                    command.sendError(-31999, @errorName(err)) catch {};
                    return err;
                };
            } else {
                dispatchCommand(&command, input.method) catch |err| {
                    command.sendError(-31998, @errorName(err)) catch {};
                    return err;
                };
            }
        }

        // A CDP session isn't 100% fully driven by the driver. There's are
        // independent actions that the browser is expected to take. For example
        // Puppeteer expects the browser to startup a tab and thus have existing
        // targets.
        // To this end, we create a [very] dummy BrowserContext, Target and
        // Session. There isn't actually a BrowserContext, just a special id.
        // When messages are received with the "STARTUP" sessionId, we do
        // "special" handling - the bare minimum we need to do until the driver
        // switches to a real BrowserContext.
        // (I can imagine this logic will become driver-specific)
        fn dispatchStartupCommand(command: anytype) !void {
            return command.sendResult(null, .{});
        }

        fn dispatchCommand(command: anytype, method: []const u8) !void {
            const domain = blk: {
                const i = std.mem.indexOfScalarPos(u8, method, 0, '.') orelse {
                    return error.InvalidMethod;
                };
                command.input.action = method[i + 1 ..];
                break :blk method[0..i];
            };

            switch (domain.len) {
                3 => switch (@as(u24, @bitCast(domain[0..3].*))) {
                    asUint("DOM") => return @import("dom.zig").processMessage(command),
                    asUint("Log") => return @import("log.zig").processMessage(command),
                    asUint("CSS") => return @import("css.zig").processMessage(command),
                    else => {},
                },
                4 => switch (@as(u32, @bitCast(domain[0..4].*))) {
                    asUint("Page") => return @import("page.zig").processMessage(command),
                    else => {},
                },
                5 => switch (@as(u40, @bitCast(domain[0..5].*))) {
                    asUint("Fetch") => return @import("fetch.zig").processMessage(command),
                    else => {},
                },
                6 => switch (@as(u48, @bitCast(domain[0..6].*))) {
                    asUint("Target") => return @import("target.zig").processMessage(command),
                    else => {},
                },
                7 => switch (@as(u56, @bitCast(domain[0..7].*))) {
                    asUint("Browser") => return @import("browser.zig").processMessage(command),
                    asUint("Runtime") => return @import("runtime.zig").processMessage(command),
                    asUint("Network") => return @import("network.zig").processMessage(command),
                    else => {},
                },
                8 => switch (@as(u64, @bitCast(domain[0..8].*))) {
                    asUint("Security") => return @import("security.zig").processMessage(command),
                    else => {},
                },
                9 => switch (@as(u72, @bitCast(domain[0..9].*))) {
                    asUint("Emulation") => return @import("emulation.zig").processMessage(command),
                    asUint("Inspector") => return @import("inspector.zig").processMessage(command),
                    else => {},
                },
                11 => switch (@as(u88, @bitCast(domain[0..11].*))) {
                    asUint("Performance") => return @import("performance.zig").processMessage(command),
                    else => {},
                },
                else => {},
            }

            return error.UnknownDomain;
        }

        fn isValidSessionId(self: *const Self, input_session_id: []const u8) bool {
            const browser_context = self.browser_context orelse return false;
            const session_id = browser_context.session_id orelse return false;
            return std.mem.eql(u8, session_id, input_session_id);
        }

        pub fn createBrowserContext(self: *Self) ![]const u8 {
            if (self.browser_context != null) {
                return error.AlreadyExists;
            }
            const browser_context_id = self.browser_context_id_gen.next();

            const browser_context = try self.browser_context_pool.create();
            errdefer self.browser_context_pool.destroy(browser_context);

            try BrowserContext(Self).init(browser_context, browser_context_id, self);
            self.browser_context = browser_context;
            return browser_context_id;
        }

        pub fn disposeBrowserContext(self: *Self, browser_context_id: []const u8) bool {
            const bc = self.browser_context orelse return false;
            if (std.mem.eql(u8, bc.id, browser_context_id) == false) {
                return false;
            }
            bc.deinit();
            self.browser_context_pool.destroy(bc);
            self.browser_context = null;
            return true;
        }

        fn sendJSON(self: *Self, message: anytype) !void {
            return self.client.sendJSON(message, .{
                .emit_null_optional_fields = false,
            });
        }
    };
}

pub fn BrowserContext(comptime CDP_T: type) type {
    const dom = @import("dom.zig");

    return struct {
        id: []const u8,
        cdp: *CDP_T,

        // Represents the browser session. There is no equivalent in CDP. For
        // all intents and purpose, from CDP's point of view our Browser and
        // our Session more or less maps to a BrowserContext. THIS HAS ZERO
        // RELATION TO SESSION_ID
        session: *CDP_T.Session,

        // Maps to our Page. (There are other types of targets, but we only
        // deal with "pages" for now). Since we only allow 1 open page at a
        // time, we only have 1 target_id.
        target_id: ?[]const u8,

        // The CDP session_id. After the target/page is created, the client
        // "attaches" to it (either explicitly or automatically). We return a
        // "sessionId" which identifies this link. `sessionId` is the how
        // the CDP client informs us what it's trying to manipulate. Because we
        // only support 1 BrowserContext at a time, and 1 page at a time, this
        // is all pretty straightforward, but it still needs to be enforced, i.e.
        // if we get a request with a sessionId that doesn't match the current one
        // we should reject it.
        session_id: ?[]const u8,

        // State
        url: []const u8,
        loader_id: []const u8,
        security_origin: []const u8,
        page_life_cycle_events: bool,
        secure_context_type: []const u8,
        node_list: dom.NodeList,
        node_search_list: dom.NodeSearchList,

        const Self = @This();

        fn init(self: *Self, id: []const u8, cdp: *CDP_T) !void {
            self.* = .{
                .id = id,
                .cdp = cdp,
                .target_id = null,
                .session_id = null,
                .url = URL_BASE,
                .security_origin = URL_BASE,
                .secure_context_type = "Secure", // TODO = enum
                .loader_id = LOADER_ID,
                .session = try cdp.browser.newSession(self),
                .page_life_cycle_events = false, // TODO; Target based value
                .node_list = dom.NodeList.init(cdp.allocator),
                .node_search_list = dom.NodeSearchList.init(cdp.allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.node_list.deinit();
            for (self.node_search_list.items) |*s| {
                s.deinit();
            }
            self.node_search_list.deinit();
        }

        pub fn reset(self: *Self) void {
            self.node_list.reset();

            // deinit all node searches.
            for (self.node_search_list.items) |*s| {
                s.deinit();
            }
            self.node_search_list.clearAndFree();
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

        // This is hacky x 2. First, we create the JSON payload by gluing our
        // session_id onto it. Second, we're much more client/websocket aware than
        // we should be.
        fn sendInspectorMessage(self: *Self, msg: []const u8) !void {
            const session_id = self.session_id orelse {
                // We no longer have an active session. What should we do
                // in this case?
                return;
            };

            const cdp = self.cdp;
            var arena = std.heap.ArenaAllocator.init(cdp.allocator);
            errdefer arena.deinit();

            const field = ",\"sessionId\":\"";

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

            try cdp.client.sendJSONRaw(arena, buf);
        }
    };
}

// This is a generic because when we send a result we have two different
// behaviors. Normally, we're sending the result to the client. But in some cases
// we want to capture the result. So we want the command.sendResult to be
// generic.
pub fn Command(comptime CDP_T: type, comptime Sender: type) type {
    return struct {
        // A misc arena that can be used for any allocation for processing
        // the message
        arena: Allocator,

        // reference to our CDP instance
        cdp: *CDP_T,

        // The browser context this command targets
        browser_context: ?*BrowserContext(CDP_T),

        // The command input (the id, optional session_id, params, ...)
        input: Input,

        // In most cases, Sender is going to be cdp itself. We'll call
        // sender.sendJSON() and CDP will send it to the client. But some
        // comamnds are dispatched internally, in which cases the Sender will
        // be code to capture the data that we were "sending".
        sender: Sender,

        const Self = @This();

        pub fn params(self: *const Self, comptime T: type) !?T {
            if (self.input.params) |p| {
                return try json.parseFromSliceLeaky(
                    T,
                    self.arena,
                    p.raw,
                    .{ .ignore_unknown_fields = true },
                );
            }
            return null;
        }

        pub fn createBrowserContext(self: *Self) !*BrowserContext(CDP_T) {
            _ = try self.cdp.createBrowserContext();
            self.browser_context = self.cdp.browser_context.?;
            return self.browser_context.?;
        }

        const SendResultOpts = struct {
            include_session_id: bool = true,
        };
        pub fn sendResult(self: *Self, result: anytype, opts: SendResultOpts) !void {
            return self.sender.sendJSON(.{
                .id = self.input.id,
                .result = if (comptime @typeInfo(@TypeOf(result)) == .null) struct {}{} else result,
                .sessionId = if (opts.include_session_id) self.input.session_id else null,
            });
        }

        const SendEventOpts = struct {
            session_id: ?[]const u8 = null,
        };
        pub fn sendEvent(self: *Self, method: []const u8, p: anytype, opts: SendEventOpts) !void {
            // Events ALWAYS go to the client. self.sender should not be used
            return self.cdp.sendJSON(.{
                .method = method,
                .params = if (comptime @typeInfo(@TypeOf(p)) == .null) struct {}{} else p,
                .sessionId = opts.session_id,
            });
        }

        pub fn sendError(self: *Self, code: i32, message: []const u8) !void {
            return self.sender.sendJSON(.{
                .id = self.input.id,
                .code = code,
                .message = message,
            });
        }

        const Input = struct {
            // When we reply to a message, we echo back the message id
            id: ?i64,

            // The "action" of the message.Given a method of "LOG.enable", the
            // action is "enable"
            action: []const u8,

            // See notes in BrowserContext about session_id
            session_id: ?[]const u8,

            // Unparsed / untyped input.params.
            params: ?InputParams,

            // The full raw json input
            json: []const u8,
        };
    };
}

// When we parse a JSON message from the client, this is the structure
// we always expect
const InputMessage = struct {
    id: ?i64 = null,
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

const testing = @import("testing.zig");
test "cdp: invalid json" {
    var ctx = testing.context();
    defer ctx.deinit();

    try testing.expectError(error.InvalidJSON, ctx.processMessage("invalid"));

    // method is required
    try testing.expectError(error.InvalidJSON, ctx.processMessage(.{}));

    try testing.expectError(error.InvalidMethod, ctx.processMessage(.{
        .method = "Target",
    }));
    try ctx.expectSentError(-31998, "InvalidMethod", .{});

    try testing.expectError(error.UnknownDomain, ctx.processMessage(.{
        .method = "Unknown.domain",
    }));

    try testing.expectError(error.UnknownMethod, ctx.processMessage(.{
        .method = "Target.over9000",
    }));
}

test "cdp: invalid sessionId" {
    var ctx = testing.context();
    defer ctx.deinit();

    {
        // we have no browser context
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "nope" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }

    {
        // we have a brower context but no session_id
        _ = try ctx.loadBrowserContext(.{});
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "BC-Has-No-SessionId" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }

    {
        // we have a brower context with a different session_id
        _ = try ctx.loadBrowserContext(.{ .session_id = "SESS-2" });
        try ctx.processMessage(.{ .method = "Hi", .sessionId = "SESS-1" });
        try ctx.expectSentError(-32001, "Unknown sessionId", .{});
    }
}

test "cdp: STARTUP sessionId" {
    var ctx = testing.context();
    defer ctx.deinit();

    {
        // we have no browser context
        try ctx.processMessage(.{ .id = 2, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 2, .index = 0, .session_id = "STARTUP" });
    }

    {
        // we have a brower context but no session_id
        _ = try ctx.loadBrowserContext(.{});
        try ctx.processMessage(.{ .id = 3, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 3, .index = 0, .session_id = "STARTUP" });
    }

    {
        // we have a brower context with a different session_id
        _ = try ctx.loadBrowserContext(.{ .session_id = "SESS-2" });
        try ctx.processMessage(.{ .id = 4, .method = "Hi", .sessionId = "STARTUP" });
        try ctx.expectSentResult(null, .{ .id = 4, .index = 0, .session_id = "STARTUP" });
    }
}
