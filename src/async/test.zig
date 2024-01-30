const std = @import("std");
const http = std.http;
const StdClient = @import("Client.zig");
const AsyncClient = @import("http.zig").Client;
const AsyncRequest = @import("http.zig").Request;

pub const Loop = @import("jsruntime").Loop;

const url = "https://www.w3.org/";

test "blocking mode fetch API" {
    const alloc = std.testing.allocator;

    var loop = try Loop.init(alloc);
    defer loop.deinit();

    var client: StdClient = .{
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

    var client: StdClient = .{
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

test "non blocking mode API" {
    const alloc = std.testing.allocator;

    var loop = try Loop.init(alloc);
    defer loop.deinit();

    var client = AsyncClient.init(alloc, &loop);
    defer client.deinit();

    var reqs: [10]AsyncRequest = undefined;
    for (0..reqs.len) |i| {
        reqs[i] = client.create(try std.Uri.parse(url));
        try reqs[i].fetch();
    }

    for (0..reqs.len) |i| {
        try reqs[i].wait();
        reqs[i].deinit();
    }
}
