const std = @import("std");

const json = std.json;
const Allocator = std.mem.Allocator;

const Testing = @This();

const main = @import("cdp.zig");
const parser = @import("netsurf");

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

const Browser = struct {
    session: ?*Session = null,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, loop: anytype) Browser {
        _ = loop;
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Browser) void {
        self.arena.deinit();
    }

    pub fn newSession(self: *Browser, ctx: anytype) !*Session {
        _ = ctx;
        if (self.session != null) {
            return error.MockBrowserSessionAlreadyExists;
        }

        const allocator = self.arena.allocator();
        self.session = try allocator.create(Session);
        self.session.?.* = .{
            .page = null,
            .allocator = allocator,
        };
        return self.session.?;
    }

    pub fn hasSession(self: *const Browser, session_id: []const u8) bool {
        const session = self.session orelse return false;
        return std.mem.eql(u8, session.id, session_id);
    }
};

const Session = struct {
    page: ?Page = null,
    allocator: Allocator,

    pub fn currentPage(self: *Session) ?*Page {
        return &(self.page orelse return null);
    }

    pub fn createPage(self: *Session) !*Page {
        if (self.page != null) {
            return error.MockBrowserPageAlreadyExists;
        }
        self.page = .{
            .session = self,
            .allocator = self.allocator,
        };
        return &self.page.?;
    }

    pub fn callInspector(self: *Session, msg: []const u8) void {
        _ = self;
        _ = msg;
    }
};

const Page = struct {
    session: *Session,
    allocator: Allocator,
    aux_data: []const u8 = "",
    doc: ?*parser.Document = null,

    pub fn navigate(self: *Page, url: []const u8, aux_data: []const u8) !void {
        _ = self;
        _ = url;
        _ = aux_data;
    }

    pub fn start(self: *Page, aux_data: []const u8) !void {
        self.aux_data = try self.allocator.dupe(u8, aux_data);
    }

    pub fn end(self: *Page) void {
        self.session.page = null;
    }
};

const Client = struct {
    allocator: Allocator,
    sent: std.ArrayListUnmanaged(json.Value) = .{},
    serialized: std.ArrayListUnmanaged([]const u8) = .{},

    fn init(allocator: Allocator) Client {
        return .{
            .allocator = allocator,
        };
    }

    pub fn sendJSON(self: *Client, message: anytype, opts: json.StringifyOptions) !void {
        var opts_copy = opts;
        opts_copy.whitespace = .indent_2;
        const serialized = try json.stringifyAlloc(self.allocator, message, opts_copy);
        try self.serialized.append(self.allocator, serialized);

        const value = try json.parseFromSliceLeaky(json.Value, self.allocator, serialized, .{});
        try self.sent.append(self.allocator, value);
    }
};

