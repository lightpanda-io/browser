// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// robots.txt gate for the HttpClient request pipeline. Answers allow/deny
// from the robot store; on a store miss it parks the transfer, coalesces
// concurrent requests for the same robots.txt behind a single internal
// fetch, and resumes (or fails) the parked transfers when it resolves.

const std = @import("std");
const lp = @import("lightpanda");

const URL = @import("../browser/URL.zig");

const http = @import("http.zig");
const Robots = @import("Robots.zig");
const Network = @import("Network.zig");
const HttpClient = @import("HttpClient.zig");
const SingleFlight = @import("SingleFlight.zig");

const log = lp.log;
const Transfer = HttpClient.Transfer;

const RobotsGate = @This();

network: *Network,
single_flight: SingleFlight,

pub const Result = enum { allowed, blocked, robots_unreachable, pending };

pub fn deinit(self: *RobotsGate) void {
    self.single_flight.deinit();
}

pub fn check(self: *RobotsGate, transfer: *Transfer) !Result {
    const url = transfer.req.url;
    const robots_url = try URL.getRobotsUrl(transfer.arena.allocator(), url);

    if (self.network.robot_store.checkPath(robots_url, URL.getPathname(url))) |decision| {
        switch (decision) {
            .allowed => return .allowed,
            .blocked => {
                log.debug(.http, "blocked by robots", .{ .url = url });
                return .blocked;
            },
            .robots_unreachable => {
                log.debug(.http, "robots.txt unreachable", .{ .url = url });
                return .robots_unreachable;
            },
        }
    }

    try self.fetchThenResume(robots_url, transfer);
    return .pending;
}

// A parked transfer is dying out-of-band (abort, owner teardown) — unlink
// it so the robots.txt resolution doesn't touch freed memory. The map entry
// stays: the in-flight fetch owns it (the key lives on the fetch's context
// arena) and still resolves the remaining waiters.
pub fn remove(self: *RobotsGate, transfer: *Transfer) void {
    self.single_flight.remove(transfer);
}

fn fetchThenResume(self: *RobotsGate, robots_url: [:0]const u8, transfer: *Transfer) !void {
    const client = transfer.client;

    const result = try self.single_flight.enter(robots_url, transfer, .robots);
    if (result == .queued) return;
    errdefer {
        self.single_flight.discard(robots_url);
        transfer.unpark();
    }

    const arena = try client.arena_pool.acquire(.small, "RobotsGate.RobotsContext");
    errdefer arena.release();

    const owned_url = try arena.dupeSentinel(u8, robots_url, 0);
    const robots_ctx = try arena.create(RobotsContext);
    robots_ctx.* = .{
        .gate = self,
        .arena = arena,
        .robots_url = owned_url,
    };

    log.debug(.browser, "fetching robots.txt", .{ .robots_url = owned_url });

    // Ownerless: no cookies, credentials, headers, or timeout. We attribute to
    // the parent for CDP correlation
    const fetch_transfer = try client.newRequest(.{
        .url = owned_url,
        .method = .GET,
        .internal = true,
        .resource_type = .fetch,
        .frame_id = transfer.req.frame_id,
        .document_frame_id = transfer.req.document_frame_id,
        .root_frame_id = transfer.req.root_frame_id,
        .loader_id = transfer.req.loader_id,
        .notification = transfer.req.notification,
        .origin = null,
        .credentials_mode = .omit,
        .request_mode = .no_cors,
        .ctx = robots_ctx,
        .header_callback = RobotsContext.headerCallback,
        .done_callback = RobotsContext.doneCallback,
        .error_callback = RobotsContext.errorCallback,
        .shutdown_callback = RobotsContext.shutdownCallback,
    }, null);

    // From here the fetch owns the pending entry and the context arena. If
    // submit fails it fires error_callback — possibly synchronously, right
    // here — which resolves the waiters (fail-open, may already have resumed
    // `transfer`) and releases the arena. So there is nothing to unwind
    // locally and the errdefers above must not run: swallow the error.
    fetch_transfer.submit() catch {};
}

