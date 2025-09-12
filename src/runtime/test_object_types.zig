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

    pub fn named_get(_: *const MyObject, name: []const u8, has_value: *bool) ?OtherUnion {
        if (std.mem.eql(u8, name, "a")) {
            has_value.* = true;
            return .{ .Other = .{ .val = 4 } };
        }
        if (std.mem.eql(u8, name, "c")) {
            has_value.* = true;
            return .{ .Bool = true };
        }
        has_value.* = false;
        return null;
    }

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

pub const Parent = packed struct {
    parent_id: i32 = 0,

    pub fn get_parent(self: *const Parent) i32 {
        return self.parent_id;
    }
    pub fn set_parent(self: *Parent, id: i32) void {
        self.parent_id = id;
    }
};

pub const Middle = struct {
    pub const prototype = *Parent;

    middle_id: i32 = 0,
    _padding_1: u8 = 0,
    _padding_2: u8 = 1,
    _padding_3: u8 = 2,
    proto: Parent,

    pub fn constructor() Middle {
        return .{
            .middle_id = 0,
            .proto = .{ .parent_id = 0 },
        };
    }

    pub fn get_middle(self: *const Middle) i32 {
        return self.middle_id;
    }
    pub fn set_middle(self: *Middle, id: i32) void {
        self.middle_id = id;
    }
};

pub const Child = struct {
    pub const prototype = *Middle;

    child_id: i32 = 0,
    _padding_1: u8 = 0,
    proto: Middle,

    pub fn constructor() Child {
        return .{
            .child_id = 0,
            .proto = .{ .middle_id = 0, .proto = .{ .parent_id = 0 } },
        };
    }

    pub fn get_child(self: *const Child) i32 {
        return self.child_id;
    }
    pub fn set_child(self: *Child, id: i32) void {
        self.child_id = id;
    }
};

pub const MiddlePtr = packed struct {
    pub const prototype = *Parent;

    middle_id: i32 = 0,
    _padding_1: u8 = 0,
    _padding_2: u8 = 1,
    _padding_3: u8 = 2,
    proto: *Parent,

    pub fn constructor(state: State) !MiddlePtr {
        const parent = try state.arena.create(Parent);
        parent.* = .{ .parent_id = 0 };
        return .{
            .middle_id = 0,
            .proto = parent,
        };
    }

    pub fn get_middle(self: *const MiddlePtr) i32 {
        return self.middle_id;
    }
    pub fn set_middle(self: *MiddlePtr, id: i32) void {
        self.middle_id = id;
    }
};

pub const ChildPtr = packed struct {
    pub const prototype = *MiddlePtr;

    child_id: i32 = 0,
    _padding_1: u8 = 0,
    _padding_2: u8 = 1,
    proto: *MiddlePtr,

    pub fn constructor(state: State) !ChildPtr {
        const parent = try state.arena.create(Parent);
        const middle = try state.arena.create(MiddlePtr);

        parent.* = .{ .parent_id = 0 };
        middle.* = .{ .middle_id = 0, .proto = parent };
        return .{
            .child_id = 0,
            .proto = middle,
        };
    }

    pub fn get_child(self: *const ChildPtr) i32 {
        return self.child_id;
    }
    pub fn set_child(self: *ChildPtr, id: i32) void {
        self.child_id = id;
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
        Parent,
        Middle,
        Child,
        MiddlePtr,
        ChildPtr,
    }).init(.{ .arena = arena.allocator() }, {});

    defer runner.deinit();

    // v8 has 3 default "own" properties
    const own_base = "3";

    try runner.testCases(&.{
        .{ "Object.getOwnPropertyNames(MyObject).length;", own_base },
        .{ "let myObj = new MyObject(true);", "undefined" },
        // check object property
        .{ "myObj.a.val()", "4" },
        .{ "myObj.b", "undefined" },
        .{ "Object.getOwnPropertyNames(myObj).length;", "0" },

        // check if setter (pointer) still works
        .{ "myObj.val", "true" },
        .{ "myObj.val = false", "false" },
        .{ "myObj.val", "false" },

        .{ "let myObj2 = new MyObject(false);", "undefined" },
        .{ "myObj2.c", "true" },
    }, .{});

    try runner.testCases(&.{
        .{ "let myAPI = new MyAPI();", "undefined" },
        .{ "let myObjIndirect = myAPI.obj();", "undefined" },
        // check object property
        .{ "myObjIndirect.a.val()", "4" },
    }, .{});

    try runner.testCases(&.{
        .{ "let m1 = new Middle();", null },
        .{ "m1.middle = 2", null },
        .{ "m1.parent = 3", null },
        .{ "m1.middle", "2" },
        .{ "m1.parent", "3" },
    }, .{});

    try runner.testCases(&.{
        .{ "let c1 = new Child();", null },
        .{ "c1.child = 1", null },
        .{ "c1.middle = 2", null },
        .{ "c1.parent = 3", null },
        .{ "c1.child", "1" },
        .{ "c1.middle", "2" },
        .{ "c1.parent", "3" },
    }, .{});

    try runner.testCases(&.{
        .{ "let m2 = new MiddlePtr();", null },
        .{ "m2.middle = 2", null },
        .{ "m2.parent = 3", null },
        .{ "m2.middle", "2" },
        .{ "m2.parent", "3" },
    }, .{});

    try runner.testCases(&.{
        .{ "let c2 = new ChildPtr();", null },
        .{ "c2.child = 1", null },
        .{ "c2.middle = 2", null },
        .{ "c2.parent = 3", null },
        .{ "c2.child", "1" },
        .{ "c2.middle", "2" },
        .{ "c2.parent", "3" },
    }, .{});
}
