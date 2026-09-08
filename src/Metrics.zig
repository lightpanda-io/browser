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
const Driver = @import("server/Driver.zig").Protocol;

serve_http_requests: CounterEnum("status", @import("network/http.zig").StatusCategory) = .{},
serve_http_evictions: Counter = .{},
serve_inbox_backlog: Counter = .{},
serve_connections: CounterEnum("driver", Driver) = .{},
serve_connection_limit: Counter = .{},
serve_active_connections: GaugeEnum("driver", Driver) = .{},
serve_commands: CounterEnum("driver", Driver) = .{},
serve_unknown_commands: CounterEnum("driver", Driver) = .{},
js_heap_limits: Counter = .{},
script_errors: Counter = .{},
js_errors: CounterEnum("kind", enum { js_exception, other }) = .{},
arena_hit: CounterEnum("size", @import("ArenaPool.zig").BucketSize) = .{},
arena_miss: CounterEnum("size", @import("ArenaPool.zig").BucketSize) = .{},
arena_inflight: GaugeEnum("size", @import("ArenaPool.zig").BucketSize) = .{},
arena_memory_bytes: Gauge = .{},
navigate: CounterEnum("type", @import("telemetry/telemetry.zig").Event.Navigate.Context) = .{},
js_heap_physical_bytes: Gauge = .{},
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
http_navigation_delay_ms: Histogram(&.{
    10,
    50,
    100,
    250,
    500,
    1000,
    2500,
    5000,
    10000,
    30000,
}) = .{},
robots_status: CounterEnum("category", @import("network/http.zig").StatusCategory) = .{},
robots_access: CounterEnum("result", enum { allow, deny }) = .{},
cors_check: CounterEnum("result", enum { same_origin, no_cors, simple, preflight }) = .{},
cors_preflight: CounterEnum("result", enum { allowed, blocked }) = .{},
cors_response: CounterEnum("result", enum { allowed, blocked }) = .{},
adblock_verdicts: CounterEnum("verdict", @import("network/adblock/AdBlocker.zig").Verdict) = .{},
adblock_rules: GaugeEnum("state", enum { loaded, skipped, cosmetic }) = .{},

// Emitted as each metric's "# HELP" line. A field without an entry is a
// compile error.
const help = .{
    .serve_http_requests = "HTTP responses sent, by status category (includes the pre-parse 400/413 rejections)",
    .serve_http_evictions = "HTTP connections closed for sitting past their deadline without completing a request",
    .serve_inbox_backlog = "Websocket connections closed for queueing more unprocessed messages than the worker could drain",
    .serve_connections = "Websocket connections accepted, by driver protocol",
    .serve_connection_limit = "Accepts deferred because the connection budget was full: the listener pauses until a slot frees (counted before any handshake, so no driver label)",
    .serve_active_connections = "Currently connected clients, by driver protocol",
    .serve_commands = "Commands dispatched, by driver protocol",
    .serve_unknown_commands = "Commands rejected for an unknown domain, module or method, by driver protocol",
    .js_heap_limits = "Pages terminated for reaching the V8 heap limit",
    .script_errors = "Scripts that failed to evaluate, e.g. an uncaught top-level exception",
    .js_errors = "Uncaught JS errors (script exceptions, listener/callback throws, unhandled promise rejections); kind=js_exception is a thrown JS value, other is an internal failure (e.g. compilation error, terminated execution)",
    .arena_hit = "Arena pool acquisitions served from the free list",
    .arena_miss = "Arena pool acquisitions that had to allocate a new arena",
    .arena_inflight = "Arenas currently checked out of the pool. Above the bucket's max, every acquisition is a miss and every release is discarded",
    .arena_memory_bytes = "Backing memory held by pooled arenas, including capacity retained on the free list",
    .navigate = "Navigations by initiating frame type",
    .js_heap_physical_bytes = "V8 heap physical size summed over every live isolate (one per connection).",
    .js_heap_size_bytes = "V8 heap physical size, sampled when a page is closed",
    .http_requests = "HTTP requests submitted, by dispatch mode (excludes internal requests like robots.txt)",
    .http_status = "Final HTTP response status category (redirects counted once, at the final hop)",
    .http_error = "HTTP requests that failed before delivering a response, by cause",
    .http_cache = "HTTP cache lookups by outcome",
    .http_redirects = "HTTP redirect hops followed",
    .http_duration_ms = "HTTP request wall-clock duration in milliseconds",
    .http_response_size_bytes = "HTTP response body size in bytes",
    .http_navigation_delay_ms = "Time in milliseconds a throttled top-level navigation waited",
    .robots_status = "robots.txt response status",
    .robots_access = "robots.txt result",
    .cors_check = "CORS initial classification: same_origin/no_cors need no CORS handling, simple needs response validation only, preflight needs an OPTIONS round-trip first",
    .cors_preflight = "CORS preflight (OPTIONS) results, one per request that required one",
    .cors_response = "CORS actual-response validation results",
    .adblock_verdicts = "Adblocker decisions for evaluated requests, by verdict (none = not blocked, allowed = an exception overrode a block)",
    .adblock_rules = "Filter-list rules by fate: loaded into the matcher, skipped as unsupported, or cosmetic (domain-scoped element hiding, outside the network realm)",
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
        self.incrBy(1);
    }

    pub fn incrBy(self: *Gauge, n: usize) void {
        _ = @atomicRmw(isize, &self.value, .Add, @intCast(n), .monotonic);
    }

    pub fn decr(self: *Gauge) void {
        self.decrBy(1);
    }

    pub fn decrBy(self: *Gauge, n: usize) void {
        _ = @atomicRmw(isize, &self.value, .Sub, @intCast(n), .monotonic);
    }

    // For callers that track an absolute value and report the change since
    // their last report. There's no set(): the gauge is a sum over threads,
    // so a caller can only move its own contribution.
    pub fn add(self: *Gauge, n: i64) void {
        _ = @atomicRmw(isize, &self.value, .Add, @intCast(n), .monotonic);
    }

    fn write(self: *const Gauge, comptime name: []const u8, comptime help_text: []const u8, writer: *std.Io.Writer) !void {
        try writer.writeAll("# HELP " ++ name ++ " " ++ help_text ++ "\n" ++ "# TYPE " ++ name ++ " gauge\n");
        try writer.print(name ++ " {d}\n", .{@atomicLoad(isize, &self.value, .monotonic)});
    }
};

fn GaugeEnum(comptime label: []const u8, comptime T: type) type {
    return struct {
        values: std.enums.EnumArray(T, Gauge) = .initFill(.{}),

        pub const Tag = T;
        pub const label_name = label;

        const Self = @This();

        pub fn incr(self: *Self, tag: T) void {
            self.values.getPtr(tag).incr();
        }

        pub fn decr(self: *Self, tag: T) void {
            self.values.getPtr(tag).decr();
        }

        pub fn add(self: *Self, tag: T, n: i64) void {
            self.values.getPtr(tag).add(n);
        }

        fn write(self: *const Self, comptime name: []const u8, comptime help_text: []const u8, writer: *std.Io.Writer) !void {
            try writer.writeAll("# HELP " ++ name ++ " " ++ help_text ++ "\n" ++ "# TYPE " ++ name ++ " gauge\n");
            inline for (comptime std.enums.values(Tag)) |tag| {
                const value = @atomicLoad(isize, &self.values.getPtrConst(tag).value, .monotonic);
                try writer.print(name ++ "{{" ++ label ++ "=\"" ++ @tagName(tag) ++ "\"}} {d}\n", .{value});
            }
        }
    };
}

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