const Outcome = union(enum) {
    allowed,
    robots_unreachable,
    robots: Robots.Robots,
    challenged,
};

// The robots.txt fetch resolved: hand every waiter back to the pipeline,
// each judged against its own path. No store entry (fetch failed, or a 200
// whose body never got parsed) fails open.
fn flushPending(self: *RobotsGate, robots_url: []const u8, outcome: Outcome) void {
    var queued = self.single_flight.take(robots_url) orelse return;
    defer queued.deinit(self.single_flight.allocator);

    for (queued.items) |transfer| {
        transfer.unpark();

        const decision: Robots.RobotStore.Decision = switch (outcome) {
            .allowed => .allowed,
            .robots_unreachable => .robots_unreachable,
            .robots => |r| if (r.isAllowed(URL.getPathname(transfer.req.url))) .allowed else .blocked,
            .challenged => {
                lp.metrics.robots_access.incr(.deny);
                transfer.failAsync(error.BotChallenge);
                continue;
            },
        };

        switch (decision) {
            .allowed => {},
            .blocked => {
                lp.metrics.robots_access.incr(.deny);
                log.debug(.http, "blocked by robots", .{ .url = transfer.req.url });
                transfer.failAsync(error.RobotsBlocked);
                continue;
            },
            .robots_unreachable => {
                lp.metrics.robots_access.incr(.deny);
                log.debug(.http, "robots.txt unreachable", .{ .url = transfer.req.url });
                transfer.failAsync(error.RobotsUnreachable);
                continue;
            },
        }
        // Hand back to the pipeline; the robots gate is the last step
        // before the network. If it fails while we still own the transfer,
        // clean up here.
        lp.metrics.robots_access.incr(.allow);
        transfer.client.resumeAfterRobots(transfer) catch |e| {
            transfer.abortPipelineError(e);
        };
    }
}

