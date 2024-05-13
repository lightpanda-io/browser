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
const http = std.http;
const Client = @import("Client.zig");
const Request = @import("Client.zig").Request;

pub const Loop = @import("jsruntime").Loop;

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
        const State = enum { new, open, send, finish, wait, done };

        cli: *Client,
        uri: std.Uri,
        headers: std.http.Headers,

        req: ?Request = undefined,
        state: State = .new,

        impl: YieldImpl,
        err: ?anyerror = null,

        pub fn deinit(self: *AsyncRequest) void {
            if (self.req) |*r| r.deinit();
            self.headers.deinit();
        }

        pub fn fetch(self: *AsyncRequest) void {
            self.state = .new;
            return self.impl.yield(self);
        }

        fn onerr(self: *AsyncRequest, err: anyerror) void {
            self.state = .done;
            self.err = err;
        }

        pub fn onYield(self: *AsyncRequest, err: ?anyerror) void {
            if (err) |e| return self.onerr(e);

            switch (self.state) {
                .new => {
                    self.state = .open;
                    self.req = self.cli.open(.GET, self.uri, self.headers, .{}) catch |e| return self.onerr(e);
                },
                .open => {
                    self.state = .send;
                    self.req.?.send(.{}) catch |e| return self.onerr(e);
                },
                .send => {
                    self.state = .finish;
                    self.req.?.finish() catch |e| return self.onerr(e);
                },
                .finish => {
                    self.state = .wait;
                    self.req.?.wait() catch |e| return self.onerr(e);
                },
                .wait => {
                    self.state = .done;
                    return;
                },
                .done => return,
            }

            return self.impl.yield(self);
        }

        pub fn wait(self: *AsyncRequest) !void {
            while (self.state != .done) try self.impl.tick();
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

    pub fn createRequest(self: *AsyncClient, uri: std.Uri) !AsyncRequest {
        return .{
            .impl = YieldImpl.init(self.cli.loop),
            .cli = &self.cli,
            .uri = uri,
            .headers = .{ .allocator = self.cli.allocator, .owned = false },
        };
    }
};

test "non blocking client" {
    const alloc = std.testing.allocator;

    var loop = try Loop.init(alloc);
    defer loop.deinit();

    var client = AsyncClient.init(alloc, &loop);
    defer client.deinit();

    var reqs: [3]AsyncClient.AsyncRequest = undefined;
    for (0..reqs.len) |i| {
        reqs[i] = try client.createRequest(try std.Uri.parse(url));
        reqs[i].fetch();
    }
    for (0..reqs.len) |i| {
        try reqs[i].wait();
        reqs[i].deinit();
    }
}