const TestCDP = main.CDPT(struct {
    pub const Loop = void;
    pub const Browser = Testing.Browser;
    pub const Session = Testing.Session;
    pub const Client = *Testing.Client;
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
            self.cdp_ = TestCDP.init(std.testing.allocator, &self.client.?, {});
        }
        return &self.cdp_.?;
    }

    const BrowserContextOpts = struct {
        id: ?[]const u8 = null,
        session_id: ?[]const u8 = null,
    };
    pub fn loadBrowserContext(self: *TestContext, opts: BrowserContextOpts) !*main.BrowserContext(TestCDP) {
        var c = self.cdp();
        if (c.browser_context) |*bc| {
            bc.deinit();
            c.browser_context = null;
        }

        _ = try c.createBrowserContext();
        var bc = &c.browser_context.?;

        if (opts.id) |id| {
            bc.id = id;
        }

        if (opts.session_id) |sid| {
            bc.session_id = sid;
        }
        return bc;
    }

    pub fn processMessage(self: *TestContext, msg: anytype) !void {
        var json_message: []const u8 = undefined;
        if (@typeInfo(@TypeOf(msg)) != .Pointer) {
            json_message = try json.stringifyAlloc(self.arena.allocator(), msg, .{});
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
            .result = if (comptime @typeInfo(@TypeOf(expected)) == .Null) struct {}{} else expected,
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
            .params = if (comptime @typeInfo(@TypeOf(params)) == .Null) struct {}{} else params,
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
            .code = code,
            .message = message,
        };
        try self.expectSent(expected_message, .{ .index = opts.index });
    }

    const SentOpts = struct {
        index: ?usize = null,
    };
    pub fn expectSent(self: *TestContext, expected: anytype, opts: SentOpts) !void {
        const serialized = try json.stringifyAlloc(self.arena.allocator(), expected, .{
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
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
}

// Zig makes this hard. When sendJSON is called, we're sending an anytype.
// We can't record that in an ArrayList(???), so we serialize it to JSON.
// Now, ideally, we could just take our expected structure, serialize it to
// json and check if the two are equal.
// Except serializing to JSON isn't deterministic.
// So we serialize the JSON then we deserialize to json.Value. And then we can
// compare our anytype expection with the json.Value that we captured

fn compareExpectedToSent(expected: []const u8, actual: json.Value) !bool {
    const expected_value = try std.json.parseFromSlice(json.Value, std.testing.allocator, expected, .{});
    defer expected_value.deinit();
    return compareJsonValues(expected_value.value, actual);
}

fn compareJsonValues(a: std.json.Value, b: std.json.Value) bool {
    if (!std.mem.eql(u8, @tagName(a), @tagName(b))) {
        return false;
    }

    switch (a) {
        .null => return true,
        .bool => return a.bool == b.bool,
        .integer => return a.integer == b.integer,
        .float => return a.float == b.float,
        .number_string => return std.mem.eql(u8, a.number_string, b.number_string),
        .string => return std.mem.eql(u8, a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            if (a_len != b_len) {
                return false;
            }
            for (a.array.items, b.array.items) |a_item, b_item| {
                if (compareJsonValues(a_item, b_item) == false) {
                    return false;
                }
            }
            return true;
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    if (compareJsonValues(entry.value_ptr.*, b_item) == false) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        },
    }
}

// fn compareAnyToJsonValue(expected: anytype, actual: json.Value) bool {
//     switch (@typeInfo(@TypeOf(expected))) {
//         .Optional => {
//             if (expected) |e| {
//                 return compareAnyToJsonValue(e, actual);
//             }
//             return actual == .null;
//         },
//         .Int, .ComptimeInt => {
//             if (actual != .integer) {
//                 return false;
//             }
//             return expected == actual.integer;
//         },
//         .Float, .ComptimeFloat => {
//             if (actual != .float) {
//                 return false;
//             }
//             return expected == actual.float;
//         },
//         .Bool => {
//             if (actual != .bool) {
//                 return false;
//             }
//             return expected == actual.bool;
//         },
//        .Pointer => |ptr| switch (ptr.size) {
//             .One => switch (@typeInfo(ptr.child)) {
//                 .Struct => return compareAnyToJsonValue(expected.*, actual),
//                 .Array => |arr| if (arr.child == u8) {
//                     if (actual != .string) {
//                         return false;
//                     }
//                     return std.mem.eql(u8, expected, actual.string);
//                 },
//                 else => {},
//             },
//             .Slice => switch (ptr.child) {
//                 u8 => {
//                     if (actual != .string) {
//                         return false;
//                     }
//                     return std.mem.eql(u8, expected, actual.string);
//                 },
//                 else => {},
//             },
//             else => {},
//         },
//         .Struct => |s| {
//             if (s.is_tuple) {
//                 // how an array might look in an anytype
//                 if (actual != .array) {
//                     return false;
//                 }
//                 if (s.fields.len != actual.array.items.len) {
//                     return false;
//                 }

//                 inline for (s.fields, 0..) |f, i| {
//                     const e = @field(expected, f.name);
//                     if (compareAnyToJsonValue(e, actual.array.items[i]) == false) {
//                         return false;
//                     }
//                 }
//                 return true;
//             }

//             if (s.fields.len == 0) {
//                 return (actual == .array and actual.array.items.len == 0);
//             }

//             if (actual != .object) {
//                 return false;
//             }
//             inline for (s.fields) |f| {
//                 const e = @field(expected, f.name);
//                 if (actual.object.get(f.name)) |a| {
//                     if (compareAnyToJsonValue(e, a) == false) {
//                         return false;
//                     }
//                 } else if (@typeInfo(f.type) != .Optional or e != null) {
//                     // We don't JSON serialize nulls. So if we're expecting
//                     // a null, that should show up as a missing field.
//                     return false;
//                 }
//             }
//             return true;
//         },
//         else => {},
//     }
//     @compileError("Can't compare " ++ @typeName(@TypeOf(expected)));
// }
