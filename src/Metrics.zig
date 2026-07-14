// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

const Metrics = @This();

cdp_connections: Counter = .{},
cdp_connection_limit: Counter = .{},
cdp_active_connections: Gauge = .{},
cdp_commands: Counter = .{},
cdp_unknown_commands: Counter = .{},
js_heap_limits: Counter = .{},
script_errors: Counter = .{},
arena_hit: CounterEnum("size", @import("ArenaPool.zig").BucketSize) = .{},
arena_miss: CounterEnum("size", @import("ArenaPool.zig").BucketSize) = .{},
navigate: CounterEnum("type", @import("telemetry/telemetry.zig").Event.Navigate.Context) = .{},
js_heap_size_bytes: Histogram(&.{
    4 * 1024 * 1024,
    8 * 1024 * 1024,
    16 * 1024 * 1024,
    32 * 1024 * 1024,
    64 * 1024 * 1024,
    128 * 1024 * 1024,
    256 * 1024 * 1024,
    512 * 1024 * 1024,
}) = .{},
http_requests: CounterEnum("mode", enum { sync, async }) = .{},
http_status: CounterEnum("category", @import("network/http.zig").StatusCategory) = .{},
http_error: CounterEnum("reason", @import("network/http.zig").ErrorReason) = .{},
http_cache: CounterEnum("result", enum { hit, miss, revalidated }) = .{},
http_redirects: Counter = .{},
http_duration_ms: Histogram(&.{
    5,
    10,
    25,
    50,
    100,
    250,
    500,
    1000,
    2500,
    5000,
    10000,
}) = .{},
http_response_size_bytes: Histogram(&.{
    32 * 1024,
    64 * 1024,
    128 * 1024,
    256 * 1024,
    512 * 1024,
    1024 * 1024,
    2 * 1024 * 1024,
    4 * 1024 * 1024,
}) = .{},
robots_status: CounterEnum("category", @import("network/http.zig").StatusCategory) = .{},
robots_access: CounterEnum("result", enum { allow, deny }) = .{},

// Emitted as each metric's "# HELP" line. A field without an entry is a
// compile error.
const help = .{
    .cdp_connections = "CDP websocket connections accepted",
    .cdp_connection_limit = "Connections rejected because --cdp-max-connections was reached",
    .cdp_active_connections = "Currently connected CDP clients",
    .cdp_commands = "CDP commands dispatched",
    .cdp_unknown_commands = "CDP commands rejected for an unknown domain or method",
    .js_heap_limits = "Pages terminated for reaching the V8 heap limit",
    .script_errors = "Scripts that failed to evaluate, e.g. an uncaught top-level exception",
    .arena_hit = "Arena pool acquisitions served from the free list",
    .arena_miss = "Arena pool acquisitions that had to allocate a new arena",
    .navigate = "Navigations by initiating frame type",
    .js_heap_size_bytes = "V8 heap physical size, sampled when a page is closed",
    .http_requests = "HTTP requests submitted, by dispatch mode (excludes internal requests like robots.txt)",
    .http_status = "Final HTTP response status category (redirects counted once, at the final hop)",
    .http_error = "HTTP requests that failed before delivering a response, by cause",
    .http_cache = "HTTP cache lookups by outcome",
    .http_redirects = "HTTP redirect hops followed",
    .http_duration_ms = "HTTP request wall-clock duration in milliseconds",
    .http_response_size_bytes = "HTTP response body size in bytes",
    .robots_status = "robots.txt response status",
    .robots_access = "robots.txt result",
};

pub fn write(self: *const Metrics, writer: *std.Io.Writer) void {
    self._write(writer) catch |err| {
        lp.log.err(.app, "metrics write", .{ .err = err });
    };
}

fn _write(self: *const Metrics, writer: *std.Io.Writer) !void {
    try writer.print(
        "# HELP build_info Lightpanda build information\n" ++
            "# TYPE build_info gauge\nbuild_info{{version=\"{s}\"}} 1\n",
        .{lp.build_config.version},
    );
    inline for (@typeInfo(Metrics).@"struct".fields) |f| {
        try @field(self, f.name).write(f.name, @field(help, f.name), writer);
    }
}

const Counter = struct {
    count: usize = 0,

    pub fn incr(self: *Counter) void {
        self.incrBy(1);
    }

    pub fn incrBy(self: *Counter, c: usize) void {
        _ = @atomicRmw(usize, &self.count, .Add, c, .monotonic);
    }

    fn write(self: *const Counter, comptime name: []const u8, comptime help_text: []const u8, writer: *std.Io.Writer) !void {
        try writer.writeAll("# HELP " ++ name ++ "_total " ++ help_text ++ "\n" ++ "# TYPE " ++ name ++ "_total counter\n");
        try writer.print(name ++ "_total {d}\n", .{self.get()});
    }

    fn get(self: *const Counter) usize {
        return @atomicLoad(usize, &self.count, .monotonic);
    }
};