const RobotsContext = struct {
    gate: *RobotsGate,
    arena: *lp.Arena,
    robots_url: [:0]const u8,
    status: u16 = 0,
    challenge: ?HttpClient.BotChallenge = null,

    fn headerCallback(transfer: *Transfer) anyerror!Transfer.HeaderResult {
        const self: *RobotsContext = @ptrCast(@alignCast(transfer.req.ctx));
        if (transfer.res.header) |hdr| {
            log.debug(.browser, "robots status", .{ .status = hdr.status, .robots_url = self.robots_url });
            self.status = hdr.status;
        }
        self.challenge = transfer.botChallenge();
        lp.metrics.robots_status.incr(http.statusCategory(self.status));
        return .proceed;
    }

    fn doneCallback(transfer: *Transfer) anyerror!void {
        const self: *RobotsContext = @ptrCast(@alignCast(transfer.req.ctx));
        const robots_url = self.robots_url;
        const network = self.gate.network;

        if (self.challenge) |challenge| {
            // Nothing here can solve it, but the challenge might be gone by
            // the next request, so don't cache it.
            log.warn(.http, "robots.txt bot challenge", .{
                .url = robots_url,
                .status = self.status,
                .provider = challenge,
            });
            self.settle(.{ .outcome = .challenged, .cache = false });
            return;
        }

        switch (self.status) {
            200 => {
                const body = transfer.responseBody();
                if (body.len == 0) {
                    // Empty robots.txt means we can short-circuit the allowed path.
                    self.settle(.{ .outcome = .allowed });
                    return;
                }

                const robots = network.robot_store.robotsFromBytes(
                    network.config.http_headers.user_agent,
                    body,
                ) catch |err| {
                    // We only return an error if an allocation or something fails.
                    // Our parser does already leniently handle malformed input and takes whichever rules it can parse.
                    // On this case of an allocation failure, it is our fault so we treat robots.txt as unreachable.
                    log.debug(.browser, "error while parsing robots.txt", .{ .robots_url = robots_url, .err = err });
                    self.settle(.{ .outcome = .robots_unreachable });
                    return;
                };

                // BE CAREFUL: robots can be invalidated after this call
                self.settle(.{ .outcome = .{ .robots = robots } });
            },
            // Unauthorized/Forbidden: keep blocking since we can't verify permissions,
            // but distinguish from explicit robots.txt rules via RobotsUnreachable.
            401, 403 => {
                log.debug(.http, "robots.txt access denied", .{
                    .url = robots_url,
                    .status = self.status,
                });
                self.settle(.{ .outcome = .robots_unreachable });
            },
            // RFC9309: Unavailable (400-499, excluding 401/403) means that we may access any resources on the server.
            400, 402, 404...499 => {
                log.debug(.http, "robots.txt unavailable", .{
                    .url = robots_url,
                    .status = self.status,
                });
                self.settle(.{ .outcome = .allowed });
            },
            // RFC9309: Unreachable (500-599) means that we are completely disallowed.
            500...599 => {
                log.debug(.http, "robots.txt unreachable", .{
                    .url = robots_url,
                    .status = self.status,
                });
                self.settle(.{ .outcome = .robots_unreachable });
            },
            else => {
                log.debug(.http, "unexpected status on robots", .{
                    .url = robots_url,
                    .status = self.status,
                });
                self.settle(.{ .outcome = .robots_unreachable });
            },
        }
    }

    fn errorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));

        log.debug(.http, "robots fetch failed", .{ .err = err });
        self.settle(.{
            .outcome = .allowed,
            .cache = false,
        });
    }

    fn shutdownCallback(ctx_ptr: *anyopaque) void {
        const self: *RobotsContext = @ptrCast(@alignCast(ctx_ptr));

        log.debug(.http, "robots fetch shutdown", .{});
        const gate = self.gate;
        const arena = self.arena;
        gate.single_flight.discard(self.robots_url);
        arena.release();
    }

    const SettleOptions = struct {
        outcome: RobotsGate.Outcome,
        cache: bool = true,
    };

    fn settle(self: *RobotsContext, options: SettleOptions) void {
        const arena = self.arena;
        defer arena.release();

        const gate = self.gate;
        const network = gate.network;

        gate.flushPending(self.robots_url, options.outcome);

        if (options.cache) {
            switch (options.outcome) {
                .allowed => network.robot_store.putAllowed(self.robots_url) catch |err| {
                    log.warn(.browser, "cache robots decision", .{ .url = self.robots_url, .err = err });
                },
                .robots_unreachable => network.robot_store.putUnreachable(self.robots_url) catch |err| {
                    log.warn(.browser, "cache robots decision", .{ .url = self.robots_url, .err = err });
                },
                .robots => |r| network.robot_store.put(self.robots_url, r) catch |err| {
                    log.warn(.browser, "cache robots rules", .{ .url = self.robots_url, .err = err });
                },
                .challenged => {},
            }
        }
    }
};

const testing = @import("../testing.zig");
const ArenaPool = @import("../ArenaPool.zig");

