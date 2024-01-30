const std = @import("std");

const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;
const Loop = jsruntime.Loop;
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const parser = @import("../netsurf.zig");

const DOMException = @import("../dom/exceptions.zig").DOMException;

const Client = Loop.TCPClient;
const Impl = Loop.Impl(Client);

pub const XHR = struct {
    url: []const u8,
    method: []const u8,
    handler: ?Callback = null,

    client: *Client,

    pub const Exception = DOMException;
    pub const mem_guarantied = true;

    pub fn constructor(alloc: std.mem.Allocator, loop: *Loop) !XHR {
        const client = try alloc.create(Client);
        client.* = try Client.init(alloc, loop);
        return .{ .url = undefined, .method = undefined, .client = client };
    }

    pub fn get_url(self: XHR) []const u8 {
        return self.url;
    }

    pub fn get_method(self: XHR) []const u8 {
        return self.method;
    }

    pub fn set_onload(self: *XHR, handler: Callback) void {
        self.handler = handler;
    }

    pub fn _open(
        self: *XHR,
        alloc: std.mem.Allocator,
        method: []const u8,
        url: []const u8,
    ) !void {
        self.method = try std.mem.Allocator.dupe(alloc, u8, method);
        self.url = try std.mem.Allocator.dupe(alloc, u8, url);
        try self.client.start(Impl, "127.0.0.1", 13370);
    }

    pub fn deinit(self: *XHR, alloc: std.mem.Allocator) void {
        alloc.destroy(self.client);
    }
};

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var common = [_]Case{
        .{ .src = 
        \\var nb = 0; var evt;
        \\function cbk(event) {
        \\evt = event;
        \\nb ++;
        \\}
        , .ex = "undefined" },
    };
    try checkCases(js_env, &common);

    var basic = [_]Case{
        .{ .src = "let xhr = new XHR()", .ex = "undefined" },
        .{ .src = "xhr.open('GET', 'http://example.com/test')", .ex = "undefined" },
        .{ .src = "xhr.method", .ex = "GET" },
        .{ .src = "xhr.url", .ex = "http://example.com/test" },
        .{ .src = "xhr.onload = cbk", .ex = 
        \\function cbk(event) {
        \\evt = event;
        \\nb ++;
        \\}
        }, // TODO
    };
    try checkCases(js_env, &basic);
}
