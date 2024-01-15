const std = @import("std");

const user_agent = "Lightpanda.io/1.0";

pub const Loader = struct {
    client: std.http.Client,

    pub const Response = struct {
        alloc: std.mem.Allocator,
        req: *std.http.Client.Request,

        pub fn deinit(self: *Response) void {
            self.req.deinit();
            self.alloc.destroy(self.req);
        }
    };

    pub fn init(alloc: std.mem.Allocator) Loader {
        return Loader{
            .client = std.http.Client{
                .allocator = alloc,
            },
        };
    }

    pub fn deinit(self: *Loader) void {
        self.client.deinit();
    }

    // the caller must deinit the FetchResult.
    pub fn fetch(self: *Loader, alloc: std.mem.Allocator, uri: std.Uri) !std.http.Client.FetchResult {
        var headers = try std.http.Headers.initList(alloc, &[_]std.http.Field{
            .{ .name = "User-Agent", .value = user_agent },
            .{ .name = "Accept", .value = "*/*" },
            .{ .name = "Accept-Language", .value = "en-US,en;q=0.5" },
        });
        defer headers.deinit();

        return try self.client.fetch(alloc, .{
            .location = .{ .uri = uri },
            .headers = headers,
            .payload = .none,
        });
    }

    // see
    // https://ziglang.org/documentation/master/std/#A;std:http.Client.fetch
    // for reference.
    // The caller is responsible for calling `deinit()` on the `Response`.
    pub fn get(self: *Loader, alloc: std.mem.Allocator, uri: std.Uri) !Response {
        var headers = try std.http.Headers.initList(alloc, &[_]std.http.Field{
            .{ .name = "User-Agent", .value = user_agent },
            .{ .name = "Accept", .value = "*/*" },
            .{ .name = "Accept-Language", .value = "en-US,en;q=0.5" },
        });
        defer headers.deinit();

        var resp = Response{
            .alloc = alloc,
            .req = try alloc.create(std.http.Client.Request),
        };
        errdefer alloc.destroy(resp.req);

        resp.req.* = try self.client.open(.GET, uri, headers, .{
            .handle_redirects = true, // TODO handle redirects manually
        });
        errdefer resp.req.deinit();

        try resp.req.send(.{});
        try resp.req.finish();
        try resp.req.wait();

        return resp;
    }
};

test "basic url fetch" {
    const alloc = std.testing.allocator;
    var loader = Loader.init(alloc);
    defer loader.deinit();

    var result = try loader.fetch(alloc, "https://en.wikipedia.org/wiki/Main_Page");
    defer result.deinit();

    try std.testing.expect(result.status == std.http.Status.ok);
}
