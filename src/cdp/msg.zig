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

// Parse incoming protocol message in json format.
pub const IncomingMessage = struct {
    scanner: std.json.Scanner,
    json: []const u8,

    obj_begin: bool = false,
    obj_end: bool = false,

    id: ?u16 = null,
    scan_sessionId: bool = false,
    sessionId: ?[]const u8 = null,
    method: ?[]const u8 = null,
    params_skip: bool = false,

    pub fn init(alloc: std.mem.Allocator, json: []const u8) IncomingMessage {
        return .{
            .json = json,
            .scanner = std.json.Scanner.initCompleteInput(alloc, json),
        };
    }

    pub fn deinit(self: *IncomingMessage) void {
        self.scanner.deinit();
    }

    fn scanUntil(self: *IncomingMessage, key: []const u8) !void {
        while (true) {
            switch (try self.scanner.next()) {
                .end_of_document => return error.EndOfDocument,
                .object_begin => {
                    if (self.obj_begin) return error.InvalidObjectBegin;
                    self.obj_begin = true;
                },
                .object_end => {
                    if (!self.obj_begin) return error.InvalidObjectEnd;
                    if (self.obj_end) return error.InvalidObjectEnd;
                    self.obj_end = true;
                },
                .string => |s| {
                    // is the key what we expects?
                    if (std.mem.eql(u8, s, key)) return;

                    // save other known keys
                    if (std.mem.eql(u8, s, "id")) try self.scanId();
                    if (std.mem.eql(u8, s, "sessionId")) try self.scanSessionId();
                    if (std.mem.eql(u8, s, "method")) try self.scanMethod();
                    if (std.mem.eql(u8, s, "params")) try self.scanParams();

                    // TODO should we skip unknown key?
                },
                else => return error.InvalidToken,
            }
        }
    }

    fn scanId(self: *IncomingMessage) !void {
        const t = try self.scanner.next();
        if (t != .number) return error.InvalidId;
        self.id = try std.fmt.parseUnsigned(u16, t.number, 10);
    }

    fn getId(self: *IncomingMessage) !u16 {
        if (self.id != null) return self.id.?;

        try self.scanUntil("id");
        try self.scanId();
        return self.id.?;
    }

    fn scanSessionId(self: *IncomingMessage) !void {
        switch (try self.scanner.next()) {
            // session id can be null.
            .null => return,
            .string => |s| self.sessionId = s,
            else => return error.InvalidSessionId,
        }

        self.scan_sessionId = true;
    }

    fn getSessionId(self: *IncomingMessage) !?[]const u8 {
        if (self.scan_sessionId) return self.sessionId;

        self.scanUntil("sessionId") catch |err| {
            if (err != error.EndOfDocument) return err;
            // if the document doesn't contains any session id key, we must
            // return null value.
            self.scan_sessionId = true;
            return null;
        };
        try self.scanSessionId();
        return self.sessionId;
    }

    fn scanMethod(self: *IncomingMessage) !void {
        const t = try self.scanner.next();
        if (t != .string) return error.InvalidMethod;
        self.method = t.string;
    }

    pub fn getMethod(self: *IncomingMessage) ![]const u8 {
        if (self.method != null) return self.method.?;

        try self.scanUntil("method");
        try self.scanMethod();
        return self.method.?;
    }

    // scanParams skip found parameters b/c if we encounter params *before*
    // asking for getParams, we don't know how to parse them.
    fn scanParams(self: *IncomingMessage) !void {
        const tt = try self.scanner.peekNextTokenType();
        if (tt != .object_begin) return error.InvalidParams;
        try self.scanner.skipValue();
        self.params_skip = true;
    }

    // getParams restart the JSON parsing
    fn getParams(self: *IncomingMessage, alloc: std.mem.Allocator, T: type) !T {
        if (T == void) return void{};

        if (self.params_skip) {
            // TODO if the params have been skipped, we have to retart the
            // parsing from start.
            return error.SkippedParams;
        }

        try self.scanUntil("params");

        // parse "params"
        const options = std.json.ParseOptions{
            .max_value_len = self.scanner.input.len,
            .allocate = .alloc_if_needed,
        };
        return try std.json.innerParse(T, alloc, &self.scanner, options);
    }

    pub fn getInput(self: *IncomingMessage, alloc: std.mem.Allocator, T: type) !struct { id: u16, sessionId: ?[]const u8, params: T } {
        return .{
            .params = try self.getParams(alloc, T),
            .id = try self.getId(),
            .sessionId = try self.getSessionId(),
        };
    }
};

test "read incoming message" {
    const inputs = [_][]const u8{
        \\{"id":1,"method":"foo","sessionId":"bar","params":{"bar":"baz"}}
        ,
        \\{"params":{"bar":"baz"},"id":1,"method":"foo","sessionId":"bar"}
        ,
        \\{"sessionId":"bar","params":{"bar":"baz"},"id":1,"method":"foo"}
        ,
        \\{"method":"foo","sessionId":"bar","params":{"bar":"baz"},"id":1}
        ,
    };

    for (inputs) |input| {
        var msg = IncomingMessage.init(std.testing.allocator, input);
        defer msg.deinit();

        try std.testing.expectEqual(1, try msg.getId());
        try std.testing.expectEqualSlices(u8, "foo", try msg.getMethod());
        try std.testing.expectEqualSlices(u8, "bar", (try msg.getSessionId()).?);

        const T = struct { bar: []const u8 };
        const in = msg.getInput(std.testing.allocator, T) catch |err| {
            if (err != error.SkippedParams) return err;
            // TODO remove this check when params in the beginning is handled.
            continue;
        };
        try std.testing.expectEqualSlices(u8, "baz", in.params.bar);
    }
}

test "read incoming message with null session id" {
    const inputs = [_][]const u8{
        \\{"id":1}
        ,
        \\{"params":{"bar":"baz"},"id":1,"method":"foo"}
        ,
        \\{"sessionId":null,"params":{"bar":"baz"},"id":1,"method":"foo"}
        ,
    };

    for (inputs) |input| {
        var msg = IncomingMessage.init(std.testing.allocator, input);
        defer msg.deinit();

        try std.testing.expect(try msg.getSessionId() == null);
        try std.testing.expectEqual(1, try msg.getId());
    }
}
