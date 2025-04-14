const std = @import("std");

// TODO: use functions instead of "fake" struct once we handle function API generation
const Primitives = struct {
    pub fn constructor() Primitives {
        return .{};
    }

    // List of bytes (string)
    pub fn _checkString(_: *const Primitives, v: []u8) []u8 {
        return v;
    }

    // Integers signed

    pub fn _checkI32(_: *const Primitives, v: i32) i32 {
        return v;
    }

    pub fn _checkI64(_: *const Primitives, v: i64) i64 {
        return v;
    }

    // Integers unsigned

    pub fn _checkU32(_: *const Primitives, v: u32) u32 {
        return v;
    }

    pub fn _checkU64(_: *const Primitives, v: u64) u64 {
        return v;
    }

    // Floats

    pub fn _checkF32(_: *const Primitives, v: f32) f32 {
        return v;
    }

    pub fn _checkF64(_: *const Primitives, v: f64) f64 {
        return v;
    }

    // Bool
    pub fn _checkBool(_: *const Primitives, v: bool) bool {
        return v;
    }

    // Undefined
    // TODO: there is a bug with this function
    // void paramater does not work => avoid for now
    // pub fn _checkUndefined(_: *const Primitives, v: void) void {
    //     return v;
    // }

    // Null
    pub fn _checkNullEmpty(_: *const Primitives, v: ?u32) bool {
        return (v == null);
    }
    pub fn _checkNullNotEmpty(_: *const Primitives, v: ?u32) bool {
        return (v != null);
    }

    // Optionals
    pub fn _checkOptional(_: *const Primitives, _: ?u8, v: u8, _: ?u8, _: ?u8) u8 {
        return v;
    }
    pub fn _checkNonOptional(_: *const Primitives, v: u8) u8 {
        std.debug.print("x: {d}\n", .{v});
        return v;
    }
    pub fn _checkOptionalReturn(_: *const Primitives) ?bool {
        return true;
    }
    pub fn _checkOptionalReturnNull(_: *const Primitives) ?bool {
        return null;
    }
    pub fn _checkOptionalReturnString(_: *const Primitives) ?[]const u8 {
        return "ok";
    }
};

const testing = @import("testing.zig");
test "JS: primitive types" {
    var runner = try testing.Runner(void, void, .{Primitives}).init({}, {});
    defer runner.deinit();

    // constructor
    try runner.testCases(&.{
        .{ "let p = new Primitives();", "undefined" },
    }, .{});

    // JS <> Native translation of primitive types
    try runner.testCases(&.{
        .{ "p.checkString('ok ascii') === 'ok ascii';", "true" },
        .{ "p.checkString('ok emoji 🚀') === 'ok emoji 🚀';", "true" },
        .{ "p.checkString('ok chinese 鿍') === 'ok chinese 鿍';", "true" },

        // String (JS liberal cases)
        .{ "p.checkString(1) === '1';", "true" },
        .{ "p.checkString(null) === 'null';", "true" },
        .{ "p.checkString(undefined) === 'undefined';", "true" },

        // Integers

        // signed
        .{ "const min_i32 = -2147483648", "undefined" },
        .{ "p.checkI32(min_i32) === min_i32;", "true" },
        .{ "p.checkI32(min_i32-1) === min_i32-1;", "false" },
        .{ "try { p.checkI32(9007199254740995n) } catch(e) { e instanceof TypeError; }", "true" },

        // unsigned
        .{ "const max_u32 = 4294967295", "undefined" },
        .{ "p.checkU32(max_u32) === max_u32;", "true" },
        .{ "p.checkU32(max_u32+1) === max_u32+1;", "false" },

        // int64 (with BigInt)
        .{ "const big_int = 9007199254740995n", "undefined" },
        .{ "p.checkI64(big_int) === big_int", "true" },
        .{ "p.checkU64(big_int) === big_int;", "true" },
        .{ "p.checkI64(0) === 0;", "true" },
        .{ "p.checkI64(-1) === -1;", "true" },
        .{ "p.checkU64(0) === 0;", "true" },

        // Floats
        // use round 2 decimals for float to ensure equality
        .{ "const r = function(x) {return Math.round(x * 100) / 100};", "undefined" },
        .{ "const double = 10.02;", "undefined" },
        .{ "r(p.checkF32(double)) === double;", "true" },
        .{ "r(p.checkF64(double)) === double;", "true" },

        // Bool
        .{ "p.checkBool(true);", "true" },
        .{ "p.checkBool(false);", "false" },
        .{ "p.checkBool(0);", "false" },
        .{ "p.checkBool(1);", "true" },

        // Bool (JS liberal cases)
        .{ "p.checkBool(null);", "false" },
        .{ "p.checkBool(undefined);", "false" },

        // Undefined
        // see TODO on Primitives.checkUndefined
        // .{ "p.checkUndefined(undefined) === undefined;", "true" },

        // Null
        .{ "p.checkNullEmpty(null);", "true" },
        .{ "p.checkNullEmpty(undefined);", "true" },
        .{ "p.checkNullNotEmpty(1);", "true" },

        // Optional
        .{ "p.checkOptional(null, 3);", "3" },
        .{ "p.checkNonOptional();", "TypeError" },
        .{ "p.checkOptionalReturn() === true;", "true" },
        .{ "p.checkOptionalReturnNull() === null;", "true" },
        .{ "p.checkOptionalReturnString() === 'ok';", "true" },
    }, .{});
}