const Gauge = struct {
    value: isize = 0,

    pub fn incr(self: *Gauge) void {
        _ = @atomicRmw(isize, &self.value, .Add, 1, .monotonic);
    }

    pub fn decr(self: *Gauge) void {
        _ = @atomicRmw(isize, &self.value, .Sub, 1, .monotonic);
    }

    fn write(self: *const Gauge, comptime name: []const u8, comptime help_text: []const u8, writer: *std.Io.Writer) !void {
        try writer.writeAll("# HELP " ++ name ++ " " ++ help_text ++ "\n" ++ "# TYPE " ++ name ++ " gauge\n");
        try writer.print(name ++ " {d}\n", .{@atomicLoad(isize, &self.value, .monotonic)});
    }
};

fn CounterEnum(comptime label: []const u8, comptime T: type) type {
    return struct {
        counts: std.enums.EnumArray(T, Counter) = .initFill(.{}),

        pub const Tag = T;
        pub const label_name = label;

        const Self = @This();

        pub fn incr(self: *Self, tag: T) void {
            self.incrBy(tag, 1);
        }

        pub fn incrBy(self: *Self, tag: T, c: usize) void {
            self.counts.getPtr(tag).incrBy(c);
        }

        fn write(self: *const Self, comptime name: []const u8, comptime help_text: []const u8, writer: *std.Io.Writer) !void {
            try writer.writeAll("# HELP " ++ name ++ "_total " ++ help_text ++ "\n" ++ "# TYPE " ++ name ++ "_total counter\n");
            inline for (comptime std.enums.values(Tag)) |tag| {
                try writer.print(name ++ "_total{{" ++ label ++ "=\"" ++ @tagName(tag) ++ "\"}} {d}\n", .{self.counts.getPtrConst(tag).get()});
            }
        }
    };
}

fn Histogram(comptime upper_bounds: []const usize) type {
    comptime {
        std.debug.assert(upper_bounds.len > 0);
        for (upper_bounds[0 .. upper_bounds.len - 1], upper_bounds[1..]) |a, b| {
            std.debug.assert(a < b);
        }
    }

    return struct {
        sum: usize = 0,
        count: usize = 0,
        buckets: [upper_bounds.len]usize = @splat(0),

        const Self = @This();

        pub fn observe(self: *Self, value: usize) void {
            _ = @atomicRmw(usize, &self.count, .Add, 1, .monotonic);
            _ = @atomicRmw(usize, &self.sum, .Add, value, .monotonic);
            inline for (upper_bounds, 0..) |upper, i| {
                if (value <= upper) {
                    _ = @atomicRmw(usize, &self.buckets[i], .Add, 1, .monotonic);
                    return;
                }
            }
            // falls in the implicit +Inf bucket, which is derived from count
        }

        fn write(self: *const Self, comptime name: []const u8, comptime help_text: []const u8, writer: *std.Io.Writer) !void {
            try writer.writeAll("# HELP " ++ name ++ " " ++ help_text ++ "\n" ++ "# TYPE " ++ name ++ " histogram\n");

            // le buckets are cumulative
            var sum: usize = 0;
            inline for (upper_bounds, 0..) |upper, i| {
                sum += @atomicLoad(usize, &self.buckets[i], .monotonic);
                try writer.print(name ++ "_bucket{{le=\"" ++ std.fmt.comptimePrint("{d}", .{upper}) ++ "\"}} {d}\n", .{sum});
            }

            const count = @atomicLoad(usize, &self.count, .monotonic);
            try writer.print(
                name ++ "_bucket{{le=\"+Inf\"}} {d}\n" ++ name ++ "_sum {d}\n" ++ name ++ "_count {d}\n",
                .{ count, @atomicLoad(usize, &self.sum, .monotonic), count },
            );
        }
    };
}

const testing = @import("testing.zig");

test "Metrics: Counter" {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();

    var c = Counter{};
    c.incr();
    c.incrBy(3);
    try c.write("stat", "counts stats", &w.writer);
    try testing.expectEqual(
        \\# HELP stat_total counts stats
        \\# TYPE stat_total counter
        \\stat_total 4
        \\
    , w.written());
}

test "Metrics: Gauge" {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();

    var g = Gauge{};
    g.incr();
    g.incr();
    g.decr();
    try g.write("stat", "counts stats", &w.writer);
    try testing.expectEqual(
        \\# HELP stat counts stats
        \\# TYPE stat gauge
        \\stat 1
        \\
    , w.written());
}

test "Metrics: CounterEnum" {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();

    var c = CounterEnum("color", enum { red, blue }){};
    c.incr(.blue);
    c.incrBy(.blue, 2);
    try c.write("stat", "counts stats", &w.writer);
    try testing.expectEqual(
        \\# HELP stat_total counts stats
        \\# TYPE stat_total counter
        \\stat_total{color="red"} 0
        \\stat_total{color="blue"} 3
        \\
    , w.written());
}

test "Metrics: Histogram" {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();

    var h = Histogram(&.{ 10, 100 }){};
    h.observe(5);
    h.observe(10); // le is inclusive
    h.observe(50);
    h.observe(200); // +Inf only
    try h.write("stat", "counts stats", &w.writer);
    try testing.expectEqual(
        \\# HELP stat counts stats
        \\# TYPE stat histogram
        \\stat_bucket{le="10"} 2
        \\stat_bucket{le="100"} 3
        \\stat_bucket{le="+Inf"} 4
        \\stat_sum 265
        \\stat_count 4
        \\
    , w.written());
}
