const std = @import("std");
const http = std.http;
const stdcli = @import("Client.zig");

pub const Loop = @import("jsruntime").Loop;

pub const Client = struct {
    cli: stdcli,

    pub fn init(alloc: std.mem.Allocator, loop: *Loop) Client {
        return .{ .cli = .{
            .allocator = alloc,
            .loop = loop,
        } };
    }

    pub fn deinit(self: *Client) void {
        self.cli.deinit();
    }

    pub fn create(self: *Client, uri: std.Uri) Request {
        return .{
            .cli = &self.cli,
            .uri = uri,
            .headers = .{ .allocator = self.cli.allocator, .owned = false },
        };
    }
};

pub const Request = struct {
    cli: *stdcli,
    uri: std.Uri,
    headers: std.http.Headers,

    done: bool = false,
    err: ?anyerror = null,

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }

    pub fn fetch(self: *Request) !void {
        self.cli.loop.yield(*Request, self, callback);
    }

    fn onerr(self: *Request, err: anyerror) void {
        self.err = err;
    }

    fn callback(self: *Request, err: ?anyerror) void {
        if (err) |e| return self.onerr(e);
        defer self.done = true;
        var req = self.cli.open(.GET, self.uri, self.headers, .{}) catch |e| return self.onerr(e);
        defer req.deinit();

        req.send(.{}) catch |e| return self.onerr(e);
        req.finish() catch |e| return self.onerr(e);
        req.wait() catch |e| return self.onerr(e);
    }

    pub fn wait(self: *Request) !void {
        while (!self.done) try self.cli.loop.tick();
        if (self.err) |err| return err;
    }
};
