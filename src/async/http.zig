const std = @import("std");
const http = std.http;
const stdcli = @import("Client.zig");

pub const Loop = @import("jsruntime").Loop;
const YieldImpl = Loop.Yield(Request);

pub const Client = struct {
    cli: stdcli,

    pub fn init(alloc: std.mem.Allocator, loop: *Loop) Client {
        return .{
            .cli = .{
                .allocator = alloc,
                .loop = loop,
            },
        };
    }

    pub fn deinit(self: *Client) void {
        self.cli.deinit();
    }

    pub fn create(self: *Client, uri: std.Uri) !*Request {
        var req = try self.cli.allocator.create(Request);
        req.* = Request{
            .impl = undefined,
            .cli = &self.cli,
            .uri = uri,
            .headers = .{ .allocator = self.cli.allocator, .owned = false },
        };
        req.impl = YieldImpl.init(self.cli.loop, req);
        return req;
    }
};

pub const Request = struct {
    cli: *stdcli,
    uri: std.Uri,
    headers: std.http.Headers,

    impl: YieldImpl,
    done: bool = false,
    err: ?anyerror = null,

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
        self.cli.allocator.destroy(self);
    }

    pub fn fetch(self: *Request) void {
        return self.impl.yield();
    }

    fn onerr(self: *Request, err: anyerror) void {
        self.err = err;
    }

    pub fn onYield(self: *Request, err: ?anyerror) void {
        defer self.done = true;
        if (err) |e| return self.onerr(e);
        var req = self.cli.open(.GET, self.uri, self.headers, .{}) catch |e| return self.onerr(e);
        defer req.deinit();

        req.send(.{}) catch |e| return self.onerr(e);
        req.finish() catch |e| return self.onerr(e);
        req.wait() catch |e| return self.onerr(e);
    }

    pub fn wait(self: *Request) !void {
        while (!self.done) try self.impl.tick();
        if (self.err) |err| return err;
    }
};
