const std = @import("std");
const js = @import("js.zig");
const generate = @import("generate.zig");

pub const allocator = std.testing.allocator;

// Very similar to the JSRunner in src/testing.zig, but it isn't tied to the
// browser.Env or the browser.SessionState
pub fn Runner(comptime State: type, comptime Global: type, comptime types: anytype) type {
    const AdjustedTypes = if (Global == void) generate.Tuple(.{ types, DefaultGlobal }) else types;
    const Env = js.Env(State, AdjustedTypes{});

    return struct {
        env: *Env,
        executor: *Env.Executor,

        const Self = @This();

        pub fn init(state: State, global: Global) !*Self {
            const runner = try allocator.create(Self);
            errdefer allocator.destroy(runner);

            runner.env = try Env.init(allocator, .{});
            errdefer runner.env.deinit();

            const G = if (Global == void) DefaultGlobal else Global;

            runner.executor = try runner.env.startExecutor(G, state, runner);
            errdefer runner.env.stopExecutor(runner.executor);

            try runner.executor.startScope(if (Global == void) &default_global else global);
            return runner;
        }

        pub fn deinit(self: *Self) void {
            self.executor.endScope();
            self.env.stopExecutor(self.executor);
            self.env.deinit();
            allocator.destroy(self);
        }

        const RunOpts = struct {};
        pub const Case = std.meta.Tuple(&.{ []const u8, []const u8 });
        pub fn testCases(self: *Self, cases: []const Case, _: RunOpts) !void {
            for (cases, 0..) |case, i| {
                var try_catch: Env.TryCatch = undefined;
                try_catch.init(self.executor);
                defer try_catch.deinit();

                const value = self.executor.exec(case.@"0", null) catch |err| {
                    if (try try_catch.err(allocator)) |msg| {
                        defer allocator.free(msg);
                        if (isExpectedTypeError(case.@"1", msg)) {
                            continue;
                        }
                        std.debug.print("{s}\n\nCase: {d}\n{s}\n", .{ msg, i + 1, case.@"0" });
                    }
                    return err;
                };

                const actual = try value.toString(allocator);
                defer allocator.free(actual);
                if (std.mem.eql(u8, case.@"1", actual) == false) {
                    std.debug.print("Expected:\n{s}\n\nGot:\n{s}\n\nCase: {d}\n{s}\n", .{ case.@"1", actual, i + 1, case.@"0" });
                    return error.UnexpectedResult;
                }
            }
        }

        pub fn fetchModuleSource(ctx: *anyopaque, specifier: []const u8) ![]const u8 {
            _ = ctx;
            _ = specifier;
            return error.DummyModuleLoader;
        }
    };
}

fn isExpectedTypeError(expected: []const u8, msg: []const u8) bool {
    if (!std.mem.eql(u8, expected, "TypeError")) {
        return false;
    }
    return std.mem.startsWith(u8, msg, "TypeError: ");
}

var default_global = DefaultGlobal{};
const DefaultGlobal = struct {};
