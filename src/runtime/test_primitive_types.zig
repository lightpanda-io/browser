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

// TODO: use functions instead of "fake" struct once we handle function API generation

const Runner = testing.Runner(void, void, .{Primitives});
const Env = Runner.Env;

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

    pub fn _echoString(_: *const Primitives, a: []const u8) []const u8 {
        return a;
    }

    pub fn _echoStringZ(_: *const Primitives, a: [:0]const u8) []const u8 {
        return a;
    }

    pub fn _int8(_: *const Primitives, arr: []i8) void {
        for (arr) |*a| {
            a.* -= @intCast(arr.len);
        }
    }

    pub fn _uint8(_: *const Primitives, arr: []u8) void {
        for (arr) |*a| {
            a.* += @intCast(arr.len);
        }
    }

    pub fn _returnEmptyUint8(_: *const Primitives) Env.TypedArray(u8) {
        return .{ .values = &.{} };
    }

    pub fn _returnUint8(_: *const Primitives) Env.TypedArray(u8) {
        return .{ .values = &.{ 10, 20, 250 } };
    }

    pub fn _returnInt8(_: *const Primitives) Env.TypedArray(i8) {
        return .{ .values = &.{ 10, -20, -120 } };
    }

    pub fn _returnUint16(_: *const Primitives) Env.TypedArray(u16) {
        return .{ .values = &.{ 10, 200, 2050 } };
    }

    pub fn _returnInt16(_: *const Primitives) Env.TypedArray(i16) {
        return .{ .values = &.{ 10, -420, 0 } };
    }

    pub fn _returnUint32(_: *const Primitives) Env.TypedArray(u32) {
        return .{ .values = &.{ 10, 2444343, 43432432 } };
    }

    pub fn _returnInt32(_: *const Primitives) Env.TypedArray(i32) {
        return .{ .values = &.{ 10, -20, -495929123 } };
    }

    pub fn _returnUint64(_: *const Primitives) Env.TypedArray(u64) {
        return .{ .values = &.{ 10, 495812375924, 0 } };
    }

    pub fn _returnInt64(_: *const Primitives) Env.TypedArray(i64) {
        return .{ .values = &.{ 10, -49283838122, -2 } };
    }

    pub fn _returnFloat32(_: *const Primitives) Env.TypedArray(f32) {
        return .{ .values = &.{ 1.1, -200.035, 0.0003 } };
    }

    pub fn _returnFloat64(_: *const Primitives) Env.TypedArray(f64) {
        return .{ .values = &.{ 8881.22284, -4928.3838122, -0.00004 } };
    }

    pub fn _int16(_: *const Primitives, arr: []i16) void {
        for (arr) |*a| {
            a.* -= @intCast(arr.len);
        }
    }

    pub fn _uint16(_: *const Primitives, arr: []u16) void {
        for (arr) |*a| {
            a.* += @intCast(arr.len);
        }
    }

    pub fn _int32(_: *const Primitives, arr: []i32) void {
        for (arr) |*a| {
            a.* -= @intCast(arr.len);
        }
    }

    pub fn _uint32(_: *const Primitives, arr: []u32) void {
        for (arr) |*a| {
            a.* += @intCast(arr.len);
        }
    }

    pub fn _int64(_: *const Primitives, arr: []i64) void {
        for (arr) |*a| {
            a.* -= @intCast(arr.len);
        }
    }

    pub fn _uint64(_: *const Primitives, arr: []u64) void {
        for (arr) |*a| {
            a.* += @intCast(arr.len);
        }
    }
};

