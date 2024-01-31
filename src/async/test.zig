const std = @import("std");
const http = std.http;
const Client = @import("Client.zig");
const Request = @import("Client.zig").Request;

pub const Loop = @import("jsruntime").Loop;

const TCPClient = @import("tcp.zig").Client;

const url = "https://w3.org";

test "blocking mode fetch API" {
    const alloc = std.testing.allocator;

    var loop = try Loop.init(alloc);
    defer loop.deinit();

    var client: Client = .{
        .allocator = alloc,
        .loop = &loop,
    };
    defer client.deinit();

    // force client's CA cert scan from system.
    try client.ca_bundle.rescan(client.allocator);

    var res = try client.fetch(alloc, .{
        .location = .{ .uri = try std.Uri.parse(url) },
        .payload = .none,
    });
    defer res.deinit();

    try std.testing.expect(res.status == .ok);
}

test "blocking mode open/send/wait API" {
    const alloc = std.testing.allocator;

    var loop = try Loop.init(alloc);
    defer loop.deinit();

    var client: Client = .{
        .allocator = alloc,
        .loop = &loop,
    };
    defer client.deinit();

    // force client's CA cert scan from system.
    try client.ca_bundle.rescan(client.allocator);

    var headers = try std.http.Headers.initList(alloc, &[_]std.http.Field{});
    defer headers.deinit();

    var req = try client.open(.GET, try std.Uri.parse(url), headers, .{});
    defer req.deinit();

    try req.send(.{});
    try req.finish();
    try req.wait();

    try std.testing.expect(req.response.status == .ok);
}

// Example how to write an async http client using the modified standard client.
const AsyncClient = struct {
    cli: Client,

    const YieldImpl = Loop.Yield(AsyncRequest);
    const AsyncRequest = struct {
        cli: *Client,
        uri: std.Uri,
        headers: std.http.Headers,

        impl: YieldImpl,
        done: bool = false,
        err: ?anyerror = null,

        pub fn deinit(self: *AsyncRequest) void {
            self.headers.deinit();
            self.cli.allocator.destroy(self);
        }

        pub fn fetch(self: *AsyncRequest) void {
            return self.impl.yield();
        }

        fn onerr(self: *AsyncRequest, err: anyerror) void {
            self.err = err;
        }

        pub fn onYield(self: *AsyncRequest, err: ?anyerror) void {
            defer self.done = true;
            if (err) |e| return self.onerr(e);
            var req = self.cli.open(.GET, self.uri, self.headers, .{}) catch |e| return self.onerr(e);
            defer req.deinit();

            req.send(.{}) catch |e| return self.onerr(e);
            req.finish() catch |e| return self.onerr(e);
            req.wait() catch |e| return self.onerr(e);
        }

        pub fn wait(self: *AsyncRequest) !void {
            while (!self.done) try self.impl.tick();
            if (self.err) |err| return err;
        }
    };

    pub fn init(alloc: std.mem.Allocator, loop: *Loop) AsyncClient {
        return .{
            .cli = .{
                .allocator = alloc,
                .loop = loop,
            },
        };
    }

    pub fn deinit(self: *AsyncClient) void {
        self.cli.deinit();
    }

    pub fn create(self: *AsyncClient, uri: std.Uri) !*AsyncRequest {
        var req = try self.cli.allocator.create(AsyncRequest);
        req.* = AsyncRequest{
            .impl = undefined,
            .cli = &self.cli,
            .uri = uri,
            .headers = .{ .allocator = self.cli.allocator, .owned = false },
        };
        req.impl = YieldImpl.init(self.cli.loop, req);
        return req;
    }
};

test "non blocking client" {
    const alloc = std.testing.allocator;

    var loop = try Loop.init(alloc);
    defer loop.deinit();

    var client = AsyncClient.init(alloc, &loop);
    defer client.deinit();

    var reqs: [10]*AsyncClient.AsyncRequest = undefined;
    for (0..reqs.len) |i| {
        reqs[i] = try client.create(try std.Uri.parse(url));
        reqs[i].fetch();
    }

    for (0..reqs.len) |i| {
        try reqs[i].wait();
        reqs[i].deinit();
    }
}
