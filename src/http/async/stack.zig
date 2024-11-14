const std = @import("std");

pub fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Fn = *const T;

        next: ?*Self = null,
        func: Fn,

        pub fn init(alloc: std.mem.Allocator, comptime func: Fn) !*Self {
            const next = try alloc.create(Self);
            next.* = .{ .func = func };
            return next;
        }

        pub fn push(self: *Self, alloc: std.mem.Allocator, comptime func: Fn) !void {
            if (self.next) |next| {
                return next.push(alloc, func);
            }
            self.next = try Self.init(alloc, func);
        }

        pub fn pop(self: *Self, alloc: std.mem.Allocator, prev: ?*Self) Fn {
            if (self.next) |next| {
                return next.pop(alloc, self);
            }
            defer {
                if (prev) |p| {
                    self.deinit(alloc, p);
                }
            }
            return self.func;
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator, prev: ?*Self) void {
            if (self.next) |next| {
                // recursivly deinit
                next.deinit(alloc, self);
            }
            if (prev) |p| {
                p.next = null;
            }
            alloc.destroy(self);
        }
    };
}

fn first() u8 {
    return 1;
}

fn second() u8 {
    return 2;
}

test "stack" {
    const alloc = std.testing.allocator;
    const TestStack = Stack(fn () u8);

    var stack = TestStack{ .func = first };
    try stack.push(alloc, second);

    const a = stack.pop(alloc, null);
    try std.testing.expect(a() == 2);

    const b = stack.pop(alloc, null);
    try std.testing.expect(b() == 1);
}

fn first_op(arg: ?*anyopaque) u8 {
    const val = @as(*u8, @ptrCast(arg));
    return val.* + @as(u8, 1);
}

fn second_op(arg: ?*anyopaque) u8 {
    const val = @as(*u8, @ptrCast(arg));
    return val.* + @as(u8, 2);
}

test "opaque stack" {
    const alloc = std.testing.allocator;
    const TestStack = Stack(fn (?*anyopaque) u8);

    var stack = TestStack{ .func = first_op };
    try stack.push(alloc, second_op);

    const a = stack.pop(alloc, null);
    var x: u8 = 5;
    try std.testing.expect(a(@as(*anyopaque, @ptrCast(&x))) == 2 + x);

    const b = stack.pop(alloc, null);
    var y: u8 = 3;
    try std.testing.expect(b(@as(*anyopaque, @ptrCast(&y))) == 1 + y);
}