const TestHarness = struct {
    pool: ArenaPool,
    network: Network,
    client: HttpClient,

    fn init(self: *TestHarness) void {
        self.pool = .init(testing.allocator, .{});

        self.network = undefined;
        self.network.config = &testing.test_config;
        self.network.robot_store = .init(testing.allocator, 32);
        self.network.available = .{};
        self.network.conn_mutex = .init;
        self.network.rate_limiter = null;
        self.network.adblocker = null;
        self.network.web_bot_auth = null;

        self.client = undefined;
        self.client.allocator = testing.allocator;
        self.client.arena_pool = &self.pool;
        self.client.network = &self.network;
        self.client.pending_queue = .{};
        self.client.dispatch_queue = .{};
        self.client.dispatch_count = 0;
        self.client.robots = .{
            .network = &self.network,
            .single_flight = .init(testing.allocator),
        };
    }

    fn deinit(self: *TestHarness) void {
        self.client.robots.deinit();
        self.network.robot_store.deinit();
        self.pool.deinit();
    }

    fn newWaiter(self: *TestHarness, arena: *lp.Arena, url: [:0]const u8, id: u32) !*Transfer {
        const transfer = try arena.create(Transfer);
        transfer.* = .{
            .arena = arena,
            .owner = null,
            .req = .{
                .method = .GET,
                .url = url,
                .origin = null,
                .credentials_mode = .omit,
                .request_mode = .no_cors,
                .resource_type = .document,
                .shutdown_callback = HttpClient.noopShutdown,
            },
            .client = &self.client,
            .id = id,
            .start_time = 0,
        };
        return transfer;
    }

    fn deliverRobotsResponse(
        self: *TestHarness,
        robots_url: [:0]const u8,
        status: u16,
        headers: []const http.Header,
        body: []const u8,
    ) !void {
        const ctx_arena = try self.pool.acquire(.small, "test.RobotsContext");
        errdefer ctx_arena.release();

        const owned_url = try ctx_arena.dupeSentinel(u8, robots_url, 0);
        const robots_ctx = try ctx_arena.create(RobotsContext);
        robots_ctx.* = .{
            .gate = &self.client.robots,
            .arena = ctx_arena,
            .robots_url = owned_url,
        };

        const fetch_arena = try self.pool.acquire(.small, "test.RobotsFetch");
        defer fetch_arena.release();

        var fetch_transfer: Transfer = .{
            .arena = fetch_arena,
            .owner = null,
            .req = .{
                .method = .GET,
                .url = owned_url,
                .internal = true,
                .origin = null,
                .credentials_mode = .omit,
                .request_mode = .no_cors,
                .resource_type = .fetch,
                .ctx = robots_ctx,
                .shutdown_callback = HttpClient.noopShutdown,
            },
            .client = &self.client,
            .id = 999,
            .start_time = 0,
        };
        fetch_transfer.res.header = .{
            .url = owned_url.ptr,
            .status = status,
            .redirect_count = 0,
        };
        fetch_transfer.res.headers = headers;

        if (body.len > 0) {
            fetch_transfer.res.buffer = .init(testing.allocator);
            try fetch_transfer.res.buffer._list.appendSlice(testing.allocator, body);
        }
        defer if (body.len > 0) fetch_transfer.res.buffer.deinit();

        try testing.expectEqual(.proceed, try RobotsContext.headerCallback(&fetch_transfer));
        try RobotsContext.doneCallback(&fetch_transfer);
    }
};

test "RobotsGate: 401 and 403 fail with RobotsUnreachable and cache the decision" {
    const Case = struct {
        status: u16,
        headers: []const http.Header = &.{},
    };
    const cases = [_]Case{
        .{ .status = 401 },
        .{ .status = 401, .headers = &.{.{ .name = "www-authenticate", .value = "Basic realm=\"restricted\"" }} },
        .{ .status = 403 },
        .{ .status = 403, .headers = &.{.{ .name = "server", .value = "cloudflare" }} },
    };

    for (cases) |case| {
        var h: TestHarness = undefined;
        h.init();
        defer h.deinit();

        const waiter_arena = try h.pool.acquire(.small, "test.waiter");
        defer waiter_arena.release();

        const robots_url = "http://example.com/robots.txt";
        const waiter = try h.newWaiter(waiter_arena, "http://example.com/abs/2401.00001", 1);
        try testing.expectEqual(.initial, try h.client.robots.single_flight.enter(robots_url, waiter, .robots));

        try h.deliverRobotsResponse(robots_url, case.status, case.headers, "");

        try testing.expectEqual(true, waiter.state == .buffered);
        try testing.expectEqual(1, waiter._events.items.len);
        try testing.expectEqual(error.RobotsUnreachable, waiter._events.items[0].err);
        try testing.expectEqual(.robots_unreachable, http.errorReason(waiter._events.items[0].err));
        try testing.expectEqual(0, h.client.robots.single_flight.count());
        try testing.expectEqual(.robots_unreachable, h.network.robot_store.checkPath(robots_url, "/abs/2401.00001").?);

        // Cached lookups on the same host must also return robots_unreachable rather than blocked.
        const cached_waiter = try h.newWaiter(waiter_arena, "http://example.com/pdf/2401.00001", 2);
        try testing.expectEqual(.robots_unreachable, try h.client.robots.check(cached_waiter));
    }
}

