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

const ws = @import("websocket");
const cdp = @import("cdp/cdp.zig");
const jsruntime = @import("jsruntime");
const Browser = @import("browser/browser.zig").Browser;

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.server);

// cdp works on a Ctx struct
pub const Ctx = Client;

pub const Client = struct {
    browser: *Browser,
    conn: *ws.Conn,
    loop: *jsruntime.Loop,
    allocator: Allocator,

    // used when gluing the session id to the inspector message
    scrap: std.ArrayListUnmanaged(u8),

    // mutated by cdp directly
    state: cdp.State,

    pub fn init(_: ws.Handshake, conn: *ws.Conn, context: anytype) !Client {
        const loop = context.loop;
        const allocator = context.allocator;

        const browser = try allocator.create(Browser);
        errdefer allocator.destroy(browser);

        try Browser.init(browser, allocator, loop, context.vm);
        errdefer browser.deinit();

        return .{
            .loop = loop,
            .conn = conn,
            .scrap = .{},
            .state = .{},
            .browser = browser,
            .allocator = allocator,
        };
    }

    pub fn afterInit(self: *Client) !void {
        try self.setupInspector();
    }

    pub fn close(self: *Client) void {
        self.browser.deinit();
    }

    fn setupInspector(self: *Client) !void {
        try self.browser.session.initInspector(self, inspectorResponse, inspectorEvent);
    }

    pub fn clientMessage(self: *Client, cmd: []const u8) !void {
        const res = cdp.do(self.allocator, cmd, self) catch |err| {
            if (err == error.DisposeBrowserContext) {
                std.log.scoped(.cdp).debug("end cmd, restarting a new session...", .{});
                try self.browser.newSession(self.allocator, self.loop);
                try self.setupInspector();
                return;
            }
            log.err("CDP error: {}\nFor message: {s}", .{err, cmd});
            return err;
        };

        if (res.len == 0) {
            if (self.state.close) {
                try self.conn.close(.{});
            }
            return;
        }

        return self.conn.write(res);
    }

    // called by cdp
    pub fn send(self: *Client, data: []const u8) !void {
        return self.conn.write(data);
    }

    // called by cdp
    pub fn sendInspector(self: *Client, msg: []const u8) !void {
        const env = self.browser.session.env;
        if (env.getInspector()) |inspector| {
            inspector.send(env, msg);
            return;
        }
        return error.InspectNotSet;
    }

    pub fn inspectorResponse(ctx: *anyopaque, _: u32, msg: []const u8) void {
        if (std.log.defaultLogEnabled(.debug)) {
            // msg should be {"id":<id>,...
            std.debug.assert(std.mem.startsWith(u8, msg, "{\"id\":"));

            const id_end = std.mem.indexOfScalar(u8, msg, ',') orelse {
                log.warn("invalid inspector response message: {s}", .{msg});
                return;
            };

            const id = msg[6..id_end];
            std.log.scoped(.cdp).debug("Res (inspector) > id {s}", .{id});
        }
        sendInspectorMessage(@alignCast(@ptrCast(ctx)), msg);
    }

    pub fn inspectorEvent(ctx: *anyopaque, msg: []const u8) void {
        if (std.log.defaultLogEnabled(.debug)) {
            // msg should be {"method":<method>,...
            std.debug.assert(std.mem.startsWith(u8, msg, "{\"method\":"));
            const method_end = std.mem.indexOfScalar(u8, msg, ',') orelse {
                log.warn("invalid inspector event message: {s}", .{msg});
                return;
            };
            const method = msg[10..method_end];
            std.log.scoped(.cdp).debug("Event (inspector) > method {s}", .{method});
        }

        sendInspectorMessage(@alignCast(@ptrCast(ctx)), msg);
    }

    fn sendInspectorMessage(self: *Client, msg: []const u8) void {
        var scrap = &self.scrap;
        scrap.clearRetainingCapacity();

        const field = ",\"sessionId\":";
        const sessionID = @tagName(self.state.sessionID);

        // + 2 for the quotes around the session
        const message_len = msg.len + sessionID.len + 2 + field.len;

        scrap.ensureTotalCapacity(self.allocator, message_len) catch |err| {
            log.err("Failed to expand inspector buffer: {}", .{err});
            @panic("OOM");
        };

        // -1  because we dont' want the closing brace '}'
        scrap.appendSliceAssumeCapacity(msg[0..msg.len - 1]);
        scrap.appendSliceAssumeCapacity(field);
        scrap.appendAssumeCapacity('"');
        scrap.appendSliceAssumeCapacity(sessionID);
        scrap.appendSliceAssumeCapacity("\"}");
        std.debug.assert(scrap.items.len == message_len);

        self.conn.write(scrap.items) catch |err| {
            log.debug("Failed to write inspector message to client: {}", .{err});
            self.conn.close(.{}) catch {};
        };
    }
};
