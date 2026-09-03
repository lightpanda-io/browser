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
const builtin = @import("builtin");

const uuidv4 = @import("../../id.zig").uuidv4;

const BiDi = @import("BiDi.zig");

pub fn processMessage(cmd: *const BiDi.Command) !void {
    const command = std.meta.stringToEnum(enum {
        status,
        new,
        end,
        subscribe,
        unsubscribe,
    }, cmd.action) orelse return error.UnknownCommand;

    // The only two commands that work without a session; `new` is what
    // creates one.
    if (command != .status and command != .new and cmd.bidi.session_id == null) {
        return cmd.sendError("invalid session id", "no active session");
    }

    switch (command) {
        .status => return status(cmd),
        .new => return new(cmd),
        .end => return end(cmd),
        .subscribe => return subscribe(cmd),
        .unsubscribe => return unsubscribe(cmd),
    }
}

fn status(cmd: *const BiDi.Command) !void {
    // `ready` reflects whether session.new can succeed on this connection.
    if (cmd.bidi.session_id == null) {
        return cmd.sendResult(.{ .ready = true, .message = "" });
    }
    return cmd.sendResult(.{ .ready = false, .message = "session already started" });
}

fn new(cmd: *const BiDi.Command) !void {
    const bidi = cmd.bidi;
    if (bidi.session_id != null) {
        return cmd.sendError("session not created", "session already exists");
    }

    bidi.session_id = @as([36]u8, undefined);
    uuidv4(&bidi.session_id.?);

    return cmd.sendResult(.{
        .sessionId = &bidi.session_id.?,
        .capabilities = Capabilities{
            .userAgent = cmd.bidi.app.config.http_headers.user_agent,
        },
    });
}

pub const Capabilities = struct {
    acceptInsecureCerts: bool = false,
    browserName: []const u8 = "Lightpanda",
    browserVersion: []const u8 = lp.build_config.version,
    platformName: []const u8 = platform_name,
    setWindowRect: bool = false,
    userAgent: []const u8,
    proxy: struct {} = .{},
    webSocketUrl: ?[]const u8 = null, // only reported for the classic handshake

    // ugh, are you kidding me? All this so we don't emit the webSocketUrl
    // when it's null.
    pub fn jsonStringify(self: *const Capabilities, jws: anytype) !void {
        try jws.beginObject();
        inline for (std.meta.fields(Capabilities)) |field| {
            const value = @field(self, field.name);
            if (@typeInfo(field.type) == .optional) {
                if (value) |v| {
                    try jws.objectField(field.name);
                    try jws.write(v);
                }
            } else {
                try jws.objectField(field.name);
                try jws.write(value);
            }
        }
        try jws.endObject();
    }
};

fn end(cmd: *const BiDi.Command) !void {
    try cmd.sendResult(struct {}{});

    const bidi = cmd.bidi;
    const arena = try bidi.browser.arena_pool.acquire(.tiny, "bidi session end");
    bidi.conn.inbox.push(arena, .close);
}

// Subscriptions are global (per-context filtering is not supported yet).
// Event names aren't validated against a known list.
fn subscribe(cmd: *const BiDi.Command) !void {
    const p = try cmd.params(struct {
        events: []const []const u8,
    });
    if (p.events.len == 0) {
        return cmd.sendError("invalid argument", "no events");
    }

    var sub_id: [36]u8 = undefined;
    uuidv4(&sub_id);

    const bidi = cmd.bidi;
    const arena = bidi.session_arena.allocator();
    for (p.events) |event| {
        try bidi.subscriptions.append(arena, .{
            .id = sub_id,
            .event = try arena.dupe(u8, event),
        });
    }
    return cmd.sendResult(.{ .subscription = &sub_id });
}

fn unsubscribe(cmd: *const BiDi.Command) !void {
    const p = try cmd.params(struct {
        events: []const []const u8 = &.{},
        subscriptions: []const []const u8 = &.{},
    });

    const subscriptions = &cmd.bidi.subscriptions;
    var i: usize = 0;
    while (i < subscriptions.items.len) {
        const sub = subscriptions.items[i];
        if (matchesAny(p.events, sub.event) or matchesAny(p.subscriptions, &sub.id)) {
            _ = subscriptions.swapRemove(i);
        } else {
            i += 1;
        }
    }
    return cmd.sendResult(struct {}{});
}

fn matchesAny(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |candidate| {
        if (std.mem.eql(u8, candidate, needle)) {
            return true;
        }
    }
    return false;
}

const platform_name = switch (builtin.os.tag) {
    .macos, .ios => "mac",
    .windows => "windows",
    .linux => "linux",
    else => @tagName(builtin.os.tag),
};