const testing = @import("testing.zig");
test "JS: primitive types" {
    var runner = try Runner.init({}, {});
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

        // strings
        .{ "p.echoString('over 9000!');", "over 9000!" },
        .{ "p.echoStringZ('Teg');", "Teg" },
    }, .{});

    // typed arrays
    try runner.testCases(&.{
        .{ "let empty_arr = new Int8Array([]);", "undefined" },
        .{ "p.int8(empty_arr)", "undefined" },
        .{ "empty_arr;", "" },

        .{ "let arr_i8 = new Int8Array([-10, -20, -30]);", "undefined" },
        .{ "p.int8(arr_i8)", "undefined" },
        .{ "arr_i8;", "-13,-23,-33" },

        .{ "let arr_u8 = new Uint8Array([10, 20, 30]);", "undefined" },
        .{ "p.uint8(arr_u8)", "undefined" },
        .{ "arr_u8;", "13,23,33" },

        .{ "let arr_i16 = new Int16Array([-1000, -2000, -3000]);", "undefined" },
        .{ "p.int16(arr_i16)", "undefined" },
        .{ "arr_i16;", "-1003,-2003,-3003" },

        .{ "let arr_u16 = new Uint16Array([1000, 2000, 3000]);", "undefined" },
        .{ "p.uint16(arr_u16)", "undefined" },
        .{ "arr_u16;", "1003,2003,3003" },

        .{ "let arr_i32 = new Int32Array([-1000000, -2000000, -3000000]);", "undefined" },
        .{ "p.int32(arr_i32)", "undefined" },
        .{ "arr_i32;", "-1000003,-2000003,-3000003" },

        .{ "let arr_u32 = new Uint32Array([1000000, 2000000, 3000000]);", "undefined" },
        .{ "p.uint32(arr_u32)", "undefined" },
        .{ "arr_u32;", "1000003,2000003,3000003" },

        .{ "let arr_i64 = new BigInt64Array([-1000000000n, -2000000000n, -3000000000n]);", "undefined" },
        .{ "p.int64(arr_i64)", "undefined" },
        .{ "arr_i64;", "-1000000003,-2000000003,-3000000003" },

        .{ "let arr_u64 = new BigUint64Array([1000000000n, 2000000000n, 3000000000n]);", "undefined" },
        .{ "p.uint64(arr_u64)", "undefined" },
        .{ "arr_u64;", "1000000003,2000000003,3000000003" },

        .{ "try { p.int8(arr_u8) } catch(e) { e instanceof TypeError; }", "true" },
        .{ "try { p.intu8(arr_i8) } catch(e) { e instanceof TypeError; }", "true" },
        .{ "try { p.intu8(arr_u32) } catch(e) { e instanceof TypeError; }", "true" },

        .{ "try { p.int16(arr_u8) } catch(e) { e instanceof TypeError; }", "true" },
        .{ "try { p.intu16(arr_i16) } catch(e) { e instanceof TypeError; }", "true" },
        .{ "try { p.int16(arr_i64) } catch(e) { e instanceof TypeError; }", "true" },

        .{ "try { p.int32(arr_u32) } catch(e) { e instanceof TypeError; }", "true" },
        .{ "try { p.intu32(arr_i32) } catch(e) { e instanceof TypeError; }", "true" },
        .{ "try { p.intu32(arr_u32) } catch(e) { e instanceof TypeError; }", "true" },

        .{ "try { p.int64(arr_u64) } catch(e) { e instanceof TypeError; }", "true" },
        .{ "try { p.intu64(arr_i64) } catch(e) { e instanceof TypeError; }", "true" },
        .{ "try { p.intu64(arr_u32) } catch(e) { e instanceof TypeError; }", "true" },

        .{ "p.returnEmptyUint8()", "" },
        .{ "p.returnUint8()", "10,20,250" },
        .{ "p.returnInt8()", "10,-20,-120" },
        .{ "p.returnUint16()", "10,200,2050" },
        .{ "p.returnInt16()", "10,-420,0" },
        .{ "p.returnUint32()", "10,2444343,43432432" },
        .{ "p.returnInt32()", "10,-20,-495929123" },
        .{ "p.returnUint64()", "10,495812375924,0" },
        .{ "p.returnInt64()", "10,-49283838122,-2" },
        .{ "p.returnFloat32()", "1.100000023841858,-200.03500366210938,0.0003000000142492354" },
        .{ "p.returnFloat64()", "8881.22284,-4928.3838122,-0.00004" },
    }, .{});

    try runner.testCases(&.{
        .{ "'foo\\\\:bar'", "foo\\:bar" },
    }, .{});
}
