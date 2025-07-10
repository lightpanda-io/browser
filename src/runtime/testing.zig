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
const js = @import("js.zig");
const generate = @import("generate.zig");

pub const allocator = std.testing.allocator;

// Very similar to the JSRunner in src/testing.zig, but it isn't tied to the
// browser.Env or the *Page state
pub fn Runner(comptime State: type, comptime Global: type, comptime types: anytype) type {
    const AdjustedTypes = if (Global == void) generate.Tuple(.{ types, DefaultGlobal }) else types;

    return struct {
        env: *Env,
        js_context: *Env.JsContext,
        executor: Env.ExecutionWorld,

        pub const Env = js.Env(State, struct {
            pub const Interfaces = AdjustedTypes;
        });

        const Self = @This();

        pub fn init(state: State, global: Global) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.env = try Env.init(allocator, null, .{});
            errdefer self.env.deinit();

            self.executor = try self.env.newExecutionWorld();
            errdefer self.executor.deinit();

            self.js_context = try self.executor.createJsContext(
                if (Global == void) &default_global else global,
                state,
                {},
                true,
                null,
            );
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.executor.deinit();
            self.env.deinit();
            allocator.destroy(self);
        }

        const RunOpts = struct {};
        pub const Case = std.meta.Tuple(&.{ []const u8, ?[]const u8 });
        pub fn testCases(self: *Self, cases: []const Case, _: RunOpts) !void {
            for (cases, 0..) |case, i| {
                var try_catch: Env.TryCatch = undefined;
                try_catch.init(self.js_context);
                defer try_catch.deinit();

                const value = self.js_context.exec(case.@"0", null) catch |err| {
                    if (try try_catch.err(allocator)) |msg| {
                        defer allocator.free(msg);
                        if (isExpectedTypeError(case.@"1", msg)) {
                            continue;
                        }
                        std.debug.print("{s}\n\nCase: {d}\n{s}\n", .{ msg, i + 1, case.@"0" });
                    }
                    return err;
                };

                if (case.@"1") |expected| {
                    const actual = try value.toString(allocator);
                    defer allocator.free(actual);
                    if (std.mem.eql(u8, expected, actual) == false) {
                        std.debug.print("Expected:\n{s}\n\nGot:\n{s}\n\nCase: {d}\n{s}\n", .{ expected, actual, i + 1, case.@"0" });
                        return error.UnexpectedResult;
                    }
                }
            }
        }
    };
}

fn isExpectedTypeError(expected_: ?[]const u8, msg: []const u8) bool {
    const expected = expected_ orelse return false;

    if (!std.mem.eql(u8, expected, "TypeError")) {
        return false;
    }
    return std.mem.startsWith(u8, msg, "TypeError: ");
}

var default_global = DefaultGlobal{};
const DefaultGlobal = struct {};
