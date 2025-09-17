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
const json = std.json;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Testing = @This();

const main = @import("cdp.zig");
const parser = @import("../browser/netsurf.zig");

const base = @import("../testing.zig");
pub const allocator = base.allocator;
pub const expectJson = base.expectJson;
pub const expect = std.testing.expect;
pub const expectEqual = base.expectEqual;
pub const expectError = base.expectError;
pub const expectEqualSlices = base.expectEqualSlices;

pub const Document = @import("../testing.zig").Document;

const Client = struct {
    allocator: Allocator,
    send_arena: ArenaAllocator,
    sent: std.ArrayListUnmanaged(json.Value) = .{},
    serialized: std.ArrayListUnmanaged([]const u8) = .{},

    fn init(alloc: Allocator) Client {
        return .{
            .allocator = alloc,
            .send_arena = ArenaAllocator.init(alloc),
        };
    }

    pub fn sendJSON(self: *Client, message: anytype, opts: json.Stringify.Options) !void {
        var opts_copy = opts;
        opts_copy.whitespace = .indent_2;
        const serialized = try json.Stringify.valueAlloc(self.allocator, message, opts_copy);
        try self.serialized.append(self.allocator, serialized);

        const value = try json.parseFromSliceLeaky(json.Value, self.allocator, serialized, .{});
        try self.sent.append(self.allocator, value);
    }

    pub fn sendJSONRaw(self: *Client, buf: std.ArrayListUnmanaged(u8)) !void {
        const value = try json.parseFromSliceLeaky(json.Value, self.allocator, buf.items, .{});
        try self.sent.append(self.allocator, value);
    }
};

const TestCDP = main.CDPT(struct {
    pub const Client = *Testing.Client;
});

const TestContext = struct {
    client: ?Client = null,
    cdp_: ?TestCDP = null,
    arena: ArenaAllocator,

    pub fn deinit(self: *TestContext) void {
        if (self.cdp_) |*c| {
            c.deinit();
        }
        self.arena.deinit();
    }

    pub fn cdp(self: *TestContext) *TestCDP {
        if (self.cdp_ == null) {
            self.client = Client.init(self.arena.allocator());
            // Don't use the arena here. We want to detect leaks in CDP.
            // The arena is only for test-specific stuff
            self.cdp_ = TestCDP.init(base.test_app, &self.client.?) catch unreachable;
        }
        return &self.cdp_.?;
    }

    const BrowserContextOpts = struct {
        id: ?[]const u8 = null,
        target_id: ?[]const u8 = null,
        session_id: ?[]const u8 = null,
        html: ?[]const u8 = null,
    };
    pub fn loadBrowserContext(self: *TestContext, opts: BrowserContextOpts) !*main.BrowserContext(TestCDP) {
        var c = self.cdp();
        if (c.browser_context) |bc| {
            _ = c.disposeBrowserContext(bc.id);
        }

        _ = try c.createBrowserContext();
        var bc = &c.browser_context.?;

        if (opts.id) |id| {
            bc.id = id;
        }

        if (opts.target_id) |tid| {
            bc.target_id = tid;
        }

        if (opts.session_id) |sid| {
            bc.session_id = sid;
        }

        if (opts.html) |html| {
            if (bc.session_id == null) bc.session_id = "SID-X";
            const page = try bc.session.createPage();
            page.window.document = (try Document.init(html)).doc;
        }
        return bc;
    }

    pub fn processMessage(self: *TestContext, msg: anytype) !void {
        var json_message: []const u8 = undefined;
        if (@typeInfo(@TypeOf(msg)) != .pointer) {
            json_message = try std.json.Stringify.valueAlloc(self.arena.allocator(), msg, .{});
        } else {
            // assume this is a string we want to send as-is, if it isn't, we'll
            // get a compile error, so no big deal.
            json_message = msg;
        }
        return self.cdp().processMessage(json_message);
    }

    pub fn expectSentCount(self: *TestContext, expected: usize) !void {
        try expectEqual(expected, self.client.?.sent.items.len);
    }

    const ExpectResultOpts = struct {
        id: ?usize = null,
        index: ?usize = null,
        session_id: ?[]const u8 = null,
    };
    pub fn expectSentResult(self: *TestContext, expected: anytype, opts: ExpectResultOpts) !void {
        const expected_result = .{
            .id = opts.id,
            .result = if (comptime @typeInfo(@TypeOf(expected)) == .null) struct {}{} else expected,
            .sessionId = opts.session_id,
        };

        try self.expectSent(expected_result, .{ .index = opts.index });
    }

    const ExpectEventOpts = struct {
        index: ?usize = null,
        session_id: ?[]const u8 = null,
    };
    pub fn expectSentEvent(self: *TestContext, method: []const u8, params: anytype, opts: ExpectEventOpts) !void {
        const expected_event = .{
            .method = method,
            .params = if (comptime @typeInfo(@TypeOf(params)) == .null) struct {}{} else params,
            .sessionId = opts.session_id,
        };

        try self.expectSent(expected_event, .{ .index = opts.index });
    }

    const ExpectErrorOpts = struct {
        id: ?usize = null,
        index: ?usize = null,
    };
    pub fn expectSentError(self: *TestContext, code: i32, message: []const u8, opts: ExpectErrorOpts) !void {
        const expected_message = .{
            .id = opts.id,
            .@"error" = .{ .code = code, .message = message },
        };
        try self.expectSent(expected_message, .{ .index = opts.index });
    }

    const SentOpts = struct {
        index: ?usize = null,
    };
    pub fn expectSent(self: *TestContext, expected: anytype, opts: SentOpts) !void {
        const serialized = try json.Stringify.valueAlloc(self.arena.allocator(), expected, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        });

        for (self.client.?.sent.items, 0..) |sent, i| {
            if (try compareExpectedToSent(serialized, sent) == false) {
                continue;
            }

            if (opts.index) |expected_index| {
                if (expected_index != i) {
                    return error.ErrorAtWrongIndex;
                }
            }
            _ = self.client.?.sent.orderedRemove(i);
            _ = self.client.?.serialized.orderedRemove(i);
            return;
        }

        std.debug.print("Error not found. Expecting:\n{s}\n\nGot:\n", .{serialized});
        for (self.client.?.serialized.items, 0..) |sent, i| {
            std.debug.print("#{d}\n{s}\n\n", .{ i, sent });
        }
        return error.ErrorNotFound;
    }
};

pub fn context() TestContext {
    return .{
        .arena = ArenaAllocator.init(std.testing.allocator),
    };
}

// Zig makes this hard. When sendJSON is called, we're sending an anytype.
// We can't record that in an ArrayList(???), so we serialize it to JSON.
// Now, ideally, we could just take our expected structure, serialize it to
// json and check if the two are equal.
// Except serializing to JSON isn't deterministic.
// So we serialize the JSON then we deserialize to json.Value. And then we can
// compare our anytype expectation with the json.Value that we captured

fn compareExpectedToSent(expected: []const u8, actual: json.Value) !bool {
    const expected_value = try std.json.parseFromSlice(json.Value, std.testing.allocator, expected, .{});
    defer expected_value.deinit();
    return base.isEqualJson(expected_value.value, actual);
}
