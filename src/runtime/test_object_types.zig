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

pub const Other = struct {
    val: u8,

    fn init(val: u8) Other {
        return .{ .val = val };
    }

    pub fn _val(self: *const Other) u8 {
        return self.val;
    }
};

pub const OtherUnion = union(enum) {
    Other: Other,
    Bool: bool,
};

pub const MyObject = struct {
    val: bool,

    pub fn constructor(do_set: bool) MyObject {
        return .{
            .val = do_set,
        };
    }

    // pub fn named_get(_: *const MyObject, name: []const u8, has_value: *bool) ?OtherUnion {
    //     if (std.mem.eql(u8, name, "a")) {
    //         has_value.* = true;
    //         return .{ .Other = .{ .val = 4 } };
    //     }
    //     if (std.mem.eql(u8, name, "c")) {
    //         has_value.* = true;
    //         return .{ .Bool = true };
    //     }
    //     has_value.* = false;
    //     return null;
    // }

    pub fn get_val(self: *const MyObject) bool {
        return self.val;
    }

    pub fn set_val(self: *MyObject, val: bool) void {
        self.val = val;
    }
};

pub const MyAPI = struct {
    pub fn constructor() MyAPI {
        return .{};
    }

    pub fn _obj(_: *const MyAPI) !MyObject {
        return MyObject.constructor(true);
    }
};

const State = struct {
    arena: Allocator,
};

const testing = @import("testing.zig");
test "JS: object types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try testing.Runner(State, void, .{
        Other,
        MyObject,
        MyAPI,
    }).init(.{ .arena = arena.allocator() }, {});

    defer runner.deinit();

    // v8 has 5 default "own" properties

    // TODO: v8 upgrade
    // const own_base = "5";

    // try runner.testCases(&.{
    //     .{ "Object.getOwnPropertyNames(MyObject).length;", own_base },
    //     .{ "let myObj = new MyObject(true);", "undefined" },
    //     // check object property
    //     .{ "myObj.a.val()", "4" },
    //     .{ "myObj.b", "undefined" },
    //     .{ "Object.getOwnPropertyNames(myObj).length;", "0" },

    //     // check if setter (pointer) still works
    //     .{ "myObj.val", "true" },
    //     .{ "myObj.val = false", "false" },
    //     .{ "myObj.val", "false" },

    //     .{ "let myObj2 = new MyObject(false);", "undefined" },
    //     .{ "myObj2.c", "true" },
    // }, .{});

    // try runner.testCases(&.{
    //     .{ "let myAPI = new MyAPI();", "undefined" },
    //     .{ "let myObjIndirect = myAPI.obj();", "undefined" },
    //     // check object property
    //     .{ "myObjIndirect.a.val()", "4" },
    // }, .{});
}