test "RobotsGate: other 4xx robots.txt responses allow access" {
    const Case = struct {
        status: u16,
        headers: []const http.Header = &.{},
    };
    const cases = [_]Case{
        .{ .status = 400 },
        .{ .status = 402 },
        .{ .status = 404 },
        .{ .status = 405, .headers = &.{.{ .name = "x-amzn-waf-action", .value = "block" }} },
        .{ .status = 410 },
        .{ .status = 429 },
        .{ .status = 451 },
        .{ .status = 499 },
    };

    for (cases) |case| {
        var h: TestHarness = undefined;
        h.init();
        defer h.deinit();

        const waiter_arena = try h.pool.acquire(.small, "test.waiter");
        defer waiter_arena.release();

        const robots_url = "http://example.com/robots.txt";
        const waiter = try h.newWaiter(waiter_arena, "http://example.com/abs/2401.00001", 1);
        try testing.expectEqual(.initial, try h.client.robots.single_flight.enter(robots_url, waiter, .robots));

        try h.deliverRobotsResponse(robots_url, case.status, case.headers, "");

        try testing.expectEqual(true, waiter.state == .queued);
        try testing.expectEqual(0, waiter._events.items.len);
        try testing.expectEqual(0, h.client.robots.single_flight.count());
        try testing.expectEqual(.allowed, h.network.robot_store.checkPath(robots_url, "/abs/2401.00001").?);
    }
}

test "RobotsGate: 5xx and unexpected status codes fail with RobotsUnreachable" {
    const statuses = [_]u16{ 500, 502, 503, 599, 300, 999 };

    for (statuses) |status| {
        var h: TestHarness = undefined;
        h.init();
        defer h.deinit();

        const waiter_arena = try h.pool.acquire(.small, "test.waiter");
        defer waiter_arena.release();

        const robots_url = "http://example.com/robots.txt";
        const waiter = try h.newWaiter(waiter_arena, "http://example.com/page", 1);
        try testing.expectEqual(.initial, try h.client.robots.single_flight.enter(robots_url, waiter, .robots));

        try h.deliverRobotsResponse(robots_url, status, &.{}, "");

        try testing.expectEqual(true, waiter.state == .buffered);
        try testing.expectEqual(1, waiter._events.items.len);
        try testing.expectEqual(error.RobotsUnreachable, waiter._events.items[0].err);
        try testing.expectEqual(0, h.client.robots.single_flight.count());
        try testing.expectEqual(.robots_unreachable, h.network.robot_store.checkPath(robots_url, "/page").?);

        const cached_waiter = try h.newWaiter(waiter_arena, "http://example.com/other", 2);
        try testing.expectEqual(.robots_unreachable, try h.client.robots.check(cached_waiter));
    }
}

test "RobotsGate: bot challenge on 403, 405, or 429 fails with BotChallenge without caching" {
    const Case = struct {
        status: u16,
        headers: []const http.Header,
    };
    const cases = [_]Case{
        .{ .status = 403, .headers = &.{.{ .name = "cf-mitigated", .value = "challenge" }} },
        .{ .status = 429, .headers = &.{.{ .name = "x-vercel-mitigated", .value = "challenge" }} },
        .{ .status = 405, .headers = &.{.{ .name = "x-amzn-waf-action", .value = "challenge" }} },
    };

    for (cases) |case| {
        var h: TestHarness = undefined;
        h.init();
        defer h.deinit();

        const waiter_arena = try h.pool.acquire(.small, "test.waiter");
        defer waiter_arena.release();

        const robots_url = "http://example.com/robots.txt";
        const waiter = try h.newWaiter(waiter_arena, "http://example.com/page", 1);
        try testing.expectEqual(.initial, try h.client.robots.single_flight.enter(robots_url, waiter, .robots));

        try h.deliverRobotsResponse(robots_url, case.status, case.headers, "");

        try testing.expectEqual(true, waiter.state == .buffered);
        try testing.expectEqual(1, waiter._events.items.len);
        try testing.expectEqual(error.BotChallenge, waiter._events.items[0].err);
        try testing.expectEqual(0, h.client.robots.single_flight.count());
        try testing.expectEqual(null, h.network.robot_store.checkPath(robots_url, "/page"));
    }
}

