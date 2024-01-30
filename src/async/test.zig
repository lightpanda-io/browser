const std = @import("std");
const http = std.http;
const StdClient = @import("Client.zig");
// const hasync = @import("http.zig");

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
