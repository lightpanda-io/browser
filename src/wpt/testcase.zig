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
const testing = std.testing;

pub const Case = struct {
    pass: bool,
    name: []const u8,

    message: ?[]const u8,

    fn init(alloc: std.mem.Allocator, name: []const u8, status: []const u8, message: []const u8) !Case {
        var case = Case{
            .pass = std.mem.eql(u8, "Pass", status),
            .name = try alloc.dupe(u8, name),
            .message = null,
        };

        if (message.len > 0) {
            case.message = try alloc.dupe(u8, message);
        }

        return case;
    }

    fn deinit(self: Case, alloc: std.mem.Allocator) void {
        alloc.free(self.name);

        if (self.message) |msg| {
            alloc.free(msg);
        }
    }

    pub fn fmtStatus(self: Case) []const u8 {
        if (self.pass) {
            return "Pass";
        }
        return "Fail";
    }

    pub fn fmtMessage(self: Case) []const u8 {
        if (self.message) |v| {
            return v;
        }
        return "";
    }
};

pub const Suite = struct {
    alloc: std.mem.Allocator,
    pass: bool,
    name: []const u8,
    message: ?[]const u8,
    cases: ?[]Case,

    // caller owns the wpt.Suite.
    // owner must call deinit().
    pub fn init(alloc: std.mem.Allocator, name: []const u8, pass: bool, res: []const u8) !Suite {
        var suite = Suite{
            .alloc = alloc,
            .pass = false,
            .name = try alloc.dupe(u8, name),
            .message = null,
            .cases = null,
        };

        // handle JS error.
        if (!pass) {
            suite.message = try alloc.dupe(u8, res);
            return suite;
        }

        // no JS error, let's try to parse the result.
        suite.pass = true;

        // special case: the result contains only "Pass" message
        if (std.mem.eql(u8, "Pass", res)) {
            return suite;
        }

        var cases = std.ArrayList(Case).init(alloc);
        defer cases.deinit();

        var lines = std.mem.splitScalar(u8, res, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) {
                break;
            }
            var fields = std.mem.splitScalar(u8, line, '|');
            var ff: [3][]const u8 = .{ "", "", "" };
            var i: u8 = 0;
            while (fields.next()) |field| {
                if (i >= 3) {
                    suite.pass = false;
                    suite.message = try alloc.dupe(u8, res);
                    return suite;
                }

                ff[i] = field;
                i += 1;
            }

            // invalid output format
            if (i != 2 and i != 3) {
                suite.pass = false;
                suite.message = try alloc.dupe(u8, res);
                return suite;
            }

            const case = try Case.init(alloc, ff[0], ff[1], ff[2]);
            if (!case.pass) {
                suite.pass = false;
            }

            try cases.append(case);
        }

        if (cases.items.len == 0) {
            // no test case, create a failed one.
            suite.pass = false;
            try cases.append(.{
                .pass = false,
                .name = "no test case",
                .message = "no test case",
            });
        }

        suite.cases = try cases.toOwnedSlice();

        return suite;
    }

    pub fn deinit(self: Suite) void {
        self.alloc.free(self.name);

        if (self.message) |res| {
            self.alloc.free(res);
        }

        if (self.cases) |cases| {
            for (cases) |case| {
                case.deinit(self.alloc);
            }
            self.alloc.free(cases);
        }
    }

    pub fn fmtMessage(self: Suite) []const u8 {
        if (self.message) |v| {
            return v;
        }
        return "";
    }
};

test "success test case" {
    const alloc = testing.allocator;

    const Res = struct {
        pass: bool,
        result: []const u8,
    };

    const res = Res{
        .pass = true,
        .result =
        \\Empty string as a name for Document.getElementsByTagName|Pass
        \\Empty string as a name for Element.getElementsByTagName|Pass
        \\
        ,
    };

    const suite = Suite.init(alloc, "foo", res.pass, res.result) catch unreachable; // TODO
    defer suite.deinit();

    try testing.expect(suite.pass == true);
    try testing.expect(suite.cases != null);
    try testing.expect(suite.cases.?.len == 2);
    try testing.expect(suite.cases.?[0].pass == true);
    try testing.expect(suite.cases.?[1].pass == true);
}

test "failed test case" {
    const alloc = testing.allocator;

    const Res = struct {
        pass: bool,
        result: []const u8,
    };

    const res = Res{
        .pass = true,
        .result =
        \\Empty string as a name for Document.getElementsByTagName|Pass
        \\Empty string as a name for Element.getElementsByTagName|Fail|div.getElementsByTagName is not a function
        \\
        ,
    };

    const suite = Suite.init(alloc, "foo", res.pass, res.result) catch unreachable; // TODO
    defer suite.deinit();

    try testing.expect(suite.pass == false);
    try testing.expect(suite.cases != null);
    try testing.expect(suite.cases.?.len == 2);
    try testing.expect(suite.cases.?[0].pass == true);
    try testing.expect(suite.cases.?[1].pass == false);
}

test "invalid result" {
    const alloc = testing.allocator;

    const Res = struct {
        pass: bool,
        result: []const u8,
    };

    const res = Res{
        .pass = true,
        .result =
        \\this is|an|invalid|result
        ,
    };

    const suite = Suite.init(alloc, "foo", res.pass, res.result) catch unreachable; // TODO
    defer suite.deinit();

    try testing.expect(suite.pass == false);
    try testing.expect(suite.message != null);
    try testing.expect(std.mem.eql(u8, res.result, suite.message.?));
    try testing.expect(suite.cases == null);

    const res2 = Res{
        .pass = true,
        .result =
        \\this is an invalid result.
        ,
    };

    const suite2 = Suite.init(alloc, "foo", res2.pass, res2.result) catch unreachable; // TODO
    defer suite2.deinit();

    try testing.expect(suite2.pass == false);
    try testing.expect(suite2.message != null);
    try testing.expect(std.mem.eql(u8, res2.result, suite2.message.?));
    try testing.expect(suite2.cases == null);
}