test "RobotsGate: 200 enforces parsed rules and empty 200 allows all" {
    {
        var h: TestHarness = undefined;
        h.init();
        defer h.deinit();

        const waiter_arena = try h.pool.acquire(.small, "test.waiter");
        defer waiter_arena.release();

        const robots_url = "http://example.com/robots.txt";
        const blocked_waiter = try h.newWaiter(waiter_arena, "http://example.com/private/secret", 1);
        const allowed_waiter = try h.newWaiter(waiter_arena, "http://example.com/public/page", 2);
        try testing.expectEqual(.initial, try h.client.robots.single_flight.enter(robots_url, blocked_waiter, .robots));
        try testing.expectEqual(.queued, try h.client.robots.single_flight.enter(robots_url, allowed_waiter, .robots));

        try h.deliverRobotsResponse(
            robots_url,
            200,
            &.{},
            "User-Agent: *\nDisallow: /private/\nAllow: /public/\n",
        );

        try testing.expectEqual(true, blocked_waiter.state == .buffered);
        try testing.expectEqual(1, blocked_waiter._events.items.len);
        try testing.expectEqual(error.RobotsBlocked, blocked_waiter._events.items[0].err);
        try testing.expectEqual(.robots_blocked, http.errorReason(blocked_waiter._events.items[0].err));
        try testing.expectEqual(true, allowed_waiter.state == .queued);
        try testing.expectEqual(0, allowed_waiter._events.items.len);
        try testing.expectEqual(.blocked, h.network.robot_store.checkPath(robots_url, "/private/secret").?);
        try testing.expectEqual(.allowed, h.network.robot_store.checkPath(robots_url, "/public/page").?);

        const cached_blocked = try h.newWaiter(waiter_arena, "http://example.com/private/other", 3);
        try testing.expectEqual(.blocked, try h.client.robots.check(cached_blocked));
    }

    {
        var h: TestHarness = undefined;
        h.init();
        defer h.deinit();

        const waiter_arena = try h.pool.acquire(.small, "test.waiter");
        defer waiter_arena.release();

        const robots_url = "http://example.com/robots.txt";
        const waiter = try h.newWaiter(waiter_arena, "http://example.com/anything", 1);
        try testing.expectEqual(.initial, try h.client.robots.single_flight.enter(robots_url, waiter, .robots));

        try h.deliverRobotsResponse(robots_url, 200, &.{}, "");

        try testing.expectEqual(true, waiter.state == .queued);
        try testing.expectEqual(0, waiter._events.items.len);
        try testing.expectEqual(.allowed, h.network.robot_store.checkPath(robots_url, "/anything").?);
    }
}

test "RobotsGate: transport error allows access without caching" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();

    const waiter_arena = try h.pool.acquire(.small, "test.waiter");
    defer waiter_arena.release();

    const robots_url = "http://example.com/robots.txt";
    const waiter = try h.newWaiter(waiter_arena, "http://example.com/page", 1);
    try testing.expectEqual(.initial, try h.client.robots.single_flight.enter(robots_url, waiter, .robots));

    const ctx_arena = try h.pool.acquire(.small, "test.RobotsContext");
    const owned_url = try ctx_arena.dupeSentinel(u8, robots_url, 0);
    const robots_ctx = try ctx_arena.create(RobotsContext);
    robots_ctx.* = .{
        .gate = &h.client.robots,
        .arena = ctx_arena,
        .robots_url = owned_url,
    };

    RobotsContext.errorCallback(robots_ctx, error.CouldntConnect);

    try testing.expectEqual(true, waiter.state == .queued);
    try testing.expectEqual(0, waiter._events.items.len);
    try testing.expectEqual(0, h.client.robots.single_flight.count());
    try testing.expectEqual(null, h.network.robot_store.checkPath(robots_url, "/page"));
}
