const std = @import("std");

const json = std.json;
const Allocator = std.mem.Allocator;

const Testing = @This();

const cdp = @import("cdp.zig");
const parser = @import("netsurf");

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

const Browser = struct {
    session: ?Session = null,

    pub fn init(_: Allocator, loop: anytype) Browser {
        _ = loop;
        return .{};
    }

    pub fn deinit(_: *const Browser) void {}

    pub fn newSession(self: *Browser, ctx: anytype) !*Session {
        _ = ctx;

        self.session = .{};
        return &self.session.?;
    }
};

const Session = struct {
    page: ?Page = null,

    pub fn currentPage(self: *Session) ?*Page {
        return &(self.page orelse return null);
    }

    pub fn createPage(self: *Session) !*Page {
        self.page = .{};
        return &self.page.?;
    }

    pub fn callInspector(self: *Session, msg: []const u8) void {
        _ = self;
        _ = msg;
    }
};

const Page = struct {
    doc: ?*parser.Document = null,

    pub fn navigate(self: *Page, url: []const u8, aux_data: []const u8) !void {
        _ = self;
        _ = url;
        _ = aux_data;
    }

    pub fn start(self: *Page, aux_data: []const u8) !void {
        _ = self;
        _ = aux_data;
    }

    pub fn end(self: *Page) void {
        _ = self;
    }
};

const Client = struct {
    allocator: Allocator,
    sent: std.ArrayListUnmanaged([]const u8) = .{},

    fn init(allocator: Allocator) Client {
        return .{
            .allocator = allocator,
        };
    }

    pub fn sendJSON(self: *Client, message: anytype, opts: json.StringifyOptions) !void {
        const serialized = try json.stringifyAlloc(self.allocator, message, opts);
        try self.sent.append(self.allocator, serialized);
    }
};

const TestCDP = cdp.CDPT(struct {
    pub const Browser = Testing.Browser;
    pub const Session = Testing.Session;
    pub const Client = Testing.Client;
});

const TestContext = struct {
    client: ?Client = null,
    cdp_: ?TestCDP = null,
    arena: std.heap.ArenaAllocator,

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
            self.cdp_ = TestCDP.init(std.testing.allocator, &self.client.?, "dummy-loop");
        }
        return &self.cdp_.?;
    }

    pub fn processMessage(self: *TestContext, msg: anytype) !void {
        var json_message: []const u8 = undefined;
        if (@typeInfo(@TypeOf(msg)) != .Pointer) {
            json_message = try std.json.stringifyAlloc(self.arena.allocator(), msg, .{});
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
            .result = expected,
            .sessionId = opts.session_id,
        };

        const serialized = try json.stringifyAlloc(self.arena.allocator(), expected_result, .{
            .emit_null_optional_fields = false,
        });

        for (self.client.?.sent.items, 0..) |sent, i| {
            if (std.mem.eql(u8, sent, serialized) == false) {
                continue;
            }
            if (opts.index) |expected_index| {
                if (expected_index != i) {
                    return error.MessageAtWrongIndex;
                }
                return;
            }
        }
        std.debug.print("Message not found. Expecting:\n{s}\n\nGot:\n", .{serialized});
        for (self.client.?.sent.items, 0..) |sent, i| {
            std.debug.print("#{d}\n{s}\n\n", .{ i, sent });
        }
        return error.MessageNotFound;
    }
};

pub fn context() TestContext {
    return .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
}
